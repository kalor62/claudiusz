//! Workflow tips: heuristics over the index and project audits that surface
//! concrete, actionable improvements. Every rule is a pure function with a
//! positive and a negative test — to add one, write the function, add it to
//! `rules`, and cover both cases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const stats = @import("stats.zig");
const index_mod = @import("index.zig");
const audit_mod = @import("audit.zig");

pub const Severity = enum { info, warn, high };

pub const Tip = struct {
    severity: Severity,
    rule: []const u8,
    project: []const u8,
    message: []const u8,
    evidence: []const u8,
};

pub const Input = struct {
    report: stats.Report,
    sessions: []const index_mod.SessionSummary,
    audits: []const audit_mod.ProjectAudit,
};

const Rule = struct {
    name: []const u8,
    run: *const fn (ctx: *Context) Allocator.Error!void,
};

const rules = [_]Rule{
    .{ .name = "missing-claude-md", .run = missingClaudeMd },
    .{ .name = "permission-friction", .run = permissionFriction },
    .{ .name = "long-prompt-pastes", .run = longPromptPastes },
    .{ .name = "failing-hooks", .run = failingHooks },
    .{ .name = "tool-error-loops", .run = toolErrorLoops },
    .{ .name = "unknown-records", .run = unknownRecords },
};

/// Runs every rule and returns the tips sorted most severe first.
pub fn evaluate(arena: Allocator, input: Input) Allocator.Error![]Tip {
    var ctx = Context{ .arena = arena, .input = input };
    for (rules) |rule| {
        ctx.rule = rule.name;
        try rule.run(&ctx);
    }
    const tips = try ctx.tips.toOwnedSlice(arena);
    std.sort.pdq(Tip, tips, {}, moreSevere);
    return tips;
}

const Context = struct {
    arena: Allocator,
    input: Input,
    rule: []const u8 = "",
    tips: std.ArrayList(Tip) = .empty,

    fn add(
        ctx: *Context,
        severity: Severity,
        project: []const u8,
        comptime message_fmt: []const u8,
        message_args: anytype,
        comptime evidence_fmt: []const u8,
        evidence_args: anytype,
    ) Allocator.Error!void {
        try ctx.tips.append(ctx.arena, .{
            .severity = severity,
            .rule = ctx.rule,
            .project = try ctx.arena.dupe(u8, project),
            .message = try std.fmt.allocPrint(ctx.arena, message_fmt, message_args),
            .evidence = try std.fmt.allocPrint(ctx.arena, evidence_fmt, evidence_args),
        });
    }
};

/// A project used across several sessions with no CLAUDE.md makes Claude
/// rediscover the codebase every time.
fn missingClaudeMd(ctx: *Context) Allocator.Error!void {
    for (ctx.input.audits) |a| {
        if (!a.exists or a.has_claude_md or a.sessions_seen < 3) continue;
        try ctx.add(
            .warn,
            a.project,
            "Add a CLAUDE.md to {s} — Claude re-learns the project layout in every session there.",
            .{a.project},
            "{d} sessions, {d} prompts, no CLAUDE.md at {s}",
            .{ a.sessions_seen, a.prompts_seen, a.cwd },
        );
    }
}

/// A session stuck on a permission prompt in a project without a local
/// allowlist suggests recurring permission fatigue.
fn permissionFriction(ctx: *Context) Allocator.Error!void {
    for (ctx.input.sessions) |s| {
        if (!std.mem.eql(u8, s.status, "waiting_for_user")) continue;
        if (std.mem.indexOf(u8, s.waiting_for, "permission") == null) continue;
        const has_allowlist = for (ctx.input.audits) |a| {
            if (std.mem.eql(u8, a.cwd, s.cwd)) break a.has_settings_local;
        } else false;
        if (has_allowlist) continue;
        try ctx.add(
            .info,
            s.project,
            "Session in {s} is blocked on a permission prompt and the project has no .claude/settings.local.json allowlist — add the commands you always approve.",
            .{s.project},
            "status=waiting_for_user waiting_for={s}",
            .{s.waiting_for},
        );
    }
}

/// Repeatedly pasting large blobs into prompts burns tokens; `@file`
/// references keep the context addressable and cacheable.
fn longPromptPastes(ctx: *Context) Allocator.Error!void {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(ctx.arena);
    for (ctx.input.sessions) |s| {
        if (s.long_prompt_count == 0) continue;
        const gop = try counts.getOrPut(ctx.arena, s.project);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += s.long_prompt_count;
    }
    var it = counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* < 3) continue;
        try ctx.add(
            .info,
            entry.key_ptr.*,
            "Prompts in {s} often contain large pasted blocks — reference files with @path instead of pasting code or logs.",
            .{entry.key_ptr.*},
            "{d} prompts over ~1.5k characters",
            .{entry.value_ptr.*},
        );
    }
}

/// A hook failing on every session start is pure noise until someone fixes it.
fn failingHooks(ctx: *Context) Allocator.Error!void {
    for (ctx.input.report.top_projects) |p| {
        if (p.hook_errors <= 2) continue;
        try ctx.add(
            .high,
            p.project,
            "A configured hook in {s} keeps failing — fix or remove it; every session pays for the error.",
            .{p.project},
            "{d} hook errors in the last {d} days",
            .{ p.hook_errors, ctx.input.report.range_days },
        );
    }
}

/// A high tool failure rate usually means a broken environment or a missing
/// setup step that Claude keeps tripping over.
fn toolErrorLoops(ctx: *Context) Allocator.Error!void {
    for (ctx.input.report.top_projects) |p| {
        if (p.tool_calls <= 20 or p.failures * 5 < p.tool_calls) continue;
        try ctx.add(
            .warn,
            p.project,
            "Tool calls in {s} fail unusually often — check for a broken build/test setup Claude keeps hitting.",
            .{p.project},
            "{d} failures out of {d} tool calls ({d} days)",
            .{ p.failures, p.tool_calls, ctx.input.report.range_days },
        );
    }
}

