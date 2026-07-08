//! TUI event loop: keyboard handling, frame pacing, tab navigation.
//! One session snapshot is taken per frame and shared by the header and the
//! active view; expensive data (audits, tips, stats) refreshes on a short
//! TTL instead of every repaint. The collector and HTTP API run in
//! background threads of the same process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const daemon_mod = @import("../daemon.zig");
const term_mod = @import("../infra/term.zig");
const project_scanner = @import("../infra/project_scanner.zig");
const claude_stats = @import("../infra/claude_stats.zig");
const render = @import("render.zig");
const widgets = @import("widgets.zig");
const index_mod = @import("../core/index.zig");
const stats_mod = @import("../core/stats.zig");
const tips_mod = @import("../core/tips.zig");
const audit_mod = @import("../core/audit.zig");
const live_view = @import("views/live.zig");
const help_view = @import("views/help.zig");
const sessions_view = @import("views/sessions.zig");
const stats_view = @import("views/stats.zig");
const tips_view = @import("views/tips.zig");
const projects_view = @import("views/projects.zig");
const root_mod = @import("../root.zig");

const log = std.log.scoped(.tui);

/// How long cached audits/tips/stats stay fresh between recomputes.
const cache_ttl_ms: i64 = 3000;

pub const Tab = enum {
    live,
    sessions,
    tips,
    projects,
    stats,
    help,

    fn label(t: Tab) []const u8 {
        return switch (t) {
            .live => "LIVE",
            .sessions => "SESSIONS",
            .tips => "TIPS",
            .projects => "PROJECTS",
            .stats => "STATS",
            .help => "HELP",
        };
    }
};

/// Everything a view needs to draw one frame. `sessions` is the single
/// index snapshot for this frame; `cache` carries the TTL-refreshed data.
pub const Frame = struct {
    arena: Allocator,
    screen: *render.Screen,
    daemon: *daemon_mod.Daemon,
    now_ms: i64,
    area: widgets.Rect,
    sessions: []const index_mod.SessionSummary,
    cache: *const ViewCache,
    live_page: usize = 0,
    help_page: usize = 0,
};

/// Audits, tips and the stats report are too expensive to rebuild at frame
/// rate (filesystem stats, full-index folds); they live in their own arena
/// and refresh every `cache_ttl_ms`.
pub const ViewCache = struct {
    arena: std.heap.ArenaAllocator,
    built_at_ms: i64 = 0,
    report: stats_mod.Report = undefined,
    audits: []const audit_mod.ProjectAudit = &.{},
    tips: []const tips_mod.Tip = &.{},
    weekly: claude_stats.Summary = .{},
    limit_bars: []const claude_stats.LimitBar = &.{},

    fn refresh(
        cache: *ViewCache,
        daemon: *daemon_mod.Daemon,
        sessions: []const index_mod.SessionSummary,
        now_ms: i64,
    ) Allocator.Error!void {
        if (cache.built_at_ms > 0 and now_ms - cache.built_at_ms < cache_ttl_ms) return;
        _ = cache.arena.reset(.retain_capacity);
        const arena = cache.arena.allocator();
        cache.report = try daemon.index.statsReport(daemon.io, arena, 14, now_ms);
        cache.audits = try project_scanner.scan(arena, daemon.io, sessions);
        cache.tips = try tips_mod.evaluate(arena, .{
            .report = cache.report,
            .sessions = sessions,
            .audits = cache.audits,
        });
        cache.weekly = claude_stats.load(arena, daemon.io, daemon.cfg.root, 8);
        cache.limit_bars = claude_stats.loadLimits(arena, daemon.io, daemon.cfg.root, cache.weekly);
        cache.built_at_ms = now_ms;
    }
};

