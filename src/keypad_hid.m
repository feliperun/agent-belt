#import <Foundation/Foundation.h>
#include "keypad_hid.h"

// The Bluetooth firmware advertises different IDs, also used by other keyboards.
// Match its exact product name AND transport, never those IDs alone.
static NSString *const MKKeypadName = @"MINI-KEYBOARD";
static NSArray<NSString *> *MKKeypadTransports(void) {
    return @[@"Bluetooth", @"Bluetooth Low Energy"];
}

CFArrayRef mk_keypad_matching(uint16_t vendor_id, uint16_t product_id, int include_f5) {
    @autoreleasepool {
        NSMutableArray *matches = [NSMutableArray arrayWithObject:@{
            @kIOHIDVendorIDKey: @(vendor_id), @kIOHIDProductIDKey: @(product_id)}];
        for (NSString *transport in MKKeypadTransports()) {
            [matches addObject:@{@kIOHIDProductKey: MKKeypadName, @kIOHIDTransportKey: transport}];
        }
        if (include_f5) [matches addObject:@{
            @kIOHIDDeviceUsagePageKey: @1, @kIOHIDDeviceUsageKey: @6}];
        return (CFArrayRef)CFBridgingRetain(matches);
    }
}

int mk_keypad_is_device(IOHIDDeviceRef device, uint16_t vendor_id, uint16_t product_id) {
    @autoreleasepool {
        id vendor = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
        id product = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
        if ([vendor isEqual:@(vendor_id)] && [product isEqual:@(product_id)]) return 1;
        id name = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
        id transport = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
        return [MKKeypadName isEqual:name] && [MKKeypadTransports() containsObject:transport ?: @""];
    }
}
