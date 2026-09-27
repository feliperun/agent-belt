#ifndef MK_EXT_MIC_H
#define MK_EXT_MIC_H

#include <stddef.h>

// An external microphone (a Fordita stick, via its Mac service) speaks into
// push-to-talk over a Unix socket: a connection is the key held, its bytes are
// 16 kHz mono PCM16, closing it is the release. One session at a time.
typedef struct {
    void (*on_start)(void *context);
    void (*on_pcm)(void *context, const void *pcm, size_t length);
    void (*on_stop)(void *context);
} mk_ext_mic_handlers;

// Binds `path` (owner-only), then serves sessions on a background thread.
int mk_ext_mic_listen(const char *path, mk_ext_mic_handlers handlers, void *context);

#endif
