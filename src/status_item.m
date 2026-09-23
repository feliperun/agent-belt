#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>

#include <math.h>
#include "macos_shim.h"

static const CGFloat mk_overlay_width = 320;
static const CGFloat mk_overlay_height = 94;
static BOOL mk_preview_mode;

static void mk_draw_label(NSString *text, CGFloat x, CGFloat y, NSFont *font, NSColor *color) {
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    }];
}

@interface MKOverlayView : NSView
@property(nonatomic) NSInteger mode;
@property(nonatomic) CGFloat smoothedLevel;
@property(nonatomic) CFAbsoluteTime stateStarted;
@property(nonatomic) NSUInteger frameNumber;
@property(nonatomic, strong) NSTimer *animationTimer;
- (void)showMode:(NSInteger)mode;
- (void)stopAnimation;
@end

@implementation MKOverlayView

- (BOOL)isOpaque { return NO; }

- (void)showMode:(NSInteger)mode {
    self.mode = mode;
    self.stateStarted = CFAbsoluteTimeGetCurrent();
    self.frameNumber = 0;
    if (!self.animationTimer) {
        __weak MKOverlayView *weakSelf = self;
        self.animationTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) {
            MKOverlayView *view = weakSelf;
            if (!view) {
                [timer invalidate];
                return;
            }
            if (view.mode == 1) {
                const CGFloat level = mk_preview_mode
                    ? 0.35 + 0.3 * sin(view.frameNumber * 0.18)
                    : mk_audio_level_permille() / 1000.0;
                const CGFloat speed = level > view.smoothedLevel ? 0.42 : 0.18;
                view.smoothedLevel += (level - view.smoothedLevel) * speed;
            } else {
                view.smoothedLevel *= 0.88;
            }
            view.frameNumber++;
            [view setNeedsDisplay:YES];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
    }
    [self setNeedsDisplay:YES];
}

- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    self.smoothedLevel = 0;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2)
                                                               xRadius:20 yRadius:20];
    [[NSColor colorWithSRGBRed:0.095 green:0.105 blue:0.15 alpha:0.97] setFill];
    [background fill];
    [[NSColor colorWithSRGBRed:0.38 green:0.43 blue:0.53 alpha:0.5] setStroke];
    background.lineWidth = 1;
    [background stroke];

    if (self.mode == 1) [self drawRecording];
    if (self.mode == 2) [self drawTranscribing];
    if (self.mode == 3) [self drawFailure];
}

- (void)drawRecording {
    const CGFloat pulse = 0.65 + 0.35 * sin(self.frameNumber * 0.16);
    [[NSColor colorWithSRGBRed:1 green:0.29 blue:0.35 alpha:pulse] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(20, 66, 8, 8)] fill];
    mk_draw_label(@"GRAVANDO", 36, 62, [NSFont boldSystemFontOfSize:12], [NSColor whiteColor]);
    mk_draw_label(@"solte para transcrever", 165, 63, [NSFont systemFontOfSize:10],
                  [NSColor colorWithSRGBRed:0.66 green:0.7 blue:0.77 alpha:1]);

    const CGFloat level = sqrt(self.smoothedLevel);
    for (NSUInteger i = 0; i < 38; i++) {
        const CGFloat shape = 0.22 + 0.78 * fabs(sin(i * 0.58 + self.frameNumber * 0.13) *
                                                cos(i * 0.31 - self.frameNumber * 0.08));
        const CGFloat breath = 1.5 + 1.5 * sin(i * 0.47 + self.frameNumber * 0.1);
        const CGFloat height = 5 + breath + level * 34 * shape;
        const CGFloat position = (CGFloat)i / 37.0;
        [[NSColor colorWithSRGBRed:1 - position * 0.36
                            green:0.31 + position * 0.27
                             blue:0.41 + position * 0.52 alpha:0.96] setFill];
        NSRect bar = NSMakeRect(27 + i * 7, 32 - height / 2, 3.2, height);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.6 yRadius:1.6] fill];
    }
}

