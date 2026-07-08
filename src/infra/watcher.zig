//! Tails Claude Code transcript files. Polling based (stat size every tick):
//! portable across macOS/Linux/Windows with zero platform code. Native change
//! notification (FSEvents/inotify) can later slot in behind the same tick API.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const claude_dirs = @import("claude_dirs.zig");

const log = std.log.scoped(.watcher);

/// Upper bound of bytes read from one file in one tick. A backlogged file
/// catches up across consecutive ticks instead of stalling the loop.
pub const max_read_per_tick: u64 = 16 * 1024 * 1024;

pub const Options = struct {
    /// When true (live tailing), files existing at startup are seeded at EOF
    /// so only fresh activity is reported. When false, full history replays.
    start_at_end: bool = true,
};

/// Polls a Claude config root and feeds every complete new transcript line to
/// a handler. Not thread-safe; owned by the collector thread.
pub const Watcher = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    options: Options,
    files: std.StringHashMap(FileState),
    first_tick_done: bool = false,

    const FileState = struct {
        offset: u64 = 0,
        /// Set when a line exceeded `max_read_per_tick`; bytes are discarded
        /// until the next newline to regain line-boundary sync.
        skip_to_newline: bool = false,
    };

    pub fn init(gpa: Allocator, io: Io, root: []const u8, options: Options) Watcher {
        return .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .options = options,
            .files = .init(gpa),
        };
    }

    pub fn deinit(w: *Watcher) void {
        var it = w.files.keyIterator();
        while (it.next()) |key| w.gpa.free(key.*);
        w.files.deinit();
        w.* = undefined;
    }

    pub const OffsetEntry = struct {
        path: []const u8,
        offset: u64,
        skip_to_newline: bool = false,
    };

    /// Pre-seeds a file's consumed offset (snapshot restore). Must run before
    /// the first tick; an already-tracked path keeps its existing state.
    pub fn seedOffset(w: *Watcher, entry: OffsetEntry) Allocator.Error!void {
        if (w.files.contains(entry.path)) return;
        const key = try w.gpa.dupe(u8, entry.path);
        errdefer w.gpa.free(key);
        try w.files.put(key, .{ .offset = entry.offset, .skip_to_newline = entry.skip_to_newline });
    }

    /// Arena-copied view of every tracked file's consumed offset.
    pub fn exportOffsets(w: *const Watcher, arena: Allocator) Allocator.Error![]OffsetEntry {
        var out = try arena.alloc(OffsetEntry, w.files.count());
        var it = w.files.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            out[i] = .{
                .path = try arena.dupe(u8, entry.key_ptr.*),
                .offset = entry.value_ptr.offset,
                .skip_to_newline = entry.value_ptr.skip_to_newline,
            };
        }
        return out;
    }

    /// One poll cycle. `handler` must provide:
    /// `fn onLine(handler, path: []const u8, line: []const u8) void`.
    /// The `line` slice is only valid during the call.
    pub fn tick(w: *Watcher, handler: anytype) Allocator.Error!void {
        const paths = try claude_dirs.collectTranscripts(w.gpa, w.io, w.root);
        defer claude_dirs.freePaths(w.gpa, paths);

        for (paths) |path| {
            const state = w.files.getPtr(path) orelse blk: {
                // Dupe before inserting: the map must never hold a key
                // borrowed from this tick's path list.
                const key = try w.gpa.dupe(u8, path);
                errdefer w.gpa.free(key);
                var initial = FileState{};
                if (w.options.start_at_end and !w.first_tick_done) {
                    initial.offset = fileSize(w.io, path) orelse 0;
                }
                try w.files.put(key, initial);
                break :blk w.files.getPtr(key).?;
            };
            w.readNew(path, state, handler);
        }
        w.first_tick_done = true;
    }

    fn readNew(w: *Watcher, path: []const u8, state: *FileState, handler: anytype) void {
        // statFile first: unchanged files (the common case) cost one syscall
        // per tick instead of open+fstat+close.
        const size = fileSize(w.io, path) orelse return;
        if (size < state.offset) {
            // Transcripts are append-only; shrinkage means replacement. Start over.
            log.debug("{s} shrank, resetting offset", .{path});
            state.* = .{};
        }
        if (size == state.offset) return;

        var file = Io.Dir.cwd().openFile(w.io, path, .{}) catch |err| {
            log.debug("cannot open {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        defer file.close(w.io);

        const want: usize = @intCast(@min(size - state.offset, max_read_per_tick));
        const buf = w.gpa.alloc(u8, want) catch |err| {
            log.warn("cannot allocate {d} bytes for {s}: {s}", .{ want, path, @errorName(err) });
            return;
        };
        defer w.gpa.free(buf);

        const read_len = file.readPositionalAll(w.io, buf, state.offset) catch |err| {
            log.debug("cannot read {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        processChunk(path, state, buf[0..read_len], handler);
    }

    fn processChunk(path: []const u8, state: *FileState, data: []const u8, handler: anytype) void {
        var consumed: usize = 0;

        if (state.skip_to_newline) {
            if (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
                consumed = nl + 1;
                state.skip_to_newline = false;
            } else {
                state.offset += data.len;
                return;
            }
        }

        while (std.mem.indexOfScalarPos(u8, data, consumed, '\n')) |nl| {
            handler.onLine(path, data[consumed..nl]);
            consumed = nl + 1;
        }

        if (consumed == 0 and data.len >= max_read_per_tick) {
            // A line longer than the per-tick budget would deadlock the tail; drop and resync.
            log.warn("line exceeding {d} bytes in {s}, skipping it", .{ max_read_per_tick, path });
            state.skip_to_newline = true;
            state.offset += data.len;
            return;
        }
        state.offset += consumed;
    }

    fn fileSize(io: Io, path: []const u8) ?u64 {
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
            log.debug("cannot stat {s}: {s}", .{ path, @errorName(err) });
            return null;
        };
        return stat.size;
    }
};

// --- tests ---------------------------------------------------------------

const testing = std.testing;

const CollectingHandler = struct {
    lines: std.ArrayList([]const u8) = .empty,
    gpa: Allocator,

    pub fn onLine(h: *CollectingHandler, path: []const u8, line: []const u8) void {
        _ = path;
        const copy = h.gpa.dupe(u8, line) catch return;
        h.lines.append(h.gpa, copy) catch h.gpa.free(copy);
    }

    fn deinit(h: *CollectingHandler) void {
        for (h.lines.items) |l| h.gpa.free(l);
        h.lines.deinit(h.gpa);
    }
};

test "watcher reports only complete appended lines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try claude_dirs.makePathForTest(tmp.dir, io, "root/projects/-p");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-p/s.jsonl", .data = "old line\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    var handler = CollectingHandler{ .gpa = testing.allocator };
    defer handler.deinit();
    var watcher = Watcher.init(testing.allocator, io, root, .{ .start_at_end = true });
    defer watcher.deinit();

    // First tick seeds at EOF: pre-existing content is skipped.
    try watcher.tick(&handler);
    try testing.expectEqual(@as(usize, 0), handler.lines.items.len);

    {
        var file = try tmp.dir.openFile(io, "root/projects/-p/s.jsonl", .{ .mode = .write_only });
        defer file.close(io);
        try file.writePositionalAll(io, "new line\npart", 9);
    }
    try watcher.tick(&handler);
    try testing.expectEqual(@as(usize, 1), handler.lines.items.len);
    try testing.expectEqualStrings("new line", handler.lines.items[0]);

    {
        var file = try tmp.dir.openFile(io, "root/projects/-p/s.jsonl", .{ .mode = .write_only });
        defer file.close(io);
        try file.writePositionalAll(io, "ial\n", 22);
    }
    try watcher.tick(&handler);
    try testing.expectEqual(@as(usize, 2), handler.lines.items.len);
    try testing.expectEqualStrings("partial", handler.lines.items[1]);
}

test "watcher with start_at_end=false replays existing content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try claude_dirs.makePathForTest(tmp.dir, io, "root/projects/-p");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/projects/-p/s.jsonl", .data = "a\nb\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    var handler = CollectingHandler{ .gpa = testing.allocator };
    defer handler.deinit();
    var watcher = Watcher.init(testing.allocator, io, root, .{ .start_at_end = false });
    defer watcher.deinit();

    try watcher.tick(&handler);
    try testing.expectEqual(@as(usize, 2), handler.lines.items.len);
    try testing.expectEqualStrings("a", handler.lines.items[0]);
    try testing.expectEqualStrings("b", handler.lines.items[1]);
}
