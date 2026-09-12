const std = @import("std");
const zaudio = @import("zaudio");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse return error.MissingArgument;
    const path = args.next() orelse return error.MissingArgument;

    zaudio.init(allocator);
    defer zaudio.deinit();

    std.debug.print("{s}", .{path});
    const engine = try zaudio.Engine.create(null);
    defer engine.destroy();

    const sound = try engine.createSoundFromFile(path, .{});
    defer sound.destroy();

    try sound.start();

    while (!sound.isAtEnd()) {
        try std.Io.sleep(init.io, .{ .nanoseconds = 10_000_000 }, .awake);
    }
}
