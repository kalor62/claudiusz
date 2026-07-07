//! claudiusz — real-time observability for Claude Code.
//!
//! Library root. The `claudiusz` binary is a thin CLI over this module; every
//! feature (collector, parser, index, API, digest) is usable as a library.

const std = @import("std");

pub const version = "0.1.0";

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const event = @import("core/event.zig");
pub const parser = @import("core/parser.zig");
pub const time = @import("core/time.zig");
pub const claude_dirs = @import("infra/claude_dirs.zig");
pub const Watcher = @import("infra/watcher.zig").Watcher;

test {
    std.testing.refAllDecls(@This());
}