- (void)drawTranscribing {
    mk_draw_label(@"TRANSCRIVENDO", 20, 63, [NSFont boldSystemFontOfSize:11],
                  [NSColor colorWithSRGBRed:0.61 green:0.8 blue:1 alpha:1]);
    mk_draw_label(@"áudio → texto", 234, 63, [NSFont systemFontOfSize:10],
                  [NSColor colorWithSRGBRed:0.66 green:0.7 blue:0.77 alpha:1]);

    NSString *word = @"TRANSCRIBINDO";
    const CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - self.stateStarted;
    const CGFloat letterWidth = 17;
    const CGFloat startX = (self.bounds.size.width - word.length * letterWidth) / 2;
    NSFont *font = [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightSemibold];
    for (NSUInteger i = 0; i < word.length; i++) {
        const CGFloat reveal = fmax(0, fmin(1, (elapsed - i * 0.06) / 0.34));
        const CGFloat x = startX + i * letterWidth;
        if (reveal < 1) {
            const CGFloat height = (5 + self.smoothedLevel * 25) * (1 - reveal) + 3;
            [[NSColor colorWithSRGBRed:0.85 green:0.48 blue:0.8 alpha:1 - reveal] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 5, 35 - height / 2, 3, height)
                                           xRadius:1.5 yRadius:1.5] fill];
        }
        if (reveal > 0) {
            unichar character = reveal < 0.78
                ? (unichar)('A' + (self.frameNumber / 2 + i * 11) % 26)
                : [word characterAtIndex:i];
            NSString *glyph = [NSString stringWithCharacters:&character length:1];
            const CGFloat shimmer = 0.73 + 0.27 * sin(self.frameNumber * 0.09 - i * 0.45);
            mk_draw_label(glyph, x, 25, font,
                          [NSColor colorWithSRGBRed:0.55 + 0.25 * shimmer
                                             green:0.76 + 0.16 * shimmer
                                              blue:1 alpha:reveal]);
        }
    }
    for (NSUInteger i = 0; i < 3; i++) {
        const CGFloat alpha = 0.25 + 0.7 * fmax(0, sin(self.frameNumber * 0.14 - i * 0.8));
        [[NSColor colorWithSRGBRed:0.64 green:0.82 blue:1 alpha:alpha] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(149 + i * 9, 12, 3, 3)] fill];
    }
}

- (void)drawFailure {
    [[NSColor colorWithSRGBRed:1 green:0.64 blue:0.28 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(22, 38, 11, 11)] fill];
    mk_draw_label(@"!", 26, 38, [NSFont boldSystemFontOfSize:9],
                  [NSColor colorWithSRGBRed:0.15 green:0.12 blue:0.13 alpha:1]);
    mk_draw_label(@"Não foi possível transcrever", 43, 42,
                  [NSFont boldSystemFontOfSize:12], [NSColor whiteColor]);
    mk_draw_label(@"Veja o erro no terminal", 43, 22, [NSFont systemFontOfSize:11],
                  [NSColor colorWithSRGBRed:0.66 green:0.7 blue:0.77 alpha:1]);
}

@end

static NSStatusItem *mk_status_item;
static NSPanel *mk_overlay_panel;
static MKOverlayView *mk_overlay_view;
static NSTimer *mk_hide_timer;
static CFRunLoopRef mk_status_runloop;

static void mk_position_overlay(void) {
    NSScreen *screen = [NSScreen mainScreen];
    const NSPoint mouse = [NSEvent mouseLocation];
    for (NSScreen *candidate in [NSScreen screens]) {
        if (NSPointInRect(mouse, candidate.frame)) {
            screen = candidate;
            break;
        }
    }
    const NSRect visible = screen.visibleFrame;
    [mk_overlay_panel setFrame:NSMakeRect(NSMidX(visible) - mk_overlay_width / 2,
                                          NSMaxY(visible) - mk_overlay_height - 14,
                                          mk_overlay_width, mk_overlay_height) display:NO];
}

static void mk_hide_overlay_after(NSTimeInterval delay) {
    mk_hide_timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [mk_overlay_panel orderOut:nil];
        [mk_overlay_view stopAnimation];
        mk_hide_timer = nil;
    }];
    [[NSRunLoop mainRunLoop] addTimer:mk_hide_timer forMode:NSRunLoopCommonModes];
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
            switch (status) {
                case 1:
                    mk_status_item.button.title = @"🔴 REC";
                    mk_status_item.button.toolTip = @"Minikeyboard gravando";
                    [mk_overlay_view showMode:1];
                    mk_position_overlay();
                    [mk_overlay_panel orderFrontRegardless];
                    break;
                case 2:
                    mk_status_item.button.title = @"⏳";
                    mk_status_item.button.toolTip = @"Minikeyboard transcrevendo";
                    [mk_overlay_view showMode:2];
                    [mk_overlay_panel orderFrontRegardless];
                    break;
                case 3:
                    mk_status_item.button.title = @"⚠︎";
                    mk_status_item.button.toolTip = @"Minikeyboard: erro, consulte o terminal";
                    [mk_overlay_view showMode:3];
                    [mk_overlay_panel orderFrontRegardless];
                    mk_hide_overlay_after(2.2);
                    break;
                default:
                    mk_status_item.button.title = @"⌨︎";
                    mk_status_item.button.toolTip = @"Minikeyboard pronto";
                    if (mk_overlay_panel.isVisible) mk_hide_overlay_after(0.45);
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
    mk_status_set(0);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, false);
    return 0;
}
