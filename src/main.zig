const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var child: std.process.Child = try std.process.spawn(init.io, .{
        .argv = &.{ "ip", "-j", "neigh" },
        .stdout = .inherit,
        .stdin = .inherit,
        .stderr = .inherit,
    });

    const term: std.process.Child.Term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Exited with code {d}", .{code});
            return error.ChildExitedWithError;
        },
        else => {
            std.debug.print("Unexpeced Error\n", .{});
        },
    }
}