pub const App = struct {
    gpa: Allocator,
    daemon: *daemon_mod.Daemon,
    term: term_mod.Terminal,
    screen: render.Screen,
    cache: ViewCache,
    tab: Tab = .live,
    selected: usize = 0,
    live_page: usize = 0,
    /// Page count as of the last drawn frame; digit keys page when > 1.
    live_pages: usize = 1,
    help_page: usize = 0,
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
            .cache = .{ .arena = std.heap.ArenaAllocator.init(gpa) },
        };
    }

    pub fn deinit(app: *App) void {
        app.clearListedIds();
        app.listed_ids.deinit(app.gpa);
        if (app.detail_session) |id| app.gpa.free(id);
        app.cache.arena.deinit();
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
                '1'...'9' => app.handleDigit(c),
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

    /// On paginated views (live with >4 sessions, help) digits jump between
    /// pages; everywhere else they switch tabs (arrows always switch tabs).
    fn handleDigit(app: *App, c: u8) void {
        const digit: usize = c - '1';
        if (app.tab == .live and app.live_pages > 1) {
            if (digit < app.live_pages) app.live_page = digit;
            return;
        }
        if (app.tab == .help) {
            if (digit < help_view.page_count) app.help_page = digit;
            return;
        }
        const tab_count = @typeInfo(Tab).@"enum".fields.len;
        if (digit < tab_count) app.switchTab(@enumFromInt(digit));
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
            _ = app.screen.writeText(0, 0, "terminal too small", widgets.theme.alert, size.width);
            app.term.writeOut(try app.screen.renderDiff());
            return;
        }

        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now_ms = app.daemon.nowMs();
        const sessions = try app.daemon.index.listSessions(app.daemon.io, arena);
        try app.cache.refresh(app.daemon, sessions, now_ms);

        app.live_pages = @max(live_view.pageCount(sessions), 1);
        if (app.live_page >= app.live_pages) app.live_page = app.live_pages - 1;

        const frame = Frame{
            .arena = arena,
            .screen = &app.screen,
            .daemon = app.daemon,
            .now_ms = now_ms,
            .area = .{ .x = 0, .y = 1, .width = size.width, .height = size.height - 2 },
            .sessions = sessions,
            .cache = &app.cache,
            .live_page = app.live_page,
            .help_page = app.help_page,
        };

        app.drawHeader(frame);
        app.drawFooter(size.height - 1);
        switch (app.tab) {
            .live => live_view.draw(frame),
            .sessions => try app.drawSessions(frame),
            .tips => tips_view.draw(frame),
            .projects => projects_view.draw(frame),
            .stats => stats_view.draw(frame),
            .help => help_view.draw(frame),
        }

        app.term.writeOut(try app.screen.renderDiff());
    }

    fn drawSessions(app: *App, frame: Frame) Allocator.Error!void {
        app.clearListedIds();
        for (frame.sessions) |s| {
            const id = app.gpa.dupe(u8, s.id) catch |err| {
                log.warn("session list truncated for selection: {s}", .{@errorName(err)});
                break;
            };
            app.listed_ids.append(app.gpa, id) catch |err| {
                log.warn("session list truncated for selection: {s}", .{@errorName(err)});
                app.gpa.free(id);
                break;
            };
        }
        if (app.selected >= frame.sessions.len and frame.sessions.len > 0) {
            app.selected = frame.sessions.len - 1;
        }

        if (app.detail_session) |id| {
            try sessions_view.drawDetail(frame, id);
        } else {
            sessions_view.drawTable(frame, frame.sessions, app.selected);
        }
    }

    fn drawHeader(app: *App, frame: Frame) void {
        const screen = &app.screen;
        screen.fillRow(0, " ", .{ .reverse = true });
        var x = screen.writeText(0, 0, " ▚ CLAUDIUSZ ", widgets.theme.header_on, 14);
        x += screen.writeText(x, 0, "▏", widgets.theme.header_off, 1);
        inline for (@typeInfo(Tab).@"enum".fields) |field| {
            const tab: Tab = @enumFromInt(field.value);
            const style = if (tab == app.tab) widgets.theme.text_bold else widgets.theme.header_off;
            x += screen.writeText(x, 0, "  ", .{ .reverse = true }, 2);
            x += screen.writeText(x, 0, tab.label(), style, 10);
        }
        if (!app.daemon.backfill_done.load(.acquire)) {
            _ = screen.writeText(x + 2, 0, "⟳ scanning history…", widgets.theme.header_off, 22);
            return;
        }
        var counts = [3]u32{ 0, 0, 0 };
        for (frame.sessions) |s| switch (s.status) {
            .working => counts[0] += 1,
            .waiting_for_user => counts[1] += 1,
            .idle => counts[2] += 1,
            .done => {},
        };
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "● {d}  ◐ {d}  ○ {d} ", .{ counts[0], counts[1], counts[2] }) catch |err| {
            log.debug("header counts formatting failed: {s}", .{@errorName(err)});
            return;
        };
        if (screen.width > x + 2 + text.len) {
            _ = screen.writeText(@intCast(screen.width - text.len), 0, text, widgets.theme.header_on, @intCast(text.len));
        }
    }

    fn drawFooter(app: *App, y: u16) void {
        app.screen.fillRow(y, " ", widgets.theme.faint);
        const hints = if (app.detail_session != null)
            " esc back · q close"
        else if ((app.tab == .live and app.live_pages > 1) or app.tab == .help)
            " q quit · ←→ tabs · 1-9 page · j/k select · ⏎ detail"
        else
            " q quit · 1-6/←→ tabs · j/k select · ⏎ detail";
        _ = app.screen.writeText(0, y, hints, widgets.theme.faint, app.screen.width);
        var buf: [32]u8 = undefined;
        const right = std.fmt.bufPrint(&buf, "api :{d} · v{s} ", .{ app.daemon.cfg.port, root_mod.version }) catch |err| {
            log.debug("footer formatting failed: {s}", .{@errorName(err)});
            return;
        };
        if (app.screen.width > right.len) {
            _ = app.screen.writeText(@intCast(app.screen.width - right.len), y, right, widgets.theme.faint, @intCast(right.len));
        }
    }
};
