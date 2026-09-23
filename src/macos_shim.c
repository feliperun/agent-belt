#include "macos_shim.h"
#include "audio_meter.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <AudioToolbox/AudioQueue.h>
#include <mach-o/dyld.h>

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
    mk_event_filter_callback filter;
    void *context;
    CFMachPortRef event_tap;
};

static const int64_t mk_injected_event_marker = 0x6d696e696b657962LL;

static int mk_is_tracked_keycode(uint16_t keycode) {
    return keycode == 0 || keycode == 11 || keycode == 8 ||
        keycode == 2 || keycode == 14 || keycode == 3;
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
    // USB HID Keyboard/Keypad page. Usages 0x04..0x09 are a..f.
    if (usage_page != 0x07 || usage < 0x04 || usage > 0x09) return;

    state->callback(state->context, (uint8_t)(usage - 0x04), IOHIDValueGetIntegerValue(value) != 0);
}

int mk_hid_run(
    uint16_t vendor_id,
    uint16_t product_id,
    mk_hid_callback callback,
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

    struct mk_hid_context state = { callback, NULL, context, NULL };
    IOHIDManagerSetDeviceMatching(manager, matching);
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
    struct mk_hid_context state = { NULL, filter, context, NULL };
    CGEventMask event_mask = (1ULL << kCGEventKeyDown) | (1ULL << kCGEventKeyUp);
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
