//! Runtime configuration resolved from CLI options and the environment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");

pub const Config = struct {
    /// Claude config root being watched (e.g. /Users/x/.claude).
    root: []const u8,
    /// HTTP API port, loopback only.
    port: u16,
    /// Transcript poll cadence.
    poll_interval_ms: u64 = 300,
};

pub const Error = error{HomeNotSet} || Allocator.Error;

/// Resolves the effective configuration. `arena` must outlive the config.
pub fn resolve(arena: Allocator, environ: *const std.process.Environ.Map, options: cli.Options) Error!Config {
    const root = options.root orelse blk: {
        const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse return error.HomeNotSet;
        break :blk try std.fs.path.join(arena, &.{ home, ".claude" });
    };
    return .{ .root = root, .port = options.port };
}
