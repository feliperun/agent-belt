#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include <math.h>
#include "macos_shim.h"
#import "agents.h"

static const CGFloat mk_overlay_width = 252;
static const CGFloat mk_overlay_height = 78;
static BOOL mk_preview_mode;
static double mk_now(void) { return mk_monotonic_ns() / 1e9; }
static double mk_ease(double t) { t = fmax(0, fmin(1, t)); return t * t * (3 - 2 * t); }
static NSColor *mk_ink(CGFloat alpha) {
    return [NSColor colorWithSRGBRed:0.72 green:0.79 blue:0.96 alpha:alpha];
}
static void mk_label(NSString *text, NSPoint point, CGFloat size, NSColor *color) {
    [text drawAtPoint:point withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: color,
    }];
}

static void mk_status_ready(void);
static void mk_refresh_title(void);
static void mk_install_status_menu(void);
static int mk_attention;        // 0 nothing, 1 an agent finished, 2 an agent waits
static int mk_dictation_status; // mk_status_set: nonzero while dictating


@interface MKOverlayView : NSView
@property(nonatomic) NSInteger mode;
@property(nonatomic) double started, lastTick, phase;
@property(nonatomic) CGFloat level, releaseLevel;
@property(nonatomic) double signalPhase, motion, previousTarget;
@property(nonatomic) BOOL reducedMotion;
@property(nonatomic) BOOL command; // listening to a voice command, not dictation
@property(nonatomic, strong) NSTimer *animationTimer;
- (void)showMode:(NSInteger)mode;
- (void)stopAnimation;
- (void)updateAudio:(double)target elapsed:(double)dt;
@end

