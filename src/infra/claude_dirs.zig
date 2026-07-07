//! Discovery of Claude Code data files inside a config root (~/.claude or any
//! directory passed via --root). Layout being walked:
//!
//!   <root>/projects/<project-slug>/<session-uuid>.jsonl
//!   <root>/projects/<project-slug>/<session-uuid>/subagents/agent-<id>.jsonl

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.claude_dirs);

/// Collects absolute paths of every transcript JSONL file under
/// `<root>/projects`, including subagent sidechain transcripts.
/// Caller owns the returned slice and each path; free with `freePaths`.
pub fn collectTranscripts(gpa: Allocator, io: Io, root: []const u8) Allocator.Error![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer freePathList(gpa, &paths);

    const projects_path = try std.fs.path.join(gpa, &.{ root, "projects" });
    defer gpa.free(projects_path);

    var projects_dir = Io.Dir.cwd().openDir(io, projects_path, .{ .iterate = true }) catch |err| {
        log.debug("cannot open {s}: {s}", .{ projects_path, @errorName(err) });
        return paths.toOwnedSlice(gpa);
    };
    defer projects_dir.close(io);

    var it = projects_dir.iterate();
    while (nextEntry(&it, io, projects_path)) |entry| {
        if (entry.kind != .directory) continue;
        collectProjectDir(gpa, io, &paths, projects_dir, projects_path, entry.name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return paths.toOwnedSlice(gpa);
}

pub fn freePaths(gpa: Allocator, paths: [][]const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn freePathList(gpa: Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |p| gpa.free(p);
    paths.deinit(gpa);
}

/// One project slug directory: session transcripts at the top level plus
/// per-session subdirectories holding subagent transcripts.
fn collectProjectDir(
    gpa: Allocator,
    io: Io,
    paths: *std.ArrayList([]const u8),
    projects_dir: Io.Dir,
    projects_path: []const u8,
    project_name: []const u8,
) Allocator.Error!void {
    var project_dir = projects_dir.openDir(io, project_name, .{ .iterate = true }) catch |err| {
        log.debug("cannot open project dir {s}: {s}", .{ project_name, @errorName(err) });
        return;
    };
    defer project_dir.close(io);

    const project_path = try std.fs.path.join(gpa, &.{ projects_path, project_name });
    defer gpa.free(project_path);

    var it = project_dir.iterate();
    while (nextEntry(&it, io, project_path)) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
                try paths.append(gpa, try std.fs.path.join(gpa, &.{ project_path, entry.name }));
            },
            .directory => try collectSubagents(gpa, io, paths, project_dir, project_path, entry.name),
            else => {},
        }
    }
}

fn collectSubagents(
    gpa: Allocator,
    io: Io,
    paths: *std.ArrayList([]const u8),
    project_dir: Io.Dir,
    project_path: []const u8,
    session_name: []const u8,
) Allocator.Error!void {
    const rel = try std.fs.path.join(gpa, &.{ session_name, "subagents" });
    defer gpa.free(rel);

    var subagents_dir = project_dir.openDir(io, rel, .{ .iterate = true }) catch |err| {
        // FileNotFound is the normal no-subagents case; anything else is still non-fatal for discovery.
        if (err != error.FileNotFound) {
            log.debug("cannot open {s}/{s}: {s}", .{ project_path, rel, @errorName(err) });
        }
        return;
    };
    defer subagents_dir.close(io);

    var it = subagents_dir.iterate();
    while (nextEntry(&it, io, rel)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        try paths.append(gpa, try std.fs.path.join(gpa, &.{ project_path, rel, entry.name }));
    }
}

/// Directory iteration that degrades to "stop" on errors instead of aborting
/// the whole scan; a transiently unreadable directory must not kill the tick.
fn nextEntry(it: *Io.Dir.Iterator, io: Io, context_path: []const u8) ?Io.Dir.Entry {
    return it.next(io) catch |err| {
        log.debug("directory iteration failed in {s}: {s}", .{ context_path, @errorName(err) });
        return null;
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

/// Recursive mkdir for tests; `Io.Dir` only ships single-level `createDir`.
pub fn makePathForTest(dir: Io.Dir, io: Io, path: []const u8) !void {
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
        dir.createDir(io, path[0..end], .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        end += 1;
    }
}

test "collectTranscripts finds session and subagent transcripts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try makePathForTest(tmp.dir, io, "root/projects/-home-dev-webshop/sess-1/subagents");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-home-dev-webshop/sess-1.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-home-dev-webshop/sess-1/subagents/agent-a.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-home-dev-webshop/notes.txt", .data = "not a transcript" });

    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    const paths = try collectTranscripts(testing.allocator, io, root);
    defer freePaths(testing.allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    var found_session = false;
    var found_subagent = false;
    for (paths) |p| {
        if (std.mem.endsWith(u8, p, "sess-1.jsonl")) found_session = true;
        if (std.mem.endsWith(u8, p, "agent-a.jsonl")) found_subagent = true;
    }
    try testing.expect(found_session);
    try testing.expect(found_subagent);
}

test "collectTranscripts on a missing root returns empty" {
    const paths = try collectTranscripts(testing.allocator, testing.io, "/nonexistent/claudiusz-test");
    defer freePaths(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 0), paths.len);
}
