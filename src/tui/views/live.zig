//! Live view: the mission-control dashboard. Active sessions get large
//! panels — current activity, last prompt, grouped recent work, token
//! stats — instead of a raw event stream. Idle sessions collapse to one
//! line each; a strip of today's totals sits on top.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const index_mod = @import("../../core/index.zig");
const stats_mod = @import("../../core/stats.zig");

const Frame = app_mod.Frame;
const theme = widgets.theme;

const max_active_panels = 3;
const max_idle_rows = 5;

pub fn draw(frame: Frame) Allocator.Error!void {
    const area = frame.area;
    var y = area.y;
    y += drawTodayStrip(frame, y);

    var active_buf: [max_active_panels]index_mod.SessionSummary = undefined;
    var active_len: usize = 0;
    var active_total: usize = 0;
    var idle_buf: [max_idle_rows]index_mod.SessionSummary = undefined;
    var idle_len: usize = 0;
    var idle_total: usize = 0;
    for (frame.sessions) |s| switch (s.status) {
        .working, .waiting_for_user => {
            active_total += 1;
            if (active_len < max_active_panels) {
                active_buf[active_len] = s;
                active_len += 1;
            }
        },
        .idle => {
            idle_total += 1;
            if (idle_len < max_idle_rows) {
                idle_buf[idle_len] = s;
                idle_len += 1;
            }
        },
        .done => {},
    };

    if (active_len == 0 and idle_len == 0) {
        drawEmptyState(frame);
        return;
    }

    const bottom = area.y + area.height;
    var idle_rows: u16 = 0;
    if (idle_len > 0) idle_rows = @intCast(idle_len + 1);
    const panel_space = bottom - y - idle_rows;

    if (active_len > 0 and panel_space >= 7) {
        const panel_height = @max(7, panel_space / @as(u16, @intCast(active_len)));
        for (active_buf[0..active_len], 0..) |s, i| {
            const top = y + panel_height * @as(u16, @intCast(i));
            if (top + 7 > bottom - idle_rows) break;
            const height = if (i == active_len - 1) panel_space - panel_height * @as(u16, @intCast(i)) else panel_height;
            try drawActivePanel(frame, .{ .x = area.x, .y = top, .width = area.width, .height = height }, s);
        }
        if (active_total > active_len) {
            var buf: [40]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "… +{d} more active", .{active_total - active_len}) catch "";
            _ = frame.screen.writeText(area.x + 2, y + panel_space - 1, note, theme.faint, area.width);
        }
    } else if (active_len == 0 and panel_space > 3) {
        const message = "no session is working right now";
        _ = frame.screen.writeText(area.x + 2, y + panel_space / 2, message, theme.faint, area.width - 2);
    }

    if (idle_len > 0) {
        drawIdleStrip(frame, bottom - idle_rows, idle_buf[0..idle_len], idle_total);
    }
}

fn drawTodayStrip(frame: Frame, y: u16) u16 {
    const report = frame.cache.report;
    const today_key = stats_mod.dayKeyFromMs(frame.now_ms) orelse 0;
    var today = stats_mod.DayAgg{};
    for (report.days) |day| {
        if (day.day_key == today_key) {
            today = .{ .prompts = day.prompts, .tool_calls = day.tool_calls, .failures = day.failures, .tokens = day.tokens };
        }
    }
    var token_buf: [16]u8 = undefined;
    var buf: [128]u8 = undefined;
    const left = std.fmt.bufPrint(&buf, " TODAY ▸ {d} prompts · {d} tool calls · ✗{d} · {s} tokens out", .{
        today.prompts,
        today.tool_calls,
        today.failures,
        widgets.formatTokens(&token_buf, today.tokens.output),
    }) catch "";
    _ = frame.screen.writeText(frame.area.x, y, left, theme.text, frame.area.width);

    var right_token_buf: [16]u8 = undefined;
    var right_buf: [64]u8 = undefined;
    const right = std.fmt.bufPrint(&right_buf, "14d: {d} prompts · {s} out ", .{
        report.totals.prompts,
        widgets.formatTokens(&right_token_buf, report.totals.tokens.output),
    }) catch "";
    if (frame.area.width > left.len + right.len + 2) {
        _ = frame.screen.writeText(@intCast(frame.area.x + frame.area.width - right.len), y, right, theme.faint, @intCast(right.len));
    }
    return 1;
}

