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

// The installer stops this daemon, and launchd then kills its whole process
// group: the update runs in a session of its own, logging to a file.
static int MKStartUpdate(NSString *tag) {
    NSString *script = MKUpdateScript();
    if (!script) { fprintf(stderr, "[agent-belt] update.sh não encontrado no app; reinstale com ./install.sh\n"); return -1; }
    NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/agent-belt-update.log"];
    NSString *line = [NSString stringWithFormat:@"exec %@ %@ >>%@ 2>&1", [script stringByReplacingOccurrencesOfString:@" " withString:@"\\ "],
                      tag ?: @"", [log stringByReplacingOccurrencesOfString:@" " withString:@"\\ "]];
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    pid_t pid;
    char *argv[] = {"/bin/bash", "-lc", (char *)line.UTF8String, NULL};
    extern char **environ;
    int result = posix_spawn(&pid, "/bin/bash", NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    fprintf(stderr, "[agent-belt] atualizando para %s (log: %s)\n", (tag ?: @"a última versão").UTF8String, log.UTF8String);
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
    else if ([response.actionIdentifier isEqual:UNNotificationDefaultActionIdentifier] && info[@"url"])
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
        content.title = [NSString stringWithFormat:@"Agent Belt %@ disponível", tag];
        // Release notes are Markdown: keep the readable lines.
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *line in [notes componentsSeparatedByString:@"\n"]) {
            NSString *clean = [[line stringByReplacingOccurrencesOfString:@"#" withString:@""]
                               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (clean.length && ![clean hasPrefix:@"["]) [lines addObject:clean];
        }
        content.body = lines.count ? [lines componentsJoinedByString:@"\n"] : @"Nova versão publicada.";
        content.categoryIdentifier = @"agent-belt-update";
        content.userInfo = @{@"tag": tag, @"url": url ?: @""};
        [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:tag content:content trigger:nil]
                 withCompletionHandler:nil];
        [tag writeToFile:seen atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
}

static void MKCheckForUpdate(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", mk_repo]]];
    [request setValue:@"agent-belt" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        if (error || !data) return;
        NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *tag = [release isKindOfClass:NSDictionary.class] ? release[@"tag_name"] : nil;
        if (![tag isKindOfClass:NSString.class] || MKCompareVersions(tag, mk_version) != NSOrderedDescending) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            mk_update_tag = tag;
            mk_update_url = release[@"html_url"];
            fprintf(stderr, "[agent-belt] nova versão disponível: %s\n", tag.UTF8String);
            MKNotifyUpdate(tag, [release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : @"", mk_update_url);
        });
    }] resume];
}

void mk_updater_start(const char *version) {
    mk_version = @(version);
    static MKUpdateDelegate *delegate;
    delegate = [MKUpdateDelegate new];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = delegate;
    UNNotificationAction *update = [UNNotificationAction actionWithIdentifier:@"update" title:@"Atualizar" options:UNNotificationActionOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:
        [UNNotificationCategory categoryWithIdentifier:@"agent-belt-update" actions:@[update] intentIdentifiers:@[] options:0]]];
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 6 * 3600 * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ MKCheckForUpdate(); });
    dispatch_resume(timer);
}

// Agent menu footer: "⬆️ v0.2.0 disponível · agb update", or NULL.
const char *mk_update_line(void) {
    return mk_update_tag ? [NSString stringWithFormat:@"⬆️ %@ disponível · agb update", mk_update_tag].UTF8String : NULL;
}

// `agb update [tag]`
int mk_update_run(const char *tag) { @autoreleasepool { return MKStartUpdate(tag && *tag ? @(tag) : nil); } }
