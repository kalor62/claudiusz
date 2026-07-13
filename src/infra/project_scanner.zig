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
        checkFilesystem(arena, io, &rows[i]);
    }
    std.sort.pdq(audit.ProjectAudit, rows, {}, mostRecentFirst);
    return rows;
}

const max_config_bytes = 256 * 1024;

fn checkFilesystem(arena: Allocator, io: Io, row: *audit.ProjectAudit) void {
    var dir = Io.Dir.cwd().openDir(io, row.cwd, .{}) catch |err| {
        log.debug("project dir {s} not openable: {s}", .{ row.cwd, @errorName(err) });
        return;
    };
    defer dir.close(io);
    row.exists = true;
    row.has_claude_md = claudeMdHasSubstance(arena, io, dir);
    row.has_claude_dir = fileExists(io, dir, ".claude");
    row.has_settings = fileExists(io, dir, ".claude/settings.json");
    row.has_settings_local = fileExists(io, dir, ".claude/settings.local.json");
    row.skill_count = countEntries(io, dir, ".claude/skills", .directories);
    row.agent_count = countEntries(io, dir, ".claude/agents", .markdown_files);
    row.mcp_server_count = countMcpServers(arena, io, dir);
    row.plugin_count = countEnabledPlugins(arena, io, dir);
}

/// A CLAUDE.md counts only when it carries real guidance: blank lines and
/// bare markdown headers are ignored, and what remains must reach this many
/// characters. An empty file or a lone "# project" title scores nothing.
const min_claude_md_substance = 40;

fn claudeMdHasSubstance(arena: Allocator, io: Io, dir: Io.Dir) bool {
    const bytes = dir.readFileAlloc(io, "CLAUDE.md", arena, .limited(max_config_bytes)) catch |err| {
        if (err != error.FileNotFound) log.debug("cannot read CLAUDE.md: {s}", .{@errorName(err)});
        return false;
    };
    var substance: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        substance += line.len;
        if (substance >= min_claude_md_substance) return true;
    }
    return false;
}

const EntryFilter = enum { directories, markdown_files };

fn countEntries(io: Io, dir: Io.Dir, sub_path: []const u8, filter: EntryFilter) u32 {
    var sub = dir.openDir(io, sub_path, .{ .iterate = true }) catch |err| {
        if (err != error.FileNotFound) log.debug("cannot open {s}: {s}", .{ sub_path, @errorName(err) });
        return 0;
    };
    defer sub.close(io);
    var count: u32 = 0;
    var it = sub.iterate();
    while (it.next(io) catch |err| {
        log.debug("iteration failed in {s}: {s}", .{ sub_path, @errorName(err) });
        return count;
    }) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const matches = switch (filter) {
            .directories => entry.kind == .directory,
            .markdown_files => entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md"),
        };
        if (matches) count += 1;
    }
    return count;
}

fn countMcpServers(arena: Allocator, io: Io, dir: Io.Dir) u32 {
    const obj = readJsonObject(arena, io, dir, ".mcp.json") orelse return 0;
    return switch (obj.get("mcpServers") orelse return 0) {
        .object => |servers| @intCast(servers.count()),
        else => 0,
    };
}

/// Counts distinct enabled plugins across project settings; the local file
/// can re-enable or duplicate entries from the shared one, hence the dedup.
fn countEnabledPlugins(arena: Allocator, io: Io, dir: Io.Dir) u32 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    for ([_][]const u8{ ".claude/settings.json", ".claude/settings.local.json" }) |path| {
        const obj = readJsonObject(arena, io, dir, path) orelse continue;
        const plugins = switch (obj.get("enabledPlugins") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        var it = plugins.iterator();
        while (it.next()) |entry| {
            const enabled = switch (entry.value_ptr.*) {
                .bool => |b| b,
                else => true,
            };
            if (!enabled) continue;
            seen.put(arena, entry.key_ptr.*, {}) catch |err| {
                log.debug("plugin dedup allocation failed: {s}", .{@errorName(err)});
                break;
            };
        }
    }
    return @intCast(seen.count());
}

