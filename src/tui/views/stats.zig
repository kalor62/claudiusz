//! Stats view: activity sparkline, totals, top tools and projects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const stats_mod = @import("../../core/stats.zig");

const Frame = app_mod.Frame;
const spark_levels = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
const range_days = 14;

pub fn draw(frame: Frame) Allocator.Error!void {
    const report = try frame.daemon.index.statsReport(frame.daemon.io, frame.arena, range_days, frame.now_ms);
    const area = frame.area;
    const screen = frame.screen;
    var y = area.y + 1;

    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "last {d} days", .{range_days}) catch "";
    widgets.drawBox(screen, area, title, .{ .dim = true });

    y += drawSparkline(frame, y, report);
    y += 1;

    var line_buf: [160]u8 = undefined;
    var token_bufs: [4][16]u8 = undefined;
    const totals = std.fmt.bufPrint(&line_buf, "prompts {d}   tool calls {d}   failures {d}   tokens in {s} / out {s} / cache-read {s} / cache-write {s}", .{
        report.totals.prompts,
        report.totals.tool_calls,
        report.totals.failures,
        widgets.formatTokens(&token_bufs[0], report.totals.tokens.input),
        widgets.formatTokens(&token_bufs[1], report.totals.tokens.output),
        widgets.formatTokens(&token_bufs[2], report.totals.tokens.cache_read),
        widgets.formatTokens(&token_bufs[3], report.totals.tokens.cache_creation),
    }) catch "";
    _ = screen.writeText(area.x + 2, y, totals, .{ .bold = true }, area.width -| 4);
    y += 2;

    const columns_top = y;
    _ = drawTopTools(frame, columns_top, report);
    _ = drawTopProjects(frame, columns_top, report);
}

fn drawSparkline(frame: Frame, y: u16, report: stats_mod.Report) u16 {
    const screen = frame.screen;
    const x0 = frame.area.x + 2;
    _ = screen.writeText(x0, y, "prompts/day ", .{ .dim = true }, 14);

    var max_prompts: u32 = 1;
    for (report.days) |day| max_prompts = @max(max_prompts, day.prompts);

    const today = stats_mod.dayKeyFromMs(report.generated_at_ms) orelse 0;
    const first_day = today - range_days + 1;
    var x = x0 + 13;
    var day_key = first_day;
    while (day_key <= today) : (day_key += 1) {
        const prompts = promptsForDay(report, day_key);
        const level = (prompts * (spark_levels.len - 1) + max_prompts / 2) / max_prompts;
        const glyph = spark_levels[@min(level, spark_levels.len - 1)];
        const style: @import("../render.zig").Style = if (prompts == 0) .{ .dim = true } else .{ .fg = .bright_cyan };
        x += screen.writeText(x, y, glyph, style, 1);
    }
    var peak_buf: [24]u8 = undefined;
    const peak = std.fmt.bufPrint(&peak_buf, "  peak {d}", .{max_prompts}) catch "";
    _ = screen.writeText(x, y, peak, .{ .dim = true }, 12);
    return 1;
}

fn promptsForDay(report: stats_mod.Report, day_key: i32) u32 {
    for (report.days) |day| {
        if (day.day_key == day_key) return day.prompts;
    }
    return 0;
}

fn drawTopTools(frame: Frame, y_start: u16, report: stats_mod.Report) u16 {
    const screen = frame.screen;
    const x = frame.area.x + 2;
    var y = y_start;
    _ = screen.writeText(x, y, "top tools", .{ .bold = true, .fg = .yellow }, 20);
    y += 1;
    var buf: [64]u8 = undefined;
    for (report.top_tools[0..@min(report.top_tools.len, 10)]) |tool| {
        const line = std.fmt.bufPrint(&buf, "{s: <18} {d}", .{ tool.name, tool.count }) catch continue;
        if (y >= frame.area.y + frame.area.height - 1) break;
        _ = screen.writeText(x, y, line, .{}, 26);
        y += 1;
    }
    return y;
}

fn drawTopProjects(frame: Frame, y_start: u16, report: stats_mod.Report) u16 {
    const screen = frame.screen;
    const x = frame.area.x + 32;
    if (x >= frame.area.x + frame.area.width) return y_start;
    var y = y_start;
    _ = screen.writeText(x, y, "top projects (prompts / tokens out / failures)", .{ .bold = true, .fg = .cyan }, frame.area.width -| 34);
    y += 1;
    var buf: [96]u8 = undefined;
    var token_buf: [16]u8 = undefined;
    for (report.top_projects[0..@min(report.top_projects.len, 10)]) |project| {
        const line = std.fmt.bufPrint(&buf, "{s: <24} {d: >5}  {s: >7}  {d}", .{
            project.project[0..@min(project.project.len, 24)],
            project.prompts,
            widgets.formatTokens(&token_buf, project.tokens.output),
            project.failures,
        }) catch continue;
        if (y >= frame.area.y + frame.area.height - 1) break;
        _ = screen.writeText(x, y, line, .{}, frame.area.width -| 34);
        y += 1;
    }
    return y;
}
