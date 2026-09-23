#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include <math.h>
#include "macos_shim.h"

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

@interface MKOverlayView : NSView
@property(nonatomic) NSInteger mode;
@property(nonatomic) double started, lastTick, phase;
@property(nonatomic) CGFloat level, releaseLevel;
@property(nonatomic) BOOL reducedMotion;
@property(nonatomic, strong) NSTimer *animationTimer;
- (void)showMode:(NSInteger)mode;
- (void)stopAnimation;
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
            const double target = view.mode == 1
                ? (mk_preview_mode ? 0.24 + 0.2 * sin(now * 3) : mk_audio_level_permille() / 1000.0)
                : 0;
            view.level += (target - view.level) * (1 - exp(-dt / (target > view.level ? 0.055 : 0.19)));
            [view setNeedsDisplay:YES];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
    }
    [self setNeedsDisplay:YES];
}
- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    self.level = 0;
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
    mk_label(self.mode == 1 ? @"Ouvindo" : @"Transcrevendo", NSMakePoint(65, 44), 12, mk_ink(0.92));
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
    const double energy = sqrt(fmax(0, self.mode == 1 ? self.level : self.releaseLevel));
    // Continuous ribbons settle into the typographic baseline; no random glyph flicker.
    for (NSUInteger layer = 0; layer < 3; layer++) {
        NSBezierPath *wave = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i <= 90; i++) {
            const double u = i / 90.0;
            const double envelope = pow(sin(u * M_PI), 1.5);
            const double amplitude = (1 + energy * 10) * envelope * (1 - morph);
            const double y = 28 + amplitude * (sin(u * 3 * M_PI - t * 3.6 + layer * 0.6) * 0.72 +
                                              sin(u * 7 * M_PI + t * 1.7) * 0.28);
            const double inset = 28 * mk_ease(morph * 2);
            const NSPoint point = NSMakePoint(66 + inset + u * (160 - inset), y);
            if (i == 0) [wave moveToPoint:point]; else [wave lineToPoint:point];
        }
        [mk_ink((0.7 - layer * 0.19) * (1 - morph)) setStroke];
        wave.lineWidth = 1.2;
        [wave stroke];
    }
    if (morph > 0) {
        const double textOpacity = mk_ease((morph - 0.25) / 0.75);
        mk_label(@"Aa", NSMakePoint(66, 19 + (1 - morph) * 4), 13, mk_ink(textOpacity * 0.65));
        const CGFloat lengths[] = { 29, 18, 35, 21 };
        CGFloat x = 94;
        for (NSUInteger i = 0; i < 4; i++) {
            const double glow = self.reducedMotion ? 0.55 : 0.4 + 0.2 * (0.5 + 0.5 * sin(t * 2.5 - i * 0.8));
            [mk_ink(textOpacity * glow) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, 27, lengths[i] * morph, 2.5)
                                           xRadius:1.25 yRadius:1.25] fill];
            x += lengths[i] + 7;
        }
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
    mk_status_item.button.title = @"⌨︎";
    mk_status_item.button.toolTip = @"Minikeyboard pronto";
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

int mk_status_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        mk_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        if (!mk_status_item) return -1;
        mk_status_item.button.title = @"⌨︎";
        mk_status_item.button.toolTip = @"Minikeyboard pronto";
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

void mk_status_set(int status) {
    if (!mk_status_runloop) return;
    CFRunLoopPerformBlock(mk_status_runloop, kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            [mk_hide_timer invalidate];
            mk_hide_timer = nil;
            if (status == 0) { mk_order_out(); return; }
            [mk_overlay_view showMode:status];
            mk_reveal_overlay();
            switch (status) {
                case 1:
                    mk_status_item.button.title = @"🔴 REC";
                    mk_status_item.button.toolTip = @"Minikeyboard gravando";
                    break;
                case 2:
                    mk_status_item.button.title = @"⏳";
                    mk_status_item.button.toolTip = @"Minikeyboard transcrevendo";
                    break;
                case 3:
                    mk_status_item.button.title = @"⚠︎";
                    mk_status_item.button.toolTip = @"Minikeyboard: erro, consulte o terminal";
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
