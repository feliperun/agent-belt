#include "macos_shim.h"
#include "audio_meter.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <AudioToolbox/AudioQueue.h>
#include <mach-o/dyld.h>

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

uint64_t mk_monotonic_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

struct mk_hid_context {
    mk_hid_callback callback;
    mk_knob_callback knob;
    mk_f5_callback f5;
    uint16_t vendor_id;
    mk_event_filter_callback filter;
    void *context;
    CFMachPortRef event_tap;
};

static const int64_t mk_injected_event_marker = 0x6d696e696b657962LL;

// The knob reports Consumer Control volume/mute usages. WindowServer turns them
// into system-defined media keys that no device filter can tell apart from the
// Mac's own volume keys, so the tap only drops those arriving while the knob
// was just active on the HID side.
static atomic_int mk_knob_intercept = 1;
static _Atomic uint64_t mk_knob_active_until_ns;
enum { mk_media_sound_up = 0, mk_media_sound_down = 1, mk_media_mute = 7 };

void mk_knob_set_intercept(int intercept) {
    atomic_store(&mk_knob_intercept, intercept);
}

static int mk_knob_recent(void) {
    return mk_monotonic_ns() <= atomic_load(&mk_knob_active_until_ns);
}

void mk_scroll_down(int32_t lines) {
    CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, -lines);
    if (!scroll) return;
    CGEventSetIntegerValueField(scroll, kCGEventSourceUserData, mk_injected_event_marker);
    CGEventPost(kCGHIDEventTap, scroll);
    CFRelease(scroll);
}

static int mk_is_tracked_keycode(uint16_t keycode) {
    return keycode == 0 || keycode == 11 || keycode == 8 ||
        keycode == 2 || keycode == 14 || keycode == 3;
}

// Mac keyboard stand-ins for the keypad, so everything works without it:
//   ⌃⌥Space agent menu (repeat moves) · ⌃⌥↑ next agent · ⌃⌥↓ agents back to the bottom
// and, while the agent menu is up, ↩ opens, Esc closes, ↑/↓ move.
// Handled keys are swallowed, down, repeat and up alike.
enum { mk_kc_return = 36, mk_kc_enter = 76, mk_kc_escape = 53, mk_kc_space = 49, mk_kc_up = 126, mk_kc_down = 125 };

static atomic_int mk_f5_swallow;

static int mk_hotkey(CGEventRef event, int down) {
    const uint16_t keycode = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const CGEventFlags modifiers = CGEventGetFlags(event) &
        (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
    const int fresh = down && !CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat);
    // F5 is push-to-talk (read from HID); the plain key must not reach apps.
    if (keycode == 96 && !modifiers && atomic_load(&mk_f5_swallow)) return 1;
    if (modifiers == (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)) {
        if (keycode == mk_kc_space) { if (fresh) mk_agents_menu_press(); return 1; }
        if (keycode == mk_kc_up) { if (fresh) mk_agents_next(0); return 1; }
        if (keycode == mk_kc_down) { if (fresh) mk_agents_bottom(); return 1; }
        return 0;
    }
    if (modifiers || !mk_agents_menu_visible()) return 0;
    switch (keycode) {
    case mk_kc_return: case mk_kc_enter: if (fresh) mk_agents_menu_open_selected(); return 1;
    case mk_kc_escape: if (fresh) mk_agents_menu_close(); return 1;
    case mk_kc_down: if (down) mk_agents_menu_step(1); return 1;
    case mk_kc_up: if (down) mk_agents_menu_step(-1); return 1;
    default: return 0;
    }
}

static CGEventRef mk_event_tap_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *refcon
) {
    (void)proxy;
    struct mk_hid_context *state = refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (state->event_tap) CGEventTapEnable(state->event_tap, true);
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == mk_injected_event_marker) {
        return event;
    }
    int media_key, media_pressed;
    if (type == (CGEventType)NX_SYSDEFINED && atomic_load(&mk_knob_intercept) &&
        mk_system_media_key(event, &media_key, &media_pressed) &&
        (media_key == mk_media_sound_up || media_key == mk_media_sound_down || media_key == mk_media_mute)) {
        // Same race as the keys below: give the HID callback time to mark the knob.
        for (int wait = 0; wait < 20 && !mk_knob_recent(); wait++) usleep(1000);
        if (mk_knob_recent()) return NULL;
    }
    if ((type == kCGEventKeyDown || type == kCGEventKeyUp) && mk_hotkey(event, type == kCGEventKeyDown)) return NULL;
    if ((type == kCGEventKeyDown || type == kCGEventKeyUp) && state->filter) {
        const uint16_t keycode = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        // IOHIDManager delivers the raw key slightly after the WindowServer
        // event tap on some devices. Give that callback a small head start so
        // the matching event can be suppressed before it reaches the app.
        if (mk_is_tracked_keycode(keycode)) usleep(5000);
        const uint8_t repeated = type == kCGEventKeyDown &&
            CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        if (state->filter(state->context, keycode, type == kCGEventKeyDown, repeated)) return NULL;
    }
    return event;
}

