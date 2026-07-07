//! Projects view: audit table — which projects have Claude Code context and
//! settings files, and which are running bare. Data comes from the frame
//! cache (TTL-refreshed filesystem scan).

const std = @import("std");
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");

const Frame = app_mod.Frame;
const theme = widgets.theme;
const log = std.log.scoped(.tui);

pub fn draw(frame: Frame) void {
    const audits = frame.cache.audits;
    const screen = frame.screen;
    const area = frame.area;
    screen.fillRow(area.y, " ", theme.header_off);

    const name_width: u16 = @min(26, area.width / 3);
    var x = area.x + 1;
    x += screen.writeText(x, area.y, "PROJECT", theme.header_off, name_width);
    x = area.x + 1 + name_width;
    _ = screen.writeText(x, area.y, "CLAUDE.md  settings  allowlist  sessions  prompts  last", theme.header_off, area.width -| x);

    var y = area.y + 1;
    for (audits) |a| {
        if (y >= area.y + area.height) break;
        const name_style: render.Style = if (a.exists) theme.text_bold else theme.faint;
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
        }) catch |err| {
            log.debug("project counters formatting failed: {s}", .{@errorName(err)});
            continue;
        };
        _ = screen.writeText(cx, y, counters, if (a.exists) theme.text else theme.faint, area.width -| cx);
        y += 1;
    }
}

fn drawMark(screen: *render.Screen, x: u16, y: u16, exists: bool, present: bool, column_width: u16) u16 {
    const mark: []const u8 = if (!exists) "-" else if (present) "✓" else "✗";
    const style: render.Style = if (!exists)
        theme.faint
    else if (present)
        theme.text_bold
    else
        theme.alert;
    _ = screen.writeText(x + column_width / 2, y, mark, style, 1);
    return column_width;
}
