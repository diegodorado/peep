const std = @import("std");
const peep = @import("peep.zig");

test "parseLine: own sender -> url" {
    const line =
        "event,0,ya-client-abc,{\"url\":\"/tmp/song.wav\"}";

    const url = peep.parseLine(line, "ya-client-abc");
    try std.testing.expectEqualStrings("/tmp/song.wav", url.?);
}

test "parseLine: own sender, extra json fields after url" {
    const line =
        "event,0,ya-client-abc,{\"url\":\"/tmp/song.mp3\",\"kind\":\"audio\"}";

    const url = peep.parseLine(line, "ya-client-abc");
    try std.testing.expectEqualStrings("/tmp/song.mp3", url.?);
}

test "parseLine: no sender filter accepts any sender" {
    const line =
        "event,0,foreign-client,{\"url\":\"/tmp/a.flac\"}";

    const url = peep.parseLine(line, null);
    try std.testing.expectEqualStrings("/tmp/a.flac", url.?);
}

test "parseLine: foreign sender -> null" {
    const line =
        "event,0,ya-client-abc,{\"url\":\"/tmp/song.wav\"}";

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        peep.parseLine(line, "some-other-client"),
    );
}

test "parseLine: malformed lines -> null without crash" {
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        peep.parseLine("event,0", "ya-client-abc"),
    );

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        peep.parseLine("a,b,c", "ya-client-abc"),
    );

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        peep.parseLine("no commas at all", "ya-client-abc"),
    );

    // Sender matches but there is no url field.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        peep.parseLine("event,0,ya-client-abc,{\"kind\":\"x\"}", "ya-client-abc"),
    );
}

test "buildYaziArgv: forwards argv unchanged without client id" {
    const allocator = std.testing.allocator;

    const argv = try peep.buildYaziArgv(
        allocator,
        &.{ "--cwd", "/tmp", "--open" },
        null,
    );
    defer allocator.free(argv);

    try std.testing.expectEqualSlices(u8, "yazi", argv[0]);
    try std.testing.expectEqualSlices(u8, "--cwd", argv[1]);
    try std.testing.expectEqualSlices(u8, "/tmp", argv[2]);
    try std.testing.expectEqualSlices(u8, "--open", argv[3]);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
}

test "buildYaziArgv: inserts --client-id after yazi" {
    const allocator = std.testing.allocator;

    const argv = try peep.buildYaziArgv(
        allocator,
        &[_][]const u8{"--separator"},
        "42",
    );
    defer allocator.free(argv);

    try std.testing.expectEqualSlices(u8, "yazi", argv[0]);
    try std.testing.expectEqualSlices(u8, "--client-id", argv[1]);
    try std.testing.expectEqualSlices(u8, "42", argv[2]);
    try std.testing.expectEqualSlices(u8, "--separator", argv[3]);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
}

test "buildYaziArgv: empty args still yields yazi" {
    const allocator = std.testing.allocator;

    const argv = try peep.buildYaziArgv(allocator, &[_][]const u8{}, null);
    defer allocator.free(argv);

    try std.testing.expectEqualSlices(u8, "yazi", argv[0]);
    try std.testing.expectEqual(@as(usize, 1), argv.len);
}

test "resolveClientId: PEEP_NO_CLIENT_ID mapping -> null" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(
        allocator,
        .{},
    );
    defer threaded.deinit();

    // main maps the env var to this bool; true means flagless spawn.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try peep.resolveClientId(allocator, threaded.io(), true),
    );
}

test "resolveClientId: generates a non-zero id string" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(
        allocator,
        .{},
    );
    defer threaded.deinit();

    const id = try peep.resolveClientId(allocator, threaded.io(), false);
    defer allocator.free(id.?);

    const numeric = try std.fmt.parseInt(u32, id.?, 10);
    try std.testing.expect(numeric != 0);
}

test "resolveClientId: consecutive calls differ" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(
        allocator,
        .{},
    );
    defer threaded.deinit();

    const first = try peep.resolveClientId(allocator, threaded.io(), false);
    defer allocator.free(first.?);

    const second = try peep.resolveClientId(allocator, threaded.io(), false);
    defer allocator.free(second.?);

    try std.testing.expect(!std.mem.eql(u8, first.?, second.?));
}

test "cleanupReapedChild: closes pipes and nulls fields, kill no-ops" {
    var threaded = std.Io.Threaded.init(
        std.testing.allocator,
        .{},
    );
    defer threaded.deinit();

    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{"/usr/bin/true"},
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);

    try std.testing.expect(child.id != null);
    try std.testing.expect(child.stdout != null);

    // Reap the already-exited child with WNOHANG.
    const pid = child.id.?;
    var status: c_int = undefined;
    var reaped = false;

    for (0..1000) |_| {
        const rc = std.posix.system.wait4(
            pid,
            &status,
            std.posix.W.NOHANG,
            null,
        );

        if (rc == pid) {
            reaped = true;
            break;
        } else if (rc == -1) {
            break;
        }

        std.Io.sleep(
            io,
            std.Io.Duration.fromMilliseconds(1),
            .awake,
        ) catch break;
    }

    try std.testing.expect(reaped);

    peep.cleanupReapedChild(&child);

    try std.testing.expectEqual(
        @as(?std.process.Child.Id, null),
        child.id,
    );
    try std.testing.expectEqual(
        @as(?std.Io.File, null),
        child.stdin,
    );
    try std.testing.expectEqual(
        @as(?std.Io.File, null),
        child.stdout,
    );
    try std.testing.expectEqual(
        @as(?std.Io.File, null),
        child.stderr,
    );

    // Both a second cleanup and kill() must be no-ops now.
    peep.cleanupReapedChild(&child);
    child.kill(io);
}
