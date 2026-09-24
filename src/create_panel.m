// The create-agent panel: hold key 5 and say the agent ("codex no windows no
// coreum para investigar o login"). A floating panel, the dictation overlay's
// sibling, shows the transcript as it streams in and what was understood:
// harness, machine, repo and intent (`agb _intent`, backed by Jev). Release to
// review; hold again to add, type to fix, pick from a field to correct it; tap 5
// or press Return to create the agent, Esc to cancel.
#import <AppKit/AppKit.h>
#include <math.h>
#include "macos_shim.h"

extern void mk_draw_core(NSPoint center, double level, double t, double morph, BOOL fast);
extern void mk_open_terminal(NSString *command, NSString *title);

static const CGFloat mk_panel_width = 600;
static NSColor *MKInk(CGFloat alpha) { return [NSColor colorWithSRGBRed:0.72 green:0.79 blue:0.96 alpha:alpha]; }
static NSFont *MKFont(CGFloat size, NSFontWeight weight) { return [NSFont systemFontOfSize:size weight:weight]; }

static NSData *MKRunAgb(NSArray<NSString *> *arguments, double timeout);

@interface MKCreatePanel : NSPanel
@end
@implementation MKCreatePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender { (void)sender; mk_create_panel_show(NULL); }
@end

@interface MKCreateView : NSView <NSTextViewDelegate>
@property(nonatomic, strong) NSTextView *text;
@property(nonatomic, strong) NSScrollView *scroll;
@property(nonatomic, strong) NSArray<NSButton *> *chips;
@property(nonatomic, strong) NSTextField *intent, *hint;
@property(nonatomic, copy) NSString *base, *live;
@property(nonatomic) BOOL recording, detecting;
@property(nonatomic, strong) NSDictionary *plan;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *fixed;
@property(nonatomic) NSUInteger serial;
@property(nonatomic, strong) NSTimer *debounce, *animation;
@property(nonatomic) double phase, level, lastTick;
@end

static MKCreatePanel *mk_panel;
static MKCreateView *mk_view;
static NSRunningApplication *mk_previous_app;

@implementation MKCreateView
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.base = @"";
    self.live = @"";
    self.fixed = [NSMutableDictionary dictionary];

    self.scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.drawsBackground = NO;
    self.scroll.hasVerticalScroller = NO;
    self.scroll.borderType = NSNoBorder;
    self.text = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.text.drawsBackground = NO;
    self.text.richText = NO;
    self.text.font = MKFont(15, NSFontWeightRegular);
    self.text.textColor = MKInk(0.95);
    self.text.insertionPointColor = MKInk(0.9);
    self.text.delegate = self;
    self.text.textContainerInset = NSMakeSize(0, 2);
    self.text.textContainer.widthTracksTextView = YES;
    self.scroll.documentView = self.text;
    [self addSubview:self.scroll];

    NSMutableArray *chips = [NSMutableArray array];
    for (NSString *key in @[@"agent", @"host", @"repo"]) {
        NSButton *chip = [NSButton buttonWithTitle:@"" target:self action:@selector(pick:)];
        chip.bordered = NO;
        chip.identifier = key;
        chip.wantsLayer = YES;
        chip.layer.cornerRadius = 9;
        chip.layer.backgroundColor = MKInk(0.09).CGColor;
        [chips addObject:chip];
        [self addSubview:chip];
    }
    self.chips = chips;
    self.intent = [NSTextField labelWithString:@""];
    self.intent.font = MKFont(12.5, NSFontWeightRegular);
    self.intent.textColor = MKInk(0.72);
    self.intent.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:self.intent];
    self.hint = [NSTextField labelWithString:@""];
    self.hint.font = MKFont(11, NSFontWeightRegular);
    self.hint.textColor = MKInk(0.45);
    [self addSubview:self.hint];
    return self;
}

