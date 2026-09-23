#import <AppKit/AppKit.h>
#include "macos_shim.h"

// Media keys arrive as NX_SYSDEFINED events whose payload only NSEvent decodes:
// subtype 8 (aux control buttons), data1 = key << 16 | state << 8.
int mk_system_media_key(const void *event, int *key, int *pressed) {
    @autoreleasepool {
        NSEvent *media = [NSEvent eventWithCGEvent:(CGEventRef)event];
        if (media.type != NSEventTypeSystemDefined || media.subtype != 8) return 0;
        const NSInteger data = media.data1;
        *key = (int)((data & 0xFFFF0000) >> 16);
        *pressed = ((data & 0xFF00) >> 8) == 0xA;
        return 1;
    }
}
