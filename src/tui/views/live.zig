//! Live view: a fixed 2×2 grid of session boxes, each exactly a quarter of
//! the screen. A box shows only the vital numbers of one active session —
//! tokens, estimated cost, prompts, session length — plus the project's
//! Claude configuration (quality score, skills, agents, MCP, plugins).
//! More than four active sessions paginate; digits 1-9 jump between pages.

const std = @import("std");
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const index_mod = @import("../../core/index.zig");
const audit_mod = @import("../../core/audit.zig");
const pricing = @import("../../core/pricing.zig");

const Frame = app_mod.Frame;
const theme = widgets.theme;

pub const page_size = 4;

/// Pages needed for the sessions that still have a live process behind them.
pub fn pageCount(sessions: []const index_mod.SessionSummary) usize {
    var active: usize = 0;
    for (sessions) |s| {
        if (s.status != .done) active += 1;
    }
    return (active + page_size - 1) / page_size;
}

pub fn draw(frame: Frame) void {
    const area = frame.area;
    const pages = pageCount(frame.sessions);
    if (pages == 0) {
        drawEmptyState(frame);
        return;
    }
    const page = @min(frame.live_page, pages - 1);

    var cells: [page_size]?index_mod.SessionSummary = @splat(null);
    var total_active: usize = 0;
    const start = page * page_size;
    for (frame.sessions) |s| {
        if (s.status == .done) continue;
        if (total_active >= start and total_active < start + page_size) {
            cells[total_active - start] = s;
        }
        total_active += 1;
    }

    const cell_w = area.width / 2;
    const cell_h = area.height / 2;
    for (cells, 0..) |cell, i| {
        const col: u16 = @intCast(i % 2);
        const row: u16 = @intCast(i / 2);
        const rect = widgets.Rect{
            .x = area.x + col * cell_w,
            .y = area.y + row * cell_h,
            .width = if (col == 1) area.width - cell_w else cell_w,
            .height = if (row == 1) area.height - cell_h else cell_h,
        };
        if (cell) |s| drawSessionBox(frame, rect, s) else drawEmptyBox(frame, rect);
    }
    if (pages > 1) drawPageIndicator(frame, page, pages, total_active);
}

fn drawSessionBox(frame: Frame, rect: widgets.Rect, s: index_mod.SessionSummary) void {
    const screen = frame.screen;
    widgets.drawBoxHeavy(screen, rect, s.project, widgets.statusStyle(s.status));
    const inner = rect.inner();
    if (inner.width < 24 or inner.height < 4) return;

    var y = inner.y;
    var x = if (s.status == .working)
        drawWorkingPulse(screen, inner, y, frame.now_ms)
    else
        screen.writeText(inner.x, y, widgets.statusLabel(s.status), widgets.statusStyle(s.status), 12);
    if (s.waiting_for.len > 0) {
        x += screen.writeText(inner.x + x, y, " ⌁ ", theme.faint, 3);
        x += screen.writeText(inner.x + x, y, s.waiting_for, theme.amber, inner.width -| x -| 24);
    }
    const model = shortModel(s.model);
    writeRight(screen, inner, y, x, model[0..@min(model.len, 22)], theme.faint);

    // The blank line under the status becomes a "folder" row once the session
    // has changed directory away from its launch project.
    if (index_mod.currentFolder(s.cwd, s.current_dir)) |cf| {
        var folder_buf: [128]u8 = undefined;
        const folder_text = if (cf.relative)
            std.fmt.bufPrint(&folder_buf, "./{s}", .{cf.text}) catch cf.text
        else
            cf.text;
        _ = drawStatRow(screen, inner, y + 1, "folder", folder_text, theme.text);
    }
    y += 2;

    var token_bufs: [3][16]u8 = undefined;
    var value_buf: [96]u8 = undefined;
    const tokens_text = std.fmt.bufPrint(&value_buf, "in {s} · out {s} · cache {s}", .{
        widgets.formatTokens(&token_bufs[0], s.tokens.input),
        widgets.formatTokens(&token_bufs[1], s.tokens.output),
        widgets.formatTokens(&token_bufs[2], s.tokens.cache_read),
    }) catch "";
    y = drawStatRow(screen, inner, y, "tokens", tokens_text, theme.text);

    var usd_buf: [16]u8 = undefined;
    const cost_text = if (pricing.costUsd(s.model, s.tokens)) |usd|
        widgets.formatUsd(&usd_buf, usd)
    else
        "-";
    y = drawStatRow(screen, inner, y, "cost", cost_text, theme.text_bold);

    var prompt_buf: [12]u8 = undefined;
    const prompts_text = std.fmt.bufPrint(&prompt_buf, "{d}", .{s.prompt_count}) catch "";
    y = drawStatRow(screen, inner, y, "prompts", prompts_text, theme.text);

    var duration_buf: [24]u8 = undefined;
    y = drawStatRow(screen, inner, y, "session", widgets.formatDuration(&duration_buf, s.first_ts_ms, s.last_ts_ms), theme.text);

    drawConfigRows(screen, inner, y, findAudit(frame.cache.audits, s.cwd));
}

const pulse_width: u16 = 12;
const pulse_step_ms: i64 = 90;

