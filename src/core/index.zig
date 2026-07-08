//! Thread-safe in-memory state: session aggregates plus a ring buffer of
//! recent events. The collector writes, the API/TUI read arena-copied
//! snapshots, so readers never hold references into guarded memory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");
const session_mod = @import("session.zig");
const stats = @import("stats.zig");

const Event = event_mod.Event;
const Tokens = event_mod.Tokens;
const Session = session_mod.Session;
pub const Status = session_mod.Status;

/// Live process state for one session, produced by the liveness scanner.
pub const LiveState = struct {
    session_id: []const u8,
    status: Status,
    waiting_for: []const u8 = "",
    pid: i64 = 0,
    updated_at_ms: i64 = 0,
};

/// A session whose status changed after a liveness pass; broadcast over SSE.
pub const StatusChange = struct {
    session_id: []const u8,
    project: []const u8,
    status: []const u8,
    waiting_for: []const u8,
};

/// Read model of a session for lists. `status` serializes as its tag name.
pub const SessionSummary = struct {
    id: []const u8,
    project: []const u8,
    cwd: []const u8,
    title: []const u8,
    agent_name: []const u8,
    status: Status,
    waiting_for: []const u8,
    model: []const u8,
    tokens: Tokens,
    prompt_count: u32,
    tool_call_count: u32,
    tool_failure_count: u32,
    long_prompt_count: u32 = 0,
    hook_error_count: u32 = 0,
    unknown_record_count: u32 = 0,
    last_activity: []const u8,
    last_prompt: []const u8,
    first_ts_ms: i64,
    last_ts_ms: i64,
};

pub const ToolCount = struct { name: []const u8, count: u32 };

/// One step of a session's recent activity, arena-copied for readers.
pub const ActivityView = struct {
    ts_ms: i64,
    kind: session_mod.ActivityKind,
    count: u16,
    tool: []const u8,
    text: []const u8,
    failed: u16,
};

/// Read model of a session for the detail view: everything we know.
pub const SessionDetail = struct {
    summary: SessionSummary,
    permission_mode: []const u8,
    git_branch: []const u8,
    app_version: []const u8,
    pid: i64,
    live_updated_at_ms: i64,
    subagent_event_count: u32,
    unknown_record_count: u32,
    hook_error_count: u32,
    tool_counts: []ToolCount,
};

/// Read model of one event, also the SSE wire shape.
pub const EventView = struct {
    ts_ms: i64,
    session_id: []const u8,
    project: []const u8,
    kind: []const u8,
    is_sidechain: bool,
    text: []const u8 = "",
    truncated: bool = false,
    tool: []const u8 = "",
    detail: []const u8 = "",
    ok: ?bool = null,
    model: []const u8 = "",
    tokens: ?Tokens = null,
};

/// Persistable aggregate of one session; the snapshot wire shape.
pub const SessionExport = struct {
    id: []const u8,
    cwd: []const u8 = "",
    title: []const u8 = "",
    agent_name: []const u8 = "",
    model: []const u8 = "",
    permission_mode: []const u8 = "",
    git_branch: []const u8 = "",
    app_version: []const u8 = "",
    last_prompt: []const u8 = "",
    last_activity: []const u8 = "",
    tokens: Tokens = .{},
    prompt_count: u32 = 0,
    tool_call_count: u32 = 0,
    tool_failure_count: u32 = 0,
    subagent_event_count: u32 = 0,
    unknown_record_count: u32 = 0,
    hook_error_count: u32 = 0,
    long_prompt_count: u32 = 0,
    first_ts_ms: i64 = 0,
    last_ts_ms: i64 = 0,
    tool_counts: []ToolCount = &.{},
    recent_usage_ids: []const []const u8 = &.{},
};

pub const DailyExport = struct {
    day_key: i32,
    prompts: u32 = 0,
    tool_calls: u32 = 0,
    failures: u32 = 0,
    tokens: Tokens = .{},
};

/// Everything the index knows, in snapshot-serializable form.
pub const State = struct {
    sessions: []SessionExport = &.{},
    daily: []DailyExport = &.{},
    hour_prompts: [24]u32 = @splat(0),
};

