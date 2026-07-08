//! Runtime configuration resolved from CLI options and the environment.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");

pub const Config = struct {
    /// Claude config root being watched (e.g. /Users/x/.claude).
    root: []const u8,
    /// HTTP API port, loopback only.
    port: u16,
    /// Transcript poll cadence.
    poll_interval_ms: u64 = 300,
    /// Index snapshot file for fast restarts; null disables the cache.
    cache_path: ?[]const u8 = null,
};

pub const Error = error{HomeNotSet} || Allocator.Error;

/// Resolves the effective configuration. `arena` must outlive the config.
pub fn resolve(arena: Allocator, environ: *const std.process.Environ.Map, options: cli.Options) Error!Config {
    const root = options.root orelse blk: {
        const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse return error.HomeNotSet;
        break :blk try std.fs.path.join(arena, &.{ home, ".claude" });
    };
    const cache_path = if (options.no_cache) null else try cachePath(arena, environ, root);
    return .{ .root = root, .port = options.port, .cache_path = cache_path };
}

/// OS cache dir + a root-derived file name, so `--root` instances stay
/// isolated. Null when no cache location can be derived from the environment.
fn cachePath(arena: Allocator, environ: *const std.process.Environ.Map, root: []const u8) Allocator.Error!?[]const u8 {
    const base: []const u8 = switch (builtin.os.tag) {
        .windows => environ.get("LOCALAPPDATA") orelse return null,
        .macos => blk: {
            const home = environ.get("HOME") orelse return null;
            break :blk try std.fs.path.join(arena, &.{ home, "Library", "Caches" });
        },
        else => environ.get("XDG_CACHE_HOME") orelse blk: {
            const home = environ.get("HOME") orelse return null;
            break :blk try std.fs.path.join(arena, &.{ home, ".cache" });
        },
    };
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x:0>16}.json", .{std.hash.Wyhash.hash(0, root)}) catch unreachable;
    return try std.fs.path.join(arena, &.{ base, "claudiusz", name });
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "cache path derives from environment and honors --no-cache" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ = std.process.Environ.Map.init(arena);
    try environ.put("HOME", "/home/u");

    const cfg = try resolve(arena, &environ, .{ .root = "/data/claude" });
    try testing.expect(cfg.cache_path != null);
    try testing.expect(std.mem.indexOf(u8, cfg.cache_path.?, "claudiusz") != null);
    try testing.expect(std.mem.endsWith(u8, cfg.cache_path.?, ".json"));

    const other = try resolve(arena, &environ, .{ .root = "/data/other" });
    try testing.expect(!std.mem.eql(u8, cfg.cache_path.?, other.cache_path.?));

    const disabled = try resolve(arena, &environ, .{ .root = "/data/claude", .no_cache = true });
    try testing.expectEqual(@as(?[]const u8, null), disabled.cache_path);
}
