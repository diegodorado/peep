const std = @import("std");
const zaudio = @import("zaudio");

const ImageWidth = 800;
const ImageHeight = 200;
const FramesPerRead = 4096;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse return error.MissingArgument;
    const path = args.next() orelse return error.MissingArgument;

    var png = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--png")) {
            png = true;
        }
    }

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

    var amplitudes: [ImageWidth]f32 = undefined;
    @memset(&amplitudes, 0);

    const buffer = try allocator.alloc(
        f32,
        FramesPerRead * channels,
    );
    defer allocator.free(buffer);

    var frame_offset: u64 = 0;

    while (frame_offset < frames) {
        const frames_to_read = @min(
            FramesPerRead,
            frames - frame_offset,
        );

        const frames_read = try decoder.readPCMFrames(
            buffer.ptr,
            frames_to_read,
        );

        if (frames_read == 0)
            break;

        for (0..frames_read) |frame| {
            var amplitude: f32 = 0;

            for (0..channels) |channel| {
                const sample =
                    buffer[frame * channels + channel];

                amplitude = @max(
                    amplitude,
                    @abs(sample),
                );
            }

            const absolute_frame =
                frame_offset + frame;

            const bucket = @min(
                absolute_frame * ImageWidth / frames,
                ImageWidth - 1,
            );

            amplitudes[bucket] =
                @max(amplitudes[bucket], amplitude);
        }

        frame_offset += frames_read;
    }

    if (png) {
        try renderPng(
            init.io,
            allocator,
            &amplitudes,
        );
    } else {
        try renderKitty(
            init.io,
            allocator,
            &amplitudes,
        );
    }
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

fn renderKitty(
    io: std.Io,
    allocator: std.mem.Allocator,
    amplitudes: []const f32,
) !void {
    const pixels = try makePixels(
        allocator,
        amplitudes,
    );
    defer allocator.free(pixels);

    try writeKitty(
        io,
        pixels,
        ImageWidth,
        ImageHeight,
    );
}

fn renderPng(
    io: std.Io,
    allocator: std.mem.Allocator,
    amplitudes: []const f32,
) !void {
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
    // For 800x200 this is only 320,200 bytes.

    const raw_size =
        ImageHeight * (1 + ImageWidth * 4);

    // A zlib stream containing DEFLATE "stored" blocks needs:
    //
    // - 2 bytes zlib header
    // - 5 bytes per DEFLATE block
    // - raw image data
    // - 4 bytes Adler-32

    const max_block_size = 65535;

    const block_count =
        (raw_size + max_block_size - 1) / max_block_size;

    const zlib_size =
        2 +
        raw_size +
        block_count * 5 +
        4;

    const zlib_data = try allocator.alloc(
        u8,
        zlib_size,
    );
    defer allocator.free(zlib_data);

    var zlib_pos: usize = 0;

    // Zlib header:
    //
    // CMF = 0x78
    // FLG = 0x01
    //
    // This means DEFLATE with a 32K window,
    // no compression / fastest strategy.
    zlib_data[zlib_pos] = 0x78;
    zlib_pos += 1;

    zlib_data[zlib_pos] = 0x01;
    zlib_pos += 1;

    var adler_a: u32 = 1;
    var adler_b: u32 = 0;

    var raw_pos: usize = 0;

    while (raw_pos < raw_size) {
        const remaining = raw_size - raw_pos;
        const block_size = @min(
            remaining,
            max_block_size,
        );

        const final_block =
            raw_pos + block_size == raw_size;

        // DEFLATE stored block header.
        //
        // BFINAL = bit 0
        // BTYPE  = bits 1..2 = 00
        //
        // Since this is byte-aligned, the remaining
        // bits in this byte are zero.

        zlib_data[zlib_pos] =
            if (final_block) 0x01 else 0x00;
        zlib_pos += 1;

        const len = @as(u16, @intCast(block_size));
        const nlen = ~len;

        // LEN, little endian.
        zlib_data[zlib_pos + 0] =
            @truncate(len);
        zlib_data[zlib_pos + 1] =
            @truncate(len >> 8);

        // NLEN, one's complement, little endian.
        zlib_data[zlib_pos + 2] =
            @truncate(nlen);
        zlib_data[zlib_pos + 3] =
            @truncate(nlen >> 8);

        zlib_pos += 4;

        // Copy the raw scanlines.
        //
        // PNG filter byte 0 = "None".

        for (0..block_size) |i| {
            const raw_index = raw_pos + i;

            var value: u8 = undefined;

            if (raw_index % (ImageWidth * 4 + 1) == 0) {
                value = 0;
            } else {
                const pixel_index =
                    raw_index -
                    (raw_index /
                    (ImageWidth * 4 + 1)) -
                    1;

                value = pixels[pixel_index];
            }

            zlib_data[zlib_pos] = value;
            zlib_pos += 1;

            // Adler-32.
            adler_a += value;
            if (adler_a >= 65521)
                adler_a -= 65521;

            adler_b += adler_a;
            if (adler_b >= 65521)
                adler_b -= 65521;
        }

        raw_pos += block_size;
    }

    const adler =
        (adler_b << 16) | adler_a;

    // Adler-32 is big endian.
    zlib_data[zlib_pos + 0] =
        @truncate(adler >> 24);
    zlib_data[zlib_pos + 1] =
        @truncate(adler >> 16);
    zlib_data[zlib_pos + 2] =
        @truncate(adler >> 8);
    zlib_data[zlib_pos + 3] =
        @truncate(adler);

    zlib_pos += 4;

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
        zlib_data[0..zlib_pos],
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

fn crc32(
    data: []const u8,
) u32 {
    return ~crc32Update(
        0xffffffff,
        data,
    );
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

fn writeKitty(
    io: std.Io,
    pixels: []const u8,
    width: usize,
    height: usize,
) !void {
    const stdout = std.Io.File.stdout();

    var writer = stdout.writer(io, &.{});
    const out = &writer.interface;

    const chunk_size = 4096;

    var encoded_buffer: [
        std.base64.standard.Encoder.calcSize(chunk_size)
    ]u8 = undefined;

    var offset: usize = 0;
    var first = true;

    while (offset < pixels.len) {
        const size = @min(
            chunk_size,
            pixels.len - offset,
        );

        const encoded =
            std.base64.standard.Encoder.encode(
            &encoded_buffer,
            pixels[offset .. offset + size],
        );

        const more =
            offset + size < pixels.len;

        if (first) {
            try out.print(
                "\x1b_Ga=T,f=32,s={},v={},m={};{s}\x1b\\",
                .{
                    width,
                    height,
                    @as(u8, if (more) 1 else 0),
                    encoded,
                },
            );

            first = false;
        } else {
            try out.print(
                "\x1b_Gm={};{s}\x1b\\",
                .{
                    @as(u8, if (more) 1 else 0),
                    encoded,
                },
            );
        }

        offset += size;
    }

    try out.writeAll("\n");
    try out.flush();
}
