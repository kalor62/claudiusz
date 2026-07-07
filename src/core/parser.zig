//! Turns one Claude Code transcript JSONL line into normalized events.
//!
//! The transcript format is not a stable public contract — it changes between
//! Claude Code versions. The parser therefore never fails on unexpected
//! input: malformed lines are dropped (logged at debug), unrecognized record
//! types become `Event.unknown`. Only allocation errors propagate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");
const time_mod = @import("time.zig");

const Event = event_mod.Event;
const Payload = event_mod.Payload;
const Tokens = event_mod.Tokens;

const log = std.log.scoped(.parser);

/// Longest prompt/assistant text kept per event, in bytes.
pub const max_text_len = 2000;
/// Longest tool detail / result summary kept per event, in bytes.
pub const max_detail_len = 400;

/// Record types that carry no information claudiusz cares about.
const ignored_types = [_][]const u8{
    "last-prompt",
    "queue-operation",
    "file-history-snapshot",
    "bridge-session",
    "summary",
};

/// Parses one JSONL line into zero or more events. Caller owns the returned
/// slice; free it with `event.freeEvents`.
pub fn parseLine(gpa: Allocator, line: []const u8) Allocator.Error![]Event {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return gpa.alloc(Event, 0);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.debug("dropping malformed transcript line ({s})", .{@errorName(err)});
            return gpa.alloc(Event, 0);
        },
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            log.debug("dropping non-object transcript line", .{});
            return gpa.alloc(Event, 0);
        },
    };
    const record_type = strField(root, "type") orelse {
        log.debug("dropping transcript line without a type field", .{});
        return gpa.alloc(Event, 0);
    };

    var builder = Builder{
        .gpa = gpa,
        .timestamp_ms = if (strField(root, "timestamp")) |t| (time_mod.parseIso8601Ms(t) orelse 0) else 0,
        .session_id = strField(root, "sessionId") orelse "",
        .cwd = strField(root, "cwd") orelse "",
        .git_branch = strField(root, "gitBranch") orelse "",
        .app_version = strField(root, "version") orelse "",
        .is_sidechain = boolField(root, "isSidechain") orelse false,
    };
    errdefer builder.deinit();

    try parseRecord(&builder, root, record_type);
    return builder.list.toOwnedSlice(gpa);
}

fn parseRecord(b: *Builder, root: std.json.ObjectMap, record_type: []const u8) Allocator.Error!void {
    if (std.mem.eql(u8, record_type, "user")) return parseUser(b, root);
    if (std.mem.eql(u8, record_type, "assistant")) return parseAssistant(b, root);
    if (std.mem.eql(u8, record_type, "system")) return parseSystem(b, root);
    if (std.mem.eql(u8, record_type, "attachment")) return parseAttachment(b, root);
    if (std.mem.eql(u8, record_type, "ai-title")) return addMetaFromField(b, root, "aiTitle", .title);
    if (std.mem.eql(u8, record_type, "custom-title")) return addMetaFromField(b, root, "customTitle", .title);
    if (std.mem.eql(u8, record_type, "permission-mode")) return addMetaFromField(b, root, "permissionMode", .permission_mode);
    if (std.mem.eql(u8, record_type, "agent-name")) return addMetaFromField(b, root, "agentName", .agent_name);
    if (std.mem.eql(u8, record_type, "mode")) return addMetaFromField(b, root, "mode", .mode);
    for (ignored_types) |ignored| {
        if (std.mem.eql(u8, record_type, ignored)) return;
    }
    try b.add(.{ .unknown = .{ .record_type = try b.gpa.dupe(u8, record_type) } });
}

fn parseUser(b: *Builder, root: std.json.ObjectMap) Allocator.Error!void {
    const message = objField(root, "message") orelse return;
    const content = message.get("content") orelse return;
    switch (content) {
        .string => |text| {
            const copy = try dupeTruncated(b.gpa, text, max_text_len);
            errdefer b.gpa.free(copy.text);
            try b.add(.{ .prompt = .{ .text = copy.text, .truncated = copy.truncated } });
        },
        .array => |blocks| for (blocks.items) |block_value| {
            const block = asObject(block_value) orelse continue;
            const block_type = strField(block, "type") orelse continue;
            if (!std.mem.eql(u8, block_type, "tool_result")) continue;
            const ok: ?bool = if (boolField(block, "is_error")) |is_error|
                !is_error
            else if (objField(root, "toolUseResult")) |result|
                boolField(result, "success")
            else
                null;
            const summary = try dupeTruncated(b.gpa, toolResultText(block), max_detail_len);
            errdefer b.gpa.free(summary.text);
            try b.add(.{ .tool_result = .{ .ok = ok, .summary = summary.text } });
        },
        else => {},
    }
}

