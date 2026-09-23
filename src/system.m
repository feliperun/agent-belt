#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "macos_shim.h"

// Secrets live in the login Keychain: a LaunchAgent does not inherit the
// shell's environment. Caller frees with mk_free_buffer.
char *mk_keychain_secret(const char *service, const char *account) {
    @autoreleasepool {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @(service),
            (__bridge id)kSecAttrAccount: @(account),
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        };
        CFTypeRef result = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return NULL;
        NSData *data = CFBridgingRelease(result);
        char *secret = malloc(data.length + 1);
        if (!secret) return NULL;
        memcpy(secret, data.bytes, data.length);
        secret[data.length] = 0;
        return secret;
    }
}

// A second daemon would double every key and scroll.
int mk_single_instance(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/agent-belt"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open([dir stringByAppendingPathComponent:@"daemon.lock"].fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return 0; // held until exit
}

// A running process never sees a grant made after it asked (AXIsProcessTrusted
// stays stale), so a missing permission is reported and the caller exits for
// launchd to restart it. The system prompt is shown at most every 10 minutes.
int mk_check_permissions(void) {
    BOOL input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
    BOOL accessibility = AXIsProcessTrusted();
    if (input && accessibility) return 0;
    NSString *marker = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/agent-belt/permission-prompt"];
    NSDate *last = [NSFileManager.defaultManager attributesOfItemAtPath:marker error:nil].fileModificationDate;
    if (!last || -last.timeIntervalSinceNow > 600) {
        [NSFileManager.defaultManager createDirectoryAtPath:marker.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES attributes:nil error:nil];
        [@"" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (!input) IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        if (!accessibility)
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
    }
    fprintf(stderr, "[agent-belt] faltam permissões em Ajustes do Sistema > Privacidade e Segurança: %s%s%s\n",
            input ? "" : "Monitoramento de Entrada", !input && !accessibility ? ", " : "",
            accessibility ? "" : "Acessibilidade");
    return -1;
}

// launchd appends stdout/stderr to the log forever; start each run fresh past 2 MB.
void mk_trim_log(void) {
    struct stat info;
    if (fstat(STDERR_FILENO, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 2 * 1024 * 1024)
        ftruncate(STDERR_FILENO, 0);
}

static NSString *MKCommandOutput(NSString *path, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return @"";
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSUInteger MKDeviceCount(uint16_t vendor_id, uint16_t product_id) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) return 0;
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)@{
        @kIOHIDVendorIDKey: @(vendor_id), @kIOHIDProductIDKey: @(product_id)});
    IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    NSUInteger count = devices ? (NSUInteger)CFSetGetCount(devices) : 0;
    if (devices) CFRelease(devices);
    CFRelease(manager);
    return count;
}

// `agent-belt status`: one screen instead of reading launchctl and the log.
int mk_status_report(uint16_t vendor_id, uint16_t product_id, const char *key_env) {
    @autoreleasepool {
        NSString *service = [NSString stringWithFormat:@"gui/%d/com.frb.agentbelt", getuid()];
        NSString *agent = MKCommandOutput(@"/bin/launchctl", @[@"print", service]);
        NSString *pid = nil;
        for (NSString *line in [agent componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([trimmed hasPrefix:@"pid = "]) pid = [trimmed substringFromIndex:6];
        }
        if (!agent.length) printf("daemon:       não instalado (rode ./install.sh)\n");
        else if (pid) printf("daemon:       rodando (pid %s)\n", pid.UTF8String);
        else printf("daemon:       instalado, mas parado\n");

        NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/agent-belt.log"];
        NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSRange ready = [log rangeOfString:@"] pronto" options:NSBackwardsSearch];
        NSRange missing = [log rangeOfString:@"] faltam permissões" options:NSBackwardsSearch];
        if (missing.location != NSNotFound && (ready.location == NSNotFound || missing.location > ready.location)) {
            NSString *line = [[log substringFromIndex:missing.location + 2] componentsSeparatedByString:@"\n"].firstObject;
            printf("permissões:   %s\n", line.UTF8String);
        } else {
            printf("permissões:   %s\n", ready.location != NSNotFound ? "ok" : "desconhecido (daemon ainda não iniciou)");
        }

        NSUInteger devices = MKDeviceCount(vendor_id, product_id);
        printf("dispositivo:  %s (VID=0x%04x PID=0x%04x)\n", devices ? "conectado" : "não encontrado", vendor_id, product_id);

        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @"agent-belt",
            (__bridge id)kSecAttrAccount: @"deepgram",
            (__bridge id)kSecReturnAttributes: @YES,
        };
        CFTypeRef attributes = NULL;
        BOOL keychain = SecItemCopyMatching((__bridge CFDictionaryRef)query, &attributes) == errSecSuccess;
        if (attributes) CFRelease(attributes);
        // Reads the secret like the daemon does (same signed app), so a missing
        // Keychain grant shows up here as the system prompt, not mid-dictation.
        char *secret = keychain ? mk_keychain_secret("agent-belt", "deepgram") : NULL;
        if (secret) { memset(secret, 0, strlen(secret)); free(secret); }
        printf("deepgram:     %s\n", secret ? "chave no Keychain, legível pelo app"
                                    : keychain ? "chave no Keychain, mas o app não tem acesso (rode status de novo e autorize)"
                                    : getenv(key_env) ? "só no ambiente do terminal (o LaunchAgent não vê)" : "sem chave");

        printf("config:       %s/.config/agent-belt/config.json\n", NSHomeDirectory().UTF8String);
        printf("log:          %s\n", logPath.UTF8String);
        NSArray *lines = [log componentsSeparatedByString:@"\n"];
        NSUInteger shown = 0;
        for (NSInteger i = (NSInteger)lines.count - 1; i >= 0 && shown < 5; i--) if ([lines[i] length]) shown++;
        if (shown) printf("\núltimas linhas do log:\n");
        NSUInteger start = lines.count;
        for (NSUInteger found = 0; start > 0 && found < shown; ) if ([lines[--start] length]) found++;
        for (NSUInteger i = start; i < lines.count; i++) if ([lines[i] length]) printf("  %s\n", [lines[i] UTF8String]);
        return 0;
    }
}