@implementation MKOverlayView
- (BOOL)isOpaque { return NO; }
- (void)showMode:(NSInteger)mode {
    self.releaseLevel = self.level;
    self.mode = mode;
    self.started = self.lastTick = mk_now();
    self.reducedMotion = [NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
    if (!self.animationTimer) {
        __weak MKOverlayView *weakSelf = self;
        self.animationTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
            MKOverlayView *view = weakSelf;
            if (!view) { [timer invalidate]; return; }
            const double now = mk_now();
            const double dt = fmin(0.1, now - view.lastTick);
            view.lastTick = now;
            view.phase += dt;
            const double previewTime = now - view.started;
            const double target = view.mode == 1
                ? (mk_preview_mode
                    ? 0.04 + (0.25 + 0.6 * mk_ease(previewTime / 3)) * pow(fmax(0, sin(previewTime * 16)), 0.6)
                    : mk_audio_level_permille() / 1000.0)
                : 0;
            [view updateAudio:target elapsed:dt];
            [view setNeedsDisplay:YES];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
    }
    [self setNeedsDisplay:YES];
}
- (void)updateAudio:(double)target elapsed:(double)dt {
    // Fast attack follows syllables; the short release leaves space between words.
    self.level += (target - self.level) * (1 - exp(-dt / (target > self.level ? 0.016 : 0.085)));
    const double onset = fmax(0, target - self.previousTarget - 0.025);
    self.motion = fmax(fmin(1, onset * 2.5), self.motion * exp(-dt / 0.1));
    self.previousTarget = target;
    // Louder speech travels faster; successive attacks add brief bursts of motion.
    self.signalPhase += dt * (2 + self.level * 10 + self.motion * 14);
}
- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    self.level = 0;
    self.motion = self.previousTarget = 0;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2)
                                                       xRadius:23 yRadius:23];
    NSGradient *surface = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.115 green:0.125 blue:0.16 alpha:0.98]
                  endingColor:[NSColor colorWithSRGBRed:0.065 green:0.075 blue:0.1 alpha:0.98]];
    [surface drawInBezierPath:shell angle:-90];
    [mk_ink(0.16) setStroke];
    shell.lineWidth = 0.75;
    [shell stroke];

    const double t = self.reducedMotion ? 0 : self.phase;
    const double morph = self.mode == 2 ? (self.reducedMotion ? 1 : mk_ease((mk_now() - self.started) / 0.7)) : 0;
    [self drawCore:t morph:morph];
    if (self.mode == 3) {
        mk_label(@"Não foi possível transcrever", NSMakePoint(65, 43), 10.5, mk_ink(0.95));
        mk_label(@"Veja o erro no terminal", NSMakePoint(65, 24), 10, mk_ink(0.5));
        return;
    }
    mk_label(self.mode == 1 ? (self.command ? @"Comando de voz" : @"Ouvindo") : (self.command ? @"Entendendo" : @"Transcrevendo"),
             NSMakePoint(65, 44), 12, mk_ink(0.92));
    [self drawSignal:t morph:morph];
}
- (void)drawCore:(double)t morph:(double)morph {
    const NSPoint center = NSMakePoint(34, 39);
    const double energy = sqrt(fmax(0, self.level));
    const double radius = 11 + energy * 2.8;
    // A low-contrast halo and three drifting contours share the same center.
    NSGradient *halo = [[NSGradient alloc] initWithStartingColor:mk_ink(0.11 + energy * 0.05)
                                                   endingColor:mk_ink(0)];
    [halo drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(12, 17, 44, 44)]
 relativeCenterPosition:NSZeroPoint];
    for (NSUInteger layer = 0; layer < 3; layer++) {
        NSBezierPath *contour = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i <= 90; i++) {
            const double a = i * 2 * M_PI / 90;
            const double ripple = sin(a * 3 + t * 1.25 + layer * 1.7) * (1.1 + energy * 2) * (1 - morph * 0.6);
            const double r = radius + layer * 1.3 + ripple;
            const double turn = t * (0.12 + morph * 0.25) + layer * 0.25;
            NSPoint point = NSMakePoint(center.x + cos(a + turn) * r,
                                        center.y + sin(a + turn) * r * 0.88);
            if (i == 0) [contour moveToPoint:point]; else [contour lineToPoint:point];
        }
        [[NSColor colorWithSRGBRed:0.58 + layer * 0.12 green:0.76 - layer * 0.05
                              blue:0.96 alpha:0.58 - layer * 0.12] setStroke];
        contour.lineWidth = 1.05;
        [contour stroke];
    }
    const double angle = t * (self.mode == 2 ? 1.5 : 0.5);
    NSPoint light = NSMakePoint(center.x + cos(angle) * radius,
                                center.y + sin(angle) * radius * 0.88);
    [mk_ink(0.88) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(light.x - 1.4, light.y - 1.4, 2.8, 2.8)] fill];
}
- (void)drawSignal:(double)t morph:(double)morph {
    const double energy = fmax(0, self.mode == 1 ? self.level : self.releaseLevel);
    const double travel = self.reducedMotion ? 0 : self.signalPhase;
    const double detail = self.reducedMotion ? 0 : self.motion;
    // Continuous ribbons settle into the typographic baseline; no random glyph flicker.
    for (NSUInteger layer = 0; layer < 3; layer++) {
        NSBezierPath *wave = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i <= 90; i++) {
            const double u = i / 90.0;
            const double envelope = pow(sin(u * M_PI), 1.5);
            const double amplitude = (0.5 + energy * 14.5) * envelope * (1 - morph);
            const double y = 28 + amplitude * (sin(u * (4 + detail * 2) * M_PI - travel + layer * 0.6) * 0.72 +
                                              sin(u * 9 * M_PI + travel * 0.6) * 0.28);
            const double inset = 28 * mk_ease(morph * 2);
            const NSPoint point = NSMakePoint(66 + inset + u * (160 - inset), y);
            if (i == 0) [wave moveToPoint:point]; else [wave lineToPoint:point];
        }
        [mk_ink((0.7 - layer * 0.19) * (1 - morph)) setStroke];
        wave.lineWidth = 1.2;
        [wave stroke];
    }
    if (morph > 0) [self drawCipher:t opacity:mk_ease((morph - 0.25) / 0.75)];

}
// While the transcription is on its way, a line of glyphs keeps deciphering
// into a phrase: letters settle left to right, hold, then scramble again.
- (void)drawCipher:(double)t opacity:(double)opacity {
    NSString *phrase = self.command ? @"decifrando o pedido" : @"decifrando sua voz";
    static NSString *const pool = @"abcdefghijklmnopqrstuvwxyz0123456789#$%&*+=<>/\\|?!";
    NSDictionary *resolved = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
                               NSForegroundColorAttributeName: mk_ink(opacity * 0.85)};
    NSDictionary *scrambled = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName: mk_ink(opacity * 0.4)};
    if (self.reducedMotion) {
        [phrase drawAtPoint:NSMakePoint(66, 18) withAttributes:resolved];
        return;
    }
    const NSUInteger count = phrase.length;
    const double cycle = 2.8, local = fmod(t, cycle) / cycle;
    // 0-45%: settle left to right; 45-75%: hold; 75-100%: scramble left to right.
    const double settled = local < 0.45 ? local / 0.45 * count : local < 0.75 ? count : (1 - (local - 0.75) / 0.25) * count;
    const long tick = (long)floor(t * 18); // glyphs change 18 times a second
    CGFloat x = 66;
    for (NSUInteger i = 0; i < count; i++) {
        unichar target = [phrase characterAtIndex:i];
        const BOOL fixed = i < settled || target == ' ';
        NSString *glyph;
        if (fixed) glyph = [NSString stringWithCharacters:&target length:1];
        else {
            const unsigned long h = (unsigned long)(i * 2654435761u) ^ (unsigned long)(tick * 40503u + i * 97u);
            unichar c = [pool characterAtIndex:(h >> 3) % pool.length];
            glyph = [NSString stringWithCharacters:&c length:1];
        }
        [glyph drawAtPoint:NSMakePoint(x, 18) withAttributes:fixed ? resolved : scrambled];
        x += 7.4;
    }
}
@end