fn drawActivePanel(frame: Frame, rect: widgets.Rect, s: index_mod.SessionSummary) Allocator.Error!void {
    const screen = frame.screen;
    const border = widgets.statusStyle(s.status);
    widgets.drawBoxHeavy(screen, rect, s.project, border);
    const inner = rect.inner();
    if (inner.width < 20 or inner.height < 3) return;

    var y = inner.y;
    var x = screen.writeText(inner.x, y, widgets.statusLabel(s.status), widgets.statusStyle(s.status), 12);
    if (s.waiting_for.len > 0) {
        x += screen.writeText(inner.x + x, y, " ⌁ ", theme.faint, 3);
        x += screen.writeText(inner.x + x, y, s.waiting_for, theme.amber, inner.width -| x);
    }
    drawPanelStats(frame, inner, y, s);
    y += 1;

    if (s.last_prompt.len > 0 and y < inner.y + inner.height) {
        var used = screen.writeText(inner.x, y, "» ", theme.accent_bold, 2);
        used += screen.writeText(inner.x + used, y, firstLine(s.last_prompt), theme.accent, inner.width -| used);
        y += 1;
    }
    if (s.last_activity.len > 0 and y < inner.y + inner.height) {
        var used = screen.writeText(inner.x, y, "▶ ", theme.text_bold, 2);
        used += screen.writeText(inner.x + used, y, firstLine(s.last_activity), theme.text, inner.width -| used);
        y += 1;
    }

    if (y + 1 >= inner.y + inner.height) return;
    _ = screen.writeText(inner.x, y, "─ activity ", theme.faint, inner.width);
    y += 1;

    const rows: usize = inner.y + inner.height - y;
    const groups = try groupActivity(frame, s.id, rows);
    for (groups) |group| {
        drawGroupRow(frame, inner, y, group);
        y += 1;
    }
}

fn drawPanelStats(frame: Frame, inner: widgets.Rect, y: u16, s: index_mod.SessionSummary) void {
    var token_bufs: [3][16]u8 = undefined;
    var buf: [128]u8 = undefined;
    const model = shortModel(s.model);
    const text = std.fmt.bufPrint(&buf, "{s} · in {s} · out {s} · cache {s} · {d}⚙", .{
        model[0..@min(model.len, 20)],
        widgets.formatTokens(&token_bufs[0], s.tokens.input),
        widgets.formatTokens(&token_bufs[1], s.tokens.output),
        widgets.formatTokens(&token_bufs[2], s.tokens.cache_read),
        s.tool_call_count,
    }) catch return;
    if (inner.width > text.len + 14) {
        _ = frame.screen.writeText(@intCast(inner.x + inner.width - text.len), y, text, theme.faint, @intCast(text.len));
    }
}

const GroupTag = @import("../../core/session.zig").ActivityKind;

const Group = struct {
    tag: GroupTag,
    tool: []const u8 = "",
    text: []const u8 = "",
    count: u32 = 1,
    failed: u32 = 0,
    last_ts: i64 = 0,
};

/// Collapses the session's activity ring into human-scale steps: consecutive
/// calls to the same tool merge into one row with a count, failures fold into
/// the row they belong to, subagent chatter becomes a single line.
fn groupActivity(frame: Frame, session_id: []const u8, limit: usize) Allocator.Error![]Group {
    const steps = try frame.daemon.index.sessionActivity(frame.daemon.io, frame.arena, session_id);
    var groups: std.ArrayList(Group) = .empty;

    for (steps) |step| {
        switch (step.kind) {
            .prompt => try groups.append(frame.arena, .{ .tag = .prompt, .text = step.text, .last_ts = step.ts_ms }),
            .responded, .subagent => try appendOrMerge(frame.arena, &groups, .{ .tag = step.kind, .count = step.count, .last_ts = step.ts_ms }),
            .tool => {
                const last = if (groups.items.len > 0) &groups.items[groups.items.len - 1] else null;
                if (last != null and last.?.tag == .tool and std.mem.eql(u8, last.?.tool, step.tool)) {
                    last.?.count += step.count;
                    last.?.text = step.text;
                    last.?.last_ts = step.ts_ms;
                    last.?.failed += step.failed;
                } else {
                    try groups.append(frame.arena, .{
                        .tag = .tool,
                        .tool = step.tool,
                        .text = step.text,
                        .count = step.count,
                        .last_ts = step.ts_ms,
                        .failed = step.failed,
                    });
                }
            },
        }
    }

    // Sort by recency, not ring order: subagent transcripts backfill after the
    // main file, so their entries land out of chronological ring position.
    std.sort.pdq(Group, groups.items, {}, newestFirst);
    if (groups.items.len > limit) groups.shrinkRetainingCapacity(limit);
    return groups.items;
}

fn newestFirst(_: void, a: Group, b: Group) bool {
    return a.last_ts > b.last_ts;
}

