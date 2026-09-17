const std = @import("std");
const peak = @import("peak.zig");

test "amplitudeBuckets: width buckets with known peaks" {
    const allocator = std.testing.allocator;
    const width: usize = 400;

    // Mono, frames == width, so frame i maps to bucket i.
    const buffer = try allocator.alloc(f32, width);
    defer allocator.free(buffer);

    for (buffer, 0..) |*sample, i| {
        sample.* = 0.1;
        if (i % 2 == 0)
            sample.* = -0.5; // negative peaks must use |sample|
    }

    const buckets = try peak.amplitudeBuckets(
        allocator,
        buffer,
        width,
        1,
        width,
    );
    defer allocator.free(buckets);

    try std.testing.expectEqual(@as(usize, width), buckets.len);

    for (buckets, 0..) |bucket, i| {
        const expected: f32 = if (i % 2 == 0) 0.5 else 0.1;
        try std.testing.expectEqual(expected, bucket);
    }
}

test "amplitudeBuckets: all channels contribute, bucket count stays width" {
    const allocator = std.testing.allocator;
    const width: usize = 400;
    const frames: usize = 200;
    const channels: usize = 2;

    // frame f maps to bucket f * 400 / 200 = 2*f, so odd buckets stay 0.
    const buffer = try allocator.alloc(f32, frames * channels);
    defer allocator.free(buffer);
    @memset(buffer, 0.1);

    // Distinct peaks per channel of the same frame: the frame's single
    // bucket must surface the max across channels.
    buffer[37 * channels + 0] = 0.9; // channel 0
    buffer[37 * channels + 1] = 0.7; // channel 1

    // Peak in channel 1 alone: proves channel 1 is actually read.
    buffer[100 * channels + 1] = 0.8;

    const buckets = try peak.amplitudeBuckets(
        allocator,
        buffer,
        frames,
        channels,
        width,
    );
    defer allocator.free(buckets);

    try std.testing.expectEqual(@as(usize, width), buckets.len);
    try std.testing.expectEqual(@as(f32, 0.9), buckets[74]); // frame 37 -> bucket 74
    try std.testing.expectEqual(@as(f32, 0.8), buckets[200]); // frame 100 -> bucket 200
    try std.testing.expectEqual(@as(f32, 0.1), buckets[398]); // frame 199 -> bucket 398
    try std.testing.expectEqual(@as(f32, 0.0), buckets[1]); // odd buckets stay zero
}

test "deflateZlib: representative raster round-trips through zlib" {
    const allocator = std.testing.allocator;

    // One second of mono audio at 16 kHz, rich enough to exercise deflate.
    const source = try allocator.alloc(f32, 16000);
    defer allocator.free(source);

    var rng = std.Random.DefaultPrng.init(0x1234_5678);
    for (source) |*s|
        s.* = rng.random().float(f32) * 2 - 1;

    const amplitudes = try peak.amplitudeBuckets(
        allocator,
        source,
        16000,
        1,
        400,
    );
    defer allocator.free(amplitudes);

    const raw = try peak.makeRawRaster(allocator, amplitudes);
    defer allocator.free(raw);

    // 200 scanlines of filter byte + 400 RGBA pixels.
    try std.testing.expectEqual(
        @as(usize, 200 * (1 + 400 * 4)),
        raw.len,
    );

    const compressed = try peak.deflateZlib(allocator, raw);
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len < raw.len);
    try std.testing.expectEqual(@as(u8, 0x78), compressed[0]); // zlib CMF

    // Round-trip through std's inflate.
    var input: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(
        &input,
        .zlib,
        &window,
    );

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const n = try decompress.reader.streamRemaining(&aw.writer);
    try std.testing.expectEqual(raw.len, n);
    try std.testing.expectEqualSlices(u8, raw, aw.written());
}

test "deflateZlib: minimal input round-trips" {
    const allocator = std.testing.allocator;

    const raw = try peak.makeRawRaster(allocator, &.{});
    defer allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 0), raw.len);

    const compressed = try peak.deflateZlib(allocator, raw);
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len >= 8); // header + empty stream + adler
    try std.testing.expectEqual(@as(u8, 0x78), compressed[0]);

    var input: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(
        &input,
        .zlib,
        &window,
    );

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const n = try decompress.reader.streamRemaining(&aw.writer);
    try std.testing.expectEqual(@as(usize, 0), n);
}