fn parseAssistant(b: *Builder, root: std.json.ObjectMap) Allocator.Error!void {
    const message = objField(root, "message") orelse return;
    const model = strField(message, "model") orelse "";

    if (message.get("content")) |content| {
        if (content == .array) for (content.array.items) |block_value| {
            const block = asObject(block_value) orelse continue;
            const block_type = strField(block, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "text")) {
                const text = strField(block, "text") orelse continue;
                if (text.len == 0) continue;
                const copy = try dupeTruncated(b.gpa, text, max_text_len);
                errdefer b.gpa.free(copy.text);
                try b.add(.{ .assistant_text = .{ .text = copy.text, .truncated = copy.truncated } });
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                const name = try b.gpa.dupe(u8, strField(block, "name") orelse "?");
                errdefer b.gpa.free(name);
                const detail = try toolCallDetail(b.gpa, block.get("input"));
                errdefer b.gpa.free(detail);
                try b.add(.{ .tool_call = .{ .name = name, .detail = detail } });
            }
            // Thinking blocks stay private: content and signatures must never leave the machine.
        };
    }

    if (objField(message, "usage")) |usage| {
        const message_id = try b.gpa.dupe(u8, strField(message, "id") orelse "");
        errdefer b.gpa.free(message_id);
        const model_copy = try b.gpa.dupe(u8, model);
        errdefer b.gpa.free(model_copy);
        try b.add(.{ .usage = .{
            .message_id = message_id,
            .model = model_copy,
            .tokens = .{
                .input = uintField(usage, "input_tokens") orelse 0,
                .output = uintField(usage, "output_tokens") orelse 0,
                .cache_read = uintField(usage, "cache_read_input_tokens") orelse 0,
                .cache_creation = uintField(usage, "cache_creation_input_tokens") orelse 0,
            },
        } });
    }
}

fn parseSystem(b: *Builder, root: std.json.ObjectMap) Allocator.Error!void {
    const subtype = try b.gpa.dupe(u8, strField(root, "subtype") orelse "");
    errdefer b.gpa.free(subtype);
    const duration: ?u64 = uintField(root, "durationMs");
    try b.add(.{ .system = .{ .subtype = subtype, .duration_ms = duration } });
}

fn parseAttachment(b: *Builder, root: std.json.ObjectMap) Allocator.Error!void {
    const attachment = objField(root, "attachment") orelse return;
    const attachment_type = strField(attachment, "type") orelse return;
    const value = if (strField(attachment, "hookName")) |hook_name|
        try std.fmt.allocPrint(b.gpa, "{s}:{s}", .{ attachment_type, hook_name })
    else
        try b.gpa.dupe(u8, attachment_type);
    errdefer b.gpa.free(value);
    try b.add(.{ .meta = .{ .kind = .attachment, .value = value } });
}

fn addMetaFromField(
    b: *Builder,
    root: std.json.ObjectMap,
    field: []const u8,
    kind: event_mod.MetaKind,
) Allocator.Error!void {
    const raw = strField(root, field) orelse return;
    const value = try b.gpa.dupe(u8, raw);
    errdefer b.gpa.free(value);
    try b.add(.{ .meta = .{ .kind = kind, .value = value } });
}

/// Accumulates events for one line, sharing the line's envelope fields.
const Builder = struct {
    gpa: Allocator,
    list: std.ArrayList(Event) = .empty,
    timestamp_ms: i64,
    session_id: []const u8,
    cwd: []const u8,
    git_branch: []const u8,
    app_version: []const u8,
    is_sidechain: bool,

    /// Takes ownership of the strings inside `payload` (they must already be
    /// gpa-owned) and appends a full event with a duplicated envelope.
    fn add(b: *Builder, payload: Payload) Allocator.Error!void {
        const session_id = try b.gpa.dupe(u8, b.session_id);
        errdefer b.gpa.free(session_id);
        const cwd = try b.gpa.dupe(u8, b.cwd);
        errdefer b.gpa.free(cwd);
        const git_branch = try b.gpa.dupe(u8, b.git_branch);
        errdefer b.gpa.free(git_branch);
        const app_version = try b.gpa.dupe(u8, b.app_version);
        errdefer b.gpa.free(app_version);
        try b.list.append(b.gpa, .{
            .timestamp_ms = b.timestamp_ms,
            .session_id = session_id,
            .cwd = cwd,
            .git_branch = git_branch,
            .app_version = app_version,
            .is_sidechain = b.is_sidechain,
            .payload = payload,
        });
    }

    fn deinit(b: *Builder) void {
        for (b.list.items) |*e| e.deinit(b.gpa);
        b.list.deinit(b.gpa);
    }
};

