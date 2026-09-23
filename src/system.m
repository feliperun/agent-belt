#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
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
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/minikeyboard"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open([dir stringByAppendingPathComponent:@"daemon.lock"].fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return 0; // held until exit
}

// Under launchd a missing permission must not become a crash loop: ask once,
// then wait until System Settings grants it.
void mk_wait_permissions(void) {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
    BOOL warned = NO;
    for (;;) {
        BOOL input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
        BOOL accessibility = AXIsProcessTrusted();
        if (input && accessibility) {
            if (warned) fprintf(stderr, "[minikeyboard] permissões concedidas\n");
            return;
        }
        if (!warned) {
            fprintf(stderr, "[minikeyboard] aguardando permissões em Ajustes do Sistema > Privacidade e Segurança: %s%s%s\n",
                    input ? "" : "Monitoramento de Entrada", !input && !accessibility ? ", " : "",
                    accessibility ? "" : "Acessibilidade");
            warned = YES;
        }
        sleep(2);
    }
}