/// A bright dot sweeping back and forth along a dim line — the "this session
/// is doing something right now" heartbeat. Driven by the frame clock, so the
/// diff renderer repaints only the few cells that moved.
fn drawWorkingPulse(screen: *render.Screen, inner: widgets.Rect, y: u16, now_ms: i64) u16 {
    if (inner.width < pulse_width) return 0;
    const steps: i64 = 2 * (@as(i64, pulse_width) - 1);
    const step = @mod(@divFloor(now_ms, pulse_step_ms), steps);
    const pos: i64 = if (step < pulse_width) step else steps - step;
    var i: u16 = 0;
    while (i < pulse_width) : (i += 1) {
        const dist = @abs(@as(i64, i) - pos);
        const glyph: []const u8 = if (dist == 0) "●" else if (dist == 1) "━" else "─";
        const style = if (dist == 0) theme.text_bold else if (dist == 1) theme.text else theme.faint;
        _ = screen.writeText(inner.x + i, y, glyph, style, 1);
    }
    return pulse_width;
}

fn drawConfigRows(screen: *render.Screen, inner: widgets.Rect, y_start: u16, project_audit: ?audit_mod.ProjectAudit) void {
    const bottom = inner.y + inner.height;
    var y = y_start;
    if (y >= bottom) return;
    _ = screen.writeText(inner.x, y, "─ project config ", theme.faint, inner.width);
    y += 1;
    if (y >= bottom) return;

    const a = project_audit orelse {
        _ = screen.writeText(inner.x, y, "no audit data", theme.faint, inner.width);
        return;
    };

    const score = a.qualityScore();
    var bar_buf: [32]u8 = undefined;
    var len: usize = 0;
    var i: u8 = 0;
    while (i < audit_mod.ProjectAudit.quality_max) : (i += 1) {
        const glyph = if (i < score) "▮" else "▯";
        @memcpy(bar_buf[len .. len + glyph.len], glyph);
        len += glyph.len;
    }
    const suffix = std.fmt.bufPrint(bar_buf[len..], " {d}/{d}", .{ score, audit_mod.ProjectAudit.quality_max }) catch "";
    const bar_style = if (score >= 4) theme.text_bold else if (score >= 2) theme.amber else theme.alert;
    y = drawStatRow(screen, inner, y, "quality", bar_buf[0 .. len + suffix.len], bar_style);
    if (y >= bottom) return;

    var x = screen.writeText(inner.x, y, "CLAUDE.md ", theme.text, 10);
    x += screen.writeText(
        inner.x + x,
        y,
        if (a.has_claude_md) "✓" else "✗",
        if (a.has_claude_md) theme.text_bold else theme.alert,
        2,
    );
    var counts_buf: [64]u8 = undefined;
    const skills_agents = std.fmt.bufPrint(&counts_buf, " · {d} skills · {d} agents", .{
        a.skill_count,
        a.agent_count,
    }) catch "";
    _ = screen.writeText(inner.x + x, y, skills_agents, theme.text, inner.width -| x);
    y += 1;
    if (y >= bottom) return;

    const rest = std.fmt.bufPrint(&counts_buf, "{d} mcp · {d} plugins", .{
        a.mcp_server_count,
        a.plugin_count,
    }) catch "";
    _ = screen.writeText(inner.x, y, rest, theme.text, inner.width);
}

fn drawStatRow(screen: *render.Screen, inner: widgets.Rect, y: u16, label: []const u8, value: []const u8, style: render.Style) u16 {
    const bottom = inner.y + inner.height;
    if (y >= bottom) return y;
    _ = screen.writeText(inner.x, y, label, theme.faint, 8);
    _ = screen.writeText(inner.x + 9, y, value, style, inner.width -| 9);
    return y + 1;
}

fn drawEmptyBox(frame: Frame, rect: widgets.Rect) void {
    widgets.drawBox(frame.screen, rect, "", theme.faint);
    const inner = rect.inner();
    const label = "no session";
    if (inner.width <= label.len or inner.height < 1) return;
    const x = inner.x + @as(u16, @intCast((inner.width - label.len) / 2));
    _ = frame.screen.writeText(x, inner.y + inner.height / 2, label, theme.faint, @intCast(label.len));
}

fn drawPageIndicator(frame: Frame, page: usize, pages: usize, total_active: usize) void {
    const area = frame.area;
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " page {d}/{d} · {d} active · press 1-{d} ", .{
        page + 1,
        pages,
        total_active,
        @min(pages, 9),
    }) catch return;
    if (area.width <= text.len + 4) return;
    const y = area.y + area.height - 1;
    _ = frame.screen.writeText(@intCast(area.x + area.width - text.len - 2), y, text, theme.amber, @intCast(text.len));
}

fn drawEmptyState(frame: Frame) void {
    const area = frame.area;
    const mid = area.y + area.height / 2;
    const line1 = "⟨ no live sessions ⟩";
    const line2 = "open Claude Code anywhere — activity appears here in real time";
    _ = frame.screen.writeText(center(area, line1.len), mid, line1, theme.text_bold, area.width);
    _ = frame.screen.writeText(center(area, line2.len), mid + 1, line2, theme.faint, area.width);
}

fn writeRight(screen: *render.Screen, inner: widgets.Rect, y: u16, used_left: u16, text: []const u8, style: render.Style) void {
    if (inner.width <= used_left + text.len + 2) return;
    _ = screen.writeText(@intCast(inner.x + inner.width - text.len), y, text, style, @intCast(text.len));
}

fn findAudit(audits: []const audit_mod.ProjectAudit, cwd: []const u8) ?audit_mod.ProjectAudit {
    for (audits) |a| {
        if (std.mem.eql(u8, a.cwd, cwd)) return a;
    }
    return null;
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
