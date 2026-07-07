//! Tips view: prioritized workflow suggestions with their evidence.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");
const tips_mod = @import("../../core/tips.zig");
const project_scanner = @import("../../infra/project_scanner.zig");

const Frame = app_mod.Frame;

pub fn draw(frame: Frame) Allocator.Error!void {
    const report = try frame.daemon.index.statsReport(frame.daemon.io, frame.arena, 7, frame.now_ms);
    const sessions = try frame.daemon.index.listSessions(frame.daemon.io, frame.arena);
    const audits = try project_scanner.scan(frame.arena, frame.daemon.io, sessions);
    const tips = try tips_mod.evaluate(frame.arena, .{ .report = report, .sessions = sessions, .audits = audits });

    const area = frame.area;
    widgets.drawBox(frame.screen, area, "tips (7-day window)", .{ .dim = true });
    const inner = area.inner();
    if (inner.height == 0) return;

    if (tips.len == 0) {
        _ = frame.screen.writeText(inner.x + 1, inner.y + 1, "Nothing to improve right now.", .{ .fg = .bright_green }, inner.width - 1);
        return;
    }

    var y = inner.y;
    for (tips) |tip| {
        if (y + 2 >= inner.y + inner.height) break;
        var x = frame.screen.writeText(inner.x, y, severityBadge(tip.severity), severityStyle(tip.severity), 8);
        if (tip.project.len > 0) {
            x += frame.screen.writeText(inner.x + x, y, tip.project, .{ .fg = .cyan, .bold = true }, 22);
            x += frame.screen.writeText(inner.x + x, y, "  ", .{}, 2);
        }
        _ = frame.screen.writeText(inner.x + x, y, tip.message, .{}, inner.width -| x);
        y += 1;
        _ = frame.screen.writeText(inner.x + 8, y, tip.evidence, .{ .dim = true }, inner.width -| 8);
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
        .high => .{ .fg = .bright_red, .bold = true },
        .warn => .{ .fg = .bright_yellow },
        .info => .{ .fg = .bright_cyan },
    };
}
