//! Cell-buffer renderer with frame diffing: each flush emits only the cells
//! that changed since the previous frame, so the terminal never flickers.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 256-color foreground index; `default` maps to the terminal default.
pub const Color = enum(u8) {
    default = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_cyan = 14,
    _,
};

pub const Style = struct {
    fg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bold == b.bold and a.dim == b.dim and a.reverse == b.reverse;
    }
};

const Cell = struct {
    bytes: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u8 = 1,
    style: Style = .{},

    fn eql(a: Cell, b: Cell) bool {
        return a.len == b.len and
            std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]) and
            a.style.eql(b.style);
    }

    fn text(c: *const Cell) []const u8 {
        return c.bytes[0..c.len];
    }
};

pub const Screen = struct {
    gpa: Allocator,
    width: u16 = 0,
    height: u16 = 0,
    cells: []Cell = &.{},
    prev: []Cell = &.{},
    /// Force a full repaint on the next flush (after resize or first frame).
    full_repaint: bool = true,
    out: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Screen {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Screen) void {
        s.gpa.free(s.cells);
        s.gpa.free(s.prev);
        s.out.deinit(s.gpa);
        s.* = undefined;
    }

    pub fn resize(s: *Screen, width: u16, height: u16) Allocator.Error!void {
        if (s.width == width and s.height == height) return;
        s.gpa.free(s.cells);
        s.gpa.free(s.prev);
        s.cells = try s.gpa.alloc(Cell, @as(usize, width) * height);
        s.prev = try s.gpa.alloc(Cell, @as(usize, width) * height);
        @memset(s.cells, .{});
        @memset(s.prev, .{});
        s.width = width;
        s.height = height;
        s.full_repaint = true;
    }

    pub fn clear(s: *Screen) void {
        @memset(s.cells, .{});
    }

    /// Writes UTF-8 text starting at (x, y), clipped to `max_width` columns.
    /// Codepoints outside the single-column monospace range render as '?' so
    /// column arithmetic stays trustworthy. Returns columns consumed.
    pub fn writeText(s: *Screen, x: u16, y: u16, input: []const u8, style: Style, max_width: u16) u16 {
        if (y >= s.height or x >= s.width) return 0;
        const limit = @min(@as(usize, max_width), s.width - x);
        var col: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(sanitizeInvalid(input));
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (col >= limit) break;
            var cell = Cell{ .style = style };
            if (cp.len > 4 or isWideOrControl(cp)) {
                cell.bytes[0] = '?';
                cell.len = 1;
            } else {
                @memcpy(cell.bytes[0..cp.len], cp);
                cell.len = @intCast(cp.len);
            }
            s.cells[@as(usize, y) * s.width + x + col] = cell;
            col += 1;
        }
        return @intCast(col);
    }

    pub fn fillRow(s: *Screen, y: u16, ch: []const u8, style: Style) void {
        if (y >= s.height) return;
        var x: u16 = 0;
        while (x < s.width) : (x += 1) {
            var cell = Cell{ .style = style };
            const len = @min(ch.len, 4);
            @memcpy(cell.bytes[0..len], ch[0..len]);
            cell.len = @intCast(len);
            s.cells[@as(usize, y) * s.width + x] = cell;
        }
    }

    /// Produces the ANSI byte stream that morphs the previous frame into the
    /// current one. Caller writes it to the terminal.
    pub fn renderDiff(s: *Screen) Allocator.Error![]const u8 {
        s.out.clearRetainingCapacity();
        var style: ?Style = null;
        var cursor_row: i32 = -1;
        var cursor_col: i32 = -1;

        for (0..s.height) |y| {
            for (0..s.width) |x| {
                const i = y * s.width + x;
                if (!s.full_repaint and s.cells[i].eql(s.prev[i])) continue;
                if (cursor_row != @as(i32, @intCast(y)) or cursor_col != @as(i32, @intCast(x))) {
                    try s.out.print(s.gpa, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
                }
                if (style == null or !style.?.eql(s.cells[i].style)) {
                    try appendSgr(&s.out, s.gpa, s.cells[i].style);
                    style = s.cells[i].style;
                }
                try s.out.appendSlice(s.gpa, s.cells[i].text());
                cursor_row = @intCast(y);
                cursor_col = @as(i32, @intCast(x)) + 1;
            }
        }
        std.mem.swap([]Cell, &s.cells, &s.prev);
        @memset(s.cells, .{});
        s.full_repaint = false;
        return s.out.items;
    }
};

fn appendSgr(out: *std.ArrayList(u8), gpa: Allocator, style: Style) Allocator.Error!void {
    try out.appendSlice(gpa, "\x1b[0");
    if (style.bold) try out.appendSlice(gpa, ";1");
    if (style.dim) try out.appendSlice(gpa, ";2");
    if (style.reverse) try out.appendSlice(gpa, ";7");
    if (style.fg != .default) try out.print(gpa, ";38;5;{d}", .{@intFromEnum(style.fg)});
    try out.appendSlice(gpa, "m");
}

/// Emoji and other wide glyphs occupy two columns and would shift everything
/// after them; substituting '?' keeps the frame diff math exact.
fn isWideOrControl(cp: []const u8) bool {
    const codepoint = std.unicode.utf8Decode(cp) catch return true;
    if (codepoint < 0x20) return true;
    if (codepoint >= 0x1100 and codepoint <= 0x115F) return true;
    if (codepoint >= 0x2E80 and codepoint <= 0xA4CF) return true;
    if (codepoint >= 0xAC00 and codepoint <= 0xD7A3) return true;
    if (codepoint >= 0xF900 and codepoint <= 0xFAFF) return true;
    if (codepoint >= 0xFE30 and codepoint <= 0xFE4F) return true;
    if (codepoint >= 0xFF00 and codepoint <= 0xFF60) return true;
    if (codepoint >= 0x1F000) return true;
    return false;
}

fn sanitizeInvalid(input: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(input)) return input;
    return "?";
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "renderDiff emits only changed cells on the second frame" {
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(10, 2);

    _ = screen.writeText(0, 0, "hello", .{}, 10);
    const first = try screen.renderDiff();
    try testing.expect(std.mem.indexOf(u8, first, "hello") != null);

    _ = screen.writeText(0, 0, "hellp", .{}, 10);
    const second = try screen.renderDiff();
    try testing.expect(std.mem.indexOf(u8, second, "p") != null);
    try testing.expect(std.mem.indexOf(u8, second, "hell") == null);
}

test "writeText clips to width and replaces wide glyphs" {
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(5, 1);

    const consumed = screen.writeText(0, 0, "za\u{017C}\u{00F3}\u{0142}\u{0107} \u{1F600}", .{}, 5);
    try testing.expectEqual(@as(u16, 5), consumed);
    const frame = try screen.renderDiff();
    try testing.expect(std.mem.indexOf(u8, frame, "\u{017C}") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\u{1F600}") == null);
}
