# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Live tab rebuilt as a mission-control dashboard: large double-framed panels
  for active sessions (status, current step, last prompt, token stats) with
  recent work grouped into human-scale steps (`Edit ×3`, failures marked ✗),
  a today-totals strip, and a compact idle-session list — replacing the raw
  event feed. Phosphor-green theme with cyan/amber accents.
- Header tabs are now unnumbered (LIVE / SESSIONS / TIPS / PROJECTS / STATS);
  1-5 shortcuts unchanged.
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
