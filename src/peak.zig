const std = @import("std");
const zaudio = @import("zaudio");

const ImageWidth = 400;
const ImageHeight = 200;
const silence_dbfs: f32 = -60.0;
const silence_amplitude: f32 = std.math.pow(f32, 10.0, silence_dbfs / 20.0);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse return error.MissingArgument;
    const path = args.next() orelse return error.MissingArgument;

    zaudio.init(allocator);
    defer zaudio.deinit();

    var decoder = try zaudio.Decoder.createFromFile(
        path,
        zaudio.Decoder.Config.init(
            .float32,
            0,
            0,
        ),
    );
    defer decoder.destroy();

    var channels: u32 = undefined;

    try decoder.getDataFormat(
        null,
        &channels,
        null,
        null,
    );

    const frames = try decoder.getLengthInPCMFrames();

    // The whole decoded file is read into memory so the waveform buckets
    // can be computed in a single pass.
    const frame_count: usize = @intCast(frames);

    const total_samples = frame_count * channels;

    const buffer = try allocator.alloc(
        f32,
        total_samples,
    );
    defer allocator.free(buffer);

    var total_read: usize = 0;

    while (total_read < frame_count) {
        const frames_to_read = @as(
            u64,
            @intCast(frame_count - total_read),
        );

        const frames_read = try decoder.readPCMFrames(
            buffer.ptr + total_read * channels,
            frames_to_read,
        );

        if (frames_read == 0)
            break;

        total_read += @intCast(frames_read);
    }

    const amplitudes = try amplitudeBuckets(
        allocator,
        buffer[0 .. total_read * channels],
        @intCast(total_read),
        channels,
        ImageWidth,
    );
    defer allocator.free(amplitudes);

    try renderPng(
        init.io,
        allocator,
        amplitudes,
    );
}

pub fn amplitudeBuckets(
    allocator: std.mem.Allocator,
    buffer: []const f32,
    frames: u64,
    channels: u32,
    width: usize,
) ![]f32 {
    const amplitudes = try allocator.alloc(f32, width);
    @memset(amplitudes, 0);

    const frame_count: usize = @intCast(frames);
    const channel_count: usize = channels;

    if (frame_count == 0 or width == 0)
        return amplitudes;

    for (0..frame_count) |frame| {
        var amplitude: f32 = 0;

        for (0..channel_count) |channel| {
            const sample =
                buffer[frame * channel_count + channel];

            amplitude = @max(
                amplitude,
                @abs(sample),
            );
        }

        const bucket = @min(
            frame * width / frame_count,
            width -| 1,
        );

        amplitudes[bucket] =
            @max(amplitudes[bucket], amplitude);
    }

    return amplitudes;
}

fn makePixels(
    allocator: std.mem.Allocator,
    amplitudes: []const f32,
) ![]u8 {
    const pixels = try allocator.alloc(
        u8,
        ImageWidth * ImageHeight * 4,
    );

    // Transparent background.
    @memset(pixels, 0);

    const center = ImageHeight / 2;

    for (0..ImageWidth) |x| {
        const amplitude = std.math.clamp(
            amplitudes[x],
            0.0,
            1.0,
        );

        const half_height = @as(usize, @intFromFloat(
            amplitude *
                @as(f32, @floatFromInt(center)),
        ));

        const top = center -| half_height;

        const bottom = @min(
            ImageHeight - 1,
            center + half_height,
        );

        if (amplitude <= silence_amplitude) {
            for ((ImageHeight * 7 / 16)..(ImageHeight * 9 / 16)) |y| {
                const pixel =
                    (y * ImageWidth + x) * 4;

                pixels[pixel + 0] = 255;
                pixels[pixel + 1] = 0;
                pixels[pixel + 2] = 0;
                pixels[pixel + 3] = 128;
            }
        }

        for (top..bottom + 1) |y| {
            const pixel =
                (y * ImageWidth + x) * 4;

            pixels[pixel + 0] = 255;
            pixels[pixel + 1] = 255;
            pixels[pixel + 2] = 255;
            pixels[pixel + 3] = 255;
        }
    }

    return pixels;
}

