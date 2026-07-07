# Contributing

## Setup

Install Zig 0.16+ (`brew install zig` on macOS). Then:

```sh
zig build          # build
zig build test     # run all tests
zig build run      # build + run
zig fmt src build.zig   # format (CI enforces this)
```

## Project layout

```
src/
  main.zig         CLI entry point (thin — all logic lives in the library)
  root.zig         public library API
  cli.zig          argument parsing
  config.zig       runtime configuration
  core/            pure domain logic, no I/O (event model, parser, index, stats, digest, tips)
  infra/           everything that touches the OS (fs watching, HTTP, terminal)
  tui/             terminal UI (app loop, renderer, widgets, views)
  api/             HTTP handlers translating the index into JSON
testdata/          anonymized transcript fixtures used by tests
```

Rules of thumb:

- `core/` must not import `infra/` and must not perform I/O. Pure functions in, data out.
- Every public declaration gets a `///` doc comment.
- All allocations take an explicit `Allocator`; tests run under the testing allocator (leaks fail the build).
- The parser must never crash on unknown input — unknown record types become `Event.unknown`. Claude Code's transcript format changes between versions; tolerate, count, move on.
- Every suppressed error is logged (`std.log.debug` at minimum). No silent `catch {}`.

## Tests

- Unit tests live next to the code in `test` blocks.
- Parser and digest tests use fixtures from `testdata/` — real record shapes, anonymized content. When adding a fixture, strip real prompts, paths, and identifiers.
- Every tips rule ships with a positive and a negative test case.

## Commits

Conventional commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`). Keep the changelog updated under `[Unreleased]`.
