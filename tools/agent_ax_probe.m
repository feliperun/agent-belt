#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static id attr(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, key, &value);
    return CFBridgingRelease(value);
}
static void walk(AXUIElementRef element, int depth, int *remaining) {
    if (depth > 24 || --*remaining <= 0) return;
    NSString *role = attr(element, kAXRoleAttribute);
    if ([role isEqual:@"AXMenuBar"]) return;
    // Inspect navigation metadata only, never conversation text or editor values.
    if ([role isEqual:@"AXStaticText"] || [role isEqual:@"AXTextArea"] ||
        [role isEqual:@"AXTextField"]) return;
    NSString *title = attr(element, kAXTitleAttribute) ?: @"";
    NSString *desc = attr(element, kAXDescriptionAttribute) ?: @"";
    NSString *ident = attr(element, kAXIdentifierAttribute) ?: @"";
    NSString *subrole = attr(element, kAXSubroleAttribute) ?: @"";
    printf("%*s%s title=%s description=%s id=%s subrole=%s selected=%s\n", depth, "",
           role.UTF8String, title.UTF8String, desc.UTF8String, ident.UTF8String,
           subrole.UTF8String, [[attr(element, kAXSelectedAttribute) description] UTF8String]);
    for (id child in attr(element, kAXChildrenAttribute))
        walk((__bridge AXUIElementRef)child, depth + 1, remaining);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 1;
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@(argv[1])]) {
            AXUIElementRef root = AXUIElementCreateApplication(app.processIdentifier);
            AXUIElementSetMessagingTimeout(root, 1.0);
            fprintf(stderr, "manual accessibility: %d\n", AXUIElementSetAttributeValue(root, CFSTR("AXManualAccessibility"), kCFBooleanTrue));
            [NSThread sleepForTimeInterval:.4];
            int remaining = 1500;
            walk(root, 0, &remaining);
            CFRelease(root);
        }
    }
}
