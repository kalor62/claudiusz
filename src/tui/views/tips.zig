//! Tips view: prioritized workflow suggestions with their evidence, served
//! from the frame cache (TTL-refreshed).

const std = @import("std");
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const tips_mod = @import("../../core/tips.zig");

const Frame = app_mod.Frame;
const theme = widgets.theme;

pub fn draw(frame: Frame) void {
    const tips = frame.cache.tips;
    const area = frame.area;
    widgets.drawBox(frame.screen, area, "tips (14-day window)", theme.frame);
    const inner = area.inner();
    if (inner.height == 0) return;

    if (tips.len == 0) {
        _ = frame.screen.writeText(inner.x + 1, inner.y + 1, "Nothing to improve right now.", theme.text_bold, inner.width - 1);
        return;
    }

    var y = inner.y;
    for (tips) |tip| {
        if (y + 2 >= inner.y + inner.height) break;
        var x = frame.screen.writeText(inner.x, y, severityBadge(tip.severity), severityStyle(tip.severity), 8);
        if (tip.project.len > 0) {
            x += frame.screen.writeText(inner.x + x, y, tip.project, theme.accent_bold, 22);
            x += frame.screen.writeText(inner.x + x, y, "  ", .{}, 2);
        }
        _ = frame.screen.writeText(inner.x + x, y, tip.message, theme.text, inner.width -| x);
        y += 1;
        _ = frame.screen.writeText(inner.x + 8, y, tip.evidence, theme.faint, inner.width -| 8);
        y += 2;
    }
}

fn severityBadge(severity: tips_mod.Severity) []const u8 {
    return switch (severity) {
        .high => "▲ high  ",
        .warn => "● warn  ",
        .info => "○ info  ",
    };
}

fn severityStyle(severity: tips_mod.Severity) render.Style {
    return switch (severity) {
        .high => theme.alert,
        .warn => theme.amber,
        .info => theme.accent,
    };
}