static NSStatusItem *mk_status_item;
static NSPanel *mk_overlay_panel;
static MKOverlayView *mk_overlay_view;
static NSTimer *mk_hide_timer;
static NSTimer *mk_show_timer;
static CFRunLoopRef mk_status_runloop;

static void mk_position_overlay(void) {
    NSScreen *screen = [NSScreen mainScreen];
    const NSPoint mouse = [NSEvent mouseLocation];
    for (NSScreen *candidate in [NSScreen screens]) {
        if (NSPointInRect(mouse, candidate.frame)) { screen = candidate; break; }
    }
    const NSRect visible = screen.visibleFrame;
    [mk_overlay_panel setFrame:NSMakeRect(NSMaxX(visible) - mk_overlay_width - 18,
                                          NSMaxY(visible) - mk_overlay_height - 14,
                                          mk_overlay_width, mk_overlay_height) display:NO];
}

static void mk_order_out(void) {
    [mk_show_timer invalidate];
    mk_show_timer = nil;
    [mk_hide_timer invalidate];
    mk_hide_timer = nil;
    [mk_overlay_panel orderOut:nil];
    [mk_overlay_view stopAnimation];
    mk_status_ready();
}

// Completion is emitted only after the panel has been removed from the screen.
static void mk_fade_out(void (^completion)(void)) {
    [mk_show_timer invalidate];
    mk_show_timer = nil;
    [mk_hide_timer invalidate];
    mk_hide_timer = nil;
    if (!mk_overlay_panel.isVisible || mk_overlay_view.reducedMotion) {
        mk_order_out();
        completion();
        return;
    }
    const double started = mk_now();
    const CGFloat initialAlpha = mk_overlay_panel.alphaValue;
    mk_hide_timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        const double progress = (mk_now() - started) / 0.12;
        mk_overlay_panel.alphaValue = initialAlpha * (1 - mk_ease(progress));
        if (progress >= 1) {
            [timer invalidate];
            mk_order_out();
            completion();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:mk_hide_timer forMode:NSRunLoopCommonModes];
}

static void mk_reveal_overlay(void) {
    if (mk_overlay_panel.isVisible) return;
    mk_position_overlay();
    mk_overlay_panel.alphaValue = mk_overlay_view.reducedMotion ? 1 : 0;
    [mk_overlay_panel orderFrontRegardless];
    if (mk_overlay_view.reducedMotion) return;
    const double started = mk_now();
    mk_show_timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        const double progress = (mk_now() - started) / 0.16;
        mk_overlay_panel.alphaValue = mk_ease(progress);
        if (progress >= 1) { [timer invalidate]; mk_show_timer = nil; }
    }];
    [[NSRunLoop mainRunLoop] addTimer:mk_show_timer forMode:NSRunLoopCommonModes];
}

int mk_status_dismiss(void) {
    if (!mk_status_runloop) return 0;
    if ([NSThread isMainThread]) { mk_order_out(); return 0; }
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        mk_fade_out(^{ dispatch_semaphore_signal(finished); });
    });
    CFRunLoopWakeUp(mk_status_runloop);
    // On timeout the caller must not inject text into a still-visible overlay.
    return dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0 ? 0 : -1;
}

void mk_app_run(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp finishLaunching];
    }
    [NSApp run];
}

