#ifndef AGENT_BELT_MACOS_SHIM_H
#define AGENT_BELT_MACOS_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef void (*mk_hid_callback)(void *context, uint8_t key, uint8_t pressed);
typedef int (*mk_event_filter_callback)(void *context, uint16_t keycode, uint8_t pressed, uint8_t repeated);
/* Knob detent: 1 clockwise, -1 counter-clockwise, 0 button press. */
typedef void (*mk_knob_callback)(void *context, int8_t event);
/* F5 (microphone key) on the Mac's own keyboards: pressed or released. */
typedef void (*mk_f5_callback)(void *context, uint8_t pressed);

int mk_hid_run(
    uint16_t vendor_id,
    uint16_t product_id,
    mk_hid_callback callback,
    mk_knob_callback knob,
    mk_f5_callback f5,
    void *context
);
void mk_knob_set_intercept(int intercept);
void mk_set_f5_handler(mk_f5_callback handler, void *context);
/* 0 start, 1 stop: discreet recording cues */
void mk_play_cue(int cue);
void mk_scroll_down(int32_t lines);
int mk_system_media_key(const void *event, int *key, int *pressed);
void mk_agents_bottom(void);
void mk_agents_monitor(void);
void mk_agents_menu_press(void);
/* Agent menu overlay; tones as mk_hud_show. */
void mk_menu_show(const char *const *labels, const char *const *details, const int *tones, int count,
                  int selected, const char *footer, int clickable);
int mk_agents_menu_visible(void);
void mk_agents_menu_click(void);
void mk_agents_menu_open(int index);
void mk_agents_menu_open_selected(void);
void mk_agents_menu_step(int delta);
void mk_agents_menu_close(void);
/* Transcript spoken with the agent menu open: create an agent through work. */
void mk_agents_voice_command(const char *text);
void mk_updater_start(const char *version);
const char *mk_update_line(void);
int mk_update_run(const char *tag);
void mk_update_check_now(void);
const char *mk_update_available(void);
const char *mk_app_version(void);
/* Menu bar emoji when idle: 0 nothing, 1 an agent finished, 2 an agent waits. */
void mk_status_attention(int attention);
/* Agent sessions on every machine: the count beside the menu bar icon. */
void mk_status_agents(int count);
void mk_menu_hide(void);
void mk_led_start(uint16_t vendor_id, uint16_t product_id);
void mk_led_status(int status);
/* 0 nothing, 1 an agent finished, 2 an agent waits for you */
void mk_led_agents(int attention);
int mk_led_set(uint16_t vendor_id, uint16_t product_id, int color, int mode);
/* tone: 0 idle, 1 working, 2 done, 3 waiting */
void mk_hud_show(const char *title, const char *detail, int tone);
// The create-agent panel (src/create_panel.m).
void mk_create_panel_show(const char *text);
int mk_create_panel_visible(void);
void mk_create_panel_recording(int recording);
void mk_create_panel_live(const char *text);
void mk_create_panel_commit(const char *text);
void mk_create_panel_confirm(void);
void mk_create_panel_request(const char *text);
void mk_create_panel_listen(void);
int mk_event_tap_run(mk_event_filter_callback filter, void *context);

int mk_status_init(void);
void mk_app_run(void);
void mk_status_set(int status);
void mk_status_live(const char *text);
int mk_status_dismiss(void);
int mk_status_preview(void);
void mk_agents_next(int desktop);
/* mode: 0 list, 1 next, 2 bottom */
int mk_agents_command(int mode, int desktop);
uint64_t mk_monotonic_ns(void);

typedef struct mk_recorder mk_recorder;

mk_recorder *mk_recorder_create(void);
typedef void (*mk_pcm_callback)(void *context, const void *pcm, size_t length);
void mk_recorder_set_pcm_handler(mk_recorder *recorder, mk_pcm_callback handler, void *context);
int mk_recorder_start(mk_recorder *recorder);
int mk_recorder_finish(mk_recorder *recorder, uint8_t **wav, size_t *wav_size);
uint32_t mk_audio_level_permille(void);
void mk_recorder_destroy(mk_recorder *recorder);
void mk_free_buffer(uint8_t *buffer);

int mk_insert_text(const uint16_t *text, size_t length);
void mk_press_key(uint16_t keycode, uint64_t flags, int pressed);
char *mk_self_exe_path(void);
char *mk_keychain_secret(const char *service, const char *account);
int mk_single_instance(void);
int mk_check_permissions(void);
void mk_open_privacy(const char *pane);
void mk_trim_log(void);
int mk_status_report(uint16_t vendor_id, uint16_t product_id, const char *key_env);

#endif