// ---------------------------------------------------------------- drawing

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:23 yRadius:23];
    NSGradient *surface = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.115 green:0.125 blue:0.16 alpha:0.98]
                  endingColor:[NSColor colorWithSRGBRed:0.065 green:0.075 blue:0.1 alpha:0.98]];
    [surface drawInBezierPath:shell angle:90];
    [MKInk(0.16) setStroke];
    shell.lineWidth = 0.75;
    [shell stroke];
    // The same breathing core as the dictation overlay, flipped view.
    NSAffineTransform *flip = [NSAffineTransform transform];
    [flip translateXBy:0 yBy:self.bounds.size.height];
    [flip scaleXBy:1 yBy:-1];
    [NSGraphicsContext saveGraphicsState];
    [flip concat];
    mk_draw_core(NSMakePoint(36, self.bounds.size.height - 38), self.recording ? self.level : 0.02, self.phase, 0, self.detecting);
    [NSGraphicsContext restoreGraphicsState];
    NSString *title = self.recording ? @"Listening for the new agent" : @"New agent";
    [title drawAtPoint:NSMakePoint(68, 16) withAttributes:@{NSFontAttributeName: MKFont(13, NSFontWeightSemibold), NSForegroundColorAttributeName: MKInk(0.92)}];
}

- (void)tick {
    const double now = (mk_monotonic_ns() / 1e9);
    const double dt = fmin(0.1, now - self.lastTick);
    self.lastTick = now;
    self.phase += dt;
    const double target = self.recording ? mk_audio_level_permille() / 1000.0 : 0;
    self.level += (target - self.level) * (1 - exp(-dt / (target > self.level ? 0.016 : 0.085)));
    [self setNeedsDisplayInRect:NSMakeRect(0, 0, 70, 76)];
}

// ---------------------------------------------------------------- layout

- (NSString *)fullText {
    if (!self.live.length) return self.base;
    if (!self.base.length) return self.live;
    return [NSString stringWithFormat:@"%@ %@", self.base, self.live];
}

- (void)relayout {
    const CGFloat pad = 68, width = mk_panel_width - pad - 24;
    [self.text.layoutManager ensureLayoutForTextContainer:self.text.textContainer];
    const CGFloat textHeight = fmin(180, fmax(24, [self.text.layoutManager usedRectForTextContainer:self.text.textContainer].size.height + 6));
    self.scroll.frame = NSMakeRect(pad, 42, width, textHeight);
    self.text.frame = NSMakeRect(0, 0, width, textHeight);
    CGFloat x = pad, y = 42 + textHeight + 10;
    for (NSButton *chip in self.chips) {
        [chip sizeToFit];
        NSRect f = chip.frame;
        f.size.width += 18;
        f.size.height = 22;
        f.origin = NSMakePoint(x, y);
        chip.frame = f;
        x += f.size.width + 8;
    }
    self.intent.frame = NSMakeRect(pad, y + 30, width, 18);
    self.hint.frame = NSMakeRect(pad, y + 52, width, 16);
    const CGFloat height = y + 80;
    NSRect frame = mk_panel.frame;
    const CGFloat top = NSMaxY(frame);
    frame.size.height = height;
    frame.origin.y = top - height; // grow downwards from where it opened
    [mk_panel setFrame:frame display:YES];
    self.frame = NSMakeRect(0, 0, mk_panel_width, height);
    [self setNeedsDisplay:YES];
}

