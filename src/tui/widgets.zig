//! Small drawing helpers shared by the TUI views.

const std = @import("std");
const render = @import("render.zig");
const session_mod = @import("../core/session.zig");

const Screen = render.Screen;
const Style = render.Style;

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn inner(r: Rect) Rect {
        if (r.width < 2 or r.height < 2) return .{ .x = r.x, .y = r.y, .width = 0, .height = 0 };
        return .{ .x = r.x + 1, .y = r.y + 1, .width = r.width - 2, .height = r.height - 2 };
    }
};

pub fn drawBox(screen: *Screen, rect: Rect, title: []const u8, style: Style) void {
    if (rect.width < 2 or rect.height < 2) return;
    const right = rect.x + rect.width - 1;
    const bottom = rect.y + rect.height - 1;

    _ = screen.writeText(rect.x, rect.y, "╭", style, 1);
    _ = screen.writeText(right, rect.y, "╮", style, 1);
    _ = screen.writeText(rect.x, bottom, "╰", style, 1);
    _ = screen.writeText(right, bottom, "╯", style, 1);
    var x = rect.x + 1;
    while (x < right) : (x += 1) {
        _ = screen.writeText(x, rect.y, "─", style, 1);
        _ = screen.writeText(x, bottom, "─", style, 1);
    }
    var y = rect.y + 1;
    while (y < bottom) : (y += 1) {
        _ = screen.writeText(rect.x, y, "│", style, 1);
        _ = screen.writeText(right, y, "│", style, 1);
    }
    if (title.len > 0 and rect.width > 6) {
        _ = screen.writeText(rect.x + 2, rect.y, " ", style, 1);
        const used = screen.writeText(rect.x + 3, rect.y, title, .{ .fg = style.fg, .bold = true }, rect.width - 6);
        _ = screen.writeText(rect.x + 3 + used, rect.y, " ", style, 1);
    }
}

pub fn statusStyle(status: []const u8) Style {
    const status_enum = std.meta.stringToEnum(session_mod.Status, status) orelse return .{ .dim = true };
    return switch (status_enum) {
        .working => .{ .fg = .bright_green, .bold = true },
        .waiting_for_user => .{ .fg = .bright_yellow, .bold = true },
        .idle => .{ .fg = .bright_cyan },
        .done => .{ .dim = true },
    };
}

pub fn statusLabel(status: []const u8) []const u8 {
    const status_enum = std.meta.stringToEnum(session_mod.Status, status) orelse return status;
    return switch (status_enum) {
        .working => "● working",
        .waiting_for_user => "◐ waiting",
        .idle => "○ idle",
        .done => "  done",
    };
}

/// Formats a token count into at most 6 columns: 999, 12.3k, 1.2M, 18.1M.
pub fn formatTokens(buf: []u8, count: u64) []const u8 {
    if (count < 1_000) {
        return std.fmt.bufPrint(buf, "{d}", .{count}) catch buf[0..0];
    }
    if (count < 1_000_000) {
        const whole = count / 1_000;
        const tenth = (count % 1_000) / 100;
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ whole, tenth }) catch buf[0..0];
    }
    const whole = count / 1_000_000;
    const tenth = (count % 1_000_000) / 100_000;
    return std.fmt.bufPrint(buf, "{d}.{d}M", .{ whole, tenth }) catch buf[0..0];
}

/// Formats "how long ago" into at most 4 columns: 12s, 5m, 3h, 2d.
pub fn formatAgo(buf: []u8, now_ms: i64, then_ms: i64) []const u8 {
    if (then_ms <= 0) return "-";
    const seconds = @divFloor(@max(now_ms - then_ms, 0), 1000);
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "-";
    if (seconds < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divFloor(seconds, 60)}) catch "-";
    if (seconds < 86_400) return std.fmt.bufPrint(buf, "{d}h", .{@divFloor(seconds, 3600)}) catch "-";
    return std.fmt.bufPrint(buf, "{d}d", .{@divFloor(seconds, 86_400)}) catch "-";
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "formatTokens compacts large numbers" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("999", formatTokens(&buf, 999));
    try testing.expectEqualStrings("12.3k", formatTokens(&buf, 12_345));
    try testing.expectEqualStrings("18.1M", formatTokens(&buf, 18_102_911));
}

test "formatAgo picks the coarsest sensible unit" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("12s", formatAgo(&buf, 13_000, 1_000));
    try testing.expectEqualStrings("5m", formatAgo(&buf, 301_000, 1_000));
    try testing.expectEqualStrings("2d", formatAgo(&buf, 1_000 + 2 * 86_400_000, 1_000));
    try testing.expectEqualStrings("-", formatAgo(&buf, 100, 0));
}
