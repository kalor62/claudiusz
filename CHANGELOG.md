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
