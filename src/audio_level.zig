//! Microphone level for the dictation overlays on Windows and Linux, the same
//! curve as the Mac (src/audio_meter.h): 16-bit little-endian samples, 0..1000.
const std = @import("std");

/// About 20 ms of 16 kHz mono PCM16: syllable attacks reach the overlay promptly.
pub const window_bytes = 640;

pub fn permille(pcm: []const u8) u32 {
    const samples = pcm.len / 2;
    if (samples == 0) return 0;
    var squares: f64 = 0;
    var peak: f64 = 0;
    var i: usize = 0;
    while (i + 1 < pcm.len) : (i += 2) {
        const s: f64 = @abs(@as(f64, @floatFromInt(std.mem.readInt(i16, pcm[i..][0..2], .little))));
        squares += s * s;
        peak = @max(peak, s);
    }
    // RMS follows voice energy; a little peak weighting preserves consonants.
    const amplitude = (0.85 * @sqrt(squares / @as(f64, @floatFromInt(samples))) + 0.15 * peak) / 32768.0;
    if (amplitude <= 0.0012589254) return 0; // noise gate: -58 dBFS
    const normalized = @min(1, (20 * std.math.log10(amplitude) + 58) / 44);
    return @intFromFloat(@round(std.math.pow(f64, normalized, 0.8) * 1000));
}

test "silence is 0, full scale is 1000" {
    const silence = [_]u8{0} ** 64;
    try std.testing.expectEqual(@as(u32, 0), permille(&silence));
    var loud: [64]u8 = undefined;
    for (0..32) |i| std.mem.writeInt(i16, loud[i * 2 ..][0..2], if (i % 2 == 0) 32767 else -32767, .little);
    try std.testing.expectEqual(@as(u32, 1000), permille(&loud));
}
