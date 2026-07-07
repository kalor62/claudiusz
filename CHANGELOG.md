# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Built-in TUI (default command): Live tab with per-project session cards and
  a real-time event feed, Sessions tab with a navigable table and a
  full-detail panel (tokens breakdown, tool usage, recent events). Flicker-free
  diff renderer, 256-color, resize-aware. POSIX terminals only.