int mk_status_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        mk_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        if (!mk_status_item) return -1;
        mk_status_ready();
        mk_install_status_menu();
        mk_overlay_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, mk_overlay_width, mk_overlay_height)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        if (!mk_overlay_panel) return -2;
        mk_overlay_panel.opaque = NO;
        mk_overlay_panel.backgroundColor = [NSColor clearColor];
        mk_overlay_panel.hasShadow = YES;
        mk_overlay_panel.level = NSStatusWindowLevel;
        mk_overlay_panel.ignoresMouseEvents = YES;
        mk_overlay_panel.hidesOnDeactivate = NO;
        mk_overlay_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                              NSWindowCollectionBehaviorFullScreenAuxiliary;
        mk_overlay_view = [[MKOverlayView alloc] initWithFrame:NSMakeRect(0, 0, mk_overlay_width, mk_overlay_height)];
        mk_overlay_panel.contentView = mk_overlay_view;
        mk_status_runloop = CFRunLoopGetCurrent();
        CFRetain(mk_status_runloop);
        return 0;
    }
}

// Discreet start/stop cues for recording, like macOS Dictation's.
void mk_play_cue(int cue) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSSound *sound = [[NSSound soundNamed:cue == 0 ? @"Tink" : @"Pop"] copy];
        sound.volume = 0.25;
        [sound play];
    });
}

void mk_status_set(int status) {
    mk_led_status(status);
    if (!mk_status_runloop) return;
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            [mk_hide_timer invalidate];
            mk_hide_timer = nil;
            mk_dictation_status = status;
            if (status == 0) { mk_order_out(); return; }
            // A voice command listens exactly like dictation; only the words differ.
            if (status == 4 || status == 1) mk_overlay_view.command = status == 4;
            [mk_overlay_view showMode:status == 4 ? 1 : status];
            mk_reveal_overlay();
            switch (status) {
                case 4:
                    mk_refresh_title();
                    mk_status_item.button.toolTip = @"Agent Belt ouvindo um comando";
                    break;
                case 1:
                    mk_refresh_title();
                    mk_status_item.button.toolTip = @"Agent Belt gravando";
                    break;
                case 2:
                    mk_refresh_title();
                    mk_status_item.button.toolTip = @"Agent Belt transcrevendo";
                    break;
                case 3:
                    mk_refresh_title();
                    mk_status_item.button.toolTip = @"Agent Belt: erro, consulte o terminal";
                    mk_hide_timer = [NSTimer timerWithTimeInterval:2.2 repeats:NO block:^(NSTimer *timer) {
                        (void)timer;
                        mk_fade_out(^{});
                    }];
                    [[NSRunLoop mainRunLoop] addTimer:mk_hide_timer forMode:NSRunLoopCommonModes];
                    break;
            }
        }
    });
    CFRunLoopWakeUp(mk_status_runloop);
}

int mk_status_preview(void) {
    const int result = mk_status_init();
    if (result != 0) return result;
    mk_preview_mode = YES;
    mk_status_set(1);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 4, false);
    mk_status_set(2);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 4, false);
    mk_fade_out(^{});
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    return 0;
}

// Agent switch HUD: which agent took focus and why, in the overlay's corner.
@interface MKHudView : NSView
@property(nonatomic, copy) NSString *title, *detail;
@property(nonatomic) int tone;
@end

@implementation MKHudView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:19 yRadius:19];
    NSGradient *surface = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.115 green:0.125 blue:0.16 alpha:0.98]
                  endingColor:[NSColor colorWithSRGBRed:0.065 green:0.075 blue:0.1 alpha:0.98]];
    [surface drawInBezierPath:shell angle:-90];
    [mk_ink(0.16) setStroke];
    shell.lineWidth = 0.75;
    [shell stroke];
    // Red waits for you, green finished, blue works, grey idles (as the key LEDs).
    NSColor *dot = @[mk_ink(0.35),
                     [NSColor colorWithSRGBRed:0.45 green:0.66 blue:1.0 alpha:1],
                     [NSColor colorWithSRGBRed:0.42 green:0.86 blue:0.6 alpha:1],
                     [NSColor colorWithSRGBRed:1.0 green:0.42 blue:0.38 alpha:1]][MAX(0, MIN(3, self.tone))];
    const NSRect dotRect = NSMakeRect(20, NSMidY(self.bounds) - 4, 8, 8);
    [[dot colorWithAlphaComponent:0.22] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dotRect, -4, -4)] fill];
    [dot setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
    NSMutableParagraphStyle *clip = [NSMutableParagraphStyle new];
    clip.lineBreakMode = NSLineBreakByTruncatingTail;
    const CGFloat width = NSWidth(self.bounds) - 58;
    [self.title drawInRect:NSMakeRect(42, 29, width, 18) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: mk_ink(0.95), NSParagraphStyleAttributeName: clip}];
    [self.detail drawInRect:NSMakeRect(42, 12, width, 16) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: mk_ink(0.55), NSParagraphStyleAttributeName: clip}];
}
@end

