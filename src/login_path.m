#import <Foundation/Foundation.h>
#include "macos_shim.h"

// launchd starts the daemon with a minimal PATH, and everything the daemon
// starts inherits it: the tmux server of an adopted or new agent, and through it
// the hooks Claude Code runs ("node: command not found", node comes from asdf).
// Only an interactive login shell knows the PATH of the user's terminals.
static NSString *const MKPathMark = @"__AGB_PATH__";

// The PATH between two marks in a shell's output, which also carries whatever
// the rc files print. Nil when there is none.
NSString *MKParseLoginPath(NSString *output) {
    NSRange open = [output rangeOfString:MKPathMark];
    if (open.location == NSNotFound) return nil;
    NSString *rest = [output substringFromIndex:NSMaxRange(open)];
    NSRange close = [rest rangeOfString:MKPathMark];
    if (close.location == NSNotFound) return nil;
    NSString *path = [rest substringToIndex:close.location];
    return [path hasPrefix:@"/"] ? path : nil;
}

static NSString *MKLoginShellPath(NSString *shell, double timeout) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:shell];
    task.arguments = @[@"-ilc", [NSString stringWithFormat:@"printf '%@%%s%@' \"$PATH\"", MKPathMark, MKPathMark]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    // An rc file that waits for input is ended; that closes the pipe below.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.running) [task terminate];
    });
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationReason != NSTaskTerminationReasonExit) return nil;
    return MKParseLoginPath([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"");
}

void mk_login_path(void) {
    @autoreleasepool {
        const char *shell = getenv("SHELL");
        NSString *path = MKLoginShellPath(shell && *shell ? @(shell) : @"/bin/zsh", 8);
        if (path) setenv("PATH", path.UTF8String, 1);
        else fprintf(stderr, "[agent-belt] could not read the login shell's PATH; children keep launchd's\n");
    }
}
