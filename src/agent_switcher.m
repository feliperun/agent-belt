#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
#include "macos_shim.h"
#import "agent_stats.h"

// Native accessibility handles never leave this process. No screenshots,
// conversation bodies, keystrokes, or private application databases are used.
@interface MKAgentTarget : NSObject
@property NSString *key;
@property NSString *label;
@property NSString *bundle;
@property NSString *terminal;
@property NSString *tmuxSession;
@property NSRunningApplication *app;
@property id window;
@property id control;
@property BOOL selected;
@property NSString *title;      // terminal title the agent sets (status glyph)
@property NSString *pane;       // tmux pane running the agent
@property NSInteger state;      // MKState
@property NSUInteger position;  // 1-based place in the ring, for the HUD
@property NSString *name;       // readable session title, when the agent's files have one
@property NSString *detail;     // recap and stats for the menu
@end
@implementation MKAgentTarget
@end

typedef NS_ENUM(NSInteger, MKState) { MKStateIdle, MKStateWorking, MKStateDone, MKStateWaiting };
static NSString *MKTitleOf(MKAgentTarget *target);

static id MKAttr(id element, CFStringRef attribute) {
    if (!element) return nil;
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue((__bridge AXUIElementRef)element, attribute, &value);
    return CFBridgingRelease(value);
}
static NSString *MKString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSArray *MKArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSString *MKName(id element) {
    NSString *title = MKString(MKAttr(element, kAXTitleAttribute));
    return title.length ? title : MKString(MKAttr(element, kAXDescriptionAttribute));
}
static BOOL MKBool(id value) { return [value respondsToSelector:@selector(boolValue)] && [value boolValue]; }
static BOOL MKPress(id element) {
    return element && AXUIElementPerformAction((__bridge AXUIElementRef)element, kAXPressAction) == kAXErrorSuccess;
}

static NSString *MKToolPath(NSString *name, NSString *overrideVar) {
    NSString *override = NSProcessInfo.processInfo.environment[overrideVar];
    if (override.length) return override;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *dir in [NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"])
        if ([dir hasPrefix:@"/"]) [paths addObject:[dir stringByAppendingPathComponent:name]];
    // launchd starts the daemon with a minimal PATH.
    for (NSString *dir in @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/Applications/Orca.app/Contents/Resources/bin"])
        [paths addObject:[dir stringByAppendingPathComponent:name]];
    for (NSString *path in paths)
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    return nil;
}

// Bounded subprocess output and timeout: a stalled app must not block the HID
// listener or leave an unbounded queue of focus changes. Arguments bypass a shell.
static NSData *MKRun(NSString *path, NSArray<NSString *> *arguments) {
    if (!path) return nil;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    // launchd gives no locale; tmux then sanitizes format output and turns
    // every tab separator into "_", hiding all tmux sessions.
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    if (!environment[@"LANG"] && !environment[@"LC_ALL"]) environment[@"LANG"] = @"en_US.UTF-8";
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    int fd = pipe.fileHandleForReading.fileDescriptor;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    NSMutableData *data = [NSMutableData data];
    double deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
    BOOL failed = NO;
    for (;;) {
        uint8_t buffer[16384];
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n > 0) [data appendBytes:buffer length:(NSUInteger)n];
        if (data.length > 4 * 1024 * 1024 || NSProcessInfo.processInfo.systemUptime > deadline) {
            failed = YES;
            if (task.running) { [task terminate]; usleep(20000); }
            if (task.running) kill(task.processIdentifier, SIGKILL);
            break;
        }
        if (n <= 0 && !task.running) break;
        if (n <= 0) usleep(5000);
    }
    [task waitUntilExit];
    [pipe.fileHandleForReading closeFile];
    return failed || task.terminationStatus != 0 ? nil : data;
}

static NSDictionary *MKOrca(NSArray<NSString *> *arguments) {
    NSData *data = MKRun(MKToolPath(@"orca", @"AGENT_BELT_ORCA_CLI"), [arguments arrayByAddingObject:@"--json"]);
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] && MKBool(json[@"ok"]) ? json[@"result"] : nil;
}

static NSArray<NSArray<NSString *> *> *MKRows(NSString *text) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"])
        if (line.length) [rows addObject:[line componentsSeparatedByString:@"\t"]];
    return rows;
}