static NSPanel *mk_hud_panel;
static MKHudView *mk_hud_view;
static NSTimer *mk_hud_timer;

static void mk_hud_fade(double from, double to, double duration, void (^done)(void)) {
    [mk_hud_timer invalidate];
    const double started = mk_now();
    const BOOL instant = [NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
    mk_hud_timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        const double progress = instant ? 1 : (mk_now() - started) / duration;
        mk_hud_panel.alphaValue = from + (to - from) * mk_ease(progress);
        if (progress >= 1) { [timer invalidate]; mk_hud_timer = nil; if (done) done(); }
    }];
    [[NSRunLoop mainRunLoop] addTimer:mk_hud_timer forMode:NSRunLoopCommonModes];
}

void mk_hud_show(const char *title, const char *detail, int tone) {
    if (!mk_status_runloop) return; // CLI: no UI
    NSString *titleText = @(title), *detailText = @(detail);
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            if (mk_overlay_panel.isVisible) return; // recording/transcribing wins the corner
            const CGFloat width = 300, height = 58;
            if (!mk_hud_panel) {
                mk_hud_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                    styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered defer:NO];
                mk_hud_panel.opaque = NO;
                mk_hud_panel.backgroundColor = [NSColor clearColor];
                mk_hud_panel.hasShadow = YES;
                mk_hud_panel.level = NSStatusWindowLevel;
                mk_hud_panel.ignoresMouseEvents = YES;
                mk_hud_panel.hidesOnDeactivate = NO;
                mk_hud_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                  NSWindowCollectionBehaviorFullScreenAuxiliary;
                mk_hud_view = [[MKHudView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
                mk_hud_panel.contentView = mk_hud_view;
            }
            mk_hud_view.title = titleText;
            mk_hud_view.detail = detailText;
            mk_hud_view.tone = tone;
            [mk_hud_view setNeedsDisplay:YES];
            NSScreen *screen = [NSScreen mainScreen];
            const NSPoint mouse = [NSEvent mouseLocation];
            for (NSScreen *candidate in [NSScreen screens])
                if (NSPointInRect(mouse, candidate.frame)) { screen = candidate; break; }
            const NSRect visible = screen.visibleFrame;
            [mk_hud_panel setFrame:NSMakeRect(NSMaxX(visible) - width - 18, NSMaxY(visible) - height - 14, width, height) display:NO];
            const double from = mk_hud_panel.isVisible ? mk_hud_panel.alphaValue : 0;
            mk_hud_panel.alphaValue = from;
            [mk_hud_panel orderFrontRegardless];
            mk_hud_fade(from, 1, 0.12, ^{
                mk_hud_timer = [NSTimer timerWithTimeInterval:1.3 repeats:NO block:^(NSTimer *timer) {
                    (void)timer;
                    mk_hud_fade(1, 0, 0.22, ^{ [mk_hud_panel orderOut:nil]; });
                }];
                [[NSRunLoop mainRunLoop] addTimer:mk_hud_timer forMode:NSRunLoopCommonModes];
            });
        }
    });
    CFRunLoopWakeUp(mk_status_runloop);
}

// Agent menu: every agent with its state; the selection moves with the key.
static NSColor *mk_tone(int tone) {
    return @[mk_ink(0.35),
             [NSColor colorWithSRGBRed:0.45 green:0.66 blue:1.0 alpha:1],
             [NSColor colorWithSRGBRed:0.42 green:0.86 blue:0.6 alpha:1],
             [NSColor colorWithSRGBRed:1.0 green:0.42 blue:0.38 alpha:1]][MAX(0, MIN(3, tone))];
}

@interface MKMenuView : NSView
@property(nonatomic, copy) NSArray<NSString *> *labels, *details;
@property(nonatomic, copy) NSArray<NSNumber *> *tones;
@property(nonatomic, copy) NSString *footer;
@property(nonatomic) NSInteger selected;
@property(nonatomic) BOOL clickable;
@end

static const CGFloat mk_menu_width = 380, mk_menu_row = 48, mk_menu_header = 34, mk_menu_pad = 8, mk_menu_footer = 28;