/// Extracts a human-useful one-liner from a tool_use input object: the most
/// identifying argument if present, otherwise a compact key=value rendering.
fn toolCallDetail(gpa: Allocator, input_value: ?std.json.Value) Allocator.Error![]const u8 {
    const input = if (input_value) |v| asObject(v) orelse return gpa.dupe(u8, "") else return gpa.dupe(u8, "");
    const preferred_keys = [_][]const u8{
        "file_path", "path", "command", "pattern", "query", "url", "prompt", "skill", "description",
    };
    for (preferred_keys) |key| {
        if (strField(input, key)) |value| {
            const copy = try dupeTruncated(gpa, value, max_detail_len);
            return copy.text;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = input.iterator();
    while (it.next()) |entry| {
        if (out.items.len >= max_detail_len) break;
        if (out.items.len > 0) try out.appendSlice(gpa, " ");
        try out.appendSlice(gpa, entry.key_ptr.*);
        try out.append(gpa, '=');
        switch (entry.value_ptr.*) {
            .string => |s| try out.appendSlice(gpa, s[0..@min(s.len, 80)]),
            .integer => |i| try out.print(gpa, "{d}", .{i}),
            .bool => |flag| try out.appendSlice(gpa, if (flag) "true" else "false"),
            else => try out.appendSlice(gpa, "..."),
        }
    }
    if (out.items.len > max_detail_len) out.shrinkRetainingCapacity(max_detail_len);
    return out.toOwnedSlice(gpa);
}

/// Extracts readable text from a tool_result content field, which is either a
/// plain string or an array of typed blocks.
fn toolResultText(block: std.json.ObjectMap) []const u8 {
    const content = block.get("content") orelse return "";
    switch (content) {
        .string => |s| return s,
        .array => |items| for (items.items) |item| {
            const inner = asObject(item) orelse continue;
            const inner_type = strField(inner, "type") orelse continue;
            if (std.mem.eql(u8, inner_type, "text")) {
                return strField(inner, "text") orelse "";
            }
        },
        else => {},
    }
    return "";
}

const TruncatedCopy = struct { text: []const u8, truncated: bool };

/// Duplicates `text` cut to at most `max` bytes without splitting a UTF-8
/// code point.
fn dupeTruncated(gpa: Allocator, text: []const u8, max: usize) Allocator.Error!TruncatedCopy {
    if (text.len <= max) return .{ .text = try gpa.dupe(u8, text), .truncated = false };
    var end = max;
    while (end > 0 and text[end] & 0b1100_0000 == 0b1000_0000) end -= 1;
    return .{ .text = try gpa.dupe(u8, text[0..end]), .truncated = true };
}

fn asObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn objField(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = obj.get(name) orelse return null;
    return asObject(value);
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) ?bool {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn uintField(obj: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn parseFixtureLine(line: []const u8) ![]Event {
    return parseLine(testing.allocator, line);
}

test "user prompt line becomes a prompt event" {
    const line =
        \\{"type":"user","message":{"role":"user","content":"fix the login bug"},"uuid":"u1","timestamp":"2026-07-07T18:54:46.347Z","cwd":"/home/dev/webshop","sessionId":"s1","isSidechain":false}
    ;
    const events = try parseFixtureLine(line);
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("fix the login bug", events[0].payload.prompt.text);
    try testing.expectEqual(false, events[0].payload.prompt.truncated);
    try testing.expectEqualStrings("s1", events[0].session_id);
    try testing.expectEqualStrings("/home/dev/webshop", events[0].cwd);
    try testing.expectEqual(@as(i64, 1783450486347), events[0].timestamp_ms);
}

test "assistant line yields text, tool_call and usage events" {
    const line =
        \\{"type":"assistant","message":{"model":"claude-opus-4-8","id":"msg_1","role":"assistant","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/home/dev/webshop/src/auth.ts"}}],"usage":{"input_tokens":12,"output_tokens":34,"cache_read_input_tokens":56,"cache_creation_input_tokens":7}},"timestamp":"2026-07-07T18:55:00Z","cwd":"/home/dev/webshop","sessionId":"s1","isSidechain":false}
    ;
    const events = try parseFixtureLine(line);
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqualStrings("Let me look.", events[0].payload.assistant_text.text);
    try testing.expectEqualStrings("Read", events[1].payload.tool_call.name);
    try testing.expectEqualStrings("/home/dev/webshop/src/auth.ts", events[1].payload.tool_call.detail);
    const usage = events[2].payload.usage;
    try testing.expectEqualStrings("msg_1", usage.message_id);
    try testing.expectEqualStrings("claude-opus-4-8", usage.model);
    try testing.expectEqual(@as(u64, 12), usage.tokens.input);
    try testing.expectEqual(@as(u64, 34), usage.tokens.output);
    try testing.expectEqual(@as(u64, 56), usage.tokens.cache_read);
    try testing.expectEqual(@as(u64, 7), usage.tokens.cache_creation);
}

test "tool_result line becomes a tool_result event" {
    const line =
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"2 files changed"}]},"toolUseResult":{"success":true},"timestamp":"2026-07-07T18:55:01Z","cwd":"/home/dev/webshop","sessionId":"s1"}
    ;
    const events = try parseFixtureLine(line);
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(?bool, true), events[0].payload.tool_result.ok);
    try testing.expectEqualStrings("2 files changed", events[0].payload.tool_result.summary);
}

