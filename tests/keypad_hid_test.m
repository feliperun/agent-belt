// Deterministic HID input pipeline: synthetic devices/values, real shim callbacks.
// No hardware, privacy grants, firmware writes, or transcription services.
#import <Foundation/Foundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <assert.h>
#include <stdio.h>

struct TestValue {
    CFDictionaryRef device;
    uint32_t page, usage;
    CFIndex value;
};
static CFTypeRef TestProperty(IOHIDDeviceRef device, CFStringRef key) {
    return CFDictionaryGetValue((CFDictionaryRef)device, key);
}
static IOHIDElementRef TestElement(IOHIDValueRef value) { return (IOHIDElementRef)value; }
static uint32_t TestPage(IOHIDElementRef element) { return ((struct TestValue *)element)->page; }
static uint32_t TestUsage(IOHIDElementRef element) { return ((struct TestValue *)element)->usage; }
static IOHIDDeviceRef TestDevice(IOHIDElementRef element) { return (IOHIDDeviceRef)((struct TestValue *)element)->device; }
static CFIndex TestInteger(IOHIDValueRef value) { return ((struct TestValue *)value)->value; }
#define IOHIDDeviceGetProperty TestProperty
#define IOHIDValueGetElement TestElement
#define IOHIDElementGetUsagePage TestPage
#define IOHIDElementGetUsage TestUsage
#define IOHIDElementGetDevice TestDevice
#define IOHIDValueGetIntegerValue TestInteger
#import "../src/keypad_hid.m"
#import "../src/macos_shim.c"

void mk_agents_menu_press(void) {}
void mk_agents_next(int desktop) { (void)desktop; }
void mk_agents_bottom(void) {}
int mk_agents_menu_visible(void) { return 0; }
void mk_agents_menu_open_selected(void) {}
void mk_agents_menu_close(void) {}
void mk_agents_menu_step(int delta) { (void)delta; }
void mk_app_run(void) {}
int mk_system_media_key(const void *event, int *key, int *pressed) {
    (void)event; (void)key; (void)pressed; return 0;
}