- (void)refresh {
    if (![self.text.string isEqualToString:self.fullText]) {
        self.text.string = self.fullText;
        [self.text scrollToEndOfDocument:nil];
    }
    self.text.editable = !self.recording;
    NSDictionary *plan = self.plan;
    NSArray *labels = @[@"agent", @"machine", @"repo"], *keys = @[@"agent", @"host", @"repo"];
    for (NSUInteger i = 0; i < 3; i++) {
        NSString *key = keys[i];
        id value = self.fixed[key] ?: plan[key];
        const double confidence = self.fixed[key] ? 1 : [plan[[key stringByAppendingString:@"_confidence"]] doubleValue];
        const BOOL missing = ![value isKindOfClass:NSString.class] || ![value length];
        // 0 is a default (not said: claude, this machine), shown dimmer; a low
        // non-zero confidence is Jev unsure, marked with "?".
        const BOOL unsure = !missing && confidence > 0 && confidence < 0.6;
        const BOOL fallback = !missing && confidence == 0;
        // No repo is fine: the agent works in ~/agents/<task> (research).
        NSString *shown = missing ? ([key isEqual:@"repo"] ? @"none" : @"?") : unsure ? [value stringByAppendingString:@" ?"] : value;
        NSColor *color = MKInk(missing || fallback ? 0.55 : unsure ? 0.6 : 0.95);
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@  ", labels[i]]
            attributes:@{NSFontAttributeName: MKFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: MKInk(0.5)}];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[shown stringByAppendingString:@" ▾"]
            attributes:@{NSFontAttributeName: MKFont(12, NSFontWeightMedium), NSForegroundColorAttributeName: color}]];
        self.chips[i].attributedTitle = title;
    }
    NSString *prompt = plan[@"prompt"];
    self.intent.stringValue = prompt.length ? [NSString stringWithFormat:@"→ %@", prompt] : @"";
    id repo = self.fixed[@"repo"] ?: plan[@"repo"];
    const BOOL noRepo = plan && (![repo isKindOfClass:NSString.class] || ![repo length]);
    self.hint.stringValue = self.recording ? @"release 5 to review"
        : self.detecting ? @"understanding…"
        : noRepo ? [NSString stringWithFormat:@"no repo: in ~/agents/%@   ·   5 creates   ·   Esc cancels", plan[@"task"]]
        : @"5 or Return creates   ·   hold 5 to say more   ·   Esc cancels";
    [self relayout];
}

// ---------------------------------------------------------------- detection

- (void)scheduleDetect {
    [self.debounce invalidate];
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.35 target:self selector:@selector(detect) userInfo:nil repeats:NO];
}

- (void)detect {
    NSString *text = [self.fullText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    const NSUInteger serial = ++self.serial;
    NSMutableArray *arguments = [NSMutableArray arrayWithObject:@"_intent"];
    for (NSString *key in @[@"agent", @"host", @"repo"]) {
        if (!self.fixed[key]) continue;
        if ([key isEqual:@"repo"] && !self.fixed[key].length) [arguments addObject:@"--no-repo"]; // chosen: no repo
        else [arguments addObjectsFromArray:@[[@"--" stringByAppendingString:key], self.fixed[key]]];
    }
    [arguments addObject:text];
    self.detecting = YES;
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *output = MKRunAgb(arguments, 15);
        NSDictionary *plan = output ? [NSJSONSerialization JSONObjectWithData:output options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (serial != self.serial) return; // a newer request is on its way
            self.detecting = NO;
            if ([plan isKindOfClass:NSDictionary.class] && plan[@"agent"]) self.plan = plan;
            else if ([plan isKindOfClass:NSDictionary.class] && plan[@"error"])
                self.hint.stringValue = [NSString stringWithFormat:@"could not understand: %@", plan[@"error"]];
            [self refresh];
        });
    });
}

static NSData *MKRunAgb(NSArray<NSString *> *arguments, double timeout) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:NSBundle.mainBundle.executablePath];
    task.arguments = arguments;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    if (!environment[@"LANG"]) environment[@"LANG"] = @"en_US.UTF-8";
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    __block NSData *output = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        output = [pipe.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        [task terminate];
        return nil;
    }
    [task waitUntilExit];
    return output;
}

// ---------------------------------------------------------------- editing

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.recording) return;
    self.base = self.text.string;
    self.live = @"";
    [self scheduleDetect];
    [self relayout];
}

