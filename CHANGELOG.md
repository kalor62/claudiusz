# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-07-13

### Added

- Live view now tracks each session's current working directory. The box title
  stays the launch project (stable identity), and a `folder` line appears under
  the status whenever the session `cd`s elsewhere — shown as `./sub` when nested
  under the launch folder, or the full path otherwise. The sessions detail panel
  gains a matching `current dir` field, and `current_dir` is exposed on the
  `/api/sessions` read model. Subagent working directories (e.g. tool-result
  staging) are excluded so they can't hijack the session's folder.

## [0.2.0] - 2026-07-08

### Added

- Startup snapshot cache: index aggregates and watcher offsets persist to the
  OS cache dir and are restored after one `stat()` per transcript, so warm
  starts take milliseconds instead of re-parsing the full history. Transcripts
  are validated per file (append-only offsets, mtime); any contradiction falls
  back to a full rebuild. `--no-cache` forces the rebuild.
- Estimated USD cost per session (`core/pricing.zig`): per-model rates with
  cache read/write factors, shown in live boxes.
- Project config audit now counts skills, agents, MCP servers and enabled
  plugins, and scores quality 0–5 (CLAUDE.md, settings, skills, agents, MCP).
  CLAUDE.md only counts when it carries real content — empty files and bare
  markdown headers score nothing.
- HELP tab: a built-in four-page user manual in the same quarter-screen box
  grid as LIVE (keys, live view, HTTP API usage, cost/limits/CLI), digit keys
  jump between pages.
- STATS: weekly usage history read from Claude Code's own `stats-cache.json`
  (messages, sessions, tool calls, tokens and top models per week, lifetime
  totals) — reaches further back than the transcripts themselves.
- STATS: optional weekly limit progress bars driven by user-calibrated budgets
  in `<root>/claudiusz.json` (`weekly_limits`, `week_reset_day`); the section
  stays hidden when unconfigured (e.g. enterprise plans without weekly caps).

### Changed

- Live tab rebuilt as a fixed 2×2 mission-control grid: each active session is
  one quarter-screen box showing only the vitals — tokens, estimated cost,
  prompt count, session length, and the project's Claude config (quality bar,
  CLAUDE.md ✓/✗, skills/agents/MCP/plugins counts). More than four active
  sessions paginate with digit keys; a working session shows a pulsing line
  instead of a status label. The raw activity feed, today strip and idle list
  are gone.
- Header tabs are now unnumbered (LIVE / SESSIONS / TIPS / PROJECTS / STATS /
  HELP); digit shortcuts switch tabs, or pages on paginated views.
- Session status is authoritative from Claude Code's state file (`busy` means
  working even mid-long-turn); the stale-heartbeat downgrade is gone.
- `SessionSummary.status` is a typed enum end-to-end (same JSON wire format).
- Expensive TUI data (audits, tips, stats) refreshes on a 3s TTL; one session
  snapshot per frame is shared by the header and views.

### Fixed

- TUI quit no longer tears the daemon down under running threads (collector
  is stopped and joined; process exit reclaims detached HTTP threads).
- Broadcaster subscriber lifecycle: no leak on subscribe failure, deinit
  destroys remaining subscribers under the lock.
- Map insertions no longer leave dangling borrowed keys on allocation
  failure (index sessions, usage dedup, tool counts, watcher file states).
- Tool detail truncation is UTF-8-safe; API JSON can no longer carry split
  code points.
- Watcher stats files by path and opens only grown ones; TUI logs route to
  /tmp/claudiusz-tui.log instead of corrupting the raw-mode screen.

### Added

- Project scaffolding: build system, CI, repository hygiene.
- Transcript collector: tails `~/.claude/projects/**/*.jsonl` (300 ms stat polling).
- JSONL parser normalizing Claude Code records into typed events.
- `claudiusz tail` command printing the live event stream to stdout.
- `--root` and `--port` flags for running isolated instances per config root.
- `claudiusz serve`: headless daemon with a loopback HTTP API.
- In-memory index: per-session aggregates (tokens deduped by message id, tool
  usage, titles) plus a ring buffer of recent events.
- Session liveness: `working` / `waiting_for_user` / `idle` / `done` derived
  from `sessions/<pid>.json` heartbeats and process checks.
- Endpoints: `/api/health`, `/api/sessions`, `/api/sessions/:id`,
  `/api/sessions/:id/tail?n=`, and `/api/stream` (SSE live feed with
  `session_status` change events).
- Daily usage aggregation and `/api/stats?range=Nd`: totals, per-day rows,
  top tools, top projects, hour histogram.
- `/api/digest?range=Nd`: compact markdown digest (totals, per-day/project
  tables, friction signals, verbatim prompt samples) built for LLM analysis.
- Stats tab in the TUI with a prompts-per-day sparkline.
- Tips engine (`/api/tips` + Tips tab): six starter rules — missing CLAUDE.md,
  permission friction, large prompt pastes, failing hooks, tool error loops,
  unknown transcript records.
- Project audit (`/api/projects` + Projects tab): per-project check for
  CLAUDE.md, `.claude/settings.json` and the local permission allowlist.
- Built-in TUI (default command): Live tab with per-project session cards and
  a real-time event feed, Sessions tab with a navigable table and a
  full-detail panel (tokens breakdown, tool usage, recent events). Flicker-free
  diff renderer, 256-color, resize-aware. POSIX terminals only.
