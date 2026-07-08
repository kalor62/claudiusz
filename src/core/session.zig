//! Per-session aggregation of transcript events plus live process state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");

const Event = event_mod.Event;
const Tokens = event_mod.Tokens;

/// One step of recent session activity, kept in a fixed per-session ring so
/// every session can show "what has it been doing" regardless of how much
/// other traffic flowed through the global event ring.
pub const ActivityKind = enum(u8) { prompt, responded, tool, subagent };

pub const activity_capacity = 48;

/// How many recent usage message-ids survive a snapshot round trip. Streamed
/// duplicates of one message appear in adjacent transcript lines, so only ids
/// near the resume boundary need dedup protection after a restart.
pub const recent_usage_capacity = 128;

pub const ActivityEntry = struct {
    ts_ms: i64 = 0,
    kind: ActivityKind = .prompt,
    count: u16 = 1,
    failed: u16 = 0,
    tool_len: u8 = 0,
    text_len: u8 = 0,
    tool_buf: [24]u8 = undefined,
    text_buf: [96]u8 = undefined,

    pub fn tool(e: *const ActivityEntry) []const u8 {
        return e.tool_buf[0..e.tool_len];
    }

    pub fn text(e: *const ActivityEntry) []const u8 {
        return e.text_buf[0..e.text_len];
    }
};

/// Real-time state of a session's Claude Code process.
pub const Status = enum {
    /// The agent is actively working.
    working,
    /// The agent is blocked on the user (permission prompt, question, input).
    waiting_for_user,
    /// The process is alive but nothing is happening.
    idle,
    /// No live process backs this session.
    done,
};