static NSArray<NSArray<NSString *> *> *MKTmux(NSArray<NSString *> *arguments) {
    NSData *data = MKRun(MKToolPath(@"tmux", @"AGENT_BELT_TMUX"), arguments);
    return data ? MKRows([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @[];
}

// Name of the coding agent a pane is running, from its foreground command.
static NSString *MKAgentCommand(NSString *command) {
    NSString *name = command.lowercaseString;
    for (NSString *agent in @[@"claude", @"codex", @"opencode", @"gemini", @"aider", @"amp", @"cursor-agent", @"goose", @"pi", @"omp"])
        if ([name isEqual:agent]) return agent;
    // Claude Code replaces its process title with its version, e.g. "2.1.280".
    if ([name rangeOfString:@"^[0-9]+\\.[0-9]+\\.[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound)
        return @"claude";
    return nil;
}

// Rows of `session, @work_agent, pane_current_command`. A session counts only
// while some pane runs an agent: the `work` mark survives the agent exiting.
static NSDictionary<NSString *, NSString *> *MKSessionAgents(NSArray<NSArray<NSString *> *> *rows) {
    NSMutableDictionary *agents = [NSMutableDictionary dictionary];
    for (NSArray<NSString *> *row in rows) {
        if (row.count < 3 || agents[row[0]]) continue;
        NSString *agent = MKAgentCommand(row[2]);
        if (agent) agents[row[0]] = [@[@"claude", @"codex"] containsObject:row[1]] ? row[1] : agent;
    }
    return agents;
}

NSString *MKProcessEnv(pid_t pid, const char *name) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return nil;
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (sysctl(mib, 3, buffer.mutableBytes, &size, NULL, 0) != 0 || size < sizeof(int)) return nil;
    const char *p = buffer.bytes, *end = p + size;
    int argc;
    memcpy(&argc, p, sizeof(argc));
    p += sizeof(argc);
    p += strnlen(p, (size_t)(end - p)); // executable path, then NUL padding
    while (p < end && !*p) p++;
    for (int i = 0; i < argc && p < end; i++) p += strnlen(p, (size_t)(end - p)) + 1;
    size_t length = strlen(name);
    while (p < end && *p) {
        size_t entry = strnlen(p, (size_t)(end - p));
        if (entry > length && !strncmp(p, name, length) && p[length] == '=')
            return [[NSString alloc] initWithBytes:p + length + 1 length:entry - length - 1 encoding:NSUTF8StringEncoding];
        p += entry + 1;
    }
    return nil;
}

// The GUI application hosting a process, e.g. the terminal a tmux client runs in.
static NSRunningApplication *MKOwningApp(pid_t pid) {
    for (int depth = 0; pid > 1 && depth < 16; depth++) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (app.bundleIdentifier && app.activationPolicy == NSApplicationActivationPolicyRegular) return app;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return nil;
        pid = (pid_t)info.pbi_ppid;
    }
    return nil;
}

// Claude Code titles its terminal "✳ task" when idle and with a spinner
// (◐◓◑◒ or braille) while working.
static BOOL MKTitleWorking(NSString *title) {
    if (!title.length) return NO;
    unichar c = [title characterAtIndex:0];
    return (c >= 0x25D0 && c <= 0x25D3) || (c >= 0x2800 && c <= 0x28FF);
}

static NSString *MKCleanTitle(NSString *title) {
    if (title.length > 2 && [title characterAtIndex:1] == ' ' &&
        (MKTitleWorking(title) || [title characterAtIndex:0] == 0x2733))
        return [title substringFromIndex:2];
    return title;
}

// Approval prompts of Claude Code ("Do you want to proceed? ❯ 1. Yes") and
// Codex ("Would you like to run…? › 1. Yes, proceed") in the last screen lines.
// Read locally only to rank the ring; never logged or stored.
static BOOL MKWaitingScreen(NSString *screen) {
    NSArray *lines = [screen componentsSeparatedByString:@"\n"];
    NSString *tail = [[lines subarrayWithRange:NSMakeRange(lines.count > 16 ? lines.count - 16 : 0,
                                                           MIN(lines.count, (NSUInteger)16))]
                      componentsJoinedByString:@"\n"];
    if (![tail containsString:@"1. Yes"]) return NO;
    for (NSString *question in @[@"Do you want", @"Would you like", @"Allow "])
        if ([tail containsString:question]) return YES;
    return NO;
}

// Rows of `session, @work_agent, command, pane_id, pane_title`: the pane and
// title of each session's agent.
static NSDictionary<NSString *, NSArray<NSString *> *> *MKSessionAgentPanes(NSArray<NSArray<NSString *> *> *rows) {
    NSMutableDictionary *panes = [NSMutableDictionary dictionary];
    for (NSArray<NSString *> *row in rows)
        if (row.count >= 5 && !panes[row[0]] && MKAgentCommand(row[2])) panes[row[0]] = @[row[3], row[4]];
    return panes;
}

static BOOL MKLiveTerminal(NSDictionary *terminal) {
    return MKBool(terminal[@"connected"]) && !MKBool(terminal[@"orphaned"]) &&
           [MKString(terminal[@"handle"]) hasPrefix:@"term_"];
}


static NSArray<MKAgentTarget *> *MKTerminalTargets(void) {
    NSArray *paneRows = MKTmux(@[@"list-panes", @"-a", @"-F",
        @"#{session_name}\t#{@work_agent}\t#{pane_current_command}\t#{pane_id}\t#{pane_title}"]);
    NSDictionary *agents = MKSessionAgents(paneRows);
    NSDictionary *agentPanes = MKSessionAgentPanes(paneRows);
    // tmux clients attached to agent sessions, keyed by the Orca terminal
    // hosting them; clients in other terminal apps are kept separately.
    NSMutableDictionary<NSString *, NSString *> *sessionByHandle = [NSMutableDictionary dictionary];
    NSMutableArray<MKAgentTarget *> *outside = [NSMutableArray array];
    for (NSArray<NSString *> *client in MKTmux(@[@"list-clients", @"-F", @"#{client_pid}\t#{session_name}"])) {
        if (client.count < 2 || !agents[client[1]]) continue;
        pid_t pid = (pid_t)client[0].intValue;
        NSString *handle = MKProcessEnv(pid, "ORCA_TERMINAL_HANDLE");
        if (handle.length) { sessionByHandle[handle] = client[1]; continue; }
        NSRunningApplication *app = MKOwningApp(pid);
        if (!app) continue;
        MKAgentTarget *target = [MKAgentTarget new];
        target.key = [@"tmux:" stringByAppendingString:client[1]];
        target.tmuxSession = client[1];
        target.label = [NSString stringWithFormat:@"%@ · %@", client[1], agents[client[1]]];
        target.pane = agentPanes[client[1]][0];
        target.title = agentPanes[client[1]][1];
        target.bundle = app.bundleIdentifier;
        target.app = app;
        [outside addObject:target];
    }

    NSMutableArray<MKAgentTarget *> *targets = [NSMutableArray array];
    NSRunningApplication *orca = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.stablyai.orca"].firstObject;
    NSDictionary *result = orca ? MKOrca(@[@"terminal", @"list", @"--limit", @"100"]) : nil;
    if (orca && !result) fprintf(stderr, "[agent-belt] Orca: CLI indisponível; confira AGENT_BELT_ORCA_CLI\n");
    for (NSDictionary *terminal in MKArray(result[@"terminals"])) {
        if (!MKLiveTerminal(terminal)) continue;
        NSString *handle = terminal[@"handle"];
        NSString *session = sessionByHandle[handle];
        NSString *agent = session ? agents[session] : MKString(terminal[@"agentIdentity"]);
        if (!agent.length) continue;
        MKAgentTarget *target = [MKAgentTarget new];
        target.key = handle;
        target.terminal = handle;
        target.tmuxSession = session;
        NSString *title = MKString(terminal[@"title"]);
        target.pane = session ? agentPanes[session][0] : nil;
        target.title = session ? agentPanes[session][1] : title;
        target.label = [NSString stringWithFormat:@"%@ · %@", session ?: (title.length ? MKCleanTitle(title) : handle), agent];
        target.bundle = orca.bundleIdentifier;
        target.app = orca;
        [targets addObject:target];
    }
    // Orca returns most-recent-output order. Never let agent output reorder the ring.
    [targets sortUsingComparator:^NSComparisonResult(MKAgentTarget *a, MKAgentTarget *b) { return [a.key compare:b.key]; }];
    [outside sortUsingComparator:^NSComparisonResult(MKAgentTarget *a, MKAgentTarget *b) { return [a.key compare:b.key]; }];
    [targets addObjectsFromArray:outside];
    return targets;
}

// Session status prefixes observed in Claude Code's sidebar (English + pt-BR).
// Merged/completed history and ordinary Claude chats are intentionally excluded.
static NSString *MKLiveSessionName(NSString *label) {
    for (NSString *prefix in @[@"Em execução ", @"Ocioso ", @"Resposta não lida ", @"Aguardando aprovação ",
                               @"Running ", @"Idle ", @"Unread response ", @"Needs approval ", @"Working "])
        if ([label hasPrefix:prefix]) return [label substringFromIndex:prefix.length];
    return nil;
}
static BOOL MKSessionTabGroup(NSString *label) {
    NSString *name = label.lowercaseString;
    for (NSString *word in @[@"session", @"sess", @"chat", @"thread", @"conversa"])
        if ([name containsString:word]) return YES;
    return [@[@"tabs", @"abas", @"open tabs"] containsObject:name];
}

// Read navigation structure only; stop at editors and chat message containers.
// Traversal is capped in time and size, including for unresponsive applications.
static void MKWalk(id element, int depth, int *budget, double deadline, void (^visit)(id, NSString *, NSString *)) {
    if (depth > 32 || --*budget < 0 || NSProcessInfo.processInfo.systemUptime > deadline) return;
    NSString *role = MKString(MKAttr(element, kAXRoleAttribute));
    if ([@[@"AXStaticText", @"AXTextArea", @"AXTextField", @"AXMenuBar", @"AXImage"] containsObject:role]) return;
    NSString *name = MKName(element);
    if ([@[@"Mensagens do chat", @"Chat messages", @"Messages", @"Conversation messages"] containsObject:name]) return;
    visit(element, role, name);
    for (id child in MKArray(MKAttr(element, kAXChildrenAttribute))) MKWalk(child, depth + 1, budget, deadline, visit);
}

static id MKFindCodeControl(id window) {
    __block id found = nil;
    int budget = 700;
    MKWalk(window, 0, &budget, NSProcessInfo.processInfo.systemUptime + .3, ^(id e, NSString *role, NSString *name) {
        if ([role isEqual:@"AXRadioButton"] && [name isEqual:@"Code"]) found = e;
    });
    return found;
}

static NSArray<MKAgentTarget *> *MKDesktopTargets(NSRunningApplication *app, BOOL frontmost) {
    id root = CFBridgingRelease(AXUIElementCreateApplication(app.processIdentifier));
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)root, .1);
    // Electron's documented opt-in. Some native apps don't implement it; that's OK.
    AXUIElementSetAttributeValue((__bridge AXUIElementRef)root, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    id focusedWindow = MKAttr(root, kAXFocusedWindowAttribute);
    BOOL claude = [app.bundleIdentifier isEqual:@"com.anthropic.claudefordesktop"];
    NSMutableArray *targets = [NSMutableArray array];
    for (id window in MKArray(MKAttr(root, kAXWindowsAttribute))) {
        if (![MKString(MKAttr(window, kAXSubroleAttribute)) isEqual:@"AXStandardWindow"]) continue;
        NSString *windowKey = [NSString stringWithFormat:@"%@:%d:%lu", app.bundleIdentifier, app.processIdentifier,
                               (unsigned long)CFHash((__bridge CFTypeRef)window)];
        BOOL focused = frontmost && [window isEqual:focusedWindow];
        NSMutableArray *sessions = [NSMutableArray array];
        id code = claude ? MKFindCodeControl(window) : nil;
        BOOL codeMode = code && MKBool(MKAttr(code, kAXValueAttribute));
        int budget = 900;
        MKWalk(window, 0, &budget, NSProcessInfo.processInfo.systemUptime + .4, ^(id e, NSString *role, NSString *name) {
            NSString *sessionName = nil;
            id parent = MKAttr(e, kAXParentAttribute);
            NSString *subrole = MKString(MKAttr(e, kAXSubroleAttribute));
            if (([role isEqual:@"AXRadioButton"] || [subrole isEqual:@"AXTab"]) &&
                [MKString(MKAttr(parent, kAXRoleAttribute)) isEqual:@"AXTabGroup"] && MKSessionTabGroup(MKName(parent)))
                sessionName = name;
            if (claude && codeMode && [role isEqual:@"AXButton"]) {
                NSString *live = MKLiveSessionName(name);
                // A session row has its own options menu, unlike arbitrary action buttons.
                if (live) for (id sibling in MKArray(MKAttr(parent, kAXChildrenAttribute))) {
                    NSString *siblingName = MKName(sibling);
                    if ([MKString(MKAttr(sibling, kAXRoleAttribute)) isEqual:@"AXPopUpButton"] &&
                        ([siblingName hasPrefix:@"Mais opções para "] || [siblingName hasPrefix:@"More options for "]))
                        sessionName = live;
                }
            }
            if (!sessionName.length) return;
            MKAgentTarget *target = [MKAgentTarget new];
            target.key = [windowKey stringByAppendingFormat:@":%@", sessionName];
            // Same-titled sessions are distinct controls, never collapse them.
            NSUInteger duplicates = 0;
            for (MKAgentTarget *existing in sessions) if ([existing.label isEqual:sessionName]) duplicates++;
            if (duplicates) target.key = [target.key stringByAppendingFormat:@":%lu", (unsigned long)duplicates];
            target.label = sessionName;
            target.bundle = app.bundleIdentifier;
            target.app = app;
            target.window = window;
            target.control = e;
            target.selected = focused && (MKBool(MKAttr(e, kAXSelectedAttribute)) || MKBool(MKAttr(e, kAXValueAttribute)));
            [sessions addObject:target];
        });
        if (sessions.count) [targets addObjectsFromArray:sessions];
        else {
            MKAgentTarget *target = [MKAgentTarget new];
            target.key = windowKey;
            target.label = claude ? @"Claude Code — janela atual" : @"Codex — janela atual";
            target.bundle = app.bundleIdentifier;
            target.app = app;
            target.window = window;
            target.selected = focused;
            [targets addObject:target];
        }
    }
    return targets;
}

// Terminal agents (Orca panes, `work` tmux sessions) form the ring. Codex and
// Claude desktop windows join only when the binding asks for "desktop".
static NSArray<MKAgentTarget *> *MKDiscover(BOOL desktop) {
    NSMutableArray *ring = [MKTerminalTargets() mutableCopy];
    if (!desktop) return ring;
    NSString *front = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    for (NSString *bundle in @[@"com.openai.codex", @"com.anthropic.claudefordesktop"])
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle])
            if (!app.terminated) [ring addObjectsFromArray:MKDesktopTargets(app, [front isEqual:bundle])];
    return ring;
}

