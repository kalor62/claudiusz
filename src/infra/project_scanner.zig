//! Audits the projects Claude Code has been used in: which of them carry a
//! CLAUDE.md, project settings, permission allowlists. Projects are derived
//! from session working directories, not from guessing a workspace root.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const audit = @import("../core/audit.zig");
const index_mod = @import("../core/index.zig");

const log = std.log.scoped(.project_scanner);

/// One audit row per unique project cwd found in `sessions`, sorted by
/// most recent activity. Arena-owned.
pub fn scan(
    arena: Allocator,
    io: Io,
    sessions: []const index_mod.SessionSummary,
) Allocator.Error![]audit.ProjectAudit {
    var by_cwd: std.StringHashMapUnmanaged(audit.ProjectAudit) = .empty;
    defer by_cwd.deinit(arena);

    for (sessions) |s| {
        if (s.cwd.len == 0) continue;
        const gop = try by_cwd.getOrPut(arena, s.cwd);
        if (!gop.found_existing) {
            gop.key_ptr.* = try arena.dupe(u8, s.cwd);
            gop.value_ptr.* = .{
                .project = try arena.dupe(u8, s.project),
                .cwd = gop.key_ptr.*,
            };
        }
        const row = gop.value_ptr;
        row.sessions_seen += 1;
        row.prompts_seen += s.prompt_count;
        row.last_activity_ms = @max(row.last_activity_ms, s.last_ts_ms);
    }

    var rows = try arena.alloc(audit.ProjectAudit, by_cwd.count());
    var it = by_cwd.valueIterator();
    var i: usize = 0;
    while (it.next()) |row| : (i += 1) {
        rows[i] = row.*;
        checkFilesystem(io, &rows[i]);
    }
    std.sort.pdq(audit.ProjectAudit, rows, {}, mostRecentFirst);
    return rows;
}

fn checkFilesystem(io: Io, row: *audit.ProjectAudit) void {
    var dir = Io.Dir.cwd().openDir(io, row.cwd, .{}) catch |err| {
        log.debug("project dir {s} not openable: {s}", .{ row.cwd, @errorName(err) });
        return;
    };
    defer dir.close(io);
    row.exists = true;
    row.has_claude_md = fileExists(io, dir, "CLAUDE.md");
    row.has_claude_dir = fileExists(io, dir, ".claude");
    row.has_settings = fileExists(io, dir, ".claude/settings.json");
    row.has_settings_local = fileExists(io, dir, ".claude/settings.local.json");
}

fn fileExists(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    _ = dir.statFile(io, sub_path, .{}) catch return false;
    return true;
}

fn mostRecentFirst(_: void, a: audit.ProjectAudit, b: audit.ProjectAudit) bool {
    return a.last_activity_ms > b.last_activity_ms;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const claude_dirs = @import("claude_dirs.zig");

test "scan derives projects from sessions and checks their files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try claude_dirs.makePathForTest(tmp.dir, io, "configured/.claude");
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/CLAUDE.md", .data = "# ctx" });
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/.claude/settings.local.json", .data = "{}" });
    try claude_dirs.makePathForTest(tmp.dir, io, "bare");

    const configured_path = try tmp.dir.realPathFileAlloc(io, "configured", testing.allocator);
    defer testing.allocator.free(configured_path);
    const bare_path = try tmp.dir.realPathFileAlloc(io, "bare", testing.allocator);
    defer testing.allocator.free(bare_path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const template = index_mod.SessionSummary{
        .id = "s",
        .project = "p",
        .cwd = "",
        .title = "",
        .agent_name = "",
        .status = "done",
        .waiting_for = "",
        .model = "",
        .tokens = .{},
        .prompt_count = 4,
        .tool_call_count = 0,
        .tool_failure_count = 0,
        .last_activity = "",
        .last_prompt = "",
        .first_ts_ms = 0,
        .last_ts_ms = 10,
    };
    var s1 = template;
    s1.cwd = configured_path;
    s1.project = "configured";
    var s2 = template;
    s2.cwd = configured_path;
    s2.project = "configured";
    s2.last_ts_ms = 99;
    var s3 = template;
    s3.cwd = bare_path;
    s3.project = "bare";
    var s4 = template;
    s4.cwd = "/does/not/exist";
    s4.project = "ghost";

    const rows = try scan(arena, io, &.{ s1, s2, s3, s4 });
    try testing.expectEqual(@as(usize, 3), rows.len);

    const configured = findRow(rows, "configured").?;
    try testing.expect(configured.exists);
    try testing.expect(configured.has_claude_md);
    try testing.expect(configured.has_claude_dir);
    try testing.expect(configured.has_settings_local);
    try testing.expect(!configured.has_settings);
    try testing.expectEqual(@as(u32, 2), configured.sessions_seen);
    try testing.expectEqual(@as(u32, 8), configured.prompts_seen);

    const bare = findRow(rows, "bare").?;
    try testing.expect(bare.exists);
    try testing.expect(!bare.has_claude_md);

    const ghost = findRow(rows, "ghost").?;
    try testing.expect(!ghost.exists);
}

fn findRow(rows: []const audit.ProjectAudit, project: []const u8) ?audit.ProjectAudit {
    for (rows) |row| {
        if (std.mem.eql(u8, row.project, project)) return row;
    }
    return null;
}
