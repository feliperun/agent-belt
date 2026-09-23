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
@end
@implementation MKAgentTarget
@end

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
    NSData *data = MKRun(MKToolPath(@"orca", @"MINIKEYBOARD_ORCA_CLI"), [arguments arrayByAddingObject:@"--json"]);
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
    NSData *data = MKRun(MKToolPath(@"tmux", @"MINIKEYBOARD_TMUX"), arguments);
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

static NSString *MKProcessEnv(pid_t pid, const char *name) {
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

static BOOL MKLiveTerminal(NSDictionary *terminal) {
    return MKBool(terminal[@"connected"]) && !MKBool(terminal[@"orphaned"]) &&
           [MKString(terminal[@"handle"]) hasPrefix:@"term_"];
}


static NSArray<MKAgentTarget *> *MKTerminalTargets(void) {
    NSDictionary *agents = MKSessionAgents(MKTmux(@[@"list-panes", @"-a", @"-F",
        @"#{session_name}\t#{@work_agent}\t#{pane_current_command}"]));
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
        target.bundle = app.bundleIdentifier;
        target.app = app;
        [outside addObject:target];
    }

    NSMutableArray<MKAgentTarget *> *targets = [NSMutableArray array];
    NSRunningApplication *orca = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.stablyai.orca"].firstObject;
    NSDictionary *result = orca ? MKOrca(@[@"terminal", @"list", @"--limit", @"100"]) : nil;
    if (orca && !result) fprintf(stderr, "[minikeyboard] Orca: CLI indisponível; confira MINIKEYBOARD_ORCA_CLI\n");
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
        target.label = [NSString stringWithFormat:@"%@ · %@", session ?: (title.length ? title : handle), agent];
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

static BOOL MKFocus(MKAgentTarget *target) {
    if (target.app.terminated) return NO;
    if (target.terminal) {
        if (!MKOrca(@[@"terminal", @"switch", @"--terminal", target.terminal])) return NO;
        return MKBringToFront(target.app) && MKWaitFrontmost(target.app);
    }
    if (target.tmuxSession) return MKBringToFront(target.app) && MKWaitFrontmost(target.app);
    id window = target.window;
    if (!MKAttr(window, kAXRoleAttribute)) return NO;
    AXUIElementSetAttributeValue((__bridge AXUIElementRef)window, kAXMinimizedAttribute, kCFBooleanFalse);
    if (!MKBringToFront(target.app)) return NO;
    if (AXUIElementPerformAction((__bridge AXUIElementRef)window, kAXRaiseAction) != kAXErrorSuccess) return NO;
    if ([target.bundle isEqual:@"com.anthropic.claudefordesktop"]) {
        id code = MKFindCodeControl(window);
        if (!code) { fprintf(stderr, "[minikeyboard] Claude: modo Code não exposto pela acessibilidade\n"); return NO; }
        if (!MKBool(MKAttr(code, kAXValueAttribute)) && !MKPress(code)) return NO;
    }
    if (target.control && !MKPress(target.control)) return NO;
    // Let focus settle without ever sending a keyboard shortcut to an unknown receiver.
    return MKWaitFrontmost(target.app);
}

// Orca's "active" worktree selector reflects the caller's worktree, not the UI,
// so the ring position is ours: the last agent focused, shared by daemon and CLI.
static NSString *MKLastKeyPath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/minikeyboard"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"last-agent"];
}

static NSArray<MKAgentTarget *> *mk_ring;
static int MKCycle(BOOL desktop) {
    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "[minikeyboard] alternar agents requer permissão de Accessibility\n");
        return -1;
    }
    mk_ring = MKStableRing(mk_ring, MKDiscover(desktop));
    if (!mk_ring.count) { fprintf(stderr, "[minikeyboard] nenhum terminal com coding agent (Orca ou work)\n"); return -1; }
    NSString *lastKey = [NSString stringWithContentsOfFile:MKLastKeyPath() encoding:NSUTF8StringEncoding error:nil];
    NSUInteger start = MKNextIndex(mk_ring, lastKey, NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
    for (NSUInteger offset = 0; offset < mk_ring.count; offset++) {
        MKAgentTarget *target = mk_ring[(start + offset) % mk_ring.count];
        if (!MKFocus(target)) continue; // app/tab may have closed after discovery
        [target.key writeToFile:MKLastKeyPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fprintf(stderr, "[minikeyboard] AGENT → %s\n", target.label.UTF8String);
        return 0;
    }
    fprintf(stderr, "[minikeyboard] não consegui focar as sessões; confira Accessibility\n");
    return -1;
}

static dispatch_queue_t mk_agents_queue;
static void MKCreateAgentsQueue(void) {
    mk_agents_queue = dispatch_queue_create("minikeyboard.agents", DISPATCH_QUEUE_SERIAL);
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

int mk_agents_command(int next, int desktop) {
    @autoreleasepool {
        if (next) return MKCycle(desktop != 0);
        if (!AXIsProcessTrusted()) {
            fprintf(stderr, "[minikeyboard] agents list requer Accessibility\n");
            return -1;
        }
        NSArray *targets = MKDiscover(desktop != 0);
        for (MKAgentTarget *target in targets)
            printf("%s\t%s\t%s\n", target.selected ? "*" : " ", target.bundle.UTF8String, target.label.UTF8String);
        if (!targets.count) printf("Nenhum terminal com coding agent (Orca ou work).\n");
        return 0;
    }
}