static NSArray<MKAgentTarget *> *MKStableRing(NSArray<MKAgentTarget *> *old, NSArray<MKAgentTarget *> *fresh) {
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    for (MKAgentTarget *target in fresh) byKey[target.key] = target;
    NSMutableArray *ring = [NSMutableArray array];
    for (MKAgentTarget *target in old) if (byKey[target.key]) {
        [ring addObject:byKey[target.key]];
        [byKey removeObjectForKey:target.key];
    }
    for (MKAgentTarget *target in fresh) if (byKey[target.key]) {
        [ring addObject:target];
        [byKey removeObjectForKey:target.key];
    }
    return ring;
}

static NSUInteger MKNextIndex(NSArray<MKAgentTarget *> *ring, NSString *lastKey, NSString *front) {
    // Trust a genuinely selected tab over our last choice (user may click elsewhere).
    for (NSUInteger i = 0; i < ring.count; i++) if (ring[i].selected) return (i + 1) % ring.count;
    for (NSUInteger i = 0; i < ring.count; i++)
        if ([ring[i].key isEqual:lastKey] && [ring[i].bundle isEqual:front]) return (i + 1) % ring.count;
    return 0;
}

static BOOL MKWaitFrontmost(NSRunningApplication *app) {
    double deadline = NSProcessInfo.processInfo.systemUptime + .5;
    do {
        if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == app.processIdentifier) return YES;
        usleep(10000);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return NO;
}