static CGFloat mk_menu_height(NSUInteger rows, BOOL footer) {
    return mk_menu_header + rows * mk_menu_row + (footer ? mk_menu_footer : 0) + mk_menu_pad;
}

@implementation MKMenuView
- (BOOL)isOpaque { return NO; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent *)event {
    if (!self.clickable) return;
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const NSInteger row = (NSInteger)floor((point.y - mk_menu_header) / mk_menu_row);
    if (row >= 0 && row < (NSInteger)self.labels.count) mk_agents_menu_open((int)row);
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:18 yRadius:18];
    NSGradient *surface = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.115 green:0.125 blue:0.16 alpha:0.98]
                  endingColor:[NSColor colorWithSRGBRed:0.065 green:0.075 blue:0.1 alpha:0.98]];
    [surface drawInBezierPath:shell angle:90];
    [mk_ink(0.16) setStroke];
    shell.lineWidth = 0.75;
    [shell stroke];

    NSMutableParagraphStyle *clip = [NSMutableParagraphStyle new];
    clip.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableParagraphStyle *right = [clip mutableCopy];
    right.alignment = NSTextAlignmentRight;
    [@"Agentes" drawInRect:NSMakeRect(18, 11, 120, 16) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: mk_ink(0.6)}];
    NSString *hint = self.clickable ? @"clique para abrir" : @"toque: próximo · 2× ou ↩: abrir";
    [hint drawInRect:NSMakeRect(130, 12, mk_menu_width - 148, 14) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: mk_ink(0.38), NSParagraphStyleAttributeName: right}];

    NSArray *states = @[@"ocioso", @"trabalhando", @"terminou", @"aguardando você"];
    for (NSUInteger i = 0; i < self.labels.count; i++) {
        const CGFloat y = mk_menu_header + i * mk_menu_row;
        const int tone = self.tones[i].intValue;
        const BOOL selected = (NSInteger)i == self.selected;
        if (selected) {
            [mk_ink(0.1) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(mk_menu_pad, y + 2, mk_menu_width - 2 * mk_menu_pad, mk_menu_row - 4)
                                             xRadius:10 yRadius:10] fill];
        }
        NSColor *dot = mk_tone(tone);
        const NSRect dotRect = NSMakeRect(20, y + 12, 8, 8);
        if (tone >= 2) {
            [[dot colorWithAlphaComponent:0.22] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dotRect, -4, -4)] fill];
        }
        [dot setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
        [self.labels[i] drawInRect:NSMakeRect(40, y + 7, mk_menu_width - 160, 17) withAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:selected ? NSFontWeightSemibold : NSFontWeightMedium],
            NSForegroundColorAttributeName: mk_ink(selected ? 0.97 : 0.8), NSParagraphStyleAttributeName: clip}];
        [states[MAX(0, MIN(3, tone))] drawInRect:NSMakeRect(mk_menu_width - 128, y + 8, 108, 15) withAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: tone >= 2 ? dot : mk_ink(0.42), NSParagraphStyleAttributeName: right}];
        [self.details[i] drawInRect:NSMakeRect(40, y + 26, mk_menu_width - 60, 15) withAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: mk_ink(selected ? 0.58 : 0.44), NSParagraphStyleAttributeName: clip}];
    }
    if (self.footer.length) {
        const CGFloat y = mk_menu_header + self.labels.count * mk_menu_row + 6;
        [mk_ink(0.1) setFill];
        NSRectFill(NSMakeRect(18, y, mk_menu_width - 36, 0.75));
        [self.footer drawInRect:NSMakeRect(18, y + 7, mk_menu_width - 36, 15) withAttributes:@{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: mk_ink(0.5), NSParagraphStyleAttributeName: clip}];
    }
}
@end

static NSPanel *mk_menu_panel;
static MKMenuView *mk_menu_view;
static id mk_menu_outside_monitor;

