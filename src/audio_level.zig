//! Microphone level for the dictation overlays on Windows and Linux: RMS of
//! 16-bit little-endian samples on a voice-friendly dB scale, 0..1000.
const std = @import("std");

pub fn permille(pcm: []const u8) u32 {
    const samples = pcm.len / 2;
    if (samples == 0) return 0;
    var sum: f64 = 0;
    var i: usize = 0;
    while (i + 1 < pcm.len) : (i += 2) {
        const s: f64 = @floatFromInt(std.mem.readInt(i16, pcm[i..][0..2], .little));
        sum += s * s;
    }
    const rms = @sqrt(sum / @as(f64, @floatFromInt(samples))) / 32768.0;
    const db = 20 * std.math.log10(@max(rms, 1e-6));
    return @intFromFloat(std.math.clamp((db + 55) / 45, 0, 1) * 1000);
}

test "silence is 0, full scale is 1000" {
    const silence = [_]u8{0} ** 64;
    try std.testing.expectEqual(@as(u32, 0), permille(&silence));
    var loud: [64]u8 = undefined;
    for (0..32) |i| std.mem.writeInt(i16, loud[i * 2 ..][0..2], if (i % 2 == 0) 32767 else -32767, .little);
    try std.testing.expectEqual(@as(u32, 1000), permille(&loud));
}
