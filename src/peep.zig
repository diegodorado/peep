const std = @import("std");
const zaudio = @import("zaudio");

const ReadBufferSize = 4096;
const LineBufferSize = 8192;
const BLOCKING_FADEOUT_MS = 30;

var engine: *zaudio.Engine = undefined;
var current_sound: ?*zaudio.Sound = null;
var io: std.Io = undefined;

const RetryOutcome = enum { ready, gave_up, stopped };

fn stopSound() void {
    if (current_sound) |sound| {
        // yes, this is blocking, but just a few ms
        sound.setFadeInMilliseconds(1.0, 0.0, BLOCKING_FADEOUT_MS);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(BLOCKING_FADEOUT_MS), .awake) catch {};
        sound.destroy();
        current_sound = null;
    }
}

pub fn parseLine(line: []const u8, sender: ?[]const u8) ?[]const u8 {
    // Hover events are "kind,receiver,sender,json": split at the 3rd comma.
    const comma1 = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    const comma2 = std.mem.indexOfScalarPos(u8, line, comma1 + 1, ',') orelse return null;
    const comma3 = std.mem.indexOfScalarPos(u8, line, comma2 + 1, ',') orelse return null;

    const line_sender = line[comma2 + 1 .. comma3];

    if (sender) |s| {
        if (!std.mem.eql(u8, line_sender, s))
            return null;
    }

    const json = line[comma3 + 1 ..];

    const prefix = "\"url\":\"";

    const start = std.mem.indexOf(u8, json, prefix) orelse return null;

    const url_start = start + prefix.len;

    const url_end = std.mem.indexOfScalarPos(
        u8,
        json,
        url_start,
        '"',
    ) orelse return null;

    return json[url_start..url_end];
}

fn processLine(line: []u8, sender: ?[]const u8) !void {
    // Lines from other senders and malformed lines are ignored entirely.
    const url = parseLine(line, sender) orelse return;

    const is_audio =
        std.ascii.endsWithIgnoreCase(url, ".wav") or
        std.ascii.endsWithIgnoreCase(url, ".mp3") or
        std.ascii.endsWithIgnoreCase(url, ".flac");

    if (!is_audio) {
        stopSound();
        return;
    }

    stopSound();

    // Replace the closing quote with NUL, turning the URL
    // in the line buffer into a sentinel-terminated string.
    const url_start = @intFromPtr(url.ptr) - @intFromPtr(line.ptr);
    const url_end = url_start + url.len;
    line[url_end] = 0;

    const path: [:0]const u8 = @ptrCast(line[url_start..url_end]);

    current_sound = engine.createSoundFromFile(path, .{}) catch |err| {
        // file might have just been deleted with yazi
        if (err == error.DoesNotExist)
            return;

        return err;
    };

    try current_sound.?.start();
}

pub fn resolveClientId(
    allocator: std.mem.Allocator,
    io_arg: std.Io,
    no_client_id: bool,
) !?[]const u8 {
    if (no_client_id)
        return null;

    var rng_source = std.Random.IoSource{
        .io = io_arg,
    };
    const rng = rng_source.interface();

    var id: u32 = 0;
    while (id == 0)
        id = rng.int(u32);

    return @as(
        ?[]const u8,
        try std.fmt.allocPrint(allocator, "{d}", .{id}),
    );
}

pub fn buildYaziArgv(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    client_id: ?[]const u8,
) ![][]const u8 {
    const extra = if (client_id != null) @as(usize, 2) else 0;

    const argv = try allocator.alloc(
        []const u8,
        1 + args.len + extra,
    );

    argv[0] = "yazi";

    var i: usize = 1;

    if (client_id) |id| {
        argv[i] = "--client-id";
        argv[i + 1] = id;
        i += 2;
    }

    for (args, 0..) |arg, j| {
        argv[i + j] = arg;
    }

    return argv;
}