static void mk_input_value_callback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDValueRef value
) {
    (void)result;
    (void)sender;
    struct mk_hid_context *state = context;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (!element) return;

    const uint32_t usage_page = IOHIDElementGetUsagePage(element);
    const uint32_t usage = IOHIDElementGetUsage(element);
    // The Mac's own keyboards only contribute F5, the microphone key.
    int32_t vendor = 0;
    CFNumberRef vendor_number = IOHIDDeviceGetProperty(IOHIDElementGetDevice(element), CFSTR(kIOHIDVendorIDKey));
    if (vendor_number) CFNumberGetValue(vendor_number, kCFNumberSInt32Type, &vendor);
    if (vendor != state->vendor_id) {
        if (usage_page == 0x07 && usage == 0x3e && state->f5)
            state->f5(state->context, IOHIDValueGetIntegerValue(value) != 0);
        return;
    }
    // Consumer page: Volume Increment/Decrement are the knob's detents, Mute its button.
    if (usage_page == 0x0c && (usage == 0xe9 || usage == 0xea || usage == 0xe2)) {
        if (!atomic_load(&mk_knob_intercept)) return;
        atomic_store(&mk_knob_active_until_ns, mk_monotonic_ns() + 150 * 1000 * 1000ULL);
        if (IOHIDValueGetIntegerValue(value) != 0 && state->knob)
            state->knob(state->context, usage == 0xe9 ? 1 : usage == 0xea ? -1 : 0);
        return;
    }
    // USB HID Keyboard/Keypad page. Usages 0x04..0x09 are a..f.
    if (usage_page != 0x07 || usage < 0x04 || usage > 0x09) return;

    state->callback(state->context, (uint8_t)(usage - 0x04), IOHIDValueGetIntegerValue(value) != 0);
}

int mk_hid_run(
    uint16_t vendor_id,
    uint16_t product_id,
    mk_hid_callback callback,
    mk_knob_callback knob,
    mk_f5_callback f5,
    void *context
) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) return -1;

    int32_t vendor = vendor_id;
    int32_t product = product_id;
    CFNumberRef vendor_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendor);
    CFNumberRef product_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &product);
    if (!vendor_number || !product_number) {
        if (vendor_number) CFRelease(vendor_number);
        if (product_number) CFRelease(product_number);
        CFRelease(manager);
        return -2;
    }

    const void *keys[] = { CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey) };
    const void *values[] = { vendor_number, product_number };
    CFDictionaryRef matching = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(vendor_number);
    CFRelease(product_number);
    if (!matching) {
        CFRelease(manager);
        return -3;
    }

    struct mk_hid_context state = { .callback = callback, .knob = knob, .f5 = f5, .vendor_id = vendor_id, .context = context };
    atomic_store(&mk_f5_swallow, f5 != NULL);
    if (f5) {
        // Also every keyboard, for F5 (their other keys are ignored above).
        int32_t page = 0x01, keyboard = 0x06;
        CFNumberRef page_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &page);
        CFNumberRef usage_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyboard);
        const void *kb_keys[] = { CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey) };
        const void *kb_values[] = { page_number, usage_number };
        CFDictionaryRef keyboards = CFDictionaryCreate(kCFAllocatorDefault, kb_keys, kb_values, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *both[] = { matching, keyboards };
        CFArrayRef list = CFArrayCreate(kCFAllocatorDefault, both, 2, &kCFTypeArrayCallBacks);
        IOHIDManagerSetDeviceMatchingMultiple(manager, list);
        CFRelease(list);
        CFRelease(keyboards);
        CFRelease(page_number);
        CFRelease(usage_number);
    } else {
        IOHIDManagerSetDeviceMatching(manager, matching);
    }
    IOHIDManagerRegisterInputValueCallback(manager, mk_input_value_callback, &state);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    const IOReturn result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    CFRelease(matching);
    if (result != kIOReturnSuccess) {
        CFRelease(manager);
        return (int)result;
    }

    CFRunLoopRun();
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);
    return 0;
}

