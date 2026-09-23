#ifndef MINIKEYBOARD_MACOS_SHIM_H
#define MINIKEYBOARD_MACOS_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef void (*mk_hid_callback)(void *context, uint8_t key, uint8_t pressed);
typedef int (*mk_event_filter_callback)(void *context, uint16_t keycode, uint8_t pressed, uint8_t repeated);
/* Knob detent: 1 clockwise, -1 counter-clockwise, 0 button press. */
typedef void (*mk_knob_callback)(void *context, int8_t event);

int mk_hid_run(
    uint16_t vendor_id,
    uint16_t product_id,
    mk_hid_callback callback,
    mk_knob_callback knob,
    void *context
);
void mk_knob_set_intercept(int intercept);
void mk_scroll_down(int32_t lines);
int mk_system_media_key(const void *event, int *key, int *pressed);
void mk_agents_bottom(void);
int mk_event_tap_run(mk_event_filter_callback filter, void *context);

int mk_status_init(void);
void mk_status_set(int status);
int mk_status_dismiss(void);
int mk_status_preview(void);
void mk_agents_next(int desktop);
/* mode: 0 list, 1 next, 2 bottom */
int mk_agents_command(int mode, int desktop);
uint64_t mk_monotonic_ns(void);

typedef struct mk_recorder mk_recorder;

mk_recorder *mk_recorder_create(void);
int mk_recorder_start(mk_recorder *recorder);
int mk_recorder_finish(mk_recorder *recorder, uint8_t **wav, size_t *wav_size);
uint32_t mk_audio_level_permille(void);
void mk_recorder_destroy(mk_recorder *recorder);
void mk_free_buffer(uint8_t *buffer);

int mk_insert_text(const uint16_t *text, size_t length);
void mk_press_key(uint16_t keycode, int pressed);
char *mk_self_exe_path(void);
char *mk_keychain_secret(const char *service, const char *account);
int mk_single_instance(void);
int mk_check_permissions(void);

#endif