- (BOOL)textView:(NSTextView *)view doCommandBySelector:(SEL)selector {
    (void)view;
    if (selector == @selector(insertNewline:)) { [self confirm]; return YES; }
    if (selector == @selector(cancelOperation:)) { mk_create_panel_show(NULL); return YES; }
    return NO;
}

// A field's menu: every option Jev chose among, the current one checked.
- (void)pick:(NSButton *)chip {
    NSString *key = chip.identifier;
    NSArray *options = [key isEqual:@"agent"] ? @[@"claude", @"codex", @"shell"]
        : [key isEqual:@"host"] ? self.plan[@"hosts"] : self.plan[@"repos"];
    if (![options isKindOfClass:NSArray.class] || !options.count) return;
    NSString *current = self.fixed[key] ?: self.plan[key];
    NSMenu *menu = [NSMenu new];
    if ([key isEqual:@"repo"]) { // research: no repo at all
        NSMenuItem *none = [menu addItemWithTitle:@"none (research, in ~/agents)" action:@selector(choose:) keyEquivalent:@""];
        none.target = self;
        none.representedObject = @[key, @""];
        if (![current isKindOfClass:NSString.class] || ![current length]) none.state = NSControlStateValueOn;
        [menu addItem:NSMenuItem.separatorItem];
    }
    for (NSString *option in options) {
        NSMenuItem *item = [menu addItemWithTitle:option action:@selector(choose:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @[key, option];
        if ([option isEqual:current]) item.state = NSControlStateValueOn;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, chip.bounds.size.height + 4) inView:chip];
}

- (void)choose:(NSMenuItem *)item {
    NSArray *choice = item.representedObject;
    self.fixed[choice[0]] = choice[1];
    // Another machine has other repos: its repo is asked again.
    if ([choice[0] isEqual:@"host"]) [self.fixed removeObjectForKey:@"repo"];
    [self detect];
}

// ---------------------------------------------------------------- create

- (void)confirm {
    if (self.recording) return;
    NSDictionary *plan = self.plan;
    NSString *agent = self.fixed[@"agent"] ?: plan[@"agent"], *host = self.fixed[@"host"] ?: plan[@"host"];
    id repo = self.fixed[@"repo"] ?: plan[@"repo"];
    if (!plan) return; // still reading the request
    NSString *agb = NSBundle.mainBundle.executablePath;
    NSString *(^q)(NSString *) = ^(NSString *s) {
        return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    };
    const BOOL hasRepo = [repo isKindOfClass:NSString.class] && [repo length];
    NSMutableString *command = [NSMutableString stringWithFormat:@"%@ new --agent %@ --host %@ %@ --task %@",
        q(agb), q(agent), q(host), hasRepo ? [@"--repo " stringByAppendingString:q(repo)] : @"--no-repo", q(plan[@"task"])];
    NSString *prompt = plan[@"prompt"];
    if (prompt.length) [command appendFormat:@" --prompt %@", q(prompt)];
    NSString *title = [NSString stringWithFormat:@"🦇 %@ · %@ @ %@", plan[@"task"], agent, host];
    fprintf(stderr, "[agent-belt] new agent: %s\n", command.UTF8String);
    mk_previous_app = nil; // the terminal takes the focus
    mk_create_panel_show(NULL);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ mk_open_terminal(command, title); });
}
@end

// ---------------------------------------------------------------- C API

static void MKOnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static void MKBuildPanel(void) {
    if (mk_panel) return;
    mk_panel = [[MKCreatePanel alloc] initWithContentRect:NSMakeRect(0, 0, mk_panel_width, 180)
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered defer:NO];
    mk_panel.opaque = NO;
    mk_panel.backgroundColor = NSColor.clearColor;
    mk_panel.hasShadow = YES;
    mk_panel.level = NSStatusWindowLevel;
    mk_panel.hidesOnDeactivate = NO;
    mk_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    mk_view = [[MKCreateView alloc] initWithFrame:NSMakeRect(0, 0, mk_panel_width, 180)];
    mk_panel.contentView = mk_view;
}