/// Many unknown record types mean the local Claude Code writes a newer
/// transcript dialect than this claudiusz understands.
fn unknownRecords(ctx: *Context) Allocator.Error!void {
    var total: u64 = 0;
    for (ctx.input.sessions) |s| total += s.unknown_record_count;
    if (total < 50) return;
    try ctx.add(
        .info,
        "",
        "Claude Code emits transcript records this claudiusz build does not recognize — update claudiusz to keep stats accurate.",
        .{},
        "{d} unknown records across all sessions",
        .{total},
    );
}

fn moreSevere(_: void, a: Tip, b: Tip) bool {
    const rank_a = @intFromEnum(a.severity);
    const rank_b = @intFromEnum(b.severity);
    if (rank_a != rank_b) return rank_a > rank_b;
    return std.mem.lessThan(u8, a.project, b.project);
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn emptyReport() stats.Report {
    return .{
        .range_days = 7,
        .generated_at_ms = 0,
        .totals = .{},
        .days = &.{},
        .top_tools = &.{},
        .top_projects = &.{},
        .hour_prompts = @splat(0),
    };
}

fn sessionTemplate() index_mod.SessionSummary {
    return .{
        .id = "s",
        .project = "webshop",
        .cwd = "/w/webshop",
        .title = "",
        .agent_name = "",
        .status = "done",
        .waiting_for = "",
        .model = "",
        .tokens = .{},
        .prompt_count = 0,
        .tool_call_count = 0,
        .tool_failure_count = 0,
        .last_activity = "",
        .last_prompt = "",
        .first_ts_ms = 0,
        .last_ts_ms = 0,
    };
}

fn evaluateWith(arena: Allocator, input: Input) ![]Tip {
    return evaluate(arena, input);
}

test "missing-claude-md fires for busy unconfigured projects only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const audits = [_]audit_mod.ProjectAudit{
        .{ .project = "busy-bare", .cwd = "/w/a", .exists = true, .sessions_seen = 5, .prompts_seen = 40 },
        .{ .project = "configured", .cwd = "/w/b", .exists = true, .has_claude_md = true, .sessions_seen = 9 },
        .{ .project = "rarely-used", .cwd = "/w/c", .exists = true, .sessions_seen = 1 },
        .{ .project = "deleted", .cwd = "/w/d", .exists = false, .sessions_seen = 8 },
    };
    const tips = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{}, .audits = &audits });
    try testing.expectEqual(@as(usize, 1), tips.len);
    try testing.expectEqualStrings("missing-claude-md", tips[0].rule);
    try testing.expectEqualStrings("busy-bare", tips[0].project);
}

test "permission-friction fires only without a local allowlist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var blocked = sessionTemplate();
    blocked.status = "waiting_for_user";
    blocked.waiting_for = "permission prompt";

    const bare_audit = [_]audit_mod.ProjectAudit{
        .{ .project = "webshop", .cwd = "/w/webshop", .exists = true },
    };
    const with_tip = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{blocked}, .audits = &bare_audit });
    try testing.expectEqual(@as(usize, 1), with_tip.len);
    try testing.expectEqualStrings("permission-friction", with_tip[0].rule);

    const allowlisted_audit = [_]audit_mod.ProjectAudit{
        .{ .project = "webshop", .cwd = "/w/webshop", .exists = true, .has_settings_local = true },
    };
    const without_tip = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{blocked}, .audits = &allowlisted_audit });
    try testing.expectEqual(@as(usize, 0), without_tip.len);
}

test "long-prompt-pastes aggregates per project with a threshold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var a = sessionTemplate();
    a.long_prompt_count = 2;
    var b = sessionTemplate();
    b.long_prompt_count = 1;
    const firing = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{ a, b }, .audits = &.{} });
    try testing.expectEqual(@as(usize, 1), firing.len);
    try testing.expectEqualStrings("long-prompt-pastes", firing[0].rule);

    var c = sessionTemplate();
    c.long_prompt_count = 2;
    const quiet = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{c}, .audits = &.{} });
    try testing.expectEqual(@as(usize, 0), quiet.len);
}

test "failing-hooks and tool-error-loops read the project report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var projects = [_]stats.ProjectRow{
        .{ .project = "darts", .hook_errors = 43, .tool_calls = 100, .failures = 30 },
        .{ .project = "clean", .hook_errors = 0, .tool_calls = 100, .failures = 1 },
    };
    var report = emptyReport();
    report.top_projects = &projects;

    const tips = try evaluateWith(arena, .{ .report = report, .sessions = &.{}, .audits = &.{} });
    try testing.expectEqual(@as(usize, 2), tips.len);
    try testing.expectEqualStrings("failing-hooks", tips[0].rule);
    try testing.expectEqual(Severity.high, tips[0].severity);
    try testing.expectEqualStrings("tool-error-loops", tips[1].rule);
}

test "unknown-records needs a substantial total" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var noisy = sessionTemplate();
    noisy.unknown_record_count = 60;
    const firing = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{noisy}, .audits = &.{} });
    try testing.expectEqual(@as(usize, 1), firing.len);
    try testing.expectEqualStrings("unknown-records", firing[0].rule);

    var calm = sessionTemplate();
    calm.unknown_record_count = 10;
    const quiet = try evaluateWith(arena, .{ .report = emptyReport(), .sessions = &.{calm}, .audits = &.{} });
    try testing.expectEqual(@as(usize, 0), quiet.len);
}
