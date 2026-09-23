#import <Foundation/Foundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <pthread.h>
#include <unistd.h>
#include "macos_shim.h"

// Key LEDs over the vendor interface (usage page 0xFF00, report ID 3).
// Protocol from the vendor app (Widget::SetRgb_Led_Key), see docs/led-protocol.md:
//   03 FB FB FB                                  identify; without it the LED write is ignored
//   03 FE B0 01 08 00 00 00 00 00 01 00 <c<<4|m>  300 ms later
// Every LED write is persisted by the firmware, so identical writes are skipped.

// Color 0 is white in reactive mode and off in static mode.
enum { MKLedWhite = 0, MKLedRed, MKLedOrange, MKLedYellow, MKLedGreen, MKLedCyan, MKLedBlue, MKLedPurple };
enum { MKModeOff = 0, MKModeStatic = 1, MKModeReactive = 2 };
static const useconds_t mk_led_gap = 300 * 1000; // shorter gaps are dropped silently

static IOHIDDeviceRef MKLedDevice(IOHIDManagerRef manager) {
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (!devices) return NULL;
    IOHIDDeviceRef device = NULL;
    if (CFSetGetCount(devices) > 0) {
        const void *first = NULL;
        CFSetGetValues(devices, &first);
        device = (IOHIDDeviceRef)CFRetain(first);
    }
    CFRelease(devices);
    return device;
}

static IOHIDManagerRef MKLedManager(uint16_t vendor_id, uint16_t product_id) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) return NULL;
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)@{
        @kIOHIDVendorIDKey: @(vendor_id), @kIOHIDProductIDKey: @(product_id),
        @kIOHIDPrimaryUsagePageKey: @0xFF00, @kIOHIDPrimaryUsageKey: @1});
    IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    return manager;
}

static BOOL MKLedSend(IOHIDDeviceRef device, uint8_t value) {
    uint8_t identify[65] = {0x03, 0xFB, 0xFB, 0xFB};
    uint8_t led[65] = {0x03, 0xFE, 0xB0, 0x01, 0x08, 0, 0, 0, 0, 0, 0x01, 0, value};
    if (IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x03, identify, sizeof identify) != kIOReturnSuccess) return NO;
    usleep(mk_led_gap);
    BOOL sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x03, led, sizeof led) == kIOReturnSuccess;
    usleep(mk_led_gap);
    return sent;
}

// Daemon state, guarded by mk_led_lock. The worker always applies the latest
// wish; stale ones are never queued.
static pthread_mutex_t mk_led_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t mk_led_wake = PTHREAD_COND_INITIALIZER;
static int mk_led_status_value;          // mk_status_set: 0 ready, 1 recording, 2 transcribing, 3 failed
static int mk_led_agents_value;          // 0 nothing, 1 an agent finished, 2 an agent waits for you
static int mk_led_applied = -1;
static uint16_t mk_led_vendor, mk_led_product;

// Priority: recording > transcribing > waiting > finished > white reactive base.
static int MKLedWanted(void) {
    if (mk_led_status_value == 1) return -2; // animated
    if (mk_led_status_value == 2) return MKLedCyan << 4 | MKModeStatic;
    if (mk_led_agents_value == 2) return MKLedRed << 4 | MKModeStatic;
    if (mk_led_agents_value == 1) return MKLedGreen << 4 | MKModeStatic;
    return MKLedWhite << 4 | MKModeReactive;
}

static void *MKLedWorker(void *unused) {
    (void)unused;
    IOHIDManagerRef manager = MKLedManager(mk_led_vendor, mk_led_product);
    int rainbow = 0;
    for (;;) {
        pthread_mutex_lock(&mk_led_lock);
        int wanted = MKLedWanted();
        while (wanted != -2 && wanted == mk_led_applied) {
            pthread_cond_wait(&mk_led_wake, &mk_led_lock);
            wanted = MKLedWanted();
        }
        pthread_mutex_unlock(&mk_led_lock);
        // The firmware has no rainbow in this dialect: cycle the static colors.
        int value = wanted == -2 ? ((rainbow++ % 7) + 1) << 4 | MKModeStatic : wanted;
        IOHIDDeviceRef device = manager ? MKLedDevice(manager) : NULL;
        BOOL sent = device && MKLedSend(device, (uint8_t)value);
        if (device) CFRelease(device);
        pthread_mutex_lock(&mk_led_lock);
        // Unplugged: remember nothing, so the state is written on reconnect.
        mk_led_applied = sent ? value : -1;
        pthread_mutex_unlock(&mk_led_lock);
        if (!sent) sleep(2);
    }
    return NULL;
}

void mk_led_start(uint16_t vendor_id, uint16_t product_id) {
    static int started;
    pthread_mutex_lock(&mk_led_lock);
    int start = !started;
    started = 1;
    mk_led_vendor = vendor_id;
    mk_led_product = product_id;
    pthread_mutex_unlock(&mk_led_lock);
    if (!start) return;
    pthread_t thread;
    pthread_create(&thread, NULL, MKLedWorker, NULL);
    pthread_detach(thread);
}

static void MKLedUpdate(int *field, int value) {
    pthread_mutex_lock(&mk_led_lock);
    *field = value;
    pthread_cond_signal(&mk_led_wake);
    pthread_mutex_unlock(&mk_led_lock);
}

void mk_led_status(int status) { MKLedUpdate(&mk_led_status_value, status); }
void mk_led_agents(int attention) { MKLedUpdate(&mk_led_agents_value, attention); }

// `minikeyboard led <color> <mode>`: one synchronous write.
int mk_led_set(uint16_t vendor_id, uint16_t product_id, int color, int mode) {
    if (color < 0 || color > 7 || mode < 0 || mode > 5) return -2;
    IOHIDManagerRef manager = MKLedManager(vendor_id, product_id);
    IOHIDDeviceRef device = manager ? MKLedDevice(manager) : NULL;
    usleep(250 * 1000); // the device answers only a moment after open
    BOOL sent = device && MKLedSend(device, (uint8_t)(color << 4 | mode));
    if (device) CFRelease(device);
    if (manager) CFRelease(manager);
    return sent ? 0 : -1;
}
