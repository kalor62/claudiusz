//! Sessions view: sortable table of every known session and a full-detail
//! panel showing everything the index knows about one of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const index_mod = @import("../../core/index.zig");
const time_mod = @import("../../core/time.zig");

const Frame = app_mod.Frame;
const log = std.log.scoped(.tui);

pub fn drawTable(frame: Frame, summaries: []const index_mod.SessionSummary, selected: usize) void {
    const screen = frame.screen;
    const area = frame.area;
    const header_y = area.y;
    screen.fillRow(header_y, " ", .{ .reverse = true, .dim = true });

    const columns = layoutColumns(area.width);
    drawRowText(screen, header_y, columns, .{ .reverse = true, .dim = true }, .{
        .project = "PROJECT",
        .title = "TITLE",
        .status = "STATUS",
        .model = "MODEL",
        .input = "IN",
        .output = "OUT",
        .cache = "CACHE",
        .last = "LAST",
    });

    const visible_rows: usize = area.height -| 1;
    const first = scrollOffset(selected, summaries.len, visible_rows);
    for (summaries[first..@min(first + visible_rows, summaries.len)], 0..) |s, row| {
        const y = header_y + 1 + @as(u16, @intCast(row));
        const is_selected = first + row == selected;
        const base: render.Style = if (is_selected) .{ .reverse = true } else .{};
        if (is_selected) screen.fillRow(y, " ", base);

        var token_bufs: [3][16]u8 = undefined;
        var ago_buf: [16]u8 = undefined;
        drawRowText(screen, y, columns, base, .{
            .project = s.project,
            .title = if (s.title.len > 0) s.title else s.last_prompt,
            .status = widgets.statusLabel(s.status),
            .model = shortModel(s.model),
            .input = widgets.formatTokens(&token_bufs[0], s.tokens.input),
            .output = widgets.formatTokens(&token_bufs[1], s.tokens.output),
            .cache = widgets.formatTokens(&token_bufs[2], s.tokens.cache_read),
            .last = widgets.formatAgo(&ago_buf, frame.now_ms, s.last_ts_ms),
        });
        if (!is_selected) {
            _ = screen.writeText(columns.status.x, y, widgets.statusLabel(s.status), widgets.statusStyle(s.status), columns.status.width);
        }
    }
}