void mk_menu_show(const char *const *labels, const char *const *details, const int *tones, int count,
                  int selected, const char *footer, int clickable) {
    if (!mk_status_runloop) return;
    NSMutableArray *labelList = [NSMutableArray array], *detailList = [NSMutableArray array], *toneList = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        [labelList addObject:@(labels[i])];
        [detailList addObject:@(details[i])];
        [toneList addObject:@(tones[i])];
    }
    NSString *footerText = footer ? @(footer) : nil;
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            const CGFloat height = mk_menu_height((NSUInteger)count, footerText.length > 0);
            if (!mk_menu_panel) {
                mk_menu_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, mk_menu_width, height)
                    styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered defer:NO];
                mk_menu_panel.opaque = NO;
                mk_menu_panel.backgroundColor = [NSColor clearColor];
                mk_menu_panel.hasShadow = YES;
                mk_menu_panel.level = NSStatusWindowLevel;
                mk_menu_panel.hidesOnDeactivate = NO;
                mk_menu_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                   NSWindowCollectionBehaviorFullScreenAuxiliary;
                mk_menu_view = [[MKMenuView alloc] initWithFrame:NSMakeRect(0, 0, mk_menu_width, height)];
                mk_menu_panel.contentView = mk_menu_view;
            }
            [mk_hud_panel orderOut:nil]; // the menu already says it all
            mk_menu_view.labels = labelList;
            mk_menu_view.details = detailList;
            mk_menu_view.tones = toneList;
            mk_menu_view.footer = footerText;
            mk_menu_view.selected = selected;
            mk_menu_view.clickable = clickable != 0;
            mk_menu_panel.ignoresMouseEvents = !clickable;
            // A click anywhere else closes a mouse-opened menu.
            if (clickable && !mk_menu_outside_monitor)
                mk_menu_outside_monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
                                                                                 handler:^(NSEvent *event) { (void)event; mk_agents_menu_close(); }];
            [mk_menu_view setNeedsDisplay:YES];
            NSScreen *screen = [NSScreen mainScreen];
            const NSPoint mouse = [NSEvent mouseLocation];
            for (NSScreen *candidate in [NSScreen screens])
                if (NSPointInRect(mouse, candidate.frame)) { screen = candidate; break; }
            const NSRect visible = screen.visibleFrame;
            [mk_menu_panel setFrame:NSMakeRect(NSMaxX(visible) - mk_menu_width - 18, NSMaxY(visible) - height - 14,
                                               mk_menu_width, height) display:YES];
            mk_menu_panel.alphaValue = 1;
            [mk_menu_panel orderFrontRegardless];
        }
    });
    CFRunLoopWakeUp(mk_status_runloop);
}

void mk_menu_hide(void) {
    if (!mk_status_runloop) return;
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        [mk_menu_panel orderOut:nil];
        if (mk_menu_outside_monitor) { [NSEvent removeMonitor:mk_menu_outside_monitor]; mk_menu_outside_monitor = nil; }
    });
    CFRunLoopWakeUp(mk_status_runloop);
}

// Menu bar icon: a belt whose buckle light shows the state. Idle it is a
// template image (tinted for light/dark bars); with a state the light takes
// the color: orange recording (like macOS's microphone indicator), cyan
// transcribing, red an agent waits for you, green one finished, yellow error.
static NSImage *mk_belt_icon(NSColor *light) {
    NSImage *icon = [NSImage imageWithSize:NSMakeSize(22, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        NSColor *ink = light ? NSColor.labelColor : NSColor.blackColor;
        [ink set];
        NSBezierPath *strap = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 6.4, 21, 3.2) xRadius:1.6 yRadius:1.6];
        NSBezierPath *buckle = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(6, 1.5, 10, 13) xRadius:3.4 yRadius:3.4];
        // The strap passes behind the buckle: cut it where the buckle sits.
        [NSGraphicsContext saveGraphicsState];
        NSBezierPath *clip = [NSBezierPath bezierPathWithRect:rect];
        [clip appendBezierPath:[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(buckle.bounds, -1.2, -1.2) xRadius:4.4 yRadius:4.4]];
        clip.windingRule = NSWindingRuleEvenOdd;
        [clip addClip];
        [strap fill];
        [NSGraphicsContext restoreGraphicsState];
        buckle.lineWidth = 1.7;
        [buckle stroke];
        NSRect lamp = NSMakeRect(8.6, 5.6, 4.8, 4.8);
        if (light) { [light setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(lamp, -0.4, -0.4)] fill]; }
        else [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(lamp, 0.9, 0.9)] fill];
        return YES;
    }];
    icon.template = light == nil;
    return icon;
}