// ignoringOtherApps has no effect since macOS 14; a background daemon brings
// the app forward through Accessibility, which we already require.
static BOOL MKBringToFront(NSRunningApplication *app) {
    id element = CFBridgingRelease(AXUIElementCreateApplication(app.processIdentifier));
    return AXUIElementSetAttributeValue((__bridge AXUIElementRef)element, kAXFrontmostAttribute, kCFBooleanTrue) == kAXErrorSuccess ||
           [app activateWithOptions:NSApplicationActivateAllWindows];
}

// A hidden (Cmd+H) or minimized app can be made frontmost while every window
// stays in the Dock: unhide it and bring back its minimized standard windows.
static void MKRestoreWindows(NSRunningApplication *app) {
    if (app.hidden) [app unhide];
    id root = CFBridgingRelease(AXUIElementCreateApplication(app.processIdentifier));
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)root, .3);
    NSArray *windows = MKArray(MKAttr(root, kAXWindowsAttribute));
    BOOL visible = NO;
    for (id window in windows)
        if ([MKString(MKAttr(window, kAXSubroleAttribute)) isEqual:@"AXStandardWindow"] && !MKBool(MKAttr(window, kAXMinimizedAttribute)))
            visible = YES;
    if (visible) return;
    for (id window in windows)
        if (MKBool(MKAttr(window, kAXMinimizedAttribute))) {
            AXUIElementSetAttributeValue((__bridge AXUIElementRef)window, kAXMinimizedAttribute, kCFBooleanFalse);
            AXUIElementPerformAction((__bridge AXUIElementRef)window, kAXRaiseAction);
        }
}

static BOOL MKFocusFailed(MKAgentTarget *target, const char *step) {
    fprintf(stderr, "[agent-belt] %s: falhou em %s\n", target.label.UTF8String, step);
    return NO;
}

static BOOL MKFocus(MKAgentTarget *target) {
    if (target.app.terminated) return MKFocusFailed(target, "app encerrado");
    if (target.terminal || target.tmuxSession) {
        MKRestoreWindows(target.app);
        if (target.terminal && !MKOrca(@[@"terminal", @"switch", @"--terminal", target.terminal]))
            return MKFocusFailed(target, "orca terminal switch");
        if (!MKBringToFront(target.app)) return MKFocusFailed(target, "trazer o app para frente");
        if (!MKWaitFrontmost(target.app)) return MKFocusFailed(target, "esperar o app ficar em primeiro plano");
        return YES;
    }
    id window = target.window;
    if (!MKAttr(window, kAXRoleAttribute)) return NO;
    AXUIElementSetAttributeValue((__bridge AXUIElementRef)window, kAXMinimizedAttribute, kCFBooleanFalse);
    if (!MKBringToFront(target.app)) return NO;
    if (AXUIElementPerformAction((__bridge AXUIElementRef)window, kAXRaiseAction) != kAXErrorSuccess) return NO;
    if ([target.bundle isEqual:@"com.anthropic.claudefordesktop"]) {
        id code = MKFindCodeControl(window);
        if (!code) { fprintf(stderr, "[agent-belt] Claude: modo Code não exposto pela acessibilidade\n"); return NO; }
        if (!MKBool(MKAttr(code, kAXValueAttribute)) && !MKPress(code)) return NO;
    }
    if (target.control && !MKPress(target.control)) return NO;
    // Let focus settle without ever sending a keyboard shortcut to an unknown receiver.
    return MKWaitFrontmost(target.app);
}

// Orca's "active" worktree selector reflects the caller's worktree, not the UI,
// so the ring position is ours: the last agent focused, shared by daemon and CLI.
static NSString *MKLastKeyPath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/agent-belt"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"last-agent"];
}

static void MKBottom(void);
static NSArray<MKAgentTarget *> *mk_ring;

// Transitions seen across discoveries (agents queue only): an agent that was
// working and went idle has finished and stays "done" until focused.
static NSMutableSet<NSString *> *mk_seen_working, *mk_done;
static void MKObserve(NSArray<MKAgentTarget *> *ring) {
    if (!mk_seen_working) { mk_seen_working = [NSMutableSet set]; mk_done = [NSMutableSet set]; }
    NSMutableSet *live = [NSMutableSet set];
    for (MKAgentTarget *target in ring) {
        [live addObject:target.key];
        if (MKTitleWorking(target.title)) {
            [mk_seen_working addObject:target.key];
            [mk_done removeObject:target.key];
            target.state = MKStateWorking;
        } else {
            if ([mk_seen_working containsObject:target.key]) [mk_done addObject:target.key];
            [mk_seen_working removeObject:target.key];
            target.state = [mk_done containsObject:target.key] ? MKStateDone : MKStateIdle;
        }
    }
    [mk_seen_working intersectSet:live];
    [mk_done intersectSet:live];
}

