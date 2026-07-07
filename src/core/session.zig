//! Per-session aggregation of transcript events plus live process state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");

const Event = event_mod.Event;
const Tokens = event_mod.Tokens;

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

    first_ts_ms: i64 = 0,
    last_ts_ms: i64 = 0,

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
            // Subagent traffic must not overwrite the interactive session's
            // activity picture — but its token usage is real cost, so that
            // still flows through the deduped accounting below.
            s.subagent_event_count += 1;
            if (e.payload != .usage) return .{};
        }

        switch (e.payload) {
            .prompt => |p| {
                s.prompt_count += 1;
                if (p.truncated or p.text.len >= 1500) s.long_prompt_count += 1;
                try replace(gpa, &s.last_prompt, p.text);
                try replace(gpa, &s.last_activity, "reading your prompt");
            },
            .assistant_text => try replace(gpa, &s.last_activity, "responding"),
            .tool_call => |p| {
                s.tool_call_count += 1;
                try bumpToolCount(gpa, &s.tool_counts, p.name);
                const activity = try std.fmt.allocPrint(gpa, "{s} {s}", .{ p.name, p.detail });
                gpa.free(s.last_activity);
                s.last_activity = activity;
            },
            .tool_result => |p| {
                if (p.ok == false) s.tool_failure_count += 1;
            },
            .usage => |p| {
                if (p.model.len > 0) try replaceIfChanged(gpa, &s.model, p.model);
                if (p.message_id.len == 0) return .{};
                const gop = try s.seen_usage_ids.getOrPut(gpa, p.message_id);
                if (gop.found_existing) return .{};
                gop.key_ptr.* = try gpa.dupe(u8, p.message_id);
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
        const gop = try counts.getOrPut(gpa, name);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.key_ptr.* = try gpa.dupe(u8, name);
            gop.value_ptr.* = 1;
        }
    }
};

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