/// Everything claudiusz knows about one session. All strings owned via `gpa`
/// passed to the mutating methods; free with `deinit`.
pub const Session = struct {
    id: []const u8,
    cwd: []const u8 = "",
    title: []const u8 = "",
    agent_name: []const u8 = "",
    model: []const u8 = "",
    permission_mode: []const u8 = "",
    git_branch: []const u8 = "",
    app_version: []const u8 = "",
    last_prompt: []const u8 = "",
    /// Human-oriented "what is happening right now", e.g. "Edit src/auth.ts".
    last_activity: []const u8 = "",

    tokens: Tokens = .{},
    prompt_count: u32 = 0,
    tool_call_count: u32 = 0,
    tool_failure_count: u32 = 0,
    subagent_event_count: u32 = 0,
    unknown_record_count: u32 = 0,
    hook_error_count: u32 = 0,
    /// Prompts that look like large pastes (code/log dumps) instead of `@file` references.
    long_prompt_count: u32 = 0,
    tool_counts: std.StringHashMapUnmanaged(u32) = .empty,
    seen_usage_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// Insertion-ordered ring over `seen_usage_ids` keys (borrowed slices).
    recent_usage: [recent_usage_capacity][]const u8 = undefined,
    recent_usage_next: usize = 0,
    recent_usage_len: usize = 0,

    first_ts_ms: i64 = 0,
    last_ts_ms: i64 = 0,

    activity: [activity_capacity]ActivityEntry = undefined,
    activity_next: usize = 0,
    activity_len: usize = 0,

    status: Status = .done,
    waiting_for: []const u8 = "",
    pid: i64 = 0,
    /// Heartbeat of the live process (sessions/<pid>.json updatedAt).
    live_updated_at_ms: i64 = 0,

    pub fn init(gpa: Allocator, id: []const u8) Allocator.Error!Session {
        return .{ .id = try gpa.dupe(u8, id) };
    }

    pub fn deinit(s: *Session, gpa: Allocator) void {
        gpa.free(s.id);
        gpa.free(s.cwd);
        gpa.free(s.title);
        gpa.free(s.agent_name);
        gpa.free(s.model);
        gpa.free(s.permission_mode);
        gpa.free(s.git_branch);
        gpa.free(s.app_version);
        gpa.free(s.last_prompt);
        gpa.free(s.last_activity);
        gpa.free(s.waiting_for);
        var tool_keys = s.tool_counts.keyIterator();
        while (tool_keys.next()) |key| gpa.free(key.*);
        s.tool_counts.deinit(gpa);
        var usage_keys = s.seen_usage_ids.keyIterator();
        while (usage_keys.next()) |key| gpa.free(key.*);
        s.seen_usage_ids.deinit(gpa);
        s.* = undefined;
    }

    /// What one event contributed, for index-level (daily) aggregation.
    pub const ApplyResult = struct {
        /// Set when this event added not-yet-counted token usage.
        fresh_usage: ?Tokens = null,
    };

    /// Folds one event into the aggregate. The event is only read.
    pub fn applyEvent(s: *Session, gpa: Allocator, e: *const Event) Allocator.Error!ApplyResult {
        if (e.timestamp_ms > 0) {
            if (s.first_ts_ms == 0 or e.timestamp_ms < s.first_ts_ms) s.first_ts_ms = e.timestamp_ms;
            if (e.timestamp_ms > s.last_ts_ms) s.last_ts_ms = e.timestamp_ms;
        }
        if (e.cwd.len > 0 and s.cwd.len == 0) try replace(gpa, &s.cwd, e.cwd);
        if (e.git_branch.len > 0) try replaceIfChanged(gpa, &s.git_branch, e.git_branch);
        if (e.app_version.len > 0 and s.app_version.len == 0) try replace(gpa, &s.app_version, e.app_version);
        if (e.is_sidechain) {
            s.subagent_event_count += 1;
            switch (e.payload) {
                .tool_call, .assistant_text => s.pushActivity(.{ .kind = .subagent, .ts_ms = e.timestamp_ms }),
                else => {},
            }
            // Subagent tokens are real cost; everything else would overwrite the session's activity picture.
            if (e.payload != .usage) return .{};
        }

        switch (e.payload) {
            .prompt => |p| {
                s.prompt_count += 1;
                if (p.truncated or p.text.len >= 1500) s.long_prompt_count += 1;
                try replace(gpa, &s.last_prompt, p.text);
                try replace(gpa, &s.last_activity, "reading your prompt");
                s.pushActivity(activityEntry(.prompt, e.timestamp_ms, "", p.text));
            },
            .assistant_text => {
                try replace(gpa, &s.last_activity, "responding");
                s.pushActivity(.{ .kind = .responded, .ts_ms = e.timestamp_ms });
            },
            .tool_call => |p| {
                s.tool_call_count += 1;
                try bumpToolCount(gpa, &s.tool_counts, p.name);
                const activity = try std.fmt.allocPrint(gpa, "{s} {s}", .{ p.name, p.detail });
                gpa.free(s.last_activity);
                s.last_activity = activity;
                s.pushActivity(activityEntry(.tool, e.timestamp_ms, p.name, p.detail));
            },
            .tool_result => |p| {
                if (p.ok == false) {
                    s.tool_failure_count += 1;
                    s.markLastToolFailed();
                }
            },
            .usage => |p| {
                // Subagents may run a different model; the session label must stay the main loop's.
                if (p.model.len > 0 and !e.is_sidechain) try replaceIfChanged(gpa, &s.model, p.model);
                if (p.message_id.len == 0) return .{};
                if (s.seen_usage_ids.contains(p.message_id)) return .{};
                const key = try gpa.dupe(u8, p.message_id);
                errdefer gpa.free(key);
                try s.seen_usage_ids.put(gpa, key, {});
                s.rememberUsageId(key);
                s.tokens.input += p.tokens.input;
                s.tokens.output += p.tokens.output;
                s.tokens.cache_read += p.tokens.cache_read;
                s.tokens.cache_creation += p.tokens.cache_creation;
                return .{ .fresh_usage = p.tokens };
            },
            .meta => |p| switch (p.kind) {
                .title => try replace(gpa, &s.title, p.value),
                .permission_mode => try replace(gpa, &s.permission_mode, p.value),
                .agent_name => try replace(gpa, &s.agent_name, p.value),
                .attachment => {
                    if (std.mem.startsWith(u8, p.value, "hook_non_blocking_error")) s.hook_error_count += 1;
                },
                .mode => {},
            },
            .system => {},
            .unknown => s.unknown_record_count += 1,
        }
        return .{};
    }

    fn rememberUsageId(s: *Session, key: []const u8) void {
        s.recent_usage[s.recent_usage_next] = key;
        s.recent_usage_next = (s.recent_usage_next + 1) % recent_usage_capacity;
        if (s.recent_usage_len < recent_usage_capacity) s.recent_usage_len += 1;
    }

    /// Registers an already-counted usage id without touching token totals
    /// (snapshot restore path).
    pub fn seedUsageId(s: *Session, gpa: Allocator, id: []const u8) Allocator.Error!void {
        if (s.seen_usage_ids.contains(id)) return;
        const key = try gpa.dupe(u8, id);
        errdefer gpa.free(key);
        try s.seen_usage_ids.put(gpa, key, {});
        s.rememberUsageId(key);
    }

    /// Copies the recent usage ids oldest-first into `out`; returns the used slice.
    pub fn copyRecentUsageIds(s: *const Session, out: [][]const u8) [][]const u8 {
        const count = @min(s.recent_usage_len, out.len);
        const start = (s.recent_usage_next + recent_usage_capacity - s.recent_usage_len) % recent_usage_capacity;
        for (0..count) |i| {
            out[i] = s.recent_usage[(start + i) % recent_usage_capacity];
        }
        return out[0..count];
    }

    /// Consecutive repeats (same tool, streamed responses, subagent bursts)
    /// merge into the previous entry so the ring holds distinct steps, not
    /// one noisy burst.
    fn pushActivity(s: *Session, entry: ActivityEntry) void {
        if (s.lastActivityEntry()) |last| {
            const mergeable = last.kind == entry.kind and switch (entry.kind) {
                .responded, .subagent => true,
                .tool => std.mem.eql(u8, last.tool(), entry.tool()),
                .prompt => false,
            };
            if (mergeable) {
                last.count +|= 1;
                last.ts_ms = entry.ts_ms;
                if (entry.kind == .tool) {
                    last.text_len = entry.text_len;
                    last.text_buf = entry.text_buf;
                }
                return;
            }
        }
        s.activity[s.activity_next] = entry;
        s.activity_next = (s.activity_next + 1) % activity_capacity;
        if (s.activity_len < activity_capacity) s.activity_len += 1;
    }

    fn lastActivityEntry(s: *Session) ?*ActivityEntry {
        if (s.activity_len == 0) return null;
        return &s.activity[(s.activity_next + activity_capacity - 1) % activity_capacity];
    }

    fn markLastToolFailed(s: *Session) void {
        const last = s.lastActivityEntry() orelse return;
        if (last.kind == .tool) last.failed +|= 1;
    }

    /// Copies the activity ring oldest-first into `out`; returns the slice used.
    pub fn copyActivity(s: *const Session, out: []ActivityEntry) []ActivityEntry {
        const count = @min(s.activity_len, out.len);
        const start = (s.activity_next + activity_capacity - s.activity_len) % activity_capacity;
        for (0..count) |i| {
            out[i] = s.activity[(start + i) % activity_capacity];
        }
        return out[0..count];
    }

    fn replace(gpa: Allocator, slot: *[]const u8, value: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, value);
        gpa.free(slot.*);
        slot.* = copy;
    }

    fn replaceIfChanged(gpa: Allocator, slot: *[]const u8, value: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, slot.*, value)) return;
        try replace(gpa, slot, value);
    }

    fn bumpToolCount(
        gpa: Allocator,
        counts: *std.StringHashMapUnmanaged(u32),
        name: []const u8,
    ) Allocator.Error!void {
        if (counts.getPtr(name)) |count| {
            count.* += 1;
            return;
        }
        const key = try gpa.dupe(u8, name);
        errdefer gpa.free(key);
        try counts.put(gpa, key, 1);
    }
};