// Approval prompts are only looked for when the key is pressed, concurrently:
// a tmux screen capture or Orca's own wait detection per terminal.
static void MKDetectWaiting(NSArray<MKAgentTarget *> *ring) {
    dispatch_apply(ring.count, DISPATCH_APPLY_AUTO, ^(size_t i) {
        MKAgentTarget *target = ring[i];
        if (target.state == MKStateWorking) return; // a spinning agent is not asking
        BOOL waiting = NO;
        if (target.pane) {
            NSData *screen = MKRun(MKToolPath(@"tmux", @"AGENT_BELT_TMUX"), @[@"capture-pane", @"-p", @"-t", target.pane]);
            waiting = screen && MKWaitingScreen([[NSString alloc] initWithData:screen encoding:NSUTF8StringEncoding] ?: @"");
        } else if (target.terminal) {
            NSDictionary *shown = MKOrca(@[@"terminal", @"show", @"--terminal", target.terminal]);
            id wait = shown[@"terminal"][@"agentWait"];
            waiting = wait && wait != NSNull.null;
        }
        if (waiting) target.state = MKStateWaiting;
    });
}

// Key LEDs: red while an agent waits for you, green when one finished unseen.
static void MKUpdateLed(NSArray<MKAgentTarget *> *ring) {
    int attention = 0;
    for (MKAgentTarget *target in ring)
        attention = MAX(attention, target.state == MKStateWaiting ? 2 : target.state == MKStateDone ? 1 : 0);
    mk_led_agents(attention);
    mk_status_attention(attention);
}

// Who needs you first: waiting for approval, then finished and unseen, then
// the plain ring order. The agent currently focused is never picked again.
static NSUInteger MKPickIndex(NSArray<MKAgentTarget *> *ring, NSString *lastKey, NSString *front) {
    NSUInteger next = MKNextIndex(ring, lastKey, front);
    NSUInteger current = NSNotFound;
    for (NSUInteger i = 0; i < ring.count; i++)
        if ([ring[i].key isEqual:lastKey] && [ring[i].bundle isEqual:front]) current = i;
    for (NSNumber *wanted in @[@(MKStateWaiting), @(MKStateDone)])
        for (NSUInteger offset = 0; offset < ring.count; offset++) {
            NSUInteger i = (next + offset) % ring.count;
            if (i != current && ring[i].state == wanted.integerValue) return i;
        }
    return next;
}

static void MKShowHud(MKAgentTarget *target, NSArray<MKAgentTarget *> *ring) {
    NSString *state = @[@"", @"trabalhando", @"terminou", @"aguardando você"][target.state];
    NSUInteger others = 0;
    for (MKAgentTarget *other in ring)
        if (other != target && other.state >= MKStateDone) others++;
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%lu/%lu", (unsigned long)target.position, (unsigned long)ring.count];
    if (state.length) [detail appendFormat:@" · %@", state];
    if (others) [detail appendFormat:@" · mais %lu pedindo atenção", (unsigned long)others];
    mk_hud_show(MKTitleOf(target).UTF8String, detail.UTF8String, (int)target.state);
}
// Focus succeeded: remember it, clear "finished", refresh HUD-less state.
static void MKOpened(MKAgentTarget *target, NSArray<MKAgentTarget *> *ring) {
    [target.key writeToFile:MKLastKeyPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [mk_done removeObject:target.key]; // seen
    if (target.state == MKStateDone) target.state = MKStateIdle;
    MKUpdateLed(ring);
    fprintf(stderr, "[agent-belt] AGENT → %s\n", MKTitleOf(target).UTF8String);
}

// Discovery plus states, with each target's place in the ring.
// Titles, recaps and usage from the agents' own files (agent_stats.m).
static void MKEnrich(NSArray<MKAgentTarget *> *ring) {
    NSDictionary<NSString *, MKSessionInfo *> *sessions = MKClaudeSessionInfo();
    for (MKAgentTarget *target in ring) {
        MKSessionInfo *info = target.pane ? sessions[[@"pane:" stringByAppendingString:target.pane]] : nil;
        if (!info && target.terminal) info = sessions[[@"orca:" stringByAppendingString:target.terminal]];
        NSString *agent = [target.label componentsSeparatedByString:@" · "].lastObject;
        target.name = info.title.length ? info.title : [target.label componentsSeparatedByString:@" · "].firstObject;
        NSMutableArray *parts = [NSMutableArray arrayWithObject:agent ?: @""];
        NSString *stats = info ? MKSessionStatsText(info) : @"";
        if (stats.length) [parts addObject:stats];
        if (info.recap.length) [parts addObject:info.recap];
        target.detail = [parts componentsJoinedByString:@" · "];
    }
}

static NSString *MKTitleOf(MKAgentTarget *target) { return target.name ?: target.label; }
static NSString *MKEnrichedName(MKAgentTarget *target) {
    if (!target.name) MKEnrich(@[target]);
    return MKTitleOf(target);
}

// Discovery plus states, with each target's place in the ring.
static NSArray<MKAgentTarget *> *MKRefreshRing(BOOL desktop) {
    mk_ring = MKStableRing(mk_ring, MKDiscover(desktop));
    for (NSUInteger i = 0; i < mk_ring.count; i++) mk_ring[i].position = i + 1;
    MKObserve(mk_ring);
    MKDetectWaiting(mk_ring);
    MKEnrich(mk_ring);
    return mk_ring;
}

static int MKCycle(BOOL desktop) {
    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "[agent-belt] alternar agents requer permissão de Accessibility\n");
        return -1;
    }
    MKRefreshRing(desktop);
    if (!mk_ring.count) { fprintf(stderr, "[agent-belt] nenhum terminal com coding agent (Orca ou work)\n"); return -1; }
    NSString *lastKey = [NSString stringWithContentsOfFile:MKLastKeyPath() encoding:NSUTF8StringEncoding error:nil];
    NSUInteger start = MKPickIndex(mk_ring, lastKey, NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
    for (NSUInteger offset = 0; offset < mk_ring.count; offset++) {
        MKAgentTarget *target = mk_ring[(start + offset) % mk_ring.count];
        if (!MKFocus(target)) continue; // app/tab may have closed after discovery
        MKOpened(target, mk_ring);
        MKShowHud(target, mk_ring);
        return 0;
    }
    fprintf(stderr, "[agent-belt] não consegui focar nenhuma sessão (veja as falhas acima)\n");
    return -1;
}