pub fn cleanupReapedChild(child: *std.process.Child) void {
    // Mirrors std's childCleanupPosix: close the pipe Files and drop the
    // process id so kill() and wait() become no-ops.
    if (child.stdin) |stdin| {
        std.Io.Threaded.closeFd(stdin.handle);
        child.stdin = null;
    }
    if (child.stdout) |stdout| {
        std.Io.Threaded.closeFd(stdout.handle);
        child.stdout = null;
    }
    if (child.stderr) |stderr| {
        std.Io.Threaded.closeFd(stderr.handle);
        child.stderr = null;
    }
    child.id = null;
}

fn spawnYaSubHover(io_arg: std.Io) !std.process.Child {
    return std.process.spawn(io_arg, .{
        .argv = &.{ "ya", "sub", "hover" },
        .stdout = .pipe,
        .stderr = .inherit,
    });
}

fn retrySpawnHover(io_arg: std.Io, hover: *std.process.Child) !RetryOutcome {
    // Give a freshly spawned hover process a grace period to connect to the
    // yazi daemon, then keep probing: the process is either alive (ready),
    // already exited (respawn, up to a ~5s deadline), or gone (stopped).
    const backoffs_ms = [_]i64{ 125, 250, 500, 1000, 2000 };

    for (backoffs_ms) |backoff_ms| {
        std.Io.sleep(io_arg, std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};

        const pid = hover.id orelse return .stopped;

        var status: c_int = undefined;

        const rc = std.posix.system.wait4(
            pid,
            &status,
            std.posix.W.NOHANG,
            null,
        );

        if (rc == 0) {
            // Still running after the grace period: connected.
            return .ready;
        } else if (rc == pid) {
            // Exited before connecting: reap and try again.
            cleanupReapedChild(hover);
            hover.* = try spawnYaSubHover(io_arg);
        } else if (rc == -1) {
            // ECHILD: already reaped elsewhere, treat as stopped.
            cleanupReapedChild(hover);
            return .stopped;
        }
    }

    return .gave_up;
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

    // Forward every argument after the program name to yazi unchanged.
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    var forwarded = std.ArrayList([]const u8).empty;
    defer forwarded.deinit(allocator);

    var first = true;

    while (args.next()) |arg| {
        if (first) {
            first = false;
            continue;
        }

        try forwarded.append(allocator, arg);
    }

    // PEEP_NO_CLIENT_ID=1 spawns yazi without --client-id and disables
    // sender filtering, for yazi versions that do not support hover
    // client ids.
    const no_client_id = std.process.Environ.containsConstant(
        init.minimal.environ,
        "PEEP_NO_CLIENT_ID",
    );

    const client_id = try resolveClientId(allocator, init.io, no_client_id);
    defer if (client_id) |id| allocator.free(id);

    const yazi_argv = try buildYaziArgv(
        allocator,
        forwarded.items,
        client_id,
    );
    defer allocator.free(yazi_argv);

    var yazi = try std.process.spawn(init.io, .{
        .argv = yazi_argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer yazi.kill(init.io);

    var hover = try spawnYaSubHover(init.io);
    defer hover.kill(init.io);

    const outcome = try retrySpawnHover(init.io, &hover);

    if (outcome == .stopped)
        return;

    // Settled: capture the hover stdout before the waiter thread may kill
    // the child, then hand the child over to the waiter.
    const stdout = hover.stdout orelse return error.NoStdout;

    const waiter = try std.Thread.spawn(.{}, waitForYazi, .{
        &yazi,
        &hover,
    });
    defer waiter.join();

    switch (outcome) {
        .ready => {
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
                        try processLine(line_buffer[0..line_len], client_id);
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
        },
        .gave_up => {
            // The hover process never connected within the deadline. yazi
            // keeps running; the waiter still reaps both processes on exit.
        },
        // Reached only if the early return above did not fire.
        .stopped => unreachable,
    }
}
