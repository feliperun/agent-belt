#ifndef AGENT_BELT_AUDIO_METER_H
#define AGENT_BELT_AUDIO_METER_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>

// 20 ms of mono PCM16 at 16 kHz, so syllable attacks reach the UI promptly.
enum { MK_AUDIO_BUFFER_BYTES = 320 * sizeof(int16_t) };

static inline uint32_t mk_pcm_level_permille(const int16_t *samples, size_t count) {
    if (!count) return 0;
    uint64_t squares = 0;
    uint32_t peak = 0;
    for (size_t i = 0; i < count; i++) {
        const int32_t sample = samples[i];
        const uint32_t magnitude = (uint32_t)(sample < 0 ? -sample : sample);
        squares += (uint64_t)magnitude * magnitude;
        if (magnitude > peak) peak = magnitude;
    }
    // RMS follows voice energy; a little peak weighting preserves consonants.
    const double amplitude = (0.85 * sqrt((double)squares / count) + 0.15 * peak) / 32768.0;
    if (amplitude <= 0.0012589254) return 0; // Noise gate: -58 dBFS.
    const double normalized = fmin(1, (20 * log10(amplitude) + 58) / 44);
    return (uint32_t)lround(pow(normalized, 0.8) * 1000);
}

#endif
