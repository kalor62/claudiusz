//! Stats view: activity sparkline, totals, top tools and projects. Data
//! comes from the frame cache (TTL-refreshed), never recomputed per frame.

const std = @import("std");
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const stats_mod = @import("../../core/stats.zig");

const Frame = app_mod.Frame;
const theme = widgets.theme;
const log = std.log.scoped(.tui);

const spark_levels = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

pub fn draw(frame: Frame) void {
    const report = frame.cache.report;
    const area = frame.area;
    const screen = frame.screen;
    var y = area.y + 1;

    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "last {d} days", .{report.range_days}) catch "stats";
    widgets.drawBox(screen, area, title, theme.frame);

    y += drawSparkline(frame, y, report);
    y += 1;

    var line_buf: [192]u8 = undefined;
    var token_bufs: [4][16]u8 = undefined;
    const totals = std.fmt.bufPrint(&line_buf, "prompts {d}   tool calls {d}   failures {d}   tokens in {s} / out {s} / cache-read {s} / cache-write {s}", .{
        report.totals.prompts,
        report.totals.tool_calls,
        report.totals.failures,
        widgets.formatTokens(&token_bufs[0], report.totals.tokens.input),
        widgets.formatTokens(&token_bufs[1], report.totals.tokens.output),
        widgets.formatTokens(&token_bufs[2], report.totals.tokens.cache_read),
        widgets.formatTokens(&token_bufs[3], report.totals.tokens.cache_creation),
    }) catch |err| blk: {
        log.debug("stats totals formatting failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    _ = screen.writeText(area.x + 2, y, totals, theme.text_bold, area.width -| 4);
    y += 2;

    y = drawWeekly(frame, y);
    drawTopTools(frame, y, report);
    drawTopProjects(frame, y, report);
}

/// Rows kept free below the weekly table for the tools/projects lists.
const weekly_reserve_rows = 8;

const limit_bar_width = 24;

/// Progress bars against the user's weekly budgets from `claudiusz.json`.
/// Draws nothing when no budgets are configured (e.g. enterprise plans).
fn drawLimitBars(frame: Frame, y_start: u16) u16 {
    const bars = frame.cache.limit_bars;
    if (bars.len == 0) return y_start;
    const screen = frame.screen;
    const area = frame.area;
    const x = area.x + 2;
    const bottom = area.y + area.height - 1;
    if (y_start + bars.len + 2 >= bottom) return y_start;
    var y = y_start;

    _ = screen.writeText(x, y, "weekly limits · budgets from claudiusz.json (tokens in+out)", theme.accent_bold, area.width -| 4);
    y += 1;
    for (bars) |bar| {
        const percent = (bar.used * 100) / bar.budget;
        const filled: usize = @min(limit_bar_width, (bar.used * limit_bar_width) / bar.budget);

        var glyphs: [limit_bar_width * 3]u8 = undefined;
        var len: usize = 0;
        for (0..limit_bar_width) |i| {
            const glyph = if (i < filled) "█" else "░";
            @memcpy(glyphs[len .. len + glyph.len], glyph);
            len += glyph.len;
        }

        var row_buf: [128]u8 = undefined;
        var token_bufs: [2][16]u8 = undefined;
        const line = std.fmt.bufPrint(&row_buf, "{s: <10} {s} {d: >3}%   {s} / {s}", .{
            bar.label[0..@min(bar.label.len, 10)],
            glyphs[0..len],
            percent,
            widgets.formatTokens(&token_bufs[0], bar.used),
            widgets.formatTokens(&token_bufs[1], bar.budget),
        }) catch |err| {
            log.debug("limit bar formatting failed: {s}", .{@errorName(err)});
            continue;
        };
        const style = if (percent >= 90) theme.alert else if (percent >= 70) theme.amber else theme.text_bold;
        _ = screen.writeText(x, y, line, style, area.width -| 4);
        y += 1;
    }
    return y + 1;
}

fn drawWeekly(frame: Frame, y_start: u16) u16 {
    const weekly = frame.cache.weekly;
    if (!weekly.available or weekly.weeks.len == 0) return y_start;
    const screen = frame.screen;
    const area = frame.area;
    const x = area.x + 2;
    const bottom = area.y + area.height - 1;
    if (y_start + weekly_reserve_rows + 3 >= bottom) return y_start;
    var y = drawLimitBars(frame, y_start);

    var head_buf: [96]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "weekly usage · Claude Code stats cache · as of {s}", .{
        weekly.last_computed_date,
    }) catch "weekly usage";
    _ = screen.writeText(x, y, head, theme.accent_bold, area.width -| 4);
    y += 1;
    _ = screen.writeText(x, y, "week of      messages  sessions  tool calls    tokens  top models (in+out)", theme.faint, area.width -| 4);
    y += 1;

    const room: usize = bottom - weekly_reserve_rows - y;
    for (weekly.weeks[0..@min(weekly.weeks.len, room)], 0..) |week, i| {
        var models_buf: [72]u8 = undefined;
        var used: usize = 0;
        for (week.top_models, 0..) |entry, n| {
            var tok_buf: [16]u8 = undefined;
            const name = shortModel(entry.model);
            const part = std.fmt.bufPrint(models_buf[used..], "{s}{s} {s}", .{
                if (n == 0) "" else " · ",
                name[0..@min(name.len, 18)],
                widgets.formatTokens(&tok_buf, entry.tokens),
            }) catch break;
            used += part.len;
        }

        var row_buf: [160]u8 = undefined;
        var date_buf: [10]u8 = undefined;
        var count_bufs: [3][16]u8 = undefined;
        const line = std.fmt.bufPrint(&row_buf, "{s}    {s: >8}  {d: >8}  {s: >10}  {s: >8}  {s}", .{
            stats_mod.formatDayKey(&date_buf, week.start_day_key),
            widgets.formatTokens(&count_bufs[0], week.messages),
            week.sessions,
            widgets.formatTokens(&count_bufs[1], week.tool_calls),
            widgets.formatTokens(&count_bufs[2], week.tokens_total),
            models_buf[0..used],
        }) catch |err| {
            log.debug("weekly row formatting failed: {s}", .{@errorName(err)});
            continue;
        };
        _ = screen.writeText(x, y, line, if (i == 0) theme.text_bold else theme.text, area.width -| 4);
        y += 1;
    }

    var footer_buf: [96]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "since {s} · {d} sessions · {d} messages total", .{
        weekly.first_session_date,
        weekly.total_sessions,
        weekly.total_messages,
    }) catch "";
    _ = screen.writeText(x, y, footer, theme.faint, area.width -| 4);
    return y + 2;
}

