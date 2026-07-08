//! Wires collector, liveness scanner, index, broadcaster and HTTP API into
//! one running process. `serve` runs headless; the TUI runs on top of the
//! same daemon and reads the index directly.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const event_mod = @import("core/event.zig");
const parser = @import("core/parser.zig");
const index_mod = @import("core/index.zig");
const watcher_mod = @import("infra/watcher.zig");
const snapshot = @import("infra/snapshot.zig");
const liveness = @import("infra/liveness.zig");
const broadcast = @import("infra/broadcast.zig");
const http = @import("infra/http.zig");
const api = @import("api/handlers.zig");
const root_mod = @import("root.zig");

const log = std.log.scoped(.daemon);

/// Recent events kept in memory for /tail and the TUI.
pub const ring_capacity = 8192;
const liveness_every_ticks = 3;
const heartbeat_every_ticks = 50;
const snapshot_save_interval_ms: i64 = 60_000;

pub const Daemon = struct {
    gpa: Allocator,
    io: Io,
    cfg: config_mod.Config,
    index: index_mod.Index,
    broadcaster: broadcast.Broadcaster,
    handlers: api.Handlers,
    backfill_done: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(true),

    pub fn init(d: *Daemon, gpa: Allocator, io: Io, cfg: config_mod.Config) Allocator.Error!void {
        d.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .index = try index_mod.Index.init(gpa, ring_capacity),
            .broadcaster = broadcast.Broadcaster.init(gpa),
            .handlers = undefined,
        };
        d.handlers = .{
            .gpa = gpa,
            .index = &d.index,
            .broadcaster = &d.broadcaster,
            .version = root_mod.version,
        };
    }

    pub fn deinit(d: *Daemon) void {
        d.broadcaster.deinit(d.io);
        d.index.deinit();
        d.* = undefined;
    }

    /// Starts the collector in a background thread. Call once.
    pub fn startCollector(d: *Daemon) !std.Thread {
        return std.Thread.spawn(.{}, collectorLoop, .{d});
    }

    /// Runs the HTTP API on the calling thread. Blocks forever.
    pub fn serveHttp(d: *Daemon) !void {
        var server = http.Server{
            .gpa = d.gpa,
            .io = d.io,
            .port = d.cfg.port,
            .handlers = &d.handlers,
        };
        try server.serve();
    }

    fn collectorLoop(d: *Daemon) void {
        var watcher = watcher_mod.Watcher.init(d.gpa, d.io, d.cfg.root, .{ .start_at_end = false });
        defer watcher.deinit();
        var sink = Sink{ .daemon = d };

        if (d.cfg.cache_path) |path| {
            _ = snapshot.load(d.gpa, d.io, path, &d.index, &watcher);
        }
        watcher.tick(&sink) catch |err| {
            log.err("history backfill failed: {s}", .{@errorName(err)});
        };
        sink.publish = true;
        d.backfill_done.store(true, .release);
        d.livenessPass();
        log.info("backfill complete, watching {s}", .{d.cfg.root});

        d.saveSnapshot(&watcher);
        var saved_lines = sink.lines_seen;
        var saved_at_ms = d.nowMs();

        var ticks: u64 = 0;
        while (d.running.load(.acquire)) : (ticks += 1) {
            watcher.tick(&sink) catch |err| {
                log.warn("collector tick failed: {s}", .{@errorName(err)});
            };
            if (ticks % liveness_every_ticks == 0) d.livenessPass();
            if (ticks % heartbeat_every_ticks == 0) d.broadcaster.publish(d.io, ": ping\n\n");
            if (sink.lines_seen != saved_lines and d.nowMs() - saved_at_ms >= snapshot_save_interval_ms) {
                d.saveSnapshot(&watcher);
                saved_lines = sink.lines_seen;
                saved_at_ms = d.nowMs();
            }
            d.io.sleep(.fromMilliseconds(@intCast(d.cfg.poll_interval_ms)), .awake) catch |err| {
                log.warn("collector sleep interrupted: {s}", .{@errorName(err)});
                return;
            };
        }
        if (sink.lines_seen != saved_lines) d.saveSnapshot(&watcher);
    }

    fn saveSnapshot(d: *Daemon, watcher: *const watcher_mod.Watcher) void {
        const path = d.cfg.cache_path orelse return;
        snapshot.save(d.gpa, d.io, path, &d.index, watcher);
    }

    /// Asks the collector loop to exit; join the thread returned by
    /// `startCollector` afterwards.
    pub fn stop(d: *Daemon) void {
        d.running.store(false, .release);
    }

    fn livenessPass(d: *Daemon) void {
        var arena_state = std.heap.ArenaAllocator.init(d.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const states = liveness.scan(arena, d.io, d.cfg.root) catch |err| {
            log.warn("liveness scan failed: {s}", .{@errorName(err)});
            return;
        };
        const changes = d.index.applyLiveness(d.io, arena, states) catch |err| {
            log.warn("liveness apply failed: {s}", .{@errorName(err)});
            return;
        };
        for (changes) |change| {
            const json = std.json.Stringify.valueAlloc(arena, change, .{}) catch |err| {
                log.warn("cannot serialize status change: {s}", .{@errorName(err)});
                continue;
            };
            const frame = std.fmt.allocPrint(arena, "event: session_status\ndata: {s}\n\n", .{json}) catch |err| {
                log.warn("cannot format status frame: {s}", .{@errorName(err)});
                continue;
            };
            d.broadcaster.publish(d.io, frame);
        }
    }

    fn publishEvent(d: *Daemon, e: *const event_mod.Event) void {
        var arena_state = std.heap.ArenaAllocator.init(d.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const view = index_mod.viewOfEvent(arena, e) catch |err| {
            log.warn("cannot build event view: {s}", .{@errorName(err)});
            return;
        };
        const json = std.json.Stringify.valueAlloc(arena, view, .{}) catch |err| {
            log.warn("cannot serialize event: {s}", .{@errorName(err)});
            return;
        };
        const frame = std.fmt.allocPrint(arena, "event: {s}\ndata: {s}\n\n", .{ sseEventName(e), json }) catch |err| {
            log.warn("cannot format event frame: {s}", .{@errorName(err)});
            return;
        };
        d.broadcaster.publish(d.io, frame);
    }

    pub fn nowMs(d: *Daemon) i64 {
        const ts = Io.Timestamp.now(d.io, .real);
        return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
    }
};

fn sseEventName(e: *const event_mod.Event) []const u8 {
    return switch (e.payload) {
        .assistant_text => "assistant",
        else => @tagName(e.payload),
    };
}

/// Feeds parsed transcript lines into the index and, after backfill, onto
/// the SSE stream.
const Sink = struct {
    daemon: *Daemon,
    publish: bool = false,
    /// Total lines applied; the snapshot writer's dirty marker.
    lines_seen: u64 = 0,

    pub fn onLine(s: *Sink, path: []const u8, line: []const u8) void {
        _ = path;
        s.lines_seen += 1;
        const d = s.daemon;
        const events = parser.parseLine(d.gpa, line) catch |err| {
            log.warn("parse failed: {s}", .{@errorName(err)});
            return;
        };
        defer d.gpa.free(events);
        for (events) |e| {
            if (s.publish) d.publishEvent(&e);
            d.index.applyEvent(d.io, e) catch |err| {
                log.warn("index apply failed: {s}", .{@errorName(err)});
            };
        }
    }
};