int mk_event_tap_run(mk_event_filter_callback filter, void *context) {
    struct mk_hid_context state = { .filter = filter, .context = context };
    CGEventMask event_mask = (1ULL << kCGEventKeyDown) | (1ULL << kCGEventKeyUp) | (1ULL << NX_SYSDEFINED);
    CFMachPortRef event_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        event_mask,
        mk_event_tap_callback,
        &state
    );
    if (!event_tap) {
        return -4;
    }
    state.event_tap = event_tap;
    CFRunLoopSourceRef event_source = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        event_tap,
        0
    );
    if (!event_source) {
        CFRelease(event_tap);
        return -5;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), event_source, kCFRunLoopCommonModes);
    CFRunLoopRun();
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), event_source, kCFRunLoopCommonModes);
    CFRelease(event_source);
    CFRelease(event_tap);
    return 0;
}

struct mk_recorder {
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[3];
    uint8_t *pcm;
    size_t length;
    size_t capacity;
    int started;
};

static atomic_uint mk_audio_level = 0;

uint32_t mk_audio_level_permille(void) {
    return atomic_load_explicit(&mk_audio_level, memory_order_relaxed);
}

static int mk_append_pcm(struct mk_recorder *recorder, const uint8_t *data, size_t length) {
    if (length == 0) return 0;
    if (recorder->length + length > recorder->capacity) {
        size_t next_capacity = recorder->capacity == 0 ? 32768 : recorder->capacity * 2;
        while (next_capacity < recorder->length + length) next_capacity *= 2;
        uint8_t *next = realloc(recorder->pcm, next_capacity);
        if (!next) return -1;
        recorder->pcm = next;
        recorder->capacity = next_capacity;
    }
    memcpy(recorder->pcm + recorder->length, data, length);
    recorder->length += length;
    return 0;
}

static void mk_audio_callback(
    void *user_data,
    AudioQueueRef queue,
    AudioQueueBufferRef buffer,
    const AudioTimeStamp *input_time,
    UInt32 packet_count,
    const AudioStreamPacketDescription *packet_descriptions
) {
    (void)input_time;
    (void)packet_count;
    (void)packet_descriptions;
    struct mk_recorder *recorder = user_data;
    if (buffer->mAudioDataByteSize > 0) {
        const int16_t *samples = buffer->mAudioData;
        const size_t sample_count = buffer->mAudioDataByteSize / sizeof(int16_t);
        atomic_store_explicit(&mk_audio_level, mk_pcm_level_permille(samples, sample_count), memory_order_relaxed);
        mk_append_pcm(recorder, buffer->mAudioData, buffer->mAudioDataByteSize);
    }
    if (recorder->started) AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

mk_recorder *mk_recorder_create(void) {
    return calloc(1, sizeof(struct mk_recorder));
}

int mk_recorder_start(mk_recorder *recorder) {
    atomic_store_explicit(&mk_audio_level, 0, memory_order_relaxed);
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = 16000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;

    OSStatus status = AudioQueueNewInput(
        &format,
        mk_audio_callback,
        recorder,
        CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode,
        0,
        &recorder->queue
    );
    if (status != noErr) return (int)status;

    for (size_t i = 0; i < 3; i++) {
        status = AudioQueueAllocateBuffer(recorder->queue, MK_AUDIO_BUFFER_BYTES, &recorder->buffers[i]);
        if (status != noErr) return (int)status;
        status = AudioQueueEnqueueBuffer(recorder->queue, recorder->buffers[i], 0, NULL);
        if (status != noErr) return (int)status;
    }

    status = AudioQueueStart(recorder->queue, NULL);
    if (status != noErr) return (int)status;
    recorder->started = 1;
    return 0;
}

static void mk_write_u16(uint8_t *at, uint16_t value) {
    at[0] = (uint8_t)(value & 0xff);
    at[1] = (uint8_t)(value >> 8);
}

static void mk_write_u32(uint8_t *at, uint32_t value) {
    at[0] = (uint8_t)(value & 0xff);
    at[1] = (uint8_t)((value >> 8) & 0xff);
    at[2] = (uint8_t)((value >> 16) & 0xff);
    at[3] = (uint8_t)((value >> 24) & 0xff);
}

int mk_recorder_finish(mk_recorder *recorder, uint8_t **wav, size_t *wav_size) {
    if (recorder->started) {
        recorder->started = 0;
        OSStatus status = AudioQueueStop(recorder->queue, true);
        if (status != noErr) return (int)status;
    }
    atomic_store_explicit(&mk_audio_level, 0, memory_order_relaxed);

    if (recorder->length > UINT32_MAX) return -10;
    const uint32_t data_size = (uint32_t)recorder->length;
    uint8_t *output = malloc(44 + recorder->length);
    if (!output) return -11;

    memcpy(output + 0, "RIFF", 4);
    mk_write_u32(output + 4, 36 + data_size);
    memcpy(output + 8, "WAVEfmt ", 8);
    mk_write_u32(output + 16, 16);
    mk_write_u16(output + 20, 1);
    mk_write_u16(output + 22, 1);
    mk_write_u32(output + 24, 16000);
    mk_write_u32(output + 28, 32000);
    mk_write_u16(output + 32, 2);
    mk_write_u16(output + 34, 16);
    memcpy(output + 36, "data", 4);
    mk_write_u32(output + 40, data_size);
    memcpy(output + 44, recorder->pcm, recorder->length);

    *wav = output;
    *wav_size = 44 + recorder->length;
    return 0;
}

void mk_recorder_destroy(mk_recorder *recorder) {
    if (!recorder) return;
    atomic_store_explicit(&mk_audio_level, 0, memory_order_relaxed);
    if (recorder->queue) {
        if (recorder->started) {
            recorder->started = 0;
            AudioQueueStop(recorder->queue, true);
        }
        AudioQueueDispose(recorder->queue, true);
    }
    free(recorder->pcm);
    free(recorder);
}

void mk_free_buffer(uint8_t *buffer) {
    free(buffer);
}

static void mk_post_key(uint16_t keycode, uint64_t flags, bool down, bool repeat) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keycode, down);
    if (!event) return;
    // Only the binding's own modifiers: a held Shift/Cmd on the Mac keyboard
    // must not turn Return into Shift+Return or Delete into Cmd+Delete.
    CGEventSetFlags(event, (CGEventFlags)flags);
    if (repeat) CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, 1);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, mk_injected_event_marker);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