fn appendOrMerge(arena: Allocator, groups: *std.ArrayList(Group), group: Group) Allocator.Error!void {
    if (groups.items.len > 0) {
        const last = &groups.items[groups.items.len - 1];
        if (last.tag == group.tag) {
            last.count += group.count;
            last.last_ts = group.last_ts;
            return;
        }
    }
    try groups.append(arena, group);
}

fn drawGroupRow(frame: Frame, inner: widgets.Rect, y: u16, group: Group) void {
    const screen = frame.screen;
    var x: u16 = 0;
    switch (group.tag) {
        .prompt => {
            x += screen.writeText(inner.x, y, "» ", theme.accent_bold, 2);
            x += screen.writeText(inner.x + x, y, firstLine(group.text), theme.accent, inner.width -| x -| 5);
        },
        .responded => {
            x += screen.writeText(inner.x, y, "◆ responded", theme.text, 12);
            x += drawCount(screen, inner, y, x, group.count);
        },
        .subagent => {
            x += screen.writeText(inner.x, y, "⇉ subagent activity", theme.faint, 20);
            x += drawCount(screen, inner, y, x, group.count);
        },
        .tool => {
            x += screen.writeText(inner.x, y, "⚙ ", theme.text, 2);
            x += screen.writeText(inner.x + x, y, group.tool, theme.text_bold, 14);
            x += drawCount(screen, inner, y, x, group.count);
            if (group.failed > 0) {
                var fail_buf: [12]u8 = undefined;
                const fail = std.fmt.bufPrint(&fail_buf, " ✗{d}", .{group.failed}) catch "";
                x += screen.writeText(inner.x + x, y, fail, theme.alert, 6);
            }
            if (group.text.len > 0 and inner.width > x + 8) {
                x += screen.writeText(inner.x + x, y, " · ", theme.faint, 3);
                x += screen.writeText(inner.x + x, y, firstLine(group.text), theme.text, inner.width -| x -| 5);
            }
        },
    }
    var ago_buf: [16]u8 = undefined;
    const ago = widgets.formatAgo(&ago_buf, frame.now_ms, group.last_ts);
    if (inner.width > ago.len + 1) {
        _ = screen.writeText(@intCast(inner.x + inner.width - ago.len), y, ago, theme.faint, @intCast(ago.len));
    }
}

fn drawCount(screen: *render.Screen, inner: widgets.Rect, y: u16, x: u16, count: u32) u16 {
    if (count < 2) return 0;
    var buf: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " ×{d}", .{count}) catch return 0;
    return screen.writeText(inner.x + x, y, text, theme.text_bold, 6);
}

fn drawIdleStrip(frame: Frame, y_start: u16, idle: []const index_mod.SessionSummary, idle_total: usize) void {
    const screen = frame.screen;
    const area = frame.area;
    var header_buf: [48]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "─ idle sessions ({d}) ", .{idle_total}) catch "";
    _ = screen.writeText(area.x, y_start, header, theme.faint, area.width);

    for (idle, 0..) |s, i| {
        const y = y_start + 1 + @as(u16, @intCast(i));
        var x = screen.writeText(area.x + 1, y, "○ ", .{ .fg = .bright_cyan }, 2);
        x += screen.writeText(area.x + 1 + x, y, s.project, theme.text, 22);
        x += screen.writeText(area.x + 1 + x, y, "  ", .{}, 2);
        const label = if (s.title.len > 0) s.title else s.last_activity;
        _ = screen.writeText(area.x + 1 + x, y, firstLine(label), theme.faint, area.width -| x -| 8);
        var ago_buf: [16]u8 = undefined;
        const ago = widgets.formatAgo(&ago_buf, frame.now_ms, s.last_ts_ms);
        if (area.width > ago.len + 1) {
            _ = screen.writeText(@intCast(area.x + area.width - ago.len - 1), y, ago, theme.faint, @intCast(ago.len));
        }
    }
}

fn drawEmptyState(frame: Frame) void {
    const area = frame.area;
    const mid = area.y + area.height / 2;
    const line1 = "⟨ no live sessions ⟩";
    const line2 = "open Claude Code anywhere — activity appears here in real time";
    _ = frame.screen.writeText(center(area, line1.len), mid, line1, theme.text_bold, area.width);
    _ = frame.screen.writeText(center(area, line2.len), mid + 1, line2, theme.faint, area.width);
}

fn center(area: widgets.Rect, text_len: usize) u16 {
    if (area.width <= text_len) return area.x;
    return area.x + @as(u16, @intCast((area.width - text_len) / 2));
}

fn shortModel(model: []const u8) []const u8 {
    const prefix = "claude-";
    if (std.mem.startsWith(u8, model, prefix)) return model[prefix.len..];
    return model;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}