struct Events {
    unsigned downs, ups, knobs, f5;
    uint8_t key, pressed;
    int8_t knob;
};
static void OnKey(void *context, uint8_t key, uint8_t pressed) {
    struct Events *events = context;
    events->key = key;
    events->pressed = pressed;
    if (pressed) events->downs++; else events->ups++;
}
static void OnKnob(void *context, int8_t knob) {
    struct Events *events = context;
    events->knobs++;
    events->knob = knob;
}
static void OnF5(void *context, uint8_t pressed) {
    struct Events *events = context;
    events->f5++;
    events->pressed = pressed;
}
static void Input(struct mk_hid_context *state, NSDictionary *device, uint32_t page, uint32_t usage, CFIndex value) {
    struct TestValue input = {(__bridge CFDictionaryRef)device, page, usage, value};
    mk_input_value_callback(state, kIOReturnSuccess, NULL, (IOHIDValueRef)&input);
}
static NSDictionary *Device(NSNumber *vendor, NSNumber *product, NSString *name, NSString *transport) {
    return @{@kIOHIDVendorIDKey: vendor, @kIOHIDProductIDKey: product,
             @kIOHIDProductKey: name, @kIOHIDTransportKey: transport};
}
static void CheckKeys(struct mk_hid_context *state, NSDictionary *device, struct Events *events) {
    unsigned downs = events->downs, ups = events->ups;
    for (uint8_t key = 0; key < 6; key++) {
        Input(state, device, 0x07, 0x04 + key, 1);
        assert(events->downs == downs + key + 1 && events->key == key && events->pressed);
        Input(state, device, 0x07, 0x04 + key, 0);
        assert(events->ups == ups + key + 1 && events->key == key && !events->pressed);
    }
}
static void CheckKnob(struct mk_hid_context *state, NSDictionary *device, struct Events *events) {
    const uint32_t usages[] = {0xe9, 0xea, 0xe2};
    const int8_t directions[] = {1, -1, 0};
    unsigned knobs = events->knobs;
    for (int i = 0; i < 3; i++) {
        Input(state, device, 0x0c, usages[i], 1);
        assert(events->knobs == knobs + i + 1 && events->knob == directions[i]);
        Input(state, device, 0x0c, usages[i], 0);
        assert(events->knobs == knobs + i + 1);
    }
    assert(mk_knob_recent());
    mk_knob_set_intercept(0);
    Input(state, device, 0x0c, 0xe9, 1);
    assert(events->knobs == knobs + 3);
    mk_knob_set_intercept(1);
}
static BOOL Matches(NSArray *matches, NSDictionary *device) {
    for (NSDictionary *match in matches) {
        BOOL accepted = YES;
        for (NSString *key in match) if (![match[key] isEqual:device[key]]) accepted = NO;
        if (accepted) return YES;
    }
    return NO;
}
static void CheckMatching(void) {
    NSArray *matches = CFBridgingRelease(mk_keypad_matching(0x514c, 0x8850, 0));
    assert(matches.count == 3);
    assert(Matches(matches, Device(@0x514c, @0x8850, @"USB keypad", @"USB")));
    assert(Matches(matches, Device(@0x05ac, @0x022c, @"MINI-KEYBOARD", @"Bluetooth Low Energy")));
    assert(Matches(matches, Device(@0, @0, @"MINI-KEYBOARD", @"Bluetooth")));
    assert(!Matches(matches, Device(@0x05ac, @0x022c, @"Other keyboard", @"Bluetooth Low Energy")));
    assert(!Matches(matches, Device(@0x05ac, @0x022c, @"MINI-KEYBOARD", @"USB")));
    assert(!Matches(matches, Device(@0x514c, @0x9999, @"USB keypad", @"USB")));
    assert(!Matches(matches, @{}));
    NSDictionary *keyboard = @{@kIOHIDDeviceUsagePageKey: @1, @kIOHIDDeviceUsageKey: @6};
    assert(!Matches(matches, keyboard));
    NSArray *withF5 = CFBridgingRelease(mk_keypad_matching(0x514c, 0x8850, 1));
    assert(Matches(withF5, keyboard));
    NSArray *custom = CFBridgingRelease(mk_keypad_matching(0x1234, 0x5678, 0));
    NSDictionary *device = Device(@0x1234, @0x5678, @"Configured keypad", @"USB");
    assert(Matches(custom, device));
    assert(mk_keypad_is_device((__bridge IOHIDDeviceRef)device, 0x1234, 0x5678));
    assert(!mk_keypad_is_device((__bridge IOHIDDeviceRef)device, 0x1234, 0x9999));
}
int main(void) {
    @autoreleasepool {
        CheckMatching();
        struct Events events = {0};
        struct mk_hid_context state = {.callback = OnKey, .knob = OnKnob, .f5 = OnF5,
                                       .vendor_id = 0x514c, .product_id = 0x8850, .context = &events};
        NSDictionary *usb = Device(@0x514c, @0x8850, @"USB keypad", @"USB");
        NSDictionary *ble = Device(@0x05ac, @0x022c, @"MINI-KEYBOARD", @"Bluetooth Low Energy");
        NSDictionary *classic = Device(@0x05ac, @0x022c, @"MINI-KEYBOARD", @"Bluetooth");
        CheckKeys(&state, usb, &events);
        CheckKnob(&state, usb, &events);
        CheckKeys(&state, ble, &events);
        CheckKnob(&state, ble, &events);
        CheckKeys(&state, classic, &events);
        CheckKnob(&state, classic, &events);
        unsigned downs = events.downs, knobs = events.knobs;
        for (NSDictionary *other in @[
            Device(@0x05ac, @0x022c, @"Other keyboard", @"Bluetooth Low Energy"),
            Device(@0x05ac, @0x022c, @"MINI-KEYBOARD", @"USB"),
            Device(@0x514c, @0x9999, @"Other keypad", @"USB"), @{}]) {
            Input(&state, other, 0x07, 0x04, 1);
            Input(&state, other, 0x0c, 0xe9, 1);
        }
        assert(events.downs == downs && events.knobs == knobs);
        Input(&state, ble, 0x07, 0x03, 1);
        Input(&state, ble, 0x07, 0x0a, 1);
        Input(&state, ble, 0x01, 0x04, 1);
        assert(events.downs == downs);
        NSDictionary *keyboard = Device(@0x05ac, @0x0342, @"Standard keyboard", @"SPI");
        Input(&state, keyboard, 0x07, 0x3e, 1);
        Input(&state, keyboard, 0x07, 0x3e, 0);
        assert(events.f5 == 2 && !events.pressed);
        Input(&state, ble, 0x07, 0x3e, 1);
        assert(events.f5 == 2);
        puts("keypad HID: USB/Bluetooth keys, knob, isolation and F5 passed");
    }
    return 0;
}
