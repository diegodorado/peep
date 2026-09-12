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

    zaudio.init(allocator);
    defer zaudio.deinit();

    var decoder = try zaudio.Decoder.createFromFile(
        path,
        zaudio.Decoder.Config.initDefault(),
    );
    defer decoder.destroy();

    var channels: u32 = undefined;

    try decoder.getDataFormat(
        null,
        &channels,
        null,
        null,
    );

    const length = try decoder.getLengthInPCMFrames();

    var amplitudes: [ImageWidth]f32 = undefined;
    @memset(&amplitudes, 0);

    const buffer = try allocator.alloc(
        f32,
        FramesPerRead * channels,
    );
    defer allocator.free(buffer);

    var frame_offset: u64 = 0;

    while (frame_offset < length) {
        const frames_to_read = @min(
            FramesPerRead,
            length - frame_offset,
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
                absolute_frame * ImageWidth / length,
                ImageWidth - 1,
            );

            amplitudes[bucket] =
                @max(amplitudes[bucket], amplitude);
        }

        frame_offset += frames_read;
    }

    try renderKitty(
        init.io,
        &amplitudes,
    );
}

fn renderKitty(
    io: std.Io,
    amplitudes: []const f32,
) !void {
    const allocator = std.heap.page_allocator;

    const pixels = try allocator.alloc(
        u8,
        ImageWidth * ImageHeight * 4,
    );
    defer allocator.free(pixels);

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

    try writeKitty(
        io,
        pixels,
        ImageWidth,
        ImageHeight,
    );
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

    var encoded_buffer: [std.base64.standard.Encoder.calcSize(chunk_size)]u8 =
        undefined;

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