fn shortModel(model: []const u8) []const u8 {
    const prefix = "claude-";
    if (std.mem.startsWith(u8, model, prefix)) return model[prefix.len..];
    return model;
}

fn drawSparkline(frame: Frame, y: u16, report: stats_mod.Report) u16 {
    const screen = frame.screen;
    const x0 = frame.area.x + 2;
    _ = screen.writeText(x0, y, "prompts/day ", theme.faint, 14);

    var max_prompts: u32 = 1;
    for (report.days) |day| max_prompts = @max(max_prompts, day.prompts);

    const today = stats_mod.dayKeyFromMs(report.generated_at_ms) orelse 0;
    const first_day = today - @as(i32, @intCast(report.range_days)) + 1;
    var x = x0 + 13;
    var day_key = first_day;
    while (day_key <= today) : (day_key += 1) {
        const prompts = promptsForDay(report, day_key);
        const level = (prompts * (spark_levels.len - 1) + max_prompts / 2) / max_prompts;
        const glyph = spark_levels[@min(level, spark_levels.len - 1)];
        const style = if (prompts == 0) theme.faint else theme.text_bold;
        x += screen.writeText(x, y, glyph, style, 1);
    }
    var peak_buf: [24]u8 = undefined;
    const peak = std.fmt.bufPrint(&peak_buf, "  peak {d}", .{max_prompts}) catch |err| blk: {
        log.debug("sparkline peak formatting failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    _ = screen.writeText(x, y, peak, theme.faint, 12);
    return 1;
}

fn promptsForDay(report: stats_mod.Report, day_key: i32) u32 {
    for (report.days) |day| {
        if (day.day_key == day_key) return day.prompts;
    }
    return 0;
}

fn drawTopTools(frame: Frame, y_start: u16, report: stats_mod.Report) void {
    const screen = frame.screen;
    const x = frame.area.x + 2;
    var y = y_start;
    _ = screen.writeText(x, y, "top tools", theme.accent_bold, 20);
    y += 1;
    var buf: [64]u8 = undefined;
    for (report.top_tools[0..@min(report.top_tools.len, 10)]) |tool| {
        const line = std.fmt.bufPrint(&buf, "{s: <18} {d}", .{ tool.name, tool.count }) catch |err| {
            log.debug("tool row formatting failed: {s}", .{@errorName(err)});
            continue;
        };
        if (y >= frame.area.y + frame.area.height - 1) break;
        _ = screen.writeText(x, y, line, theme.text, 26);
        y += 1;
    }
}

fn drawTopProjects(frame: Frame, y_start: u16, report: stats_mod.Report) void {
    const screen = frame.screen;
    const x = frame.area.x + 32;
    if (x >= frame.area.x + frame.area.width) return;
    var y = y_start;
    _ = screen.writeText(x, y, "top projects (prompts / tokens out / failures)", theme.accent_bold, frame.area.width -| 34);
    y += 1;
    var buf: [96]u8 = undefined;
    var token_buf: [16]u8 = undefined;
    for (report.top_projects[0..@min(report.top_projects.len, 10)]) |project| {
        const line = std.fmt.bufPrint(&buf, "{s: <24} {d: >5}  {s: >7}  {d}", .{
            project.project[0..@min(project.project.len, 24)],
            project.prompts,
            widgets.formatTokens(&token_buf, project.tokens.output),
            project.failures,
        }) catch |err| {
            log.debug("project row formatting failed: {s}", .{@errorName(err)});
            continue;
        };
        if (y >= frame.area.y + frame.area.height - 1) break;
        _ = screen.writeText(x, y, line, theme.text, frame.area.width -| 34);
        y += 1;
    }
}