// macOS stores key repeat in ticks of 15 ms (System Settings > Keyboard).
static uint64_t mk_key_repeat_ns(CFStringRef key, long fallback_ticks) {
    Boolean valid = false;
    long ticks = CFPreferencesGetAppIntegerValue(key, kCFPreferencesAnyApplication, &valid);
    if (!valid || ticks <= 0) ticks = fallback_ticks;
    return (uint64_t)ticks * 15 * NSEC_PER_MSEC;
}

// Synthetic events never autorepeat, so a held key repeats here. All state
// lives on one serial queue; pthread_once because dispatch_once traps under
// the UBSan Zig enables for C.
static dispatch_queue_t mk_key_queue;
static dispatch_source_t mk_key_timer;
static uint16_t mk_key_held;
static uint64_t mk_key_held_flags;
static void mk_key_queue_create(void) {
    mk_key_queue = dispatch_queue_create("agent-belt.keys", DISPATCH_QUEUE_SERIAL);
}

void mk_press_key(uint16_t keycode, uint64_t flags, int pressed) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, mk_key_queue_create);
    dispatch_async(mk_key_queue, ^{
        if (mk_key_timer) {
            dispatch_source_cancel(mk_key_timer);
            mk_key_timer = NULL;
        }
        if (!pressed) {
            if (mk_key_held == keycode) mk_post_key(keycode, flags, false, false);
            mk_key_held = 0;
            return;
        }
        if (mk_key_held) mk_post_key(mk_key_held, mk_key_held_flags, false, false);
        mk_key_held = keycode;
        mk_key_held_flags = flags;
        mk_post_key(keycode, flags, true, false);
        mk_key_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, mk_key_queue);
        dispatch_source_set_timer(mk_key_timer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)mk_key_repeat_ns(CFSTR("InitialKeyRepeat"), 25)),
            mk_key_repeat_ns(CFSTR("KeyRepeat"), 2), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(mk_key_timer, ^{ mk_post_key(keycode, flags, true, true); });
        dispatch_resume(mk_key_timer);
    });
}

int mk_insert_text(const uint16_t *text, size_t length) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
    if (!down) return -1;
    CGEventKeyboardSetUnicodeString(down, length, text);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, mk_injected_event_marker);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);

    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
    if (!up) return -2;
    CGEventKeyboardSetUnicodeString(up, length, text);
    CGEventSetIntegerValueField(up, kCGEventSourceUserData, mk_injected_event_marker);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(up);
    return 0;
}

char *mk_self_exe_path(void) {
    uint32_t size = 0;
    if (_NSGetExecutablePath(NULL, &size) == 0 || size == 0) return NULL;
    char *path = malloc(size);
    if (!path) return NULL;
    if (_NSGetExecutablePath(path, &size) != 0) {
        free(path);
        return NULL;
    }
    return path;
}
