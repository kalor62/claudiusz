//! Projects view: audit table — which projects have Claude Code context and
//! settings files, and which are running bare.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const project_scanner = @import("../../infra/project_scanner.zig");

const Frame = app_mod.Frame;

pub fn draw(frame: Frame) Allocator.Error!void {
    const sessions = try frame.daemon.index.listSessions(frame.daemon.io, frame.arena);
    const audits = try project_scanner.scan(frame.arena, frame.daemon.io, sessions);

    const screen = frame.screen;
    const area = frame.area;
    screen.fillRow(area.y, " ", .{ .reverse = true, .dim = true });

    const name_width: u16 = @min(26, area.width / 3);
    var x = area.x + 1;
    x += screen.writeText(x, area.y, "PROJECT", .{ .reverse = true, .dim = true }, name_width);
    x = area.x + 1 + name_width;
    _ = screen.writeText(x, area.y, "CLAUDE.md  settings  allowlist  sessions  prompts  last", .{ .reverse = true, .dim = true }, area.width -| x);

    var y = area.y + 1;
    for (audits) |a| {
        if (y >= area.y + area.height) break;
        const name_style: render.Style = if (a.exists) .{ .bold = true } else .{ .dim = true };
        _ = screen.writeText(area.x + 1, y, a.project, name_style, name_width - 1);
        var cx = area.x + 1 + name_width;
        cx += drawMark(screen, cx, y, a.exists, a.has_claude_md, 11);
        cx += drawMark(screen, cx, y, a.exists, a.has_settings, 10);
        cx += drawMark(screen, cx, y, a.exists, a.has_settings_local, 11);

        var buf: [48]u8 = undefined;
        var ago_buf: [16]u8 = undefined;
        const counters = std.fmt.bufPrint(&buf, "{d: >8}  {d: >7}  {s}", .{
            a.sessions_seen,
            a.prompts_seen,
            widgets.formatAgo(&ago_buf, frame.now_ms, a.last_activity_ms),
        }) catch "";
        _ = screen.writeText(cx, y, counters, if (a.exists) .{} else .{ .dim = true }, area.width -| cx);
        y += 1;
    }
}

fn drawMark(screen: *render.Screen, x: u16, y: u16, exists: bool, present: bool, column_width: u16) u16 {
    const mark: []const u8 = if (!exists) "-" else if (present) "✓" else "✗";
    const style: render.Style = if (!exists)
        .{ .dim = true }
    else if (present)
        .{ .fg = .bright_green }
    else
        .{ .fg = .bright_red };
    _ = screen.writeText(x + column_width / 2, y, mark, style, 1);
    return column_width;
}