fn readJsonObject(arena: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) ?std.json.ObjectMap {
    const bytes = dir.readFileAlloc(io, sub_path, arena, .limited(max_config_bytes)) catch |err| {
        if (err != error.FileNotFound) log.debug("cannot read {s}: {s}", .{ sub_path, @errorName(err) });
        return null;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| {
        log.debug("malformed {s}: {s}", .{ sub_path, @errorName(err) });
        return null;
    };
    return switch (parsed) {
        .object => |o| o,
        else => null,
    };
}

fn fileExists(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    _ = dir.statFile(io, sub_path, .{}) catch |err| {
        if (err != error.FileNotFound) log.debug("stat {s} failed: {s}", .{ sub_path, @errorName(err) });
        return false;
    };
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

    try claude_dirs.makePathForTest(tmp.dir, io, "configured/.claude/skills/my-skill");
    try claude_dirs.makePathForTest(tmp.dir, io, "configured/.claude/agents");
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/CLAUDE.md", .data =
        \\# ctx
        \\Always run the full test suite with `zig build test` before committing.
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/.claude/settings.local.json", .data =
        \\{"enabledPlugins":{"repo@one":true,"repo@two":false}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/.claude/agents/helper.md", .data = "# agent" });
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/.claude/agents/notes.txt", .data = "not an agent" });
    try tmp.dir.writeFile(io, .{ .sub_path = "configured/.mcp.json", .data =
        \\{"mcpServers":{"github":{},"postgres":{}}}
    });
    try claude_dirs.makePathForTest(tmp.dir, io, "bare");
    try claude_dirs.makePathForTest(tmp.dir, io, "trivial");
    try tmp.dir.writeFile(io, .{ .sub_path = "trivial/CLAUDE.md", .data = "# my project\n\n" });

    const configured_path = try tmp.dir.realPathFileAlloc(io, "configured", testing.allocator);
    defer testing.allocator.free(configured_path);
    const bare_path = try tmp.dir.realPathFileAlloc(io, "bare", testing.allocator);
    defer testing.allocator.free(bare_path);
    const trivial_path = try tmp.dir.realPathFileAlloc(io, "trivial", testing.allocator);
    defer testing.allocator.free(trivial_path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const template = index_mod.SessionSummary{
        .id = "s",
        .project = "p",
        .cwd = "",
        .current_dir = "",
        .title = "",
        .agent_name = "",
        .status = .done,
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
    var s5 = template;
    s5.cwd = trivial_path;
    s5.project = "trivial";

    const rows = try scan(arena, io, &.{ s1, s2, s3, s4, s5 });
    try testing.expectEqual(@as(usize, 4), rows.len);

    const configured = findRow(rows, "configured").?;
    try testing.expect(configured.exists);
    try testing.expect(configured.has_claude_md);
    try testing.expect(configured.has_claude_dir);
    try testing.expect(configured.has_settings_local);
    try testing.expect(!configured.has_settings);
    try testing.expectEqual(@as(u32, 1), configured.skill_count);
    try testing.expectEqual(@as(u32, 1), configured.agent_count);
    try testing.expectEqual(@as(u32, 2), configured.mcp_server_count);
    try testing.expectEqual(@as(u32, 1), configured.plugin_count);
    try testing.expectEqual(@as(u8, 5), configured.qualityScore());
    try testing.expectEqual(@as(u32, 2), configured.sessions_seen);
    try testing.expectEqual(@as(u32, 8), configured.prompts_seen);

    const bare = findRow(rows, "bare").?;
    try testing.expect(bare.exists);
    try testing.expect(!bare.has_claude_md);

    // A header-only CLAUDE.md carries no guidance and must not score.
    const trivial = findRow(rows, "trivial").?;
    try testing.expect(trivial.exists);
    try testing.expect(!trivial.has_claude_md);

    const ghost = findRow(rows, "ghost").?;
    try testing.expect(!ghost.exists);
}

fn findRow(rows: []const audit.ProjectAudit, project: []const u8) ?audit.ProjectAudit {
    for (rows) |row| {
        if (std.mem.eql(u8, row.project, project)) return row;
    }
    return null;
}