static dispatch_queue_t mk_agents_queue;
static void MKCreateAgentsQueue(void) {
    mk_agents_queue = dispatch_queue_create("agent-belt.agents", DISPATCH_QUEUE_SERIAL);
}

void mk_agents_next(int desktop) {
    // Not dispatch_once: its inline DISPATCH_COMPILER_CAN_ASSUME traps under the
    // UBSan that Zig enables for C in safe builds, killing the daemon.
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    static atomic_uint pending;
    pthread_once(&once, MKCreateAgentsQueue);
    if (atomic_fetch_add(&pending, 1) >= 4) { atomic_fetch_sub(&pending, 1); return; }
    dispatch_async(mk_agents_queue, ^{
        @autoreleasepool { MKCycle(desktop != 0); }
        atomic_fetch_sub(&pending, 1);
    });
}

// Agent menu on one key: a press shows it, a later press moves the selection,
// a quick double press opens the selected agent. A single press waits out the
// double-press window before moving, so a double press opens what was
// highlighted rather than the next row.
typedef NS_ENUM(NSInteger, MKMenuAction) { MKMenuShow, MKMenuMove, MKMenuOpen };
static const double mk_menu_double = 0.35, mk_menu_timeout = 6;

static MKMenuAction MKMenuDecide(BOOL visible, double sinceLastPress) {
    if (!visible) return MKMenuShow;
    return sinceLastPress < mk_menu_double ? MKMenuOpen : MKMenuMove;
}

// Agents queue only.
static NSArray<MKAgentTarget *> *mk_menu_ring;
static NSUInteger mk_menu_selected;
static BOOL mk_menu_visible;
static atomic_bool mk_menu_shown; // read by the event tap for Return/Esc/arrows
static double mk_menu_last_press = -1;
static NSUInteger mk_menu_generation; // invalidates pending moves and timeouts

static BOOL mk_menu_clickable;
static void MKMenuRender(void) {
    NSUInteger count = mk_menu_ring.count;
    const char *labels[count ? count : 1], *details[count ? count : 1];
    int tones[count ? count : 1];
    for (NSUInteger i = 0; i < count; i++) {
        labels[i] = MKTitleOf(mk_menu_ring[i]).UTF8String;
        details[i] = (mk_menu_ring[i].detail ?: @"").UTF8String;
        tones[i] = (int)mk_menu_ring[i].state;
    }
    NSString *footer = MKQuotaLine();
    const char *update = mk_update_line();
    if (update) footer = footer ? [NSString stringWithFormat:@"%s   %@", update, footer] : @(update);
    mk_menu_show(labels, details, tones, (int)count, (int)mk_menu_selected, footer.UTF8String, mk_menu_clickable);
}

static void MKMenuClose(void) {
    mk_menu_visible = NO;
    atomic_store(&mk_menu_shown, false);
    mk_menu_generation++;
    mk_menu_hide();
}

static void MKMenuArmTimeout(void) {
    NSUInteger generation = ++mk_menu_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(mk_menu_timeout * NSEC_PER_SEC)), mk_agents_queue, ^{
        if (generation == mk_menu_generation && mk_menu_visible) MKMenuClose();
    });
}

static void MKMenuPress(void) {
    const double now = NSProcessInfo.processInfo.systemUptime;
    const double since = mk_menu_last_press < 0 ? INFINITY : now - mk_menu_last_press;
    mk_menu_last_press = now;
    switch (MKMenuDecide(mk_menu_visible, since)) {
    case MKMenuShow: {
        if (!AXIsProcessTrusted()) { fprintf(stderr, "[agent-belt] menu de agents requer Accessibility\n"); return; }
        mk_menu_ring = MKRefreshRing(NO);
        if (!mk_menu_ring.count) { mk_hud_show("Nenhum coding agent", "Orca ou work", 0); return; }
        NSString *lastKey = [NSString stringWithContentsOfFile:MKLastKeyPath() encoding:NSUTF8StringEncoding error:nil];
        mk_menu_selected = MKPickIndex(mk_menu_ring, lastKey, NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
        mk_menu_visible = YES;
        mk_menu_clickable = NO;
        atomic_store(&mk_menu_shown, true);
        MKMenuRender();
        MKMenuArmTimeout();
        return;
    }
    case MKMenuMove: {
        NSUInteger generation = ++mk_menu_generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(mk_menu_double * NSEC_PER_SEC)), mk_agents_queue, ^{
            if (generation != mk_menu_generation || !mk_menu_visible) return; // became a double press
            mk_menu_selected = (mk_menu_selected + 1) % mk_menu_ring.count;
            MKMenuRender();
            MKMenuArmTimeout();
        });
        return;
    }
    case MKMenuOpen: {
        mk_menu_last_press = -1; // a third quick press starts over
        MKAgentTarget *target = mk_menu_ring[mk_menu_selected];
        MKMenuClose();
        if (MKFocus(target)) MKOpened(target, mk_menu_ring);
        else mk_hud_show(MKTitleOf(target).UTF8String, "não consegui abrir; a sessão ainda existe?", 3);
        return;
    }
    }
}

static void MKMenuOpenIndex(NSUInteger index) {
    if (!mk_menu_visible || index >= mk_menu_ring.count) return;
    mk_menu_selected = index;
    mk_menu_last_press = NSProcessInfo.processInfo.systemUptime;
    MKMenuPress(); // within the double-press window: opens the selection
}

static void MKMenuStep(int delta) {
    if (!mk_menu_visible || !mk_menu_ring.count) return;
    mk_menu_selected = (mk_menu_selected + mk_menu_ring.count + delta) % mk_menu_ring.count;
    MKMenuRender();
    MKMenuArmTimeout();
}

// Menu bar click: the same menu, with clickable rows.
static void MKMenuToggleClick(void) {
    if (mk_menu_visible) { MKMenuClose(); return; }
    mk_menu_last_press = -1;
    MKMenuPress();
    if (!mk_menu_visible) return;
    mk_menu_clickable = YES;
    mk_menu_generation++; // no timeout while the mouse is in charge
    MKMenuRender();
}

static void MKAgentsAsync(void (^block)(void)) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, MKCreateAgentsQueue);
    dispatch_async(mk_agents_queue, ^{ @autoreleasepool { block(); } });
}

