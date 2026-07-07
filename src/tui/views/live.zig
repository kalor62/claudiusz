//! Live view: cards for every live session on the left, the real-time event
//! feed on the right.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const time_mod = @import("../../core/time.zig");

const Frame = app_mod.Frame;

pub fn draw(frame: Frame) Allocator.Error!void {
    const cards_width = @min(frame.area.width / 2, 60);
    try drawCards(frame, .{
        .x = frame.area.x,
        .y = frame.area.y,
        .width = cards_width,
        .height = frame.area.height,
    });
    try drawFeed(frame, .{
        .x = frame.area.x + cards_width,
        .y = frame.area.y,
        .width = frame.area.width - cards_width,
        .height = frame.area.height,
    });
}

fn drawCards(frame: Frame, area: widgets.Rect) Allocator.Error!void {
    const summaries = try frame.daemon.index.listSessions(frame.daemon.io, frame.arena);
    var y = area.y;
    var shown: usize = 0;
    for (summaries) |s| {
        if (std.mem.eql(u8, s.status, "done")) continue;
        const card_height = 5;
        if (y + card_height > area.y + area.height) break;
        drawCard(frame, .{ .x = area.x, .y = y, .width = area.width, .height = card_height }, s);
        y += card_height;
        shown += 1;
    }
    if (shown == 0) {
        const message = "No live sessions — open Claude Code anywhere";
        _ = frame.screen.writeText(area.x + 2, area.y + 1, message, .{ .dim = true }, area.width - 2);
    }
}

fn drawCard(frame: Frame, rect: widgets.Rect, s: anytype) void {
    const screen = frame.screen;
    const status_style = widgets.statusStyle(s.status);
    widgets.drawBox(screen, rect, s.project, status_style);
    const inner = rect.inner();
    if (inner.width == 0) return;

    const badge = widgets.statusLabel(s.status);
    _ = screen.writeText(inner.x, inner.y, badge, status_style, inner.width);
    if (s.waiting_for.len > 0) {
        const after_badge: u16 = @intCast(@min(badge.len + 2, inner.width));
        _ = screen.writeText(inner.x + after_badge, inner.y, s.waiting_for, .{ .fg = .bright_yellow, .dim = true }, inner.width - after_badge);
    }
    var ago_buf: [16]u8 = undefined;
    const ago = widgets.formatAgo(&ago_buf, frame.now_ms, s.last_ts_ms);
    if (inner.width > ago.len) {
        _ = screen.writeText(@intCast(inner.x + inner.width - ago.len), inner.y, ago, .{ .dim = true }, @intCast(ago.len));
    }

    var line = inner.y + 1;
    if (s.last_prompt.len > 0) {
        var used = screen.writeText(inner.x, line, "> ", .{ .fg = .cyan, .bold = true }, inner.width);
        used += screen.writeText(inner.x + used, line, firstLine(s.last_prompt), .{ .fg = .cyan }, inner.width - used);
        line += 1;
    }
    if (s.last_activity.len > 0) {
        _ = screen.writeText(inner.x, line, firstLine(s.last_activity), .{}, inner.width);
    }
}

fn drawFeed(frame: Frame, area: widgets.Rect) Allocator.Error!void {
    widgets.drawBox(frame.screen, area, "events", .{ .dim = true });
    const inner = area.inner();
    if (inner.height == 0) return;

    const events = try frame.daemon.index.tailEvents(frame.daemon.io, frame.arena, null, inner.height);
    const start_y = inner.y + inner.height - @as(u16, @intCast(@min(events.len, inner.height)));
    for (events, 0..) |e, i| {
        const y = start_y + @as(u16, @intCast(i));
        var clock_buf: [8]u8 = undefined;
        var x = frame.screen.writeText(inner.x, y, time_mod.formatClock(&clock_buf, e.ts_ms), .{ .dim = true }, inner.width);
        x += frame.screen.writeText(inner.x + x, y, " ", .{}, 1);
        x += frame.screen.writeText(inner.x + x, y, e.project, .{ .fg = .cyan }, 12);
        x += frame.screen.writeText(inner.x + x, y, " ", .{}, 1);
        x += frame.screen.writeText(inner.x + x, y, eventGlyph(e.kind), eventStyle(e), 2);
        if (inner.width > x) {
            _ = frame.screen.writeText(inner.x + x, y, firstLine(eventText(e)), eventStyle(e), inner.width - x);
        }
    }
}

fn eventGlyph(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "prompt")) return "» ";
    if (std.mem.eql(u8, kind, "assistant_text")) return "◆ ";
    if (std.mem.eql(u8, kind, "tool_call")) return "⚙ ";
    if (std.mem.eql(u8, kind, "tool_result")) return "← ";
    if (std.mem.eql(u8, kind, "usage")) return "Σ ";
    return "· ";
}

fn eventStyle(e: anytype) render.Style {
    if (std.mem.eql(u8, e.kind, "prompt")) return .{ .fg = .bright_cyan, .bold = true };
    if (std.mem.eql(u8, e.kind, "tool_result") and e.ok == false) return .{ .fg = .bright_red };
    if (std.mem.eql(u8, e.kind, "tool_call")) return .{ .fg = .yellow };
    if (std.mem.eql(u8, e.kind, "assistant_text")) return .{ .fg = .green };
    return .{ .dim = true };
}

fn eventText(e: anytype) []const u8 {
    if (e.text.len > 0) return e.text;
    if (e.tool.len > 0 and e.detail.len > 0) return e.detail;
    if (e.tool.len > 0) return e.tool;
    if (e.model.len > 0) return e.model;
    return "";
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}
