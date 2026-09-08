const std = @import("std");
const zaudio = @import("zaudio");

const ReadBufferSize = 4096;
const LineBufferSize = 8192;
const BLOCKING_FADEOUT_MS = 30;

var engine: *zaudio.Engine = undefined;
var current_sound: ?*zaudio.Sound = null;
var io: std.Io = undefined;

fn stopSound() void {
    if (current_sound) |sound| {
        // yes, this is blocking, but just a few ms
        sound.setFadeInMilliseconds(1.0, 0.0, BLOCKING_FADEOUT_MS);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(BLOCKING_FADEOUT_MS), .awake) catch {};
        sound.destroy();
        current_sound = null;
    }
}

fn processLine(line: []u8) !void {
    const prefix = "\"url\":\"";

    const start = std.mem.indexOf(u8, line, prefix) orelse {
        stopSound();
        return;
    };

    const url_start = start + prefix.len;

    const url_end = std.mem.indexOfScalarPos(
        u8,
        line,
        url_start,
        '"',
    ) orelse {
        stopSound();
        return;
    };

    const url = line[url_start..url_end];

    if (!std.mem.endsWith(u8, url, ".wav")) {
        stopSound();
        return;
    }

    stopSound();

    // Replace the closing quote with NUL, turning the URL
    // in the line buffer into a sentinel-terminated string.
    line[url_end] = 0;

    const path: [:0]const u8 = @ptrCast(line[url_start..url_end]);

    current_sound = try engine.createSoundFromFile(path, .{});
    try current_sound.?.start();
}

fn waitForYazi(yazi: *std.process.Child, hover: *std.process.Child) void {
    _ = yazi.wait(io) catch {};
    hover.kill(io);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    io = init.io;

    zaudio.init(allocator);
    defer zaudio.deinit();

    engine = try zaudio.Engine.create(null);
    defer engine.destroy();

    var yazi = try std.process.spawn(init.io, .{
        .argv = &.{"yazi"},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer yazi.kill(init.io);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};

    var hover = try std.process.spawn(init.io, .{
        .argv = &.{ "ya", "sub", "hover" },
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer hover.kill(init.io);

    const stdout = hover.stdout orelse return error.NoStdout;

    const waiter = try std.Thread.spawn(.{}, waitForYazi, .{
        &yazi,
        &hover,
    });
    defer waiter.join();

    var read_buffer: [ReadBufferSize]u8 = undefined;
    var line_buffer: [LineBufferSize]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const buffers = [_][]u8{&read_buffer};

        const n = stdout.readStreaming(init.io, &buffers) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            }
        };

        for (read_buffer[0..n]) |byte| {
            if (byte == '\n') {
                try processLine(line_buffer[0..line_len]);
                line_len = 0;
                continue;
            }

            if (line_len < line_buffer.len) {
                line_buffer[line_len] = byte;
                line_len += 1;
            } else {
                // Line is too long. Discard it until the next newline.
                line_len = 0;
            }
        }
    }

    stopSound();
}