int mk_agents_menu_visible(void) { return atomic_load(&mk_menu_shown); }
void mk_agents_menu_click(void) { MKAgentsAsync(^{ MKMenuToggleClick(); }); }
void mk_agents_menu_open(int index) { MKAgentsAsync(^{ MKMenuOpenIndex((NSUInteger)MAX(index, 0)); }); }
void mk_agents_menu_open_selected(void) { MKAgentsAsync(^{ MKMenuOpenIndex(mk_menu_selected); }); }
void mk_agents_menu_step(int delta) { MKAgentsAsync(^{ MKMenuStep(delta); }); }
void mk_agents_menu_close(void) { MKAgentsAsync(^{ if (mk_menu_visible) MKMenuClose(); }); }

void mk_agents_menu_press(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, MKCreateAgentsQueue);
    dispatch_async(mk_agents_queue, ^{
        @autoreleasepool { MKMenuPress(); }
    });
}

int mk_agents_command(int mode, int desktop) {
    @autoreleasepool {
        if (mode == 2) { MKBottom(); return 0; }
        if (mode == 1) return MKCycle(desktop != 0);
        if (!AXIsProcessTrusted()) {
            fprintf(stderr, "[agent-belt] agents list requer Accessibility\n");
            return -1;
        }
        NSArray *targets = MKDiscover(desktop != 0);
        MKObserve(targets);
        MKDetectWaiting(targets);
        MKEnrich(targets);
        for (MKAgentTarget *target in targets)
            printf("%-12s %s\n             %s\n", [@[@"ocioso", @"trabalhando", @"terminou", @"aguardando"][target.state] UTF8String],
                   MKTitleOf(target).UTF8String, target.detail.UTF8String);
        if (!targets.count) printf("Nenhum terminal com coding agent (Orca ou work).\n");
        NSString *quotas = MKQuotaLine();
        printf("\ncotas: %s\n", quotas ? quotas.UTF8String : "indisponíveis");
        return 0;
    }
}

// Hosts where "back to the bottom" may scroll the view under the pointer.
static BOOL MKAgentHost(NSString *bundle) {
    return [@[@"com.stablyai.orca", @"com.openai.codex", @"com.anthropic.claudefordesktop",
              @"com.mitchellh.ghostty", @"com.apple.Terminal", @"com.googlecode.iterm2",
              @"com.github.wez.wezterm", @"net.kovidgoyal.kitty", @"org.alacritty",
              @"dev.warp.Warp-Stable"] containsObject:bundle];
}

// Knob button: every agent pane scrolled back into tmux history returns to
// live output, and the agent view under the pointer scrolls to its end.
static void MKBottom(void) {
    NSUInteger cancelled = 0;
    for (NSArray<NSString *> *pane in MKTmux(@[@"list-panes", @"-a", @"-F",
                                               @"#{pane_id}\t#{pane_in_mode}\t#{pane_current_command}"])) {
        if (pane.count < 3 || ![pane[1] isEqual:@"1"] || !MKAgentCommand(pane[2])) continue;
        MKTmux(@[@"send-keys", @"-t", pane[0], @"-X", @"cancel"]);
        cancelled++;
    }
    if (MKAgentHost(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier))
        for (int i = 0; i < 4; i++) mk_scroll_down(5000);
    fprintf(stderr, "[agent-belt] AGENTS ↓ fim (%lu pane(s) tmux)\n", (unsigned long)cancelled);
}

void mk_agents_bottom(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, MKCreateAgentsQueue);
    dispatch_async(mk_agents_queue, ^{
        @autoreleasepool { MKBottom(); }
    });
}

// Away from the Mac, an agent waiting for you reaches the phone: WhatsApp via
// ford-send once per waiting episode, after 3 min of waiting with no input on
// the Mac for 2 min. The message carries only the session title.
static void MKNotifyAway(NSArray<MKAgentTarget *> *ring) {
    static NSMutableDictionary<NSString *, NSNumber *> *since;
    static NSMutableSet<NSString *> *notified;
    if (!since) { since = [NSMutableDictionary dictionary]; notified = [NSMutableSet set]; }
    const double now = NSProcessInfo.processInfo.systemUptime;
    NSMutableSet *waiting = [NSMutableSet set];
    for (MKAgentTarget *target in ring) if (target.state == MKStateWaiting) [waiting addObject:target.key];
    for (NSString *key in since.allKeys) if (![waiting containsObject:key]) [since removeObjectForKey:key];
    [notified intersectSet:waiting];
    const double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    NSString *ford = MKToolPath(@"ford-send", @"AGENT_BELT_FORD_SEND");
    for (MKAgentTarget *target in ring) {
        if (target.state != MKStateWaiting) continue;
        if (!since[target.key]) since[target.key] = @(now);
        if ([notified containsObject:target.key] || now - since[target.key].doubleValue < 180 || idle < 120 || !ford) continue;
        [notified addObject:target.key];
        NSString *name = MKEnrichedName(target);
        NSTask *task = [NSTask new]; // no timeout: a text message takes ~3 s
        task.executableURL = [NSURL fileURLWithPath:ford];
        task.arguments = @[[NSString stringWithFormat:@"🔴 %@ está esperando uma decisão sua há %.0f min", name,
                            (now - since[target.key].doubleValue) / 60]];
        task.standardOutput = task.standardError = [NSFileHandle fileHandleWithNullDevice];
        if ([task launchAndReturnError:nil]) fprintf(stderr, "[agent-belt] aviso no WhatsApp: %s\n", name.UTF8String);
    }
}

// Daemon only: every 5 s, catch "finished" and "waiting" between presses and
// reflect them on the key LEDs.
void mk_agents_monitor(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    static dispatch_source_t timer;
    pthread_once(&once, MKCreateAgentsQueue);
    if (timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, mk_agents_queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            NSArray *ring = MKTerminalTargets();
            MKObserve(ring);
            MKDetectWaiting(ring);
            MKUpdateLed(ring);
            MKNotifyAway(ring);
        }
    });
    dispatch_resume(timer);
}

// ---------------------------------------------------------------- new agents by voice

// Held push-to-talk while the agent menu is up: the transcript is a command such
// as "crie um agente no windows com codex no coreum para investigar o login".
// A small model turns it into work's arguments; a new Orca terminal runs work.

static NSData *MKRunLong(NSString *path, NSArray<NSString *> *arguments, double timeout) {
    if (!path) return nil;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
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
    return task.terminationStatus == 0 ? output : nil;
}