static void mk_refresh_title(void) {
    NSColor *light = nil;
    NSString *tip = @"Agent Belt: nada pendente";
    switch (mk_dictation_status) {
    case 1: light = NSColor.systemOrangeColor; tip = @"Agent Belt gravando"; break;
    case 4: light = NSColor.systemOrangeColor; tip = @"Agent Belt ouvindo um comando"; break;
    case 2: light = NSColor.systemTealColor; tip = @"Agent Belt transcrevendo"; break;
    case 3: light = NSColor.systemYellowColor; tip = @"Agent Belt: erro, veja o log"; break;
    default:
        if (mk_attention == 2) { light = NSColor.systemRedColor; tip = @"Agent Belt: um agente aguarda você"; }
        else if (mk_attention == 1) { light = NSColor.systemGreenColor; tip = @"Agent Belt: um agente terminou"; }
    }
    mk_status_item.button.image = mk_belt_icon(light);
    mk_status_item.button.title = @"";
    mk_status_item.button.toolTip = tip;
}

// Click: a native menu with the agents (click opens one), a way to create an
// agent by typing, quotas, updates and the usual housekeeping.
@interface MKStatusMenu : NSObject <NSMenuDelegate>
@end
@implementation MKStatusMenu
- (NSMenuItem *)add:(NSMenu *)menu title:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    const char *update = mk_update_available();
    NSMenuItem *header = [menu addItemWithTitle:[NSString stringWithFormat:@"Agent Belt %s", mk_app_version()] action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    NSArray<NSDictionary *> *agents = MKAgentsSnapshot();
    NSArray *dots = @[@"⚪", @"🔵", @"🟢", @"🔴"], *states = @[@"ocioso", @"trabalhando", @"terminou", @"aguardando você"];
    if (!agents.count) [menu addItemWithTitle:@"Nenhum agente rodando" action:nil keyEquivalent:@""].enabled = NO;
    for (NSDictionary *agent in agents) {
        const int tone = MAX(0, MIN(3, [agent[@"tone"] intValue]));
        NSMenuItem *item = [self add:menu title:[NSString stringWithFormat:@"%@  %@", dots[tone], agent[@"title"]] action:@selector(openAgent:)];
        item.representedObject = agent[@"key"];
        item.toolTip = [NSString stringWithFormat:@"%@ · %@", states[tone], agent[@"detail"]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self add:menu title:@"Novo agente…" action:@selector(newAgent:)];
    [self add:menu title:@"Menu flutuante de agentes   ⌃⌥Espaço" action:@selector(floatingMenu:)];
    NSString *quota = MKAgentsQuotaLine();
    if (quota) {
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItemWithTitle:quota action:nil keyEquivalent:@""].enabled = NO;
    }
    [menu addItem:NSMenuItem.separatorItem];
    if (update) [self add:menu title:[NSString stringWithFormat:@"Atualizar para %s", update] action:@selector(installUpdate:)];
    else [self add:menu title:@"Verificar atualizações" action:@selector(checkUpdates:)];
    [self add:menu title:@"Permissões…" action:@selector(permissions:)];
    [self add:menu title:@"Abrir log" action:@selector(openLog:)];
}
- (void)openAgent:(NSMenuItem *)item { MKAgentsOpenKey(item.representedObject); }
- (void)floatingMenu:(id)sender { (void)sender; mk_agents_menu_click(); }
- (void)newAgent:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Novo agente";
    alert.informativeText = @"Descreva o agente, como diria em voz alta. Ex.: no windows com codex no coreum, investigar o login.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
    field.placeholderString = @"crie um agente aqui com claude no agent-belt para…";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Criar"];
    [alert addButtonWithTitle:@"Cancelar"];
    [NSApp activateIgnoringOtherApps:YES];
    alert.window.initialFirstResponder = field;
    if ([alert runModal] == NSAlertFirstButtonReturn && field.stringValue.length)
        mk_agents_voice_command(field.stringValue.UTF8String);
}
- (void)checkUpdates:(id)sender { (void)sender; mk_update_check_now(); }
- (void)installUpdate:(id)sender { (void)sender; mk_update_run(mk_update_available()); }
- (void)permissions:(id)sender {
    (void)sender;
    mk_open_privacy("ListenEvent");
}
- (void)openLog:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/agent-belt.log"]]];
}
@end

static void mk_install_status_menu(void) {
    static MKStatusMenu *controller;
    controller = [MKStatusMenu new];
    NSMenu *menu = [NSMenu new];
    menu.delegate = controller;
    mk_status_item.menu = menu;
}

void mk_status_attention(int attention) {
    if (!mk_status_runloop) return;
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        mk_attention = attention;
        mk_refresh_title();
    });
    CFRunLoopWakeUp(mk_status_runloop);
}


static void mk_status_ready(void) {
    mk_dictation_status = 0;
    mk_refresh_title();
}