/// Opens the panel (text may seed it); NULL closes it.
void mk_create_panel_show(const char *text) {
    NSString *seed = text ? @(text) : nil;
    MKOnMain(^{
        if (!seed) {
            [mk_view.animation invalidate];
            mk_view.animation = nil;
            [mk_panel orderOut:nil];
            mk_view.recording = NO;
            if (mk_previous_app) [mk_previous_app activateWithOptions:0];
            mk_previous_app = nil;
            return;
        }
        MKBuildPanel();
        if (!mk_panel.isVisible) {
            mk_view.base = seed;
            mk_view.live = @"";
            mk_view.plan = nil;
            [mk_view.fixed removeAllObjects];
            NSRect screen = (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
            [mk_panel setFrame:NSMakeRect(NSMidX(screen) - mk_panel_width / 2, NSMinY(screen) + screen.size.height * 0.62, mk_panel_width, 180) display:NO];
            NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
            mk_previous_app = [front.bundleIdentifier isEqual:NSBundle.mainBundle.bundleIdentifier] ? nil : front;
            mk_view.lastTick = (mk_monotonic_ns() / 1e9);
            mk_view.animation = [NSTimer timerWithTimeInterval:1.0 / 60 target:mk_view selector:@selector(tick) userInfo:nil repeats:YES];
            [NSRunLoop.mainRunLoop addTimer:mk_view.animation forMode:NSRunLoopCommonModes];
            // Fresh repo lists for the next requests, in the background.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ MKRunAgb(@[@"_repos-cache"], 30); });
        }
        [mk_view refresh];
        if (seed.length) [mk_view detect];
        [NSApp activateIgnoringOtherApps:YES];
        [mk_panel makeKeyAndOrderFront:nil];
        [mk_panel makeFirstResponder:mk_view.text];
    });
}

int mk_create_panel_visible(void) {
    __block int visible = 0;
    if (NSThread.isMainThread) return mk_panel.isVisible;
    dispatch_sync(dispatch_get_main_queue(), ^{ visible = mk_panel.isVisible; });
    return visible;
}

void mk_create_panel_recording(int recording) {
    MKOnMain(^{
        mk_view.recording = recording != 0;
        [mk_view refresh];
    });
}

/// The words of the segment being spoken, replaced as they are refined.
void mk_create_panel_live(const char *text) {
    NSString *live = @(text ?: "");
    MKOnMain(^{
        mk_view.live = live;
        [mk_view refresh];
        [mk_view scheduleDetect];
    });
}

/// The segment's final words, appended to what was said and typed before.
void mk_create_panel_commit(const char *text) {
    NSString *words = [@(text ?: "") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    MKOnMain(^{
        mk_view.live = @"";
        if (words.length) mk_view.base = mk_view.base.length ? [NSString stringWithFormat:@"%@ %@", mk_view.base, words] : words;
        [mk_view refresh];
        [mk_view detect];
    });
}

void mk_create_panel_confirm(void) {
    MKOnMain(^{ [mk_view confirm]; });
}

// `agb panel [words]` from a terminal asks the running daemon to open it.
static NSString *const MKPanelNotification = @"com.frb.agentbelt.create-panel";

void mk_create_panel_request(const char *text) {
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:MKPanelNotification object:@(text ?: "")
                                                               userInfo:nil deliverImmediately:YES];
}

void mk_create_panel_listen(void) {
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:MKPanelNotification object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *note) {
        NSString *text = [note.object isKindOfClass:NSString.class] ? note.object : @"";
        if ([text isEqual:@"--confirm"]) mk_create_panel_confirm();
        else mk_create_panel_show([text isEqual:@"--close"] ? NULL : text.UTF8String);
    }];
}
