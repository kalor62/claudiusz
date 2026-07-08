# claudiusz

Real-time observability for [Claude Code](https://claude.com/claude-code). Watch what you prompt and what Claude does — live, in your terminal — and expose the same data over a local HTTP API for any frontend you want to build.

Claude Code writes full session transcripts to `~/.claude/projects/**/*.jsonl`. `claudiusz` tails those files, normalizes them into a stream of events, and gives you:

- **Live TUI** — open sessions, current prompts and tool calls per project, token usage per session, navigable session details.
- **Local HTTP API + SSE stream** — build your own dashboard on top (`/api/stream`, `/api/sessions`, `/api/stats`, …).
- **LLM digest** (`/api/digest`) — a compact markdown summary of your recent usage, designed to be handed to Claude for "how can I improve my workflow" analysis.
- **Tips & project audit** — heuristics that spot friction: missing `CLAUDE.md`, repeated permission prompts, failing hooks, error loops.

Everything runs locally. Nothing leaves your machine. The API binds to `127.0.0.1` only.

## Install

### From a release (no toolchain needed)

Grab the archive for your platform from [Releases](https://github.com/kalor62/claudiusz/releases), then:

```sh
tar -xzf claudiusz-*-macos-arm64.tar.gz
xattr -d com.apple.quarantine claudiusz   # macOS: clear the Gatekeeper quarantine
mv claudiusz /usr/local/bin/
claudiusz
```

Releases currently ship a macOS arm64 binary; on other platforms build from source below.

### From source

Requires [Zig](https://ziglang.org) 0.16+.

```sh
git clone https://github.com/kalor62/claudiusz && cd claudiusz
zig build -Doptimize=ReleaseSafe
./zig-out/bin/claudiusz
```

## Usage

```sh
claudiusz                # TUI + API on :8899, watching ~/.claude
claudiusz serve          # headless: API only
claudiusz tail           # debug: print normalized events to stdout
claudiusz --root ~/.claude-enterprise --port 8900   # isolated second instance
```

Run one instance per Claude Code config root — stats stay isolated per instance.

## API

| Endpoint | Description |
| --- | --- |
| `GET /api/sessions` | All sessions: project, status (live/waiting/done), model, tokens |
| `GET /api/sessions/:id` | Full session detail: tokens breakdown, tool calls, subagents, tasks |
| `GET /api/sessions/:id/tail?n=50` | Last n events of a session |
| `GET /api/stream` | SSE live stream: prompts, assistant output, tool calls/results |
| `GET /api/stats?range=7d` | Aggregated usage stats |
| `GET /api/tips` | Workflow improvement suggestions |
| `GET /api/projects` | Project audit results |
| `GET /api/digest?range=7d` | LLM-ready markdown digest |

## Privacy

`claudiusz` reads local Claude Code transcript files and never sends data anywhere. The HTTP server listens on loopback only. Thinking-block signatures and pasted clipboard contents are never exposed through the API.

## License

MIT