pub fn makeRawRaster(
    allocator: std.mem.Allocator,
    amplitudes: []const f32,
) ![]u8 {
    if (amplitudes.len == 0)
        return allocator.alloc(u8, 0);

    const pixels = try makePixels(
        allocator,
        amplitudes,
    );
    defer allocator.free(pixels);

    // Each PNG scanline is:
    //
    //     filter byte + RGBA pixels
    //
    // So the uncompressed image data is:
    //
    //     ImageHeight * (1 + ImageWidth * 4)
    //
    // For 400x200 this is 320,200 bytes.

    const raw_size =
        ImageHeight * (1 + ImageWidth * 4);

    const raw = try allocator.alloc(u8, raw_size);

    var raw_pos: usize = 0;

    for (0..ImageHeight) |row| {
        // PNG filter byte 0 = "None".
        raw[raw_pos] = 0;
        raw_pos += 1;

        const row_start = row * ImageWidth * 4;

        @memcpy(
            raw[raw_pos .. raw_pos + ImageWidth * 4],
            pixels[row_start .. row_start + ImageWidth * 4],
        );

        raw_pos += ImageWidth * 4;
    }

    return raw;
}

pub fn deflateZlib(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    // A stored DEFLATE block is the least compressed encoding, so a zlib
    // stream can never exceed:
    //
    // - 2 bytes zlib header
    // - 5 bytes per DEFLATE stored block
    // - raw image data
    // - 4 bytes Adler-32
    //
    // `std.compress.flate` picks the smallest block encoding per block, so
    // this is a hard upper bound for the compressed output.

    const max_block_size = 65535;

    const zlib_capacity = @max(
        64,
        2 +
            raw.len +
            (raw.len + max_block_size - 1) / max_block_size * 5 +
            4,
    );

    const zlib_data = try allocator.alloc(
        u8,
        zlib_capacity,
    );
    errdefer allocator.free(zlib_data);

    var out: std.Io.Writer = .fixed(zlib_data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;

    var compress = try std.compress.flate.Compress.init(
        &out,
        &window,
        .zlib,
        .default,
    );

    try compress.writer.writeAll(raw);
    try compress.finish();

    // Shrink to the exact stream length so callers can free the slice
    // they receive.
    return allocator.realloc(zlib_data, out.buffered().len);
}

fn renderPng(
    io: std.Io,
    allocator: std.mem.Allocator,
    amplitudes: []const f32,
) !void {
    const raw = try makeRawRaster(
        allocator,
        amplitudes,
    );
    defer allocator.free(raw);

    const zlib_data = try deflateZlib(
        allocator,
        raw,
    );
    defer allocator.free(zlib_data);

    const stdout = std.Io.File.stdout();

    var writer = stdout.writer(io, &.{});
    const out = &writer.interface;

    // PNG signature.
    try out.writeAll(&.{
        0x89, 'P',  'N',  'G',
        0x0d, 0x0a, 0x1a, 0x0a,
    });

    // IHDR.
    var ihdr: [13]u8 = undefined;

    writeU32BE(
        ihdr[0..4],
        ImageWidth,
    );

    writeU32BE(
        ihdr[4..8],
        ImageHeight,
    );

    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace

    try writePngChunk(
        out,
        "IHDR",
        &ihdr,
    );

    // IDAT.
    try writePngChunk(
        out,
        "IDAT",
        zlib_data,
    );

    // IEND.
    try writePngChunk(
        out,
        "IEND",
        &.{},
    );

    try out.flush();
}

fn writePngChunk(
    out: *std.Io.Writer,
    chunk_type: *const [4]u8,
    data: []const u8,
) !void {
    var length: [4]u8 = undefined;

    writeU32BE(
        &length,
        @as(u32, @intCast(data.len)),
    );

    try out.writeAll(&length);
    try out.writeAll(chunk_type);
    try out.writeAll(data);

    var crc = crc32Update(
        0xffffffff,
        chunk_type,
    );

    crc = crc32Update(
        crc,
        data,
    );

    crc = ~crc;

    var crc_bytes: [4]u8 = undefined;

    writeU32BE(
        &crc_bytes,
        crc,
    );

    try out.writeAll(&crc_bytes);
}

fn writeU32BE(
    dest: []u8,
    value: anytype,
) void {
    const v: u32 = @intCast(value);

    dest[0] = @truncate(v >> 24);
    dest[1] = @truncate(v >> 16);
    dest[2] = @truncate(v >> 8);
    dest[3] = @truncate(v);
}

fn crc32Update(
    initial: u32,
    data: []const u8,
) u32 {
    var crc = initial;

    for (data) |byte| {
        crc ^= byte;

        for (0..8) |_| {
            const mask =
                @as(u32, 0) -% (crc & 1);

            crc =
                (crc >> 1) ^
                (0xedb88320 & mask);
        }
    }

    return crc;
}
