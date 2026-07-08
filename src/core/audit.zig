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
    skill_count: u32 = 0,
    agent_count: u32 = 0,
    mcp_server_count: u32 = 0,
    plugin_count: u32 = 0,
    sessions_seen: u32 = 0,
    prompts_seen: u32 = 0,
    last_activity_ms: i64 = 0,
    long_prompt_sessions: u32 = 0,

    pub const quality_max: u8 = 5;

    /// 0..quality_max — one point each for CLAUDE.md, settings, skills,
    /// agents and MCP servers being present.
    pub fn qualityScore(a: ProjectAudit) u8 {
        var score: u8 = 0;
        if (a.has_claude_md) score += 1;
        if (a.has_settings or a.has_settings_local) score += 1;
        if (a.skill_count > 0) score += 1;
        if (a.agent_count > 0) score += 1;
        if (a.mcp_server_count > 0) score += 1;
        return score;
    }
};