pub fn drawDetail(frame: Frame, session_id: []const u8) Allocator.Error!void {
    const screen = frame.screen;
    const area = frame.area;
    const detail = (try frame.daemon.index.sessionDetail(frame.daemon.io, frame.arena, session_id)) orelse {
        _ = screen.writeText(area.x + 2, area.y + 1, "session no longer known", .{ .fg = .bright_red }, area.width);
        return;
    };
    const s = detail.summary;

    widgets.drawBox(screen, area, s.project, widgets.statusStyle(s.status));
    const inner = area.inner();
    if (inner.width < 20 or inner.height < 8) return;

    var y = inner.y;
    y += drawField(screen, inner, y, "session", s.id);
    y += drawField(screen, inner, y, "title", if (s.title.len > 0) s.title else "-");
    y += drawField(screen, inner, y, "cwd", s.cwd);
    y += drawField(screen, inner, y, "branch", orDash(detail.git_branch));
    y += drawField(screen, inner, y, "model", orDash(s.model));
    y += drawField(screen, inner, y, "permissions", orDash(detail.permission_mode));
    y += drawField(screen, inner, y, "cc version", orDash(detail.app_version));

    var buf: [96]u8 = undefined;
    const status_line = std.fmt.bufPrint(&buf, "{s}  {s}", .{ widgets.statusLabel(s.status), s.waiting_for }) catch |err| blk: {
        log.debug("detail status formatting failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    _ = screen.writeText(inner.x, y, "status      ", .{ .dim = true }, inner.width);
    _ = screen.writeText(inner.x + 12, y, status_line, widgets.statusStyle(s.status), inner.width - 12);
    y += 1;

    var pid_buf: [64]u8 = undefined;
    if (detail.pid > 0) {
        const pid_line = std.fmt.bufPrint(&pid_buf, "{d}", .{detail.pid}) catch unreachable;
        y += drawField(screen, inner, y, "pid", pid_line);
    }

    var stats_buf: [160]u8 = undefined;
    var token_bufs: [4][16]u8 = undefined;
    const stats_line = std.fmt.bufPrint(&stats_buf, "in {s}  out {s}  cache-read {s}  cache-write {s}", .{
        widgets.formatTokens(&token_bufs[0], s.tokens.input),
        widgets.formatTokens(&token_bufs[1], s.tokens.output),
        widgets.formatTokens(&token_bufs[2], s.tokens.cache_read),
        widgets.formatTokens(&token_bufs[3], s.tokens.cache_creation),
    }) catch |err| blk: {
        log.debug("detail tokens formatting failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    y += drawField(screen, inner, y, "tokens", stats_line);

    const counts_line = std.fmt.bufPrint(&stats_buf, "{d} prompts  {d} tool calls  {d} failures  {d} subagent events", .{
        s.prompt_count, s.tool_call_count, s.tool_failure_count, detail.subagent_event_count,
    }) catch |err| blk: {
        log.debug("detail activity formatting failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    y += drawField(screen, inner, y, "activity", counts_line);

    y += drawToolCounts(screen, inner, y, detail.tool_counts);
    y += 1;
    try drawEventTail(frame, inner, y, session_id);
}

fn drawField(screen: *render.Screen, inner: widgets.Rect, y: u16, label: []const u8, value: []const u8) u16 {
    if (y >= inner.y + inner.height) return 0;
    _ = screen.writeText(inner.x, y, label, .{ .dim = true }, 12);
    _ = screen.writeText(inner.x + 12, y, value, .{}, inner.width -| 12);
    return 1;
}

fn drawToolCounts(screen: *render.Screen, inner: widgets.Rect, y: u16, tool_counts: []const index_mod.ToolCount) u16 {
    if (y >= inner.y + inner.height or tool_counts.len == 0) return 0;
    _ = screen.writeText(inner.x, y, "tools", .{ .dim = true }, 12);
    var x = inner.x + 12;
    var buf: [48]u8 = undefined;
    for (tool_counts) |tc| {
        const chunk = std.fmt.bufPrint(&buf, "{s}:{d}  ", .{ tc.name, tc.count }) catch |err| {
            log.debug("tool count formatting failed: {s}", .{@errorName(err)});
            continue;
        };
        if (x + chunk.len >= inner.x + inner.width) break;
        x += screen.writeText(x, y, chunk, .{}, inner.width);
    }
    return 1;
}

fn drawEventTail(frame: Frame, inner: widgets.Rect, start_y: u16, session_id: []const u8) Allocator.Error!void {
    if (start_y + 1 >= inner.y + inner.height) return;
    _ = frame.screen.writeText(inner.x, start_y, "recent events", .{ .dim = true, .bold = true }, inner.width);
    const rows: usize = inner.y + inner.height - start_y - 1;
    const events = try frame.daemon.index.tailEvents(frame.daemon.io, frame.arena, session_id, rows);
    for (events, 0..) |e, i| {
        const y = start_y + 1 + @as(u16, @intCast(i));
        var clock_buf: [8]u8 = undefined;
        var x = frame.screen.writeText(inner.x, y, time_mod.formatClock(&clock_buf, e.ts_ms), .{ .dim = true }, inner.width);
        x += frame.screen.writeText(inner.x + x, y, " ", .{}, 1);
        x += frame.screen.writeText(inner.x + x, y, e.kind, .{ .fg = .yellow }, 14);
        x += frame.screen.writeText(inner.x + x, y, " ", .{}, 1);
        const text = if (e.text.len > 0) e.text else e.detail;
        _ = frame.screen.writeText(inner.x + x, y, firstLine(text), .{}, inner.width -| x);
    }
}

const Columns = struct {
    project: widgets.Rect,
    title: widgets.Rect,
    status: widgets.Rect,
    model: widgets.Rect,
    input: widgets.Rect,
    output: widgets.Rect,
    cache: widgets.Rect,
    last: widgets.Rect,
};

const RowText = struct {
    project: []const u8,
    title: []const u8,
    status: []const u8,
    model: []const u8,
    input: []const u8,
    output: []const u8,
    cache: []const u8,
    last: []const u8,
};

fn layoutColumns(width: u16) Columns {
    const fixed: u16 = 16 + 11 + 15 + 7 + 7 + 7 + 5 + 8;
    const title_width = if (width > fixed) width - fixed else 8;
    var x: u16 = 1;
    const project = col(&x, 16);
    const title = col(&x, title_width);
    const status = col(&x, 11);
    const model = col(&x, 15);
    const input = col(&x, 7);
    const output = col(&x, 7);
    const cache = col(&x, 7);
    const last = col(&x, 5);
    return .{
        .project = project,
        .title = title,
        .status = status,
        .model = model,
        .input = input,
        .output = output,
        .cache = cache,
        .last = last,
    };
}

fn col(x: *u16, width: u16) widgets.Rect {
    const rect = widgets.Rect{ .x = x.*, .y = 0, .width = width -| 1, .height = 1 };
    x.* += width;
    return rect;
}

fn drawRowText(screen: *render.Screen, y: u16, columns: Columns, style: render.Style, row: RowText) void {
    _ = screen.writeText(columns.project.x, y, row.project, style, columns.project.width);
    _ = screen.writeText(columns.title.x, y, firstLine(row.title), style, columns.title.width);
    _ = screen.writeText(columns.status.x, y, row.status, style, columns.status.width);
    _ = screen.writeText(columns.model.x, y, row.model, style, columns.model.width);
    _ = screen.writeText(columns.input.x, y, row.input, style, columns.input.width);
    _ = screen.writeText(columns.output.x, y, row.output, style, columns.output.width);
    _ = screen.writeText(columns.cache.x, y, row.cache, style, columns.cache.width);
    _ = screen.writeText(columns.last.x, y, row.last, style, columns.last.width);
}

/// Keeps the selection visible: scrolls when it walks past the viewport.
fn scrollOffset(selected: usize, total: usize, visible: usize) usize {
    if (total <= visible or visible == 0) return 0;
    if (selected < visible / 2) return 0;
    const centered = selected - visible / 2;
    return @min(centered, total - visible);
}

fn orDash(text: []const u8) []const u8 {
    return if (text.len > 0) text else "-";
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

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "scrollOffset keeps selection in the viewport" {
    try testing.expectEqual(@as(usize, 0), scrollOffset(0, 100, 20));
    try testing.expectEqual(@as(usize, 0), scrollOffset(5, 100, 20));
    try testing.expectEqual(@as(usize, 40), scrollOffset(50, 100, 20));
    try testing.expectEqual(@as(usize, 80), scrollOffset(99, 100, 20));
    try testing.expectEqual(@as(usize, 0), scrollOffset(3, 5, 20));
}

test "shortModel strips the vendor prefix" {
    try testing.expectEqualStrings("fable-5", shortModel("claude-fable-5"));
    try testing.expectEqualStrings("gpt-x", shortModel("gpt-x"));
}
