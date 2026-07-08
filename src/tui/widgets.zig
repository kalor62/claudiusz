//! Small drawing helpers shared by the TUI views.

const std = @import("std");
const render = @import("render.zig");
const session_mod = @import("../core/session.zig");

const Screen = render.Screen;
const Style = render.Style;

/// The dashboard palette: phosphor green as the base, cyan for the human
/// side (prompts), amber for waiting, red for failures.
pub const theme = struct {
    pub const text: Style = .{ .fg = .bright_green };
    pub const text_bold: Style = .{ .fg = .bright_green, .bold = true };
    pub const faint: Style = .{ .fg = .green, .dim = true };
    pub const frame: Style = .{ .fg = .green };
    pub const accent: Style = .{ .fg = .bright_cyan };
    pub const accent_bold: Style = .{ .fg = .bright_cyan, .bold = true };
    pub const amber: Style = .{ .fg = .bright_yellow, .bold = true };
    pub const alert: Style = .{ .fg = .bright_red, .bold = true };
    pub const header_on: Style = .{ .fg = .bright_green, .reverse = true, .bold = true };
    pub const header_off: Style = .{ .fg = .green, .reverse = true, .dim = true };
};

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

const BoxGlyphs = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
};

const rounded_glyphs = BoxGlyphs{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .horizontal = "─", .vertical = "│" };
const heavy_glyphs = BoxGlyphs{ .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .horizontal = "═", .vertical = "║" };

pub fn drawBox(screen: *Screen, rect: Rect, title: []const u8, style: Style) void {
    drawBoxGlyphs(screen, rect, title, style, rounded_glyphs);
}

/// Double-line frame for panels that should dominate the screen.
pub fn drawBoxHeavy(screen: *Screen, rect: Rect, title: []const u8, style: Style) void {
    drawBoxGlyphs(screen, rect, title, style, heavy_glyphs);
}

fn drawBoxGlyphs(screen: *Screen, rect: Rect, title: []const u8, style: Style, glyphs: BoxGlyphs) void {
    if (rect.width < 2 or rect.height < 2) return;
    const right = rect.x + rect.width - 1;
    const bottom = rect.y + rect.height - 1;

    _ = screen.writeText(rect.x, rect.y, glyphs.tl, style, 1);
    _ = screen.writeText(right, rect.y, glyphs.tr, style, 1);
    _ = screen.writeText(rect.x, bottom, glyphs.bl, style, 1);
    _ = screen.writeText(right, bottom, glyphs.br, style, 1);
    var x = rect.x + 1;
    while (x < right) : (x += 1) {
        _ = screen.writeText(x, rect.y, glyphs.horizontal, style, 1);
        _ = screen.writeText(x, bottom, glyphs.horizontal, style, 1);
    }
    var y = rect.y + 1;
    while (y < bottom) : (y += 1) {
        _ = screen.writeText(rect.x, y, glyphs.vertical, style, 1);
        _ = screen.writeText(right, y, glyphs.vertical, style, 1);
    }
    if (title.len > 0 and rect.width > 6) {
        _ = screen.writeText(rect.x + 2, rect.y, " ", style, 1);
        const used = screen.writeText(rect.x + 3, rect.y, title, .{ .fg = style.fg, .bold = true }, rect.width - 6);
        _ = screen.writeText(rect.x + 3 + used, rect.y, " ", style, 1);
    }
}

pub fn statusStyle(status: session_mod.Status) Style {
    return switch (status) {
        .working => theme.text_bold,
        .waiting_for_user => theme.amber,
        .idle => .{ .fg = .bright_cyan },
        .done => theme.faint,
    };
}

pub fn statusLabel(status: session_mod.Status) []const u8 {
    return switch (status) {
        .working => "● WORKING",
        .waiting_for_user => "◐ WAITING",
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

/// Formats a dollar amount into at most 7 columns: $0.42, $12.3, $123.
pub fn formatUsd(buf: []u8, usd: f64) []const u8 {
    if (usd < 10) return std.fmt.bufPrint(buf, "${d:.2}", .{usd}) catch "$?";
    if (usd < 100) return std.fmt.bufPrint(buf, "${d:.1}", .{usd}) catch "$?";
    return std.fmt.bufPrint(buf, "${d:.0}", .{usd}) catch "$?";
}

/// Formats a session's wall-clock span: 45s, 12m 5s, 3h 20m, 2d 4h.
pub fn formatDuration(buf: []u8, first_ms: i64, last_ms: i64) []const u8 {
    if (first_ms <= 0 or last_ms <= first_ms) return "-";
    const seconds = @divFloor(last_ms - first_ms, 1000);
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "-";
    const minutes = @divFloor(seconds, 60);
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, @mod(seconds, 60) }) catch "-";
    const hours = @divFloor(minutes, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, @mod(minutes, 60) }) catch "-";
    return std.fmt.bufPrint(buf, "{d}d {d}h", .{ @divFloor(hours, 24), @mod(hours, 24) }) catch "-";
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

test "formatUsd narrows precision as amounts grow" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("$0.42", formatUsd(&buf, 0.421));
    try testing.expectEqualStrings("$12.3", formatUsd(&buf, 12.34));
    try testing.expectEqualStrings("$123", formatUsd(&buf, 123.4));
}

test "formatDuration spans seconds to days" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("45s", formatDuration(&buf, 1_000, 46_000));
    try testing.expectEqualStrings("12m 5s", formatDuration(&buf, 1_000, 726_000));
    try testing.expectEqualStrings("3h 20m", formatDuration(&buf, 1_000, 12_001_000));
    try testing.expectEqualStrings("2d 4h", formatDuration(&buf, 1_000, 187_201_000));
    try testing.expectEqualStrings("-", formatDuration(&buf, 10, 10));
    try testing.expectEqualStrings("-", formatDuration(&buf, 0, 45_000));
}

test "formatAgo picks the coarsest sensible unit" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("12s", formatAgo(&buf, 13_000, 1_000));
    try testing.expectEqualStrings("5m", formatAgo(&buf, 301_000, 1_000));
    try testing.expectEqualStrings("2d", formatAgo(&buf, 1_000 + 2 * 86_400_000, 1_000));
    try testing.expectEqualStrings("-", formatAgo(&buf, 100, 0));
}
