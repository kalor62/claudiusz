//! Startup cache: persists index aggregates plus watcher offsets so a restart
//! validates transcripts with one stat() each instead of re-parsing the whole
//! history. Transcripts are append-only, so `size >= offset` means the cached
//! aggregate is still a correct prefix and only the tail needs parsing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const index_mod = @import("../core/index.zig");
const watcher_mod = @import("watcher.zig");

const log = std.log.scoped(.snapshot);

pub const format_version: u32 = 1;

const max_snapshot_bytes = 256 * 1024 * 1024;

const FileEntry = struct {
    path: []const u8,
    offset: u64 = 0,
    skip_to_newline: bool = false,
    mtime_ns: i64 = 0,
};

const Payload = struct {
    version: u32 = 0,
    files: []FileEntry = &.{},
    state: index_mod.State = .{},
};

/// Restores index aggregates and watcher offsets from `path`. Returns false
/// (leaving index and watcher untouched) when the snapshot is missing, stale
/// or contradicts the files on disk; the caller then does a full backfill.
pub fn load(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    index: *index_mod.Index,
    watcher: *watcher_mod.Watcher,
) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_snapshot_bytes)) catch |err| {
        if (err != error.FileNotFound) log.warn("cannot read snapshot {s}: {s}", .{ path, @errorName(err) });
        return false;
    };
    const payload = std.json.parseFromSliceLeaky(Payload, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("malformed snapshot {s}: {s}", .{ path, @errorName(err) });
        return false;
    };
    if (payload.version != format_version) {
        log.info("snapshot format v{d} != v{d}, rebuilding", .{ payload.version, format_version });
        return false;
    }

    // Validate every file before touching any state: a single rewritten or
    // truncated transcript poisons aggregates that cannot be subtracted.
    var seedable = std.ArrayList(FileEntry).empty;
    for (payload.files) |entry| {
        const stat = Io.Dir.cwd().statFile(io, entry.path, .{}) catch {
            // Deleted transcript (e.g. Claude Code's periodic cleanup): the
            // cached aggregate stays; there is just no tail left to follow.
            log.debug("transcript {s} gone; keeping cached aggregates", .{entry.path});
            continue;
        };
        if (stat.size < entry.offset) {
            log.info("transcript {s} shrank ({d} < {d}); rebuilding from scratch", .{ entry.path, stat.size, entry.offset });
            return false;
        }
        if (stat.size == entry.offset and mtimeNs(stat) != entry.mtime_ns and entry.mtime_ns != 0) {
            log.info("transcript {s} modified in place; rebuilding from scratch", .{entry.path});
            return false;
        }
        seedable.append(arena, entry) catch |err| {
            log.warn("snapshot restore allocation failed: {s}", .{@errorName(err)});
            return false;
        };
    }

    index.importState(io, payload.state) catch |err| {
        log.err("snapshot import failed ({s}); rebuilding from scratch", .{@errorName(err)});
        index.reset(io);
        return false;
    };
    for (seedable.items) |entry| {
        watcher.seedOffset(.{
            .path = entry.path,
            .offset = entry.offset,
            .skip_to_newline = entry.skip_to_newline,
        }) catch |err| {
            // Unseeded files would replay from byte 0 onto restored aggregates
            // and double-count; the only safe recovery is a clean rebuild.
            log.err("watcher seeding failed ({s}); rebuilding from scratch", .{@errorName(err)});
            index.reset(io);
            watcher.deinit();
            watcher.* = watcher_mod.Watcher.init(gpa, io, watcher.root, watcher.options);
            return false;
        };
    }
    log.info("restored {d} sessions and {d} file offsets from snapshot", .{
        payload.state.sessions.len,
        seedable.items.len,
    });
    return true;
}

