//! Help view: the built-in user manual. Same 2×2 quarter-screen box grid as
//! the live view, split into pages the user jumps between with digit keys.

const std = @import("std");
const app_mod = @import("../app.zig");
const widgets = @import("../widgets.zig");
const render = @import("../render.zig");

const Frame = app_mod.Frame;
const theme = widgets.theme;

const Line = struct {
    key: []const u8 = "",
    text: []const u8,
};

const Box = struct {
    title: []const u8,
    lines: []const Line,
};

const pages = [_][4]Box{
    .{
        .{ .title = "what is claudiusz", .lines = &.{
            .{ .text = "Real-time observability for Claude" },
            .{ .text = "Code. It tails the transcripts in" },
            .{ .text = "~/.claude and shows what you and" },
            .{ .text = "Claude are doing — live." },
            .{ .text = "" },
            .{ .text = "Everything stays on this machine;" },
            .{ .text = "the API binds to 127.0.0.1 only." },
        } },
        .{ .title = "keys", .lines = &.{
            .{ .key = "q", .text = "quit (or close detail)" },
            .{ .key = "← →", .text = "switch tabs" },
            .{ .key = "1-9", .text = "tabs; pages on LIVE & HELP" },
            .{ .key = "j / k", .text = "move selection" },
            .{ .key = "⏎", .text = "open session detail" },
            .{ .key = "esc", .text = "close detail" },
        } },
        .{ .title = "tabs", .lines = &.{
            .{ .key = "LIVE", .text = "active sessions as boxes" },
            .{ .key = "SESSIONS", .text = "all sessions, ⏎ for detail" },
            .{ .key = "TIPS", .text = "workflow suggestions" },
            .{ .key = "PROJECTS", .text = "per-project config audit" },
            .{ .key = "STATS", .text = "usage report + weekly history" },
            .{ .key = "HELP", .text = "this manual" },
        } },
        .{ .title = "header counters", .lines = &.{
            .{ .key = "● N", .text = "sessions working right now" },
            .{ .key = "◐ N", .text = "waiting for your input" },
            .{ .key = "○ N", .text = "idle, process still alive" },
            .{ .key = "⟳", .text = "scanning history at startup" },
            .{ .text = "" },
            .{ .text = "Closed (done) sessions are only" },
            .{ .text = "listed on the SESSIONS tab." },
        } },
    },
    .{
        .{ .title = "live: session boxes", .lines = &.{
            .{ .text = "Each box is one active session and" },
            .{ .text = "always takes a quarter of the" },
            .{ .text = "screen. With more than 4 active" },
            .{ .text = "sessions the view paginates:" },
            .{ .text = "" },
            .{ .key = "1-9", .text = "jump to that page" },
        } },
        .{ .title = "live: box fields", .lines = &.{
            .{ .key = "tokens", .text = "in / out / cache read" },
            .{ .key = "cost", .text = "estimated USD for session" },
            .{ .key = "prompts", .text = "prompts you sent" },
            .{ .key = "session", .text = "first to last activity" },
            .{ .text = "" },
            .{ .text = "Top right shows the model." },
        } },
        .{ .title = "live: statuses", .lines = &.{
            .{ .key = "──●──", .text = "pulse line: working" },
            .{ .key = "◐", .text = "WAITING, blocked on you" },
            .{ .key = "○", .text = "idle, nothing happening" },
            .{ .text = "" },
            .{ .text = "A waiting session also shows what" },
            .{ .text = "it waits for (e.g. permission)." },
        } },
        .{ .title = "live: project config", .lines = &.{
            .{ .key = "quality", .text = "1 pt each, 5 total:" },
            .{ .text = "  CLAUDE.md, settings, skills," },
            .{ .text = "  agents, MCP servers" },
            .{ .key = "CLAUDE.md", .text = "✓ only for real content;" },
            .{ .text = "  empty files and bare headers" },
            .{ .text = "  count as ✗" },
        } },
    },
    .{
        .{ .title = "api: basics", .lines = &.{
            .{ .text = "A plain JSON HTTP API runs next to" },
            .{ .text = "the TUI — build any frontend on it." },
            .{ .text = "" },
            .{ .key = "address", .text = "http://127.0.0.1:8899" },
            .{ .key = "auth", .text = "none; loopback only" },
            .{ .key = "headless", .text = "claudiusz serve" },
            .{ .text = "" },
            .{ .text = "The port is in the footer; change" },
            .{ .text = "it with --port <n>." },
        } },
        .{ .title = "api: endpoints", .lines = &.{
            .{ .key = "/api/sessions", .text = "all sessions" },
            .{ .key = "/api/sessions/:id", .text = "one session" },
            .{ .key = "/api/sessions/:id/tail", .text = "last events" },
            .{ .key = "/api/stream", .text = "live SSE feed" },
            .{ .key = "/api/stats?range=7d", .text = "usage report" },
            .{ .key = "/api/tips", .text = "suggestions" },
            .{ .key = "/api/projects", .text = "config audit" },
            .{ .key = "/api/digest", .text = "LLM-ready markdown" },
        } },
        .{ .title = "api: live stream", .lines = &.{
            .{ .text = "/api/stream is Server-Sent Events:" },
            .{ .text = "prompts, assistant output, tool" },
            .{ .text = "calls and session status changes" },
            .{ .text = "as they happen, plus ping frames." },
            .{ .text = "" },
            .{ .key = "curl", .text = "curl -N :8899/api/stream" },
            .{ .key = "browser", .text = "new EventSource(url)" },
        } },
        .{ .title = "api: from your app", .lines = &.{
            .{ .text = "Poll JSON or subscribe to the" },
            .{ .text = "stream — no SDK needed:" },
            .{ .text = "" },
            .{ .text = "curl :8899/api/sessions" },
            .{ .text = "curl \":8899/api/stats?range=14d\"" },
            .{ .text = "" },
            .{ .text = "Feed /api/digest to Claude and ask" },
            .{ .text = "how to improve your workflow." },
        } },
    },
    .{
        .{ .title = "cost & weekly limits", .lines = &.{
            .{ .key = "opus", .text = "$5 in / $25 out per MTok" },
            .{ .key = "sonnet", .text = "$3 / $15" },
            .{ .key = "haiku", .text = "$1 / $5" },
            .{ .key = "fable", .text = "$10 / $50" },
            .{ .key = "cache", .text = "read 0.1x, write 1.25x" },
            .{ .text = "An estimate — not your invoice." },
            .{ .text = "" },
            .{ .text = "STATS shows weekly limit bars when" },
            .{ .text = "~/.claude/claudiusz.json exists:" },
            .{ .text = "{\"weekly_limits\":{\"all\":12000000," },
            .{ .text = " \"fable\":6000000}," },
            .{ .text = " \"week_reset_day\":\"thu\"}" },
            .{ .text = "Calibrate budgets against /usage." },
        } },
        .{ .title = "snapshot cache", .lines = &.{
            .{ .text = "Startup restores aggregates from a" },
            .{ .text = "cache and re-reads only transcripts" },
            .{ .text = "that changed, so restarts are" },
            .{ .text = "instant. Force a full rebuild:" },
            .{ .text = "" },
            .{ .key = "--no-cache", .text = "rebuild from disk" },
        } },
        .{ .title = "cli", .lines = &.{
            .{ .key = "claudiusz", .text = "TUI + API (default)" },
            .{ .key = "serve", .text = "headless API only" },
            .{ .key = "tail", .text = "print event stream" },
            .{ .key = "--root <dir>", .text = "watch another root" },
            .{ .key = "--port <n>", .text = "API port (8899)" },
        } },
        .{ .title = "multiple instances", .lines = &.{
            .{ .text = "Run one instance per Claude config" },
            .{ .text = "root; stats and caches stay fully" },
            .{ .text = "isolated per instance:" },
            .{ .text = "" },
            .{ .text = "claudiusz --root ~/.claude-work \\" },
            .{ .text = "          --port 8900" },
        } },
    },
};

