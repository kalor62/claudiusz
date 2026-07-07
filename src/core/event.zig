//! Normalized event model. Every Claude Code transcript record is reduced to
//! one or more `Event` values — the single vocabulary shared by the collector,
//! index, API, and TUI.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Token counts reported by the API for one assistant message.
pub const Tokens = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_creation: u64 = 0,
};

/// What a `meta` event describes about its session.
pub const MetaKind = enum {
    title,
    permission_mode,
    mode,
    agent_name,
    attachment,
};

/// Event payload. Strings are owned by the event and freed in `Event.deinit`.
pub const Payload = union(enum) {
    /// A prompt typed (or injected) on the user side of the conversation.
    prompt: struct { text: []const u8, truncated: bool },
    /// Assistant-visible text output.
    assistant_text: struct { text: []const u8, truncated: bool },
    /// Assistant invoking a tool.
    tool_call: struct { name: []const u8, detail: []const u8 },
    /// Result of a tool invocation coming back into the conversation.
    tool_result: struct { ok: ?bool, summary: []const u8 },
    /// Token usage attached to an assistant message. Repeats across the
    /// streamed blocks of one turn — consumers must dedupe by `message_id`.
    usage: struct { message_id: []const u8, model: []const u8, tokens: Tokens },
    /// Session metadata change (title, permission mode, ...).
    meta: struct { kind: MetaKind, value: []const u8 },
    /// System record such as turn duration.
    system: struct { subtype: []const u8, duration_ms: ?u64 },
    /// Record type this version of claudiusz does not understand.
    unknown: struct { record_type: []const u8 },
};

/// One normalized transcript event.
pub const Event = struct {
    /// Milliseconds since the Unix epoch, UTC. Zero when the record carried
    /// no timestamp (thin control records).
    timestamp_ms: i64,
    session_id: []const u8,
    /// Project working directory the session runs in. Empty when unknown.
    cwd: []const u8,
    /// Git branch active in the session. Empty when unknown.
    git_branch: []const u8,
    /// Claude Code version that wrote the record. Empty when unknown.
    app_version: []const u8,
    /// True for subagent (sidechain) activity.
    is_sidechain: bool,
    payload: Payload,

    pub fn deinit(event: *Event, gpa: Allocator) void {
        gpa.free(event.session_id);
        gpa.free(event.cwd);
        gpa.free(event.git_branch);
        gpa.free(event.app_version);
        switch (event.payload) {
            .prompt => |p| gpa.free(p.text),
            .assistant_text => |p| gpa.free(p.text),
            .tool_call => |p| {
                gpa.free(p.name);
                gpa.free(p.detail);
            },
            .tool_result => |p| gpa.free(p.summary),
            .usage => |p| {
                gpa.free(p.message_id);
                gpa.free(p.model);
            },
            .meta => |p| gpa.free(p.value),
            .system => |p| gpa.free(p.subtype),
            .unknown => |p| gpa.free(p.record_type),
        }
        event.* = undefined;
    }

    /// Stable lowercase name of the payload variant, e.g. "tool_call".
    pub fn kindName(event: *const Event) []const u8 {
        return @tagName(event.payload);
    }
};

/// Frees a slice of events returned by the parser.
pub fn freeEvents(gpa: Allocator, events: []Event) void {
    for (events) |*e| e.deinit(gpa);
    gpa.free(events);
}