/// Atomically writes the current index state and watcher offsets to `path`.
/// Failures are logged and swallowed: the cache is an optimization, never a
/// reason to take the collector down.
pub fn save(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    index: *index_mod.Index,
    watcher: *const watcher_mod.Watcher,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state = index.exportState(io, arena) catch |err| {
        log.warn("snapshot export failed: {s}", .{@errorName(err)});
        return;
    };
    const offsets = watcher.exportOffsets(arena) catch |err| {
        log.warn("snapshot offset export failed: {s}", .{@errorName(err)});
        return;
    };
    const files = arena.alloc(FileEntry, offsets.len) catch |err| {
        log.warn("snapshot allocation failed: {s}", .{@errorName(err)});
        return;
    };
    for (offsets, 0..) |entry, i| {
        const mtime: i64 = if (Io.Dir.cwd().statFile(io, entry.path, .{})) |stat| mtimeNs(stat) else |_| 0;
        files[i] = .{
            .path = entry.path,
            .offset = entry.offset,
            .skip_to_newline = entry.skip_to_newline,
            .mtime_ns = mtime,
        };
    }

    const payload = Payload{ .version = format_version, .files = files, .state = state };
    const json = std.json.Stringify.valueAlloc(arena, payload, .{}) catch |err| {
        log.warn("snapshot serialization failed: {s}", .{@errorName(err)});
        return;
    };

    if (std.fs.path.dirname(path)) |dir| ensureDir(io, dir);
    const tmp_path = std.fmt.allocPrint(arena, "{s}.tmp", .{path}) catch |err| {
        log.warn("snapshot path allocation failed: {s}", .{@errorName(err)});
        return;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json }) catch |err| {
        log.warn("cannot write snapshot {s}: {s}", .{ tmp_path, @errorName(err) });
        return;
    };
    Io.Dir.cwd().rename(tmp_path, Io.Dir.cwd(), path, io) catch |err| {
        log.warn("cannot move snapshot into place at {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    log.debug("snapshot saved: {d} sessions, {d} files", .{ state.sessions.len, files.len });
}

fn mtimeNs(stat: anytype) i64 {
    return std.math.lossyCast(i64, stat.mtime.nanoseconds);
}

fn ensureDir(io: Io, path: []const u8) void {
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
        if (end > 0) {
            Io.Dir.cwd().createDir(io, path[0..end], .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => log.debug("mkdir {s} failed: {s}", .{ path[0..end], @errorName(err) }),
            };
        }
        end += 1;
    }
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const parser = @import("../core/parser.zig");
const claude_dirs = @import("claude_dirs.zig");

const TestSink = struct {
    gpa: Allocator,
    io: Io,
    index: *index_mod.Index,

    pub fn onLine(s: *TestSink, path: []const u8, line: []const u8) void {
        _ = path;
        const events = parser.parseLine(s.gpa, line) catch return;
        defer s.gpa.free(events);
        for (events) |e| s.index.applyEvent(s.io, e) catch {};
    }
};

test "snapshot round trip restores aggregates and skips consumed bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try claude_dirs.makePathForTest(tmp.dir, io, "root/projects/-w");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-w/s1.jsonl", .data =
        \\{"type":"user","message":{"content":"first"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/w","sessionId":"s1"}
        \\{"type":"assistant","message":{"model":"claude-opus-4-8","id":"m1","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":20}},"timestamp":"2026-07-07T10:00:01Z","cwd":"/w","sessionId":"s1"}
        \\
    });
    const root = try tmp.dir.realPathFileAlloc(io, "root", gpa);
    defer gpa.free(root);
    const snap_path = try std.fs.path.join(gpa, &.{ root, "cache", "snapshot.json" });
    defer gpa.free(snap_path);

    // First run: full backfill, then save.
    {
        var ix = try index_mod.Index.init(gpa, 16);
        defer ix.deinit();
        var watcher = watcher_mod.Watcher.init(gpa, io, root, .{ .start_at_end = false });
        defer watcher.deinit();
        var sink = TestSink{ .gpa = gpa, .io = io, .index = &ix };
        try watcher.tick(&sink);
        save(gpa, io, snap_path, &ix, &watcher);
    }

    // Second run: restore, append one line, tick — no double counting.
    var ix = try index_mod.Index.init(gpa, 16);
    defer ix.deinit();
    var watcher = watcher_mod.Watcher.init(gpa, io, root, .{ .start_at_end = false });
    defer watcher.deinit();
    try testing.expect(load(gpa, io, snap_path, &ix, &watcher));

    {
        var file = try tmp.dir.openFile(io, "root/projects/-w/s1.jsonl", .{ .mode = .write_only });
        defer file.close(io);
        const stat = try file.stat(io);
        const extra =
            \\{"type":"assistant","message":{"model":"claude-opus-4-8","id":"m2","content":[{"type":"text","text":"more"}],"usage":{"input_tokens":5,"output_tokens":7}},"timestamp":"2026-07-07T10:00:02Z","cwd":"/w","sessionId":"s1"}
        ;
        try file.writePositionalAll(io, extra ++ "\n", stat.size);
    }
    var sink = TestSink{ .gpa = gpa, .io = io, .index = &ix };
    try watcher.tick(&sink);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = try ix.listSessions(io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqual(@as(u32, 1), sessions[0].prompt_count);
    try testing.expectEqual(@as(u64, 15), sessions[0].tokens.input);
    try testing.expectEqual(@as(u64, 27), sessions[0].tokens.output);
    try testing.expectEqualStrings("claude-opus-4-8", sessions[0].model);
}

test "snapshot is rejected when a transcript shrinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try claude_dirs.makePathForTest(tmp.dir, io, "root/projects/-w");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-w/s1.jsonl", .data =
        \\{"type":"user","message":{"content":"first prompt with some length"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/w","sessionId":"s1"}
        \\
    });
    const root = try tmp.dir.realPathFileAlloc(io, "root", gpa);
    defer gpa.free(root);
    const snap_path = try std.fs.path.join(gpa, &.{ root, "cache", "snapshot.json" });
    defer gpa.free(snap_path);

    {
        var ix = try index_mod.Index.init(gpa, 16);
        defer ix.deinit();
        var watcher = watcher_mod.Watcher.init(gpa, io, root, .{ .start_at_end = false });
        defer watcher.deinit();
        var sink = TestSink{ .gpa = gpa, .io = io, .index = &ix };
        try watcher.tick(&sink);
        save(gpa, io, snap_path, &ix, &watcher);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-w/s1.jsonl", .data = "{}\n" });

    var ix = try index_mod.Index.init(gpa, 16);
    defer ix.deinit();
    var watcher = watcher_mod.Watcher.init(gpa, io, root, .{ .start_at_end = false });
    defer watcher.deinit();
    try testing.expect(!load(gpa, io, snap_path, &ix, &watcher));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = try ix.listSessions(io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 0), sessions.len);
}

test "missing snapshot file loads nothing" {
    var ix = try index_mod.Index.init(testing.allocator, 8);
    defer ix.deinit();
    var watcher = watcher_mod.Watcher.init(testing.allocator, testing.io, "/nonexistent", .{});
    defer watcher.deinit();
    try testing.expect(!load(testing.allocator, testing.io, "/nonexistent/snapshot.json", &ix, &watcher));
}
