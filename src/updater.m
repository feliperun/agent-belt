#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdlib.h>
#include "macos_shim.h"

// Every 6 h the daemon asks GitHub for the latest release. A newer one shows a
// notification with its notes and an "Atualizar" action, and a line in the
// agent menu. Updating builds that release from source (scripts/update.sh).

static NSString *const mk_repo = @"feliperun/agent-belt";
static NSString *mk_version;
static NSString *mk_update_tag, *mk_update_url;

// Pure: numeric comparison of dotted versions, "v" prefix ignored.
NSComparisonResult MKCompareVersions(NSString *a, NSString *b) {
    NSArray *x = [[a stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"v"]] componentsSeparatedByString:@"."];
    NSArray *y = [[b stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"v"]] componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        NSInteger p = i < x.count ? [x[i] integerValue] : 0, q = i < y.count ? [y[i] integerValue] : 0;
        if (p != q) return p < q ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSString *MKUpdateScript(void) {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    char resolved[PATH_MAX];
    if (_NSGetExecutablePath(path, &size) != 0 || !realpath(path, resolved)) return nil;
    // .../Agent Belt.app/Contents/MacOS/agb -> .../Contents/Resources/update.sh
    NSString *script = [[[@(resolved) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:@"Resources/update.sh"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:script] ? script : nil;
}

// A tag reaches a shell and a download URL, and it arrives from the GitHub API
// or from `agb update <tag>`: only the shape of a release tag is ever accepted.
static BOOL MKIsReleaseTag(NSString *tag) {
    NSCharacterSet *forbidden = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+"] invertedSet];
    return tag.length > 0 && tag.length <= 64 && [tag rangeOfCharacterFromSet:forbidden].location == NSNotFound;
}

// The installer stops this daemon, and launchd then kills its whole process
// group: the update runs in a session of its own, logging to a file.
static int MKStartUpdate(NSString *tag) {
    if (tag && !MKIsReleaseTag(tag)) { fprintf(stderr, "[agent-belt] not a release tag; refusing to update\n"); return -1; }
    NSString *script = MKUpdateScript();
    if (!script) { fprintf(stderr, "[agent-belt] update.sh is missing from the app; reinstall with ./install.sh\n"); return -1; }
    NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/agent-belt-update.log"];
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    pid_t pid;
    // The script, the tag and the log path are positional arguments: nothing
    // that came over the network is ever spliced into the command itself.
    char *argv[] = {"/bin/bash", "-lc", "exec \"$0\" ${1:+\"$1\"} >>\"$2\" 2>&1",
                    (char *)script.UTF8String, (char *)(tag ?: @"").UTF8String, (char *)log.UTF8String, NULL};
    extern char **environ;
    int result = posix_spawn(&pid, "/bin/bash", NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    fprintf(stderr, "[agent-belt] updating to %s (log: %s)\n", (tag ?: @"the latest version").UTF8String, log.UTF8String);
    return result == 0 ? 0 : -1;
}

@interface MKUpdateDelegate : NSObject <UNUserNotificationCenterDelegate>
@end
@implementation MKUpdateDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completion {
    (void)center;
    NSDictionary *info = response.notification.request.content.userInfo;
    if ([response.actionIdentifier isEqual:@"update"]) MKStartUpdate(info[@"tag"]);
    else if ([response.actionIdentifier isEqual:UNNotificationDefaultActionIdentifier] && [info[@"url"] length])
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:info[@"url"]]];
    completion();
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    (void)center; (void)notification;
    completion(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}
@end

static void MKNotifyUpdate(NSString *tag, NSString *notes, NSString *url) {
    NSString *seen = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/agent-belt/notified-version"];
    if ([[NSString stringWithContentsOfFile:seen encoding:NSUTF8StringEncoding error:nil] isEqual:tag]) return;
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                          completionHandler:^(BOOL granted, NSError *error) {
        (void)error;
        if (!granted) return;
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = [NSString stringWithFormat:@"Agent Belt %@ is available", tag];
        // Release notes are Markdown: keep the readable lines.
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *line in [notes componentsSeparatedByString:@"\n"]) {
            NSString *clean = [[line stringByReplacingOccurrencesOfString:@"#" withString:@""]
                               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (clean.length && ![clean hasPrefix:@"["]) [lines addObject:clean];
        }
        content.body = lines.count ? [lines componentsJoinedByString:@"\n"] : @"A new version is out.";
        content.categoryIdentifier = @"agent-belt-update";
        content.userInfo = @{@"tag": tag, @"url": url ?: @""};
        [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:tag content:content trigger:nil]
                 withCompletionHandler:nil];
        [tag writeToFile:seen atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
}

// The release page the notification opens on a click: an https github.com URL
// or nothing. The response must not hand the workspace an arbitrary scheme.
static NSString *MKReleaseURL(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSURL *url = [NSURL URLWithString:value];
    NSString *host = url.host.lowercaseString;
    if (![url.scheme isEqual:@"https"]) return nil;
    return ([host isEqual:@"github.com"] || [host hasSuffix:@".github.com"]) ? value : nil;
}

// A release payload is a few kB of JSON. Anything else — an error page, a
// redirect to something huge, a body that never ends — is not one.
static NSDictionary *MKReleaseBody(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (error || status != 200 || data.length == 0 || data.length > 1024 * 1024) return nil;
    NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [release isKindOfClass:NSDictionary.class] ? release : nil;
}

static void MKCheckForUpdate(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", mk_repo]]];
    [request setValue:@"agent-belt" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *release = MKReleaseBody(data, response, error);
        NSString *tag = release[@"tag_name"];
        if (![tag isKindOfClass:NSString.class] || !MKIsReleaseTag(tag) ||
            MKCompareVersions(tag, mk_version) != NSOrderedDescending) return;
        NSString *url = MKReleaseURL(release[@"html_url"]);
        NSString *notes = [release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            mk_update_tag = tag;
            mk_update_url = url;
            fprintf(stderr, "[agent-belt] new version available: %s\n", tag.UTF8String);
            MKNotifyUpdate(tag, notes, url);
        });
    }] resume];
}

void mk_updater_start(const char *version) {
    mk_version = @(version);
    static MKUpdateDelegate *delegate;
    delegate = [MKUpdateDelegate new];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = delegate;
    UNNotificationAction *update = [UNNotificationAction actionWithIdentifier:@"update" title:@"Update" options:UNNotificationActionOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:
        [UNNotificationCategory categoryWithIdentifier:@"agent-belt-update" actions:@[update] intentIdentifiers:@[] options:0]]];
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 6 * 3600 * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ MKCheckForUpdate(); });
    dispatch_resume(timer);
}

// Agent menu footer: "⬆️ v0.2.0 available · agb update", or NULL.
const char *mk_update_line(void) {
    return mk_update_tag ? [NSString stringWithFormat:@"⬆️ %@ available · agb update", mk_update_tag].UTF8String : NULL;
}

// Menu bar: check now; the result lands in the menu and, if new, a notification.
void mk_update_check_now(void) { dispatch_async(dispatch_get_main_queue(), ^{ MKCheckForUpdate(); }); }
const char *mk_update_available(void) { return mk_update_tag.UTF8String; }
const char *mk_app_version(void) { return mk_version.UTF8String ?: "?"; }

// `agb update [tag]`
int mk_update_run(const char *tag) { @autoreleasepool { return MKStartUpdate(tag && *tag ? @(tag) : nil); } }
