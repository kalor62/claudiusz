//! TUI event loop: keyboard handling, frame pacing, tab navigation.
//! Reads index snapshots each frame; the collector and HTTP API run in
//! background threads of the same process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const daemon_mod = @import("../daemon.zig");
const term_mod = @import("../infra/term.zig");
const render = @import("render.zig");
const widgets = @import("widgets.zig");
const live_view = @import("views/live.zig");
const sessions_view = @import("views/sessions.zig");
const stats_view = @import("views/stats.zig");
const tips_view = @import("views/tips.zig");
const projects_view = @import("views/projects.zig");
const root_mod = @import("../root.zig");

const log = std.log.scoped(.tui);

pub const Tab = enum {
    live,
    sessions,
    tips,
    projects,
    stats,

    fn label(t: Tab) []const u8 {
        return switch (t) {
            .live => "1 Live",
            .sessions => "2 Sessions",
            .tips => "3 Tips",
            .projects => "4 Projects",
            .stats => "5 Stats",
        };
    }
};

/// Everything a view needs to draw one frame.
pub const Frame = struct {
    arena: Allocator,
    screen: *render.Screen,
    daemon: *daemon_mod.Daemon,
    now_ms: i64,
    area: widgets.Rect,
};

pub const App = struct {
    gpa: Allocator,
    daemon: *daemon_mod.Daemon,
    term: term_mod.Terminal,
    screen: render.Screen,
    tab: Tab = .live,
    selected: usize = 0,
    /// Session id whose detail panel is open; owned by `gpa`.
    detail_session: ?[]const u8 = null,
    /// Session ids as last drawn by the sessions table, for selection.
    listed_ids: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, daemon: *daemon_mod.Daemon) !App {
        return .{
            .gpa = gpa,
            .daemon = daemon,
            .term = try term_mod.Terminal.init(daemon.io),
            .screen = render.Screen.init(gpa),
        };
    }

    pub fn deinit(app: *App) void {
        app.clearListedIds();
        app.listed_ids.deinit(app.gpa);
        if (app.detail_session) |id| app.gpa.free(id);
        app.screen.deinit();
        app.term.deinit();
        app.* = undefined;
    }

    pub fn run(app: *App) !void {
        while (true) {
            if (app.term.readKey()) |key| {
                if (app.handleKey(key)) return;
            }
            app.drawFrame() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }

    /// Returns true when the user asked to quit.
    fn handleKey(app: *App, key: term_mod.Key) bool {
        switch (key) {
            .char => |c| switch (c) {
                'q' => {
                    if (app.detail_session != null) {
                        app.closeDetail();
                        return false;
                    }
                    return true;
                },
                '1' => app.switchTab(.live),
                '2' => app.switchTab(.sessions),
                '3' => app.switchTab(.tips),
                '4' => app.switchTab(.projects),
                '5' => app.switchTab(.stats),
                'j' => app.moveSelection(1),
                'k' => app.moveSelection(-1),
                else => {},
            },
            .up => app.moveSelection(-1),
            .down => app.moveSelection(1),
            .left => app.switchTabBy(-1),
            .right => app.switchTabBy(1),
            .enter => app.openDetail(),
            .escape => app.closeDetail(),
        }
        return false;
    }

    fn switchTab(app: *App, tab: Tab) void {
        app.tab = tab;
        app.selected = 0;
        app.closeDetail();
    }

    fn switchTabBy(app: *App, delta: i32) void {
        const count = @typeInfo(Tab).@"enum".fields.len;
        const current: i32 = @intFromEnum(app.tab);
        const next = @mod(current + delta, @as(i32, @intCast(count)));
        app.switchTab(@enumFromInt(next));
    }

    fn moveSelection(app: *App, delta: i32) void {
        if (app.listed_ids.items.len == 0) return;
        const last: i32 = @intCast(app.listed_ids.items.len - 1);
        const next = std.math.clamp(@as(i32, @intCast(app.selected)) + delta, 0, last);
        app.selected = @intCast(next);
    }

    fn openDetail(app: *App) void {
        if (app.tab != .sessions) return;
        if (app.selected >= app.listed_ids.items.len) return;
        const id = app.gpa.dupe(u8, app.listed_ids.items[app.selected]) catch |err| {
            log.warn("cannot open detail: {s}", .{@errorName(err)});
            return;
        };
        app.closeDetail();
        app.detail_session = id;
    }

    fn closeDetail(app: *App) void {
        if (app.detail_session) |id| app.gpa.free(id);
        app.detail_session = null;
    }

    fn clearListedIds(app: *App) void {
        for (app.listed_ids.items) |id| app.gpa.free(id);
        app.listed_ids.clearRetainingCapacity();
    }

    fn drawFrame(app: *App) Allocator.Error!void {
        const size = app.term.size();
        try app.screen.resize(size.width, size.height);
        if (size.height < 6 or size.width < 40) {
            _ = app.screen.writeText(0, 0, "terminal too small", .{ .fg = .bright_red }, size.width);
            app.term.writeOut(try app.screen.renderDiff());
            return;
        }

        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const frame = Frame{
            .arena = arena_state.allocator(),
            .screen = &app.screen,
            .daemon = app.daemon,
            .now_ms = app.daemon.nowMs(),
            .area = .{ .x = 0, .y = 1, .width = size.width, .height = size.height - 2 },
        };

        app.drawHeader(frame);
        app.drawFooter(frame, size.height - 1);
        switch (app.tab) {
            .live => try live_view.draw(frame),
            .sessions => try app.drawSessions(frame),
            .tips => try tips_view.draw(frame),
            .projects => try projects_view.draw(frame),
            .stats => try stats_view.draw(frame),
        }

        app.term.writeOut(try app.screen.renderDiff());
    }

    fn drawSessions(app: *App, frame: Frame) Allocator.Error!void {
        const summaries = try app.daemon.index.listSessions(app.daemon.io, frame.arena);
        app.clearListedIds();
        for (summaries) |s| {
            const id = app.gpa.dupe(u8, s.id) catch break;
            app.listed_ids.append(app.gpa, id) catch {
                app.gpa.free(id);
                break;
            };
        }
        if (app.selected >= summaries.len and summaries.len > 0) app.selected = summaries.len - 1;

        if (app.detail_session) |id| {
            try sessions_view.drawDetail(frame, id);
        } else {
            sessions_view.drawTable(frame, summaries, app.selected);
        }
    }

    fn drawHeader(app: *App, frame: Frame) void {
        const screen = &app.screen;
        screen.fillRow(0, " ", .{ .reverse = true });
        var x = screen.writeText(0, 0, " claudiusz ", .{ .reverse = true, .bold = true }, 12);
        inline for (@typeInfo(Tab).@"enum".fields) |field| {
            const tab: Tab = @enumFromInt(field.value);
            const style: render.Style = if (tab == app.tab)
                .{ .bold = true }
            else
                .{ .reverse = true, .dim = true };
            x += screen.writeText(x, 0, " ", .{ .reverse = true }, 1);
            x += screen.writeText(x, 0, tab.label(), style, 14);
        }
        if (!app.daemon.backfill_done.load(.acquire)) {
            _ = screen.writeText(x + 2, 0, "⟳ backfilling history…", .{ .reverse = true, .dim = true }, 24);
        } else {
            var counts_buf: [64]u8 = undefined;
            const counts = app.liveCounts(frame.arena);
            const text = std.fmt.bufPrint(&counts_buf, "● {d} working  ◐ {d} waiting  ○ {d} idle", .{
                counts.working, counts.waiting, counts.idle,
            }) catch "";
            if (frame.screen.width > x + 2 + text.len) {
                _ = screen.writeText(@intCast(frame.screen.width - text.len - 1), 0, text, .{ .reverse = true }, @intCast(text.len));
            }
        }
    }

    const LiveCounts = struct { working: u32 = 0, waiting: u32 = 0, idle: u32 = 0 };

    fn liveCounts(app: *App, arena: Allocator) LiveCounts {
        const summaries = app.daemon.index.listSessions(app.daemon.io, arena) catch return .{};
        var counts = LiveCounts{};
        for (summaries) |s| {
            if (std.mem.eql(u8, s.status, "working")) counts.working += 1;
            if (std.mem.eql(u8, s.status, "waiting_for_user")) counts.waiting += 1;
            if (std.mem.eql(u8, s.status, "idle")) counts.idle += 1;
        }
        return counts;
    }

    fn drawFooter(app: *App, frame: Frame, y: u16) void {
        _ = frame;
        app.screen.fillRow(y, " ", .{ .dim = true });
        const hints = if (app.detail_session != null)
            " esc back   q close   http://127.0.0.1 API "
        else
            " q quit   1-5 tabs   j/k select   enter detail ";
        _ = app.screen.writeText(0, y, hints, .{ .dim = true }, app.screen.width);
        var port_buf: [24]u8 = undefined;
        const port = std.fmt.bufPrint(&port_buf, "api :{d}  v{s} ", .{ app.daemon.cfg.port, root_mod.version }) catch "";
        if (app.screen.width > port.len) {
            _ = app.screen.writeText(@intCast(app.screen.width - port.len), y, port, .{ .dim = true }, @intCast(port.len));
        }
    }

    fn drawPlaceholder(frame: Frame, message: []const u8) void {
        const y = frame.area.y + frame.area.height / 2;
        const x = if (frame.area.width > message.len) (frame.area.width - @as(u16, @intCast(message.len))) / 2 else 0;
        _ = frame.screen.writeText(x, y, message, .{ .dim = true }, frame.area.width);
    }
};
