const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

fn run_ip(io: Io, allocator: Allocator) !std.process.RunResult {
    const result: std.process.RunResult = try std.process.run(allocator, io, .{ .argv = &.{ "ip", "-j", "neigh" } });

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("ip failed: {d}", .{code});
                return error.ChildExitedWithError;
            }
        },
        else => return error.ChildExitedAbnormally,
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    var allocator = init.arena.allocator();
    const result = try run_ip(init.io, allocator);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}