static NSArray<NSString *> *MKWorkHosts(void) {
    NSString *config = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@".config/work/hosts.conf"]
                                                 encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *hosts = [NSMutableArray array];
    for (NSString *line in [config componentsSeparatedByString:@"\n"]) {
        NSArray *words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (words.count >= 2 && [words[0] isEqual:@"host"]) [hosts addObject:words[1]];
    }
    return hosts;
}

static NSArray<NSString *> *MKLocalRepos(void) {
    NSMutableOrderedSet *repos = [NSMutableOrderedSet orderedSet];
    for (NSString *dir in @[@"dev/micromed", @"dev/frb", @"dev"]) {
        NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:dir];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil])
            if ([NSFileManager.defaultManager fileExistsAtPath:[[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@".git"]])
                [repos addObject:name];
    }
    return repos.array;
}

static NSString *MKShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// Pure: the model's reply (JSON, possibly wrapped in prose) to a work command
// line, or nil with a reason. Hosts must be known; task must be a slug.
static NSString *MKWorkCommand(NSString *reply, NSArray<NSString *> *hosts, NSString **why, NSDictionary **parsed) {
    NSRange open = [reply rangeOfString:@"{"], close = [reply rangeOfString:@"}" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location < open.location) { *why = @"não entendi o comando"; return nil; }
    NSData *json = [[reply substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *spec = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![spec isKindOfClass:NSDictionary.class]) { *why = @"não entendi o comando"; return nil; }
    if (parsed) *parsed = spec;
    NSString *host = MKString(spec[@"host"]), *agent = MKString(spec[@"agent"]).lowercaseString;
    NSString *repo = MKString(spec[@"repo"]), *task = MKString(spec[@"task"]), *prompt = MKString(spec[@"prompt"]);
    if (host.length && ![hosts containsObject:host]) { *why = [NSString stringWithFormat:@"máquina desconhecida: %@", host]; return nil; }
    if (![@[@"claude", @"codex", @"shell"] containsObject:agent]) agent = @"claude";
    if ([task rangeOfString:@"^[A-Za-z0-9._-]{1,40}$" options:NSRegularExpressionSearch].location == NSNotFound) { *why = @"faltou um nome curto para a tarefa"; return nil; }
    if (!repo.length || [repo rangeOfString:@"^[A-Za-z0-9._-]+$" options:NSRegularExpressionSearch].location == NSNotFound) { *why = @"diga em qual repositório"; return nil; }
    NSMutableString *command = [NSMutableString stringWithString:@"work"];
    if (host.length) [command appendFormat:@" %@", host];
    [command appendFormat:@" %@ %@ --agent %@", task, repo, agent];
    if (prompt.length) [command appendFormat:@" --prompt %@", MKShellQuote(prompt)];
    return command;
}

static void MKOpenTerminal(NSString *command, NSString *title) {
    NSRunningApplication *orca = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.stablyai.orca"].firstObject;
    if (orca && MKOrca(@[@"terminal", @"create", @"--worktree", [@"path:" stringByAppendingString:NSHomeDirectory()],
                         @"--title", title, @"--command", command, @"--focus"])) {
        MKRestoreWindows(orca);
        MKBringToFront(orca);
        return;
    }
    // No Orca: a .command file opens in Terminal.
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/agent-belt"];
    NSString *script = [dir stringByAppendingPathComponent:@"new-agent.command"];
    [[NSString stringWithFormat:@"#!/bin/zsh -l\n%@\n", command] writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:script error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:script]];
}

static int MKVoiceCommand(NSString *text, BOOL dryRun) {
    NSArray *hosts = MKWorkHosts(), *repos = MKLocalRepos();
    mk_hud_show("Entendendo o comando…", text.UTF8String, 1);
    NSString *instructions = [NSString stringWithFormat:
        @"Converta o pedido de voz abaixo nos argumentos de uma ferramenta que cria uma sessão de coding agent. "
         "Responda SOMENTE um objeto JSON, sem texto fora dele, com as chaves:\n"
         "host: uma destas máquinas, ou null para esta máquina (%@). \"windows\" costuma ser a que tem windows no nome; \"mac\"/\"aqui\"/\"local\" é null.\n"
         "agent: \"claude\", \"codex\" ou \"shell\" (claude se não disser).\n"
         "repo: o nome do repositório; prefira um destes quando parecer o mesmo (%@); null se não disser.\n"
         "task: slug curto em minúsculas com hífens (até 30 caracteres) que resuma a tarefa.\n"
         "prompt: a instrução para o agente, em português, reescrita com clareza, sem mencionar máquina/agente/repositório.\n\n"
         "Pedido: %@", [hosts componentsJoinedByString:@", "], [repos componentsJoinedByString:@", "], text];
    NSData *reply = MKRunLong(MKToolPath(@"claude", @"AGENT_BELT_CLAUDE"),
                              @[@"-p", @"--model", @"haiku", @"--output-format", @"text", instructions], 90);
    NSString *why = nil;
    NSDictionary *spec = nil;
    NSString *command = reply ? MKWorkCommand([[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] ?: @"", hosts, &why, &spec) : nil;
    if (!reply) why = @"o claude não respondeu (claude -p)";
    if (!command) {
        fprintf(stderr, "[agent-belt] comando de voz recusado: %s\n", why.UTF8String);
        mk_hud_show([@"Não criei: " stringByAppendingString:why].UTF8String, text.UTF8String, 3);
        return -1;
    }
    if (dryRun) { printf("%s\n", command.UTF8String); return 0; }
    NSString *host = MKString(spec[@"host"]).length ? spec[@"host"] : @"este Mac";
    NSString *title = [NSString stringWithFormat:@"🦇 %@ · %@ @ %@", spec[@"task"], spec[@"agent"] ?: @"claude", host];
    fprintf(stderr, "[agent-belt] novo agente: %s\n", command.UTF8String);
    mk_hud_show(title.UTF8String, (MKString(spec[@"prompt"]) ?: text).UTF8String, 1);
    MKOpenTerminal(command, MKString(spec[@"task"]));
    return 0;
}

void mk_agents_voice_command(const char *text) {
    NSString *copy = @(text);
    MKAgentsAsync(^{ MKVoiceCommand(copy, NO); });
}

// `agb new [--dry-run] <pedido>`: the same path from a terminal or another agent.
int mk_agents_new(const char *text, int dry_run) {
    @autoreleasepool { return MKVoiceCommand(@(text), dry_run != 0); }
}
