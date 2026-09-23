// Native integration test: actual AppKit panel + run loop, no HID, mic or API.
#undef NDEBUG
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#import "../src/status_item.m"
#include "../src/audio_meter.h"

static uint32_t test_level;
uint32_t mk_audio_level_permille(void) { return test_level; }
uint64_t mk_monotonic_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void mk_led_status(int status) { (void)status; }
void mk_agents_menu_click(void) {}
void mk_agents_menu_close(void) {}
void mk_agents_menu_open(int index) { (void)index; }
static atomic_bool test_dismissed;
static int test_dismiss_result;

static uint32_t tone_level(double amplitude) {
    int16_t samples[320];
    for (size_t i = 0; i < 320; i++) samples[i] = (int16_t)(sin(i * 2 * M_PI / 40) * amplitude);
    return mk_pcm_level_permille(samples, 320);
}

static void test_speech_response(void) {
    const uint32_t quiet = tone_level(120);
    const uint32_t normal = tone_level(900);
    const uint32_t loud = tone_level(10000);
    assert(tone_level(0) == 0 && tone_level(25) == 0);
    assert(quiet > 100 && quiet < 400);
    assert(normal > 450 && normal < 800);
    assert(loud > 950 && loud <= 1000);
    assert(mk_pcm_level_permille(NULL, 0) == 0);
    const int16_t clipped[] = {INT16_MIN, INT16_MAX};
    assert(mk_pcm_level_permille(clipped, 2) == 1000);

    MKOverlayView *voice = [[MKOverlayView alloc] initWithFrame:NSZeroRect];
    [voice updateAudio:0.8 elapsed:0.02];
    assert(voice.level > 0.55); // A syllable must register within one audio buffer.
    for (int i = 0; i < 10; i++) [voice updateAudio:0 elapsed:0.02];
    assert(voice.level < 0.06); // A pause should visibly quiet the line.

    MKOverlayView *soft = [[MKOverlayView alloc] initWithFrame:NSZeroRect];
    MKOverlayView *strong = [[MKOverlayView alloc] initWithFrame:NSZeroRect];
    MKOverlayView *syllables = [[MKOverlayView alloc] initWithFrame:NSZeroRect];
    for (int i = 0; i < 100; i++) {
        [soft updateAudio:0.15 elapsed:0.02];
        [strong updateAudio:0.75 elapsed:0.02];
        [syllables updateAudio:(i % 10 < 5 ? 0.3 : 0) elapsed:0.02];
    }
    assert(strong.signalPhase > soft.signalPhase * 2);
    // Same mean input level as soft, but faster syllables should move more.
    assert(syllables.signalPhase > soft.signalPhase * 1.2);
    printf("audio response: quiet=%u normal=%u loud=%u; attack, release and cadence OK\n", quiet, normal, loud);
}

static void pump(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static void snapshot(const char *directory, NSString *name) {
    if (!directory) return;
    NSRect bounds = mk_overlay_view.bounds;
    NSBitmapImageRep *bitmap = [mk_overlay_view bitmapImageRepForCachingDisplayInRect:bounds];
    [mk_overlay_view cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:name];
    assert([png writeToFile:path atomically:YES]);
}

static void dismiss_from_worker(void) {
    atomic_store(&test_dismissed, false);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        test_dismiss_result = mk_status_dismiss();
        atomic_store_explicit(&test_dismissed, true, memory_order_release);
    });
    const double deadline = mk_now() + 3;
    while (!atomic_load_explicit(&test_dismissed, memory_order_acquire) && mk_now() < deadline) pump(0.01);
    assert(atomic_load(&test_dismissed));
    assert(test_dismiss_result == 0);
    // The worker is now allowed to inject text: the panel must already be gone.
    assert(!mk_overlay_panel.isVisible);
    assert(mk_overlay_view.animationTimer == nil);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        test_speech_response();
        const char *directory = argc > 1 ? argv[1] : NULL;
        const pid_t frontmost = [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier;
        assert(mk_status_init() == 0);
        test_level = 700;
        mk_status_set(1);
        pump(0.3);
        assert(mk_overlay_panel.isVisible);
        assert(!mk_overlay_panel.isKeyWindow);
        assert(mk_overlay_panel.ignoresMouseEvents);
        assert([NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier == frontmost);
        NSRect screen = mk_overlay_panel.screen.visibleFrame;
        assert(fabs(NSMaxX(screen) - NSMaxX(mk_overlay_panel.frame) - 18) < 1);
        assert(fabs(NSMaxY(screen) - NSMaxY(mk_overlay_panel.frame) - 14) < 1);
        assert(mk_overlay_view.level > 0.5);
        snapshot(directory, @"recording.png");
        test_level = 0;
        pump(0.5);
        assert(mk_overlay_view.level < 0.1);
        snapshot(directory, @"quiet.png");
        mk_status_set(2);
        pump(0.3);
        snapshot(directory, @"morph.png");
        pump(0.6);
        snapshot(directory, @"transcribing.png");
        dismiss_from_worker();
        // A subsequent recording must restore visibility and alpha after the fade.
        mk_status_set(1);
        pump(0.25);
        assert(mk_overlay_panel.isVisible && mk_overlay_panel.alphaValue == 1);
        mk_overlay_view.reducedMotion = YES;
        dismiss_from_worker();
        assert(mk_status_dismiss() == 0); // Already hidden, main-thread path.
        puts("overlay: position, focus, audio response, transition and dismiss-before-insert OK");
    }
    return 0;
}