pub const page_count = pages.len;

pub fn draw(frame: Frame) void {
    const area = frame.area;
    const page = @min(frame.help_page, page_count - 1);
    const cell_w = area.width / 2;
    const cell_h = area.height / 2;

    for (pages[page], 0..) |box, i| {
        const col: u16 = @intCast(i % 2);
        const row: u16 = @intCast(i / 2);
        const rect = widgets.Rect{
            .x = area.x + col * cell_w,
            .y = area.y + row * cell_h,
            .width = if (col == 1) area.width - cell_w else cell_w,
            .height = if (row == 1) area.height - cell_h else cell_h,
        };
        drawManualBox(frame, rect, box);
    }
    drawPageIndicator(frame, page);
}

fn drawManualBox(frame: Frame, rect: widgets.Rect, box: Box) void {
    const screen = frame.screen;
    widgets.drawBox(screen, rect, box.title, theme.frame);
    const inner = rect.inner();
    if (inner.width < 20 or inner.height < 1) return;

    const key_column = longestKey(box.lines);
    var y = inner.y;
    for (box.lines) |line| {
        if (y >= inner.y + inner.height) return;
        var x: u16 = 1;
        if (line.key.len > 0) {
            _ = screen.writeText(inner.x + x, y, line.key, theme.accent_bold, inner.width -| x);
            x += key_column + 2;
        }
        _ = screen.writeText(inner.x + x, y, line.text, theme.text, inner.width -| x);
        y += 1;
    }
}

/// Column width shared by every keyed line in a box, so values align.
fn longestKey(lines: []const Line) u16 {
    var longest: usize = 0;
    for (lines) |line| longest = @max(longest, displayWidth(line.key));
    return @intCast(longest);
}

/// Key labels mix ASCII with a few single-column glyphs (●, ⏎, ←); counting
/// UTF-8 sequences instead of bytes keeps the columns aligned.
fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    for (text) |byte| {
        if (byte & 0b1100_0000 != 0b1000_0000) width += 1;
    }
    return width;
}

fn drawPageIndicator(frame: Frame, page: usize) void {
    const area = frame.area;
    var buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " page {d}/{d} · press 1-{d} ", .{ page + 1, page_count, page_count }) catch return;
    if (area.width <= text.len + 4) return;
    const y = area.y + area.height - 1;
    _ = frame.screen.writeText(@intCast(area.x + area.width - text.len - 2), y, text, theme.amber, @intCast(text.len));
}
