const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\Usage: scannerz --interface NAME [--interval 30s] [--once]
    \\
    \\Actively discover IPv4 devices on your local network using arp-scan.
    \\  -i, --interface NAME  Network interface (see: ip -br addr)
    \\  -t, --interval TIME   Delay after each scan; ms, s, m, h (default: 30s)
    \\      --once            Scan once and exit
    \\  -h, --help            Show this help
    \\
    \\Requires arp-scan and permission to send raw packets.
    \\Only scan networks you own or have permission to scan.
    \\
;

const Options = struct {
    interface: []const u8 = "",
    interval_ms: i64 = 30_000,
    once: bool = false,
    help: bool = false,
};

fn parseInterval(text: []const u8) !i64 {
    const units = .{ .{ "ms", 1 }, .{ "s", 1000 }, .{ "m", 60_000 }, .{ "h", 3_600_000 } };
    inline for (units) |unit| {
        if (std.mem.endsWith(u8, text, unit[0])) {
            const digits = text[0 .. text.len - unit[0].len];
            if (digits.len == 0) return error.InvalidInterval;
            for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidInterval;
            const value = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidInterval;
            if (value <= 0 or value > std.math.maxInt(i64) / unit[1]) return error.InvalidInterval;
            return value * unit[1];
        }
    }
    return error.InvalidInterval;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else if (std.mem.eql(u8, arg, "--interface") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i == args.len or args[i].len == 0 or args[i][0] == '-') return error.MissingInterface;
            options.interface = args[i];
        } else if (std.mem.eql(u8, arg, "--interval") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i == args.len) return error.MissingInterval;
            options.interval_ms = try parseInterval(args[i]);
        } else {
            return error.UnknownOption;
        }
    }
    if (!options.help and options.interface.len == 0) return error.MissingInterface;
    return options;
}

const Device = struct {
    ip: []const u8,
    mac: []const u8,
    vendor: []const u8,
};

fn validIpv4(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
        count += 1;
    }
    return count == 4;
}

fn validMac(text: []const u8) bool {
    if (text.len != 17) return false;
    for (text, 0..) |c, i| {
        if (i % 3 == 2) {
            if (c != ':') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// Slices borrow the process output; consume them before freeing that buffer.
fn parseDevice(line: []const u8) ?Device {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const ip = fields.next() orelse return null;
    const mac = fields.next() orelse return null;
    if (!validIpv4(ip) or !validMac(mac)) return null;
    return .{
        .ip = ip,
        .mac = mac,
        .vendor = std.mem.trim(u8, fields.rest(), " \t"),
    };
}

fn scan(io: Io, allocator: Allocator, interface: []const u8, out: *Io.Writer) !void {
    // One argv entry prevents an interface name from becoming another option.
    const interface_arg = try std.fmt.allocPrint(allocator, "--interface={s}", .{interface});
    defer allocator.free(interface_arg);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "arp-scan", interface_arg, "--localnet", "--plain", "--numeric", "--ignoredups", "--format=${ip}\\t${mac}\\t${vendor}" },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        std.debug.print("Could not run arp-scan: {s}. Check installation and raw-packet permissions.\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stderr.len != 0) std.debug.print("{s}\n", .{std.mem.trimEnd(u8, result.stderr, "\r\n")});
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("arp-scan exited with code {d}.\n", .{code});
            return error.ScanFailed;
        },
        else => return error.ScanTerminated,
    }

    try out.print("\nScan on {s}\nIP\tMAC\tVENDOR\n", .{interface});
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const device = parseDevice(line) orelse {
            if (std.mem.trim(u8, line, " \t\r").len != 0) return error.InvalidScanOutput;
            continue;
        };
        try out.print("{s}\t{s}\t{s}\n", .{ device.ip, device.mac, device.vendor });
        count += 1;
    }
    try out.print("{d} device(s) responded.\n", .{count});
    try out.flush();
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) catch |err| {
        std.debug.print("Invalid arguments: {s}\n\n{s}", .{ @errorName(err), usage });
        return 1;
    };

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    if (options.help) {
        try out.writeAll(usage);
        try out.flush();
        return 0;
    }

    var first_scan = true;
    while (true) {
        scan(init.io, init.gpa, options.interface, out) catch |err| {
            std.debug.print("Scan failed: {s}\n", .{@errorName(err)});
            // Fail fast for setup errors; later transient failures can recover.
            if (first_scan or options.once or err == error.WriteFailed) return 1;
        };
        if (options.once) return 0;
        first_scan = false;
        try Io.sleep(init.io, .fromMilliseconds(options.interval_ms), .awake);
    }
}

test "intervals accept positive integer durations and reject invalid or overflowing values" {
    try std.testing.expectEqual(@as(i64, 500), try parseInterval("500ms"));
    try std.testing.expectEqual(@as(i64, 30_000), try parseInterval("30s"));
    try std.testing.expectEqual(@as(i64, 120_000), try parseInterval("2m"));
    try std.testing.expectEqual(@as(i64, 3_600_000), try parseInterval("1h"));
    for ([_][]const u8{ "", "s", "0s", "-1s", "+1s", "1.5s", "30", "1d", "9223372036854775807h", "999999999999999999999s" }) |text| {
        try std.testing.expectError(error.InvalidInterval, parseInterval(text));
    }
}

test "command line options" {
    const options = try parseOptions(&.{ "-i", "eth0", "--interval", "2m", "--once" });
    try std.testing.expectEqualStrings("eth0", options.interface);
    try std.testing.expectEqual(@as(i64, 120_000), options.interval_ms);
    try std.testing.expect(options.once);
    try std.testing.expect((try parseOptions(&.{"--help"})).help);
    try std.testing.expectEqual(@as(i64, 30_000), (try parseOptions(&.{ "--interface", "eth0" })).interval_ms);
    try std.testing.expectError(error.MissingInterface, parseOptions(&.{}));
    try std.testing.expectError(error.MissingInterface, parseOptions(&.{"-i"}));
    try std.testing.expectError(error.MissingInterface, parseOptions(&.{ "-i", "--once" }));
    try std.testing.expectError(error.MissingInterval, parseOptions(&.{"-t"}));
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{"--wat"}));
}

test "parse arp-scan rows preserving vendor names" {
    const device = parseDevice("192.168.1.1\taa:bb:cc:dd:ee:ff\tExample Device Inc.\r").?;
    try std.testing.expectEqualStrings("192.168.1.1", device.ip);
    try std.testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", device.mac);
    try std.testing.expectEqualStrings("Example Device Inc.", device.vendor);
    const no_vendor = parseDevice("  10.0.0.2   AA:BB:CC:DD:EE:FF  ").?;
    try std.testing.expectEqualStrings("", no_vendor.vendor);
    for ([_][]const u8{ "", "Starting arp-scan", "256.0.0.1 aa:bb:cc:dd:ee:ff", "1.2.3 aa:bb:cc:dd:ee:ff", "1.2.3.4.5 aa:bb:cc:dd:ee:ff", "1.2.3.4 zz:bb:cc:dd:ee:ff", "1.2.3.4 aa:bb", "1.2.3.4" }) |line| {
        try std.testing.expect(parseDevice(line) == null);
    }
}