fn activityEntry(kind: ActivityKind, ts_ms: i64, tool_name: []const u8, text: []const u8) ActivityEntry {
    var entry = ActivityEntry{ .kind = kind, .ts_ms = ts_ms };
    entry.tool_len = @intCast(copyUtf8Prefix(&entry.tool_buf, tool_name));
    entry.text_len = @intCast(copyUtf8Prefix(&entry.text_buf, firstLine(text)));
    return entry;
}

fn copyUtf8Prefix(dest: []u8, src: []const u8) usize {
    var end = @min(src.len, dest.len);
    if (end < src.len) {
        while (end > 0 and src[end] & 0b1100_0000 == 0b1000_0000) end -= 1;
    }
    @memcpy(dest[0..end], src[0..end]);
    return end;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

test "session aggregates prompts, tools and deduped usage" {
    const gpa = testing.allocator;
    var session = try Session.init(gpa, "s1");
    defer session.deinit(gpa);

    const lines = [_][]const u8{
        \\{"type":"user","message":{"content":"do the thing"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/p","sessionId":"s1","gitBranch":"main","version":"2.1.202"}
        ,
        \\{"type":"assistant","message":{"model":"claude-opus-4-8","id":"m1","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"a.ts"}}],"usage":{"input_tokens":10,"output_tokens":20}},"timestamp":"2026-07-07T10:00:05Z","cwd":"/p","sessionId":"s1"}
        ,
        // Same message id streamed again: usage must not double-count.
        \\{"type":"assistant","message":{"model":"claude-opus-4-8","id":"m1","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":10,"output_tokens":20}},"timestamp":"2026-07-07T10:00:06Z","cwd":"/p","sessionId":"s1"}
        ,
        \\{"type":"ai-title","aiTitle":"Thing doing","sessionId":"s1"}
        ,
    };
    for (lines) |line| {
        const events = try parser.parseLine(gpa, line);
        defer event_mod.freeEvents(gpa, events);
        for (events) |*e| _ = try session.applyEvent(gpa, e);
    }

    try testing.expectEqual(@as(u32, 1), session.prompt_count);
    try testing.expectEqual(@as(u32, 1), session.tool_call_count);
    try testing.expectEqual(@as(u64, 10), session.tokens.input);
    try testing.expectEqual(@as(u64, 20), session.tokens.output);
    try testing.expectEqualStrings("claude-opus-4-8", session.model);
    try testing.expectEqualStrings("Thing doing", session.title);
    try testing.expectEqualStrings("main", session.git_branch);
    try testing.expectEqualStrings("2.1.202", session.app_version);
    try testing.expectEqualStrings("do the thing", session.last_prompt);
    try testing.expectEqual(@as(u32, 1), session.tool_counts.get("Edit").?);
    try testing.expectEqualStrings("responding", session.last_activity);
}

test "sidechain events count separately and keep main activity" {
    const gpa = testing.allocator;
    var session = try Session.init(gpa, "s1");
    defer session.deinit(gpa);

    const main_line =
        \\{"type":"user","message":{"content":"hi"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/p","sessionId":"s1"}
    ;
    const side_line =
        \\{"type":"assistant","message":{"model":"m","id":"m2","content":[{"type":"tool_use","id":"t","name":"Grep","input":{"pattern":"x"}}]},"timestamp":"2026-07-07T10:00:01Z","cwd":"/p","sessionId":"s1","isSidechain":true}
    ;
    for ([_][]const u8{ main_line, side_line }) |line| {
        const events = try parser.parseLine(gpa, line);
        defer event_mod.freeEvents(gpa, events);
        for (events) |*e| _ = try session.applyEvent(gpa, e);
    }

    try testing.expectEqual(@as(u32, 1), session.subagent_event_count);
    try testing.expectEqual(@as(u32, 0), session.tool_call_count);
    try testing.expectEqualStrings("reading your prompt", session.last_activity);
}
