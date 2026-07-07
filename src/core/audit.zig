//! Project audit model: what a well-configured Claude Code project has and
//! what this one is missing. Pure data — the filesystem walk lives in
//! infra/project_scanner.zig.

const std = @import("std");

pub const ProjectAudit = struct {
    project: []const u8,
    cwd: []const u8,
    /// False when the directory no longer exists on disk.
    exists: bool = false,
    has_claude_md: bool = false,
    has_claude_dir: bool = false,
    has_settings: bool = false,
    has_settings_local: bool = false,
    sessions_seen: u32 = 0,
    prompts_seen: u32 = 0,
    last_activity_ms: i64 = 0,
    long_prompt_sessions: u32 = 0,
};