pub const Index = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,
    ring: []?Event,
    ring_next: usize = 0,
    ring_len: usize = 0,
    daily: std.AutoHashMapUnmanaged(i32, stats.DayAgg) = .empty,
    hour_prompts: [24]u32 = @splat(0),

    pub fn init(gpa: Allocator, ring_capacity: usize) Allocator.Error!Index {
        const ring = try gpa.alloc(?Event, ring_capacity);
        @memset(ring, null);
        return .{ .gpa = gpa, .ring = ring };
    }

    pub fn deinit(ix: *Index) void {
        var it = ix.sessions.valueIterator();
        while (it.next()) |session_ptr| {
            session_ptr.*.deinit(ix.gpa);
            ix.gpa.destroy(session_ptr.*);
        }
        ix.sessions.deinit(ix.gpa);
        for (ix.ring) |*slot| {
            if (slot.*) |*e| e.deinit(ix.gpa);
        }
        ix.gpa.free(ix.ring);
        ix.daily.deinit(ix.gpa);
        ix.* = undefined;
    }

    /// Arena-copied snapshot of all aggregates, for persistence.
    pub fn exportState(ix: *Index, io: Io, arena: Allocator) Allocator.Error!State {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        var sessions = try arena.alloc(SessionExport, ix.sessions.count());
        var it = ix.sessions.valueIterator();
        var i: usize = 0;
        while (it.next()) |session_ptr| : (i += 1) {
            const s = session_ptr.*;
            var tool_counts = try arena.alloc(ToolCount, s.tool_counts.count());
            var tool_it = s.tool_counts.iterator();
            var t: usize = 0;
            while (tool_it.next()) |entry| : (t += 1) {
                tool_counts[t] = .{ .name = try arena.dupe(u8, entry.key_ptr.*), .count = entry.value_ptr.* };
            }
            var id_buf: [session_mod.recent_usage_capacity][]const u8 = undefined;
            const recent = s.copyRecentUsageIds(&id_buf);
            const ids = try arena.alloc([]const u8, recent.len);
            for (recent, 0..) |id, n| ids[n] = try arena.dupe(u8, id);
            sessions[i] = .{
                .id = try arena.dupe(u8, s.id),
                .cwd = try arena.dupe(u8, s.cwd),
                .title = try arena.dupe(u8, s.title),
                .agent_name = try arena.dupe(u8, s.agent_name),
                .model = try arena.dupe(u8, s.model),
                .permission_mode = try arena.dupe(u8, s.permission_mode),
                .git_branch = try arena.dupe(u8, s.git_branch),
                .app_version = try arena.dupe(u8, s.app_version),
                .last_prompt = try arena.dupe(u8, s.last_prompt),
                .last_activity = try arena.dupe(u8, s.last_activity),
                .tokens = s.tokens,
                .prompt_count = s.prompt_count,
                .tool_call_count = s.tool_call_count,
                .tool_failure_count = s.tool_failure_count,
                .subagent_event_count = s.subagent_event_count,
                .unknown_record_count = s.unknown_record_count,
                .hook_error_count = s.hook_error_count,
                .long_prompt_count = s.long_prompt_count,
                .first_ts_ms = s.first_ts_ms,
                .last_ts_ms = s.last_ts_ms,
                .tool_counts = tool_counts,
                .recent_usage_ids = ids,
            };
        }

        var daily = try arena.alloc(DailyExport, ix.daily.count());
        var day_it = ix.daily.iterator();
        i = 0;
        while (day_it.next()) |entry| : (i += 1) {
            daily[i] = .{
                .day_key = entry.key_ptr.*,
                .prompts = entry.value_ptr.prompts,
                .tool_calls = entry.value_ptr.tool_calls,
                .failures = entry.value_ptr.failures,
                .tokens = entry.value_ptr.tokens,
            };
        }
        return .{ .sessions = sessions, .daily = daily, .hour_prompts = ix.hour_prompts };
    }

    /// Rebuilds aggregates from a snapshot. Intended for a fresh index before
    /// any transcript replay; sessions already present are left untouched.
    pub fn importState(ix: *Index, io: Io, state: State) Allocator.Error!void {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        for (state.sessions) |snap| {
            if (snap.id.len == 0 or ix.sessions.contains(snap.id)) continue;
            const created = try ix.gpa.create(Session);
            errdefer ix.gpa.destroy(created);
            created.* = try Session.init(ix.gpa, snap.id);
            errdefer created.deinit(ix.gpa);
            try fillSession(ix.gpa, created, snap);
            try ix.sessions.put(ix.gpa, created.id, created);
        }
        for (state.daily) |day| {
            const gop = try ix.daily.getOrPut(ix.gpa, day.day_key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.add(.{
                .prompts = day.prompts,
                .tool_calls = day.tool_calls,
                .failures = day.failures,
                .tokens = day.tokens,
            });
        }
        for (&ix.hour_prompts, state.hour_prompts) |*slot, restored| slot.* += restored;
    }

    fn fillSession(gpa: Allocator, s: *Session, snap: SessionExport) Allocator.Error!void {
        s.cwd = try gpa.dupe(u8, snap.cwd);
        s.title = try gpa.dupe(u8, snap.title);
        s.agent_name = try gpa.dupe(u8, snap.agent_name);
        s.model = try gpa.dupe(u8, snap.model);
        s.permission_mode = try gpa.dupe(u8, snap.permission_mode);
        s.git_branch = try gpa.dupe(u8, snap.git_branch);
        s.app_version = try gpa.dupe(u8, snap.app_version);
        s.last_prompt = try gpa.dupe(u8, snap.last_prompt);
        s.last_activity = try gpa.dupe(u8, snap.last_activity);
        s.tokens = snap.tokens;
        s.prompt_count = snap.prompt_count;
        s.tool_call_count = snap.tool_call_count;
        s.tool_failure_count = snap.tool_failure_count;
        s.subagent_event_count = snap.subagent_event_count;
        s.unknown_record_count = snap.unknown_record_count;
        s.hook_error_count = snap.hook_error_count;
        s.long_prompt_count = snap.long_prompt_count;
        s.first_ts_ms = snap.first_ts_ms;
        s.last_ts_ms = snap.last_ts_ms;
        for (snap.tool_counts) |tc| {
            const key = try gpa.dupe(u8, tc.name);
            errdefer gpa.free(key);
            try s.tool_counts.put(gpa, key, tc.count);
        }
        for (snap.recent_usage_ids) |id| try s.seedUsageId(gpa, id);
    }

    /// Drops every aggregate and ring entry, returning the index to its
    /// just-initialized state. Used when a snapshot import must be undone.
    pub fn reset(ix: *Index, io: Io) void {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        var it = ix.sessions.valueIterator();
        while (it.next()) |session_ptr| {
            session_ptr.*.deinit(ix.gpa);
            ix.gpa.destroy(session_ptr.*);
        }
        ix.sessions.clearRetainingCapacity();
        for (ix.ring) |*slot| {
            if (slot.*) |*e| e.deinit(ix.gpa);
            slot.* = null;
        }
        ix.ring_next = 0;
        ix.ring_len = 0;
        ix.daily.clearRetainingCapacity();
        ix.hour_prompts = @splat(0);
    }

    /// Folds the event into its session aggregate and stores it in the ring.
    /// Takes ownership of `e` in every case.
    pub fn applyEvent(ix: *Index, io: Io, e: Event) Allocator.Error!void {
        var owned = e;
        errdefer owned.deinit(ix.gpa);

        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        if (owned.session_id.len > 0) {
            // Build the Session fully before touching the map: a half-inserted
            // entry with a borrowed key would outlive this event on error.
            const session = ix.sessions.get(owned.session_id) orelse blk: {
                const created = try ix.gpa.create(Session);
                errdefer ix.gpa.destroy(created);
                created.* = try Session.init(ix.gpa, owned.session_id);
                errdefer created.deinit(ix.gpa);
                try ix.sessions.put(ix.gpa, created.id, created);
                break :blk created;
            };
            const result = try session.applyEvent(ix.gpa, &owned);
            try ix.applyToDaily(&owned, result);
        }
        ix.pushRing(owned);
    }

    fn applyToDaily(ix: *Index, e: *const Event, result: Session.ApplyResult) Allocator.Error!void {
        const day = stats.dayKeyFromMs(e.timestamp_ms) orelse return;
        const gop = try ix.daily.getOrPut(ix.gpa, day);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const agg = gop.value_ptr;
        if (result.fresh_usage) |tokens| {
            agg.tokens.input += tokens.input;
            agg.tokens.output += tokens.output;
            agg.tokens.cache_read += tokens.cache_read;
            agg.tokens.cache_creation += tokens.cache_creation;
        }
        if (e.is_sidechain) return;
        switch (e.payload) {
            .prompt => {
                agg.prompts += 1;
                ix.hour_prompts[stats.hourFromMs(e.timestamp_ms)] += 1;
            },
            .tool_call => agg.tool_calls += 1,
            .tool_result => |p| {
                if (p.ok == false) agg.failures += 1;
            },
            else => {},
        }
    }

    /// Arena-copied statistics report for the trailing `range_days` window.
    pub fn statsReport(
        ix: *Index,
        io: Io,
        arena: Allocator,
        range_days: u32,
        now_ms: i64,
    ) Allocator.Error!stats.Report {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        const today = stats.dayKeyFromMs(now_ms) orelse 0;
        const first_day = today - @as(i32, @intCast(range_days)) + 1;
        const range_start_ms = @as(i64, first_day) * 86_400_000;

        var totals = stats.DayAgg{};
        var days: std.ArrayList(stats.DayRow) = .empty;
        var day_it = ix.daily.iterator();
        while (day_it.next()) |entry| {
            if (entry.key_ptr.* < first_day) continue;
            totals.add(entry.value_ptr.*);
            var date_buf: [10]u8 = undefined;
            try days.append(arena, .{
                .date = try arena.dupe(u8, stats.formatDayKey(&date_buf, entry.key_ptr.*)),
                .day_key = entry.key_ptr.*,
                .prompts = entry.value_ptr.prompts,
                .tool_calls = entry.value_ptr.tool_calls,
                .failures = entry.value_ptr.failures,
                .tokens = entry.value_ptr.tokens,
            });
        }
        const day_rows = try days.toOwnedSlice(arena);
        std.sort.pdq(stats.DayRow, day_rows, {}, dayRowLessThan);

        var tools: std.StringHashMapUnmanaged(u32) = .empty;
        defer tools.deinit(arena);
        var projects: std.StringHashMapUnmanaged(stats.ProjectRow) = .empty;
        defer projects.deinit(arena);
        var session_it = ix.sessions.valueIterator();
        while (session_it.next()) |session_ptr| {
            const session = session_ptr.*;
            if (session.last_ts_ms < range_start_ms) continue;
            var tool_it = session.tool_counts.iterator();
            while (tool_it.next()) |entry| {
                const gop = try tools.getOrPut(arena, entry.key_ptr.*);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try arena.dupe(u8, entry.key_ptr.*);
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += entry.value_ptr.*;
            }
            const project = projectName(session.cwd);
            const gop = try projects.getOrPut(arena, project);
            if (!gop.found_existing) {
                gop.key_ptr.* = try arena.dupe(u8, project);
                gop.value_ptr.* = .{ .project = gop.key_ptr.* };
            }
            const row = gop.value_ptr;
            row.sessions += 1;
            row.prompts += session.prompt_count;
            row.tool_calls += session.tool_call_count;
            row.failures += session.tool_failure_count;
            row.hook_errors += session.hook_error_count;
            row.tokens.input += session.tokens.input;
            row.tokens.output += session.tokens.output;
            row.tokens.cache_read += session.tokens.cache_read;
            row.tokens.cache_creation += session.tokens.cache_creation;
        }

        var tool_rows = try arena.alloc(ToolCount, tools.count());
        var tool_it = tools.iterator();
        var i: usize = 0;
        while (tool_it.next()) |entry| : (i += 1) {
            tool_rows[i] = .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* };
        }
        std.sort.pdq(ToolCount, tool_rows, {}, toolCountGreaterThan);

        var project_rows = try arena.alloc(stats.ProjectRow, projects.count());
        var project_it = projects.valueIterator();
        i = 0;
        while (project_it.next()) |row| : (i += 1) project_rows[i] = row.*;
        std.sort.pdq(stats.ProjectRow, project_rows, {}, projectMoreActive);

        return .{
            .range_days = range_days,
            .generated_at_ms = now_ms,
            .totals = totals,
            .days = day_rows,
            .top_tools = tool_rows,
            .top_projects = project_rows,
            .hour_prompts = ix.hour_prompts,
        };
    }

    fn dayRowLessThan(_: void, a: stats.DayRow, b: stats.DayRow) bool {
        return a.day_key < b.day_key;
    }

    fn projectMoreActive(_: void, a: stats.ProjectRow, b: stats.ProjectRow) bool {
        if (a.prompts != b.prompts) return a.prompts > b.prompts;
        return a.tokens.output > b.tokens.output;
    }

    /// Overlays live process state onto sessions. Sessions absent from
    /// `states` fall back to `.done`. Returns the sessions whose status
    /// changed, arena-copied for broadcasting.
    pub fn applyLiveness(
        ix: *Index,
        io: Io,
        arena: Allocator,
        states: []const LiveState,
    ) Allocator.Error![]StatusChange {
        var changes: std.ArrayList(StatusChange) = .empty;

        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        var it = ix.sessions.valueIterator();
        while (it.next()) |session_ptr| {
            const session = session_ptr.*;
            const live: ?LiveState = for (states) |state| {
                if (std.mem.eql(u8, state.session_id, session.id)) break state;
            } else null;

            const new_status: Status = if (live) |l| l.status else .done;
            const new_waiting = if (live) |l| l.waiting_for else "";
            const status_changed = session.status != new_status or
                !std.mem.eql(u8, session.waiting_for, new_waiting);

            if (live) |l| {
                session.pid = l.pid;
                session.live_updated_at_ms = l.updated_at_ms;
            } else {
                session.pid = 0;
            }
            if (status_changed) {
                session.status = new_status;
                const waiting_copy = try ix.gpa.dupe(u8, new_waiting);
                ix.gpa.free(session.waiting_for);
                session.waiting_for = waiting_copy;
                try changes.append(arena, .{
                    .session_id = try arena.dupe(u8, session.id),
                    .project = try arena.dupe(u8, projectName(session.cwd)),
                    .status = @tagName(new_status),
                    .waiting_for = try arena.dupe(u8, new_waiting),
                });
            }
        }
        return changes.toOwnedSlice(arena);
    }

    /// Arena-copied list of all sessions, live ones first, then most recent.
    pub fn listSessions(ix: *Index, io: Io, arena: Allocator) Allocator.Error![]SessionSummary {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        var summaries = try arena.alloc(SessionSummary, ix.sessions.count());
        var it = ix.sessions.valueIterator();
        var i: usize = 0;
        while (it.next()) |session_ptr| : (i += 1) {
            summaries[i] = try summarize(arena, session_ptr.*);
        }
        std.sort.pdq(SessionSummary, summaries, {}, summaryLessThan);
        return summaries;
    }

    /// Arena-copied full detail for one session, or null if unknown.
    pub fn sessionDetail(ix: *Index, io: Io, arena: Allocator, id: []const u8) Allocator.Error!?SessionDetail {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        const session = (ix.sessions.get(id) orelse return null);
        var tool_counts = try arena.alloc(ToolCount, session.tool_counts.count());
        var it = session.tool_counts.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            tool_counts[i] = .{ .name = try arena.dupe(u8, entry.key_ptr.*), .count = entry.value_ptr.* };
        }
        std.sort.pdq(ToolCount, tool_counts, {}, toolCountGreaterThan);
        return .{
            .summary = try summarize(arena, session),
            .permission_mode = try arena.dupe(u8, session.permission_mode),
            .git_branch = try arena.dupe(u8, session.git_branch),
            .app_version = try arena.dupe(u8, session.app_version),
            .pid = session.pid,
            .live_updated_at_ms = session.live_updated_at_ms,
            .subagent_event_count = session.subagent_event_count,
            .unknown_record_count = session.unknown_record_count,
            .hook_error_count = session.hook_error_count,
            .tool_counts = tool_counts,
        };
    }

    /// Arena-copied recent activity steps of one session, oldest first.
    /// Backed by the per-session ring, so history survives regardless of
    /// global event volume.
    pub fn sessionActivity(
        ix: *Index,
        io: Io,
        arena: Allocator,
        id: []const u8,
    ) Allocator.Error![]ActivityView {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        const session = ix.sessions.get(id) orelse return arena.alloc(ActivityView, 0);
        var entries: [session_mod.activity_capacity]session_mod.ActivityEntry = undefined;
        const used = session.copyActivity(&entries);
        var views = try arena.alloc(ActivityView, used.len);
        for (used, 0..) |*entry, i| {
            views[i] = .{
                .ts_ms = entry.ts_ms,
                .kind = entry.kind,
                .count = entry.count,
                .tool = try arena.dupe(u8, entry.tool()),
                .text = try arena.dupe(u8, entry.text()),
                .failed = entry.failed,
            };
        }
        return views;
    }

    /// Arena-copied views of the most recent ring events (oldest first),
    /// optionally filtered to one session.
    pub fn tailEvents(
        ix: *Index,
        io: Io,
        arena: Allocator,
        session_filter: ?[]const u8,
        limit: usize,
    ) Allocator.Error![]EventView {
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);

        var views: std.ArrayList(EventView) = .empty;
        var taken: usize = 0;
        var i: usize = 0;
        // Newest-first walk so `limit` keeps the most recent events; reversed below.
        while (i < ix.ring_len and taken < limit) : (i += 1) {
            const slot = (ix.ring_next + ix.ring.len - 1 - i) % ix.ring.len;
            const e = &(ix.ring[slot] orelse continue);
            if (session_filter) |wanted| {
                if (!std.mem.eql(u8, e.session_id, wanted)) continue;
            }
            try views.append(arena, try viewOfEvent(arena, e));
            taken += 1;
        }
        const out = try views.toOwnedSlice(arena);
        std.mem.reverse(EventView, out);
        return out;
    }

    fn pushRing(ix: *Index, e: Event) void {
        if (ix.ring.len == 0) {
            var dropped = e;
            dropped.deinit(ix.gpa);
            return;
        }
        if (ix.ring[ix.ring_next]) |*old| old.deinit(ix.gpa);
        ix.ring[ix.ring_next] = e;
        ix.ring_next = (ix.ring_next + 1) % ix.ring.len;
        if (ix.ring_len < ix.ring.len) ix.ring_len += 1;
    }

    fn summarize(arena: Allocator, s: *const Session) Allocator.Error!SessionSummary {
        return .{
            .id = try arena.dupe(u8, s.id),
            .project = try arena.dupe(u8, projectName(s.cwd)),
            .cwd = try arena.dupe(u8, s.cwd),
            .title = try arena.dupe(u8, s.title),
            .agent_name = try arena.dupe(u8, s.agent_name),
            .status = s.status,
            .waiting_for = try arena.dupe(u8, s.waiting_for),
            .model = try arena.dupe(u8, s.model),
            .tokens = s.tokens,
            .prompt_count = s.prompt_count,
            .tool_call_count = s.tool_call_count,
            .tool_failure_count = s.tool_failure_count,
            .long_prompt_count = s.long_prompt_count,
            .hook_error_count = s.hook_error_count,
            .unknown_record_count = s.unknown_record_count,
            .last_activity = try arena.dupe(u8, s.last_activity),
            .last_prompt = try arena.dupe(u8, s.last_prompt),
            .first_ts_ms = s.first_ts_ms,
            .last_ts_ms = s.last_ts_ms,
        };
    }

    fn summaryLessThan(_: void, a: SessionSummary, b: SessionSummary) bool {
        const rank_a = statusRank(a.status);
        const rank_b = statusRank(b.status);
        if (rank_a != rank_b) return rank_a < rank_b;
        return a.last_ts_ms > b.last_ts_ms;
    }

    fn statusRank(status: Status) u8 {
        return switch (status) {
            .working => 0,
            .waiting_for_user => 1,
            .idle => 2,
            .done => 3,
        };
    }

    fn toolCountGreaterThan(_: void, a: ToolCount, b: ToolCount) bool {
        if (a.count != b.count) return a.count > b.count;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// Last path component of a cwd, used as the human project label.
pub fn projectName(cwd: []const u8) []const u8 {
    if (cwd.len == 0) return "-";
    return std.fs.path.basename(cwd);
}

/// Builds the read/wire view of one event.
pub fn viewOfEvent(arena: Allocator, e: *const Event) Allocator.Error!EventView {
    var view = EventView{
        .ts_ms = e.timestamp_ms,
        .session_id = try arena.dupe(u8, e.session_id),
        .project = try arena.dupe(u8, projectName(e.cwd)),
        .kind = e.kindName(),
        .is_sidechain = e.is_sidechain,
    };
    switch (e.payload) {
        .prompt => |p| {
            view.text = try arena.dupe(u8, p.text);
            view.truncated = p.truncated;
        },
        .assistant_text => |p| {
            view.text = try arena.dupe(u8, p.text);
            view.truncated = p.truncated;
        },
        .tool_call => |p| {
            view.tool = try arena.dupe(u8, p.name);
            view.detail = try arena.dupe(u8, p.detail);
        },
        .tool_result => |p| {
            view.ok = p.ok;
            view.text = try arena.dupe(u8, p.summary);
        },
        .usage => |p| {
            view.model = try arena.dupe(u8, p.model);
            view.tokens = p.tokens;
        },
        .meta => |p| {
            view.tool = @tagName(p.kind);
            view.text = try arena.dupe(u8, p.value);
        },
        .system => |p| view.text = try arena.dupe(u8, p.subtype),
        .unknown => |p| view.text = try arena.dupe(u8, p.record_type),
    }
    return view;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

fn applyLines(ix: *Index, io: Io, lines: []const []const u8) !void {
    for (lines) |line| {
        const events = try parser.parseLine(testing.allocator, line);
        defer testing.allocator.free(events);
        for (events) |e| try ix.applyEvent(io, e);
    }
}

test "index aggregates sessions and serves snapshots" {
    const io = testing.io;
    var ix = try Index.init(testing.allocator, 16);
    defer ix.deinit();

    try applyLines(&ix, io, &.{
        \\{"type":"user","message":{"content":"task one"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/w/alpha","sessionId":"s1"}
        ,
        \\{"type":"assistant","message":{"model":"claude-opus-4-8","id":"m1","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"x"}}],"usage":{"input_tokens":5,"output_tokens":7}},"timestamp":"2026-07-07T10:00:02Z","cwd":"/w/alpha","sessionId":"s1"}
        ,
        \\{"type":"user","message":{"content":"task two"},"timestamp":"2026-07-07T11:00:00Z","cwd":"/w/beta","sessionId":"s2"}
        ,
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sessions = try ix.listSessions(io, arena);
    try testing.expectEqual(@as(usize, 2), sessions.len);
    // Both done → newest last_ts first.
    try testing.expectEqualStrings("s2", sessions[0].id);
    try testing.expectEqualStrings("beta", sessions[0].project);

    const detail = (try ix.sessionDetail(io, arena, "s1")).?;
    try testing.expectEqualStrings("claude-opus-4-8", detail.summary.model);
    try testing.expectEqual(@as(usize, 1), detail.tool_counts.len);
    try testing.expectEqualStrings("Read", detail.tool_counts[0].name);

    const all_events = try ix.tailEvents(io, arena, null, 100);
    try testing.expectEqual(@as(usize, 4), all_events.len);
    const s1_events = try ix.tailEvents(io, arena, "s1", 100);
    try testing.expectEqual(@as(usize, 3), s1_events.len);
    try testing.expectEqualStrings("prompt", s1_events[0].kind);
    try testing.expectEqualStrings("task one", s1_events[0].text);
}

test "liveness overlay updates status and reports changes" {
    const io = testing.io;
    var ix = try Index.init(testing.allocator, 8);
    defer ix.deinit();

    try applyLines(&ix, io, &.{
        \\{"type":"user","message":{"content":"hello"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/w/alpha","sessionId":"s1"}
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const changes = try ix.applyLiveness(io, arena, &.{
        .{ .session_id = "s1", .status = .waiting_for_user, .waiting_for = "permission prompt", .pid = 123, .updated_at_ms = 5 },
    });
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("waiting_for_user", changes[0].status);
    try testing.expectEqualStrings("permission prompt", changes[0].waiting_for);

    const changes_again = try ix.applyLiveness(io, arena, &.{
        .{ .session_id = "s1", .status = .waiting_for_user, .waiting_for = "permission prompt", .pid = 123, .updated_at_ms = 9 },
    });
    try testing.expectEqual(@as(usize, 0), changes_again.len);

    const changes_after_process_exit = try ix.applyLiveness(io, arena, &.{});
    try testing.expectEqual(@as(usize, 1), changes_after_process_exit.len);
    try testing.expectEqualStrings("done", changes_after_process_exit[0].status);

    const sessions = try ix.listSessions(io, arena);
    try testing.expectEqual(session_mod.Status.done, sessions[0].status);
}

test "ring buffer evicts oldest events without leaking" {
    const io = testing.io;
    var ix = try Index.init(testing.allocator, 2);
    defer ix.deinit();

    try applyLines(&ix, io, &.{
        \\{"type":"user","message":{"content":"one"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/w","sessionId":"s1"}
        ,
        \\{"type":"user","message":{"content":"two"},"timestamp":"2026-07-07T10:00:01Z","cwd":"/w","sessionId":"s1"}
        ,
        \\{"type":"user","message":{"content":"three"},"timestamp":"2026-07-07T10:00:02Z","cwd":"/w","sessionId":"s1"}
        ,
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const events = try ix.tailEvents(testing.io, arena_state.allocator(), null, 10);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("two", events[0].text);
    try testing.expectEqualStrings("three", events[1].text);
}
