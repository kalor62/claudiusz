//! Raw-mode terminal: alternate screen, keyboard decoding, size queries.
//! POSIX only — on Windows use `claudiusz serve` with an external frontend.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const log = std.log.scoped(.term);

pub const Size = struct { width: u16, height: u16 };

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
};

pub const Terminal = struct {
    io: Io,
    original: posix.termios,

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;

    pub fn init(io: Io) !Terminal {
        const original = try posix.tcgetattr(stdin_fd);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.oflag.OPOST = false;
        // VMIN=0/VTIME=1: reads return after ≤100 ms, which paces the UI loop.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;
        try posix.tcsetattr(stdin_fd, .FLUSH, raw);

        var terminal = Terminal{ .io = io, .original = original };
        terminal.writeOut("\x1b[?1049h\x1b[?25l\x1b[2J");
        return terminal;
    }

    pub fn deinit(t: *Terminal) void {
        t.writeOut("\x1b[?1049l\x1b[?25h");
        posix.tcsetattr(stdin_fd, .FLUSH, t.original) catch |err| {
            log.warn("cannot restore terminal attributes: {s}", .{@errorName(err)});
        };
    }

    pub fn size(t: *Terminal) Size {
        _ = t;
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS or ws.col == 0 or ws.row == 0) {
            return .{ .width = 80, .height = 24 };
        }
        return .{ .width = ws.col, .height = ws.row };
    }

    /// Blocks for at most ~100 ms. Null means no input arrived.
    pub fn readKey(t: *Terminal) ?Key {
        _ = t;
        var buf: [8]u8 = undefined;
        const rc = std.c.read(stdin_fd, &buf, buf.len);
        if (rc <= 0) {
            if (rc < 0) log.debug("stdin read failed: {s}", .{@tagName(posix.errno(rc))});
            return null;
        }
        return decodeKey(buf[0..@intCast(rc)]);
    }

    pub fn writeOut(t: *Terminal, bytes: []const u8) void {
        _ = t;
        var rest = bytes;
        while (rest.len > 0) {
            const rc = std.c.write(stdout_fd, rest.ptr, rest.len);
            if (rc < 0) {
                log.debug("stdout write failed: {s}", .{@tagName(posix.errno(rc))});
                return;
            }
            rest = rest[@intCast(rc)..];
        }
    }
};

fn decodeKey(bytes: []const u8) ?Key {
    if (bytes.len == 0) return null;
    if (bytes[0] == 0x1b) {
        if (bytes.len == 1) return .escape;
        if (bytes.len >= 3 and bytes[1] == '[') {
            return switch (bytes[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => null,
            };
        }
        return .escape;
    }
    return switch (bytes[0]) {
        '\r', '\n' => .enter,
        else => |c| if (std.ascii.isPrint(c)) Key{ .char = c } else null,
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "decodeKey handles printable, control and escape sequences" {
    try testing.expectEqual(Key{ .char = 'q' }, decodeKey("q").?);
    try testing.expectEqual(Key.enter, decodeKey("\r").?);
    try testing.expectEqual(Key.escape, decodeKey("\x1b").?);
    try testing.expectEqual(Key.up, decodeKey("\x1b[A").?);
    try testing.expectEqual(Key.down, decodeKey("\x1b[B").?);
    try testing.expectEqual(@as(?Key, null), decodeKey("\x01"));
}