test "control records map to meta events" {
    const title_events = try parseFixtureLine(
        \\{"type":"ai-title","aiTitle":"Fix login flow","sessionId":"s1"}
    );
    defer event_mod.freeEvents(testing.allocator, title_events);
    try testing.expectEqual(@as(usize, 1), title_events.len);
    try testing.expectEqual(event_mod.MetaKind.title, title_events[0].payload.meta.kind);
    try testing.expectEqualStrings("Fix login flow", title_events[0].payload.meta.value);

    const mode_events = try parseFixtureLine(
        \\{"type":"permission-mode","permissionMode":"plan","sessionId":"s1"}
    );
    defer event_mod.freeEvents(testing.allocator, mode_events);
    try testing.expectEqual(event_mod.MetaKind.permission_mode, mode_events[0].payload.meta.kind);
}

test "hook error attachment surfaces hook name" {
    const line =
        \\{"type":"attachment","attachment":{"type":"hook_non_blocking_error","hookName":"SessionStart:startup","stderr":"boom"},"timestamp":"2026-07-07T18:54:46.347Z","sessionId":"s1","cwd":"/home/dev/webshop"}
    ;
    const events = try parseFixtureLine(line);
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("hook_non_blocking_error:SessionStart:startup", events[0].payload.meta.value);
}

test "unknown record type is preserved as unknown event" {
    const events = try parseFixtureLine(
        \\{"type":"brand-new-thing","sessionId":"s1"}
    );
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("brand-new-thing", events[0].payload.unknown.record_type);
}

test "noise record types produce no events" {
    const events = try parseFixtureLine(
        \\{"type":"file-history-snapshot","messageId":"m1","snapshot":"...","sessionId":"s1"}
    );
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "malformed and empty lines are dropped without error" {
    const broken = try parseFixtureLine("{\"type\":\"user\",");
    defer event_mod.freeEvents(testing.allocator, broken);
    try testing.expectEqual(@as(usize, 0), broken.len);

    const empty = try parseFixtureLine("   \n");
    defer event_mod.freeEvents(testing.allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const non_object = try parseFixtureLine("[1,2,3]");
    defer event_mod.freeEvents(testing.allocator, non_object);
    try testing.expectEqual(@as(usize, 0), non_object.len);
}

test "long prompt text is truncated at a UTF-8 boundary" {
    var long_line: std.ArrayList(u8) = .empty;
    defer long_line.deinit(testing.allocator);
    try long_line.appendSlice(testing.allocator, "{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"");
    // 2 bytes per 'ó' — an odd max_text_len would split the code point.
    for (0..2000) |_| try long_line.appendSlice(testing.allocator, "ó");
    try long_line.appendSlice(testing.allocator, "\"}}");

    const events = try parseLine(testing.allocator, long_line.items);
    defer event_mod.freeEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expect(events[0].payload.prompt.truncated);
    try testing.expect(events[0].payload.prompt.text.len <= max_text_len);
    try testing.expect(std.unicode.utf8ValidateSlice(events[0].payload.prompt.text));
}
