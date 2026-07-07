//! claudiusz — real-time observability for Claude Code.
//!
//! Library root. The `claudiusz` binary is a thin CLI over this module; every
//! feature (collector, parser, index, API, digest) is usable as a library.

const std = @import("std");

pub const version = "0.1.0";

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const daemon = @import("daemon.zig");
pub const event = @import("core/event.zig");
pub const parser = @import("core/parser.zig");
pub const session = @import("core/session.zig");
pub const index = @import("core/index.zig");
pub const stats = @import("core/stats.zig");
pub const digest = @import("core/digest.zig");
pub const tips = @import("core/tips.zig");
pub const audit = @import("core/audit.zig");
pub const time = @import("core/time.zig");
pub const project_scanner = @import("infra/project_scanner.zig");
pub const api = @import("api/handlers.zig");
pub const claude_dirs = @import("infra/claude_dirs.zig");
pub const liveness = @import("infra/liveness.zig");
pub const broadcast = @import("infra/broadcast.zig");
pub const http = @import("infra/http.zig");
pub const Watcher = @import("infra/watcher.zig").Watcher;
pub const tui = if (@import("builtin").os.tag == .windows) struct {} else struct {
    pub const app = @import("tui/app.zig");
    pub const render = @import("tui/render.zig");
    pub const widgets = @import("tui/widgets.zig");
};

test {
    std.testing.refAllDecls(@This());
}
