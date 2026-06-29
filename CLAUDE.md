# CLAUDE.md

Conventions for working in this repo. Keep it clean and consistent.

## What this is

`orb` is a single cross-platform CLI binary that aggregates many small tools. It is
written in **Zig** (0.16) and compiles to a standalone, dependency-free native
executable per platform. There is no runtime and no package manager.

## Architecture

- **Command registry** (`src/registry.zig`) is the single source of truth.
  `COMMANDS` drives `--help`, the interactive menu, and CLI dispatch. Register new
  commands there.
- **One file per command** under `src/commands/` (or a folder for larger ones like
  `src/commands/qr/`):
  - **pure logic** with side-effecting dependencies injected as parameters (the
    interface providers, `fetch`, file readers) with real defaults, so tests pass
    fixtures instead of touching the system. See `ip.zig` and `sysinfo.zig`.
  - a `render(ctx: *Ctx) anyerror!void` function — the presentation layer; it
    computes nothing of substance, it just formats and writes to `ctx.term`.
  - an optional `run(ctx: *Ctx) anyerror!?[]const u8` plain-output handler for
    script-friendly one-shot invocations (e.g. `orb ip --local`). Return an
    allocated string to print and skip the UI, or `null` to fall through to
    `render`.
- **UI is separated from logic.** Logic returns data; `render` writes ANSI.
  Terminal/raw-mode/key handling lives in `src/term.zig`.
- **Entry/dispatch:** `src/main.zig` parses argv (`src/cli.zig`), then either runs
  a single command (one-shot) or the interactive `src/menu.zig`. `src/banner.zig`
  prints the cached "update available" notice above command output.
- **The new std.Io model:** the 0.16 standard library threads an `Io` through all
  filesystem / socket / process operations. `src/io.zig` owns a process-wide `Io`
  (installed from the runtime's in `main`); call `io.get()` rather than
  constructing your own.
- **Auto-update:** `src/updater/`. `check.zig` queries GitHub releases;
  `state.zig` caches results (10-min throttle) under the platform config dir
  (`paths.zig`); `reconcile.zig` re-derives the verdict against the running
  version; `refresh.zig` fires a detached background refresh; `apply.zig`
  self-replaces the binary for `orb update`.
- **QR encoder:** `src/commands/qr/encoder.zig` is a from-scratch port of the
  `qrcode` library's core (GF(256), Reed-Solomon, mask selection). It is validated
  in tests against ground-truth matrices in `src/testdata/qr_truth.json`, so it
  produces byte-identical, scannable codes.

## Command lifecycle

- Simple print-and-exit commands (`ip`, `sysinfo`) leave `manages_exit` unset.
- Commands that stay interactive or run long (`qr`, `serve`, `update`) set
  `manages_exit = true` and drive their own input loop via `ctx.term`.
- Commands that accept piped input set `reads_stdin = true`; `main` reads stdin
  when there are no positional args and stdin is not a TTY.

## Conventions

- Memory: pure functions take an allocator and document ownership (caller frees,
  or use an arena). Tests run under `std.testing.allocator`, which fails on leaks
  and double-frees — keep allocations balanced.
- Errors in update/network paths are swallowed into safe results — they must never
  break the command the user actually ran.
- Asset names in `src/updater/assets.zig` must match the gzipped output names in
  `.github/workflows/release.yml` (`orb-<os>-<arch>.gz`, Windows `.exe.gz`).
- Windows builds compile but report the terminal as non-interactive (std doesn't
  expose the console-mode APIs); one-shot commands work fully there.

## Commands

```sh
zig build test                       # run the test suite (src/tests.zig)
zig build run -- <args>              # run from source
zig build                            # debug binary → zig-out/bin/orb
zig build -Doptimize=ReleaseSafe     # optimized build
zig build -Dtarget=<triple>          # cross-compile one target
```

## Release

**Every push to `main` cuts a release** (`.github/workflows/release.yml`): it runs
the tests, cross-compiles all targets (darwin on a macOS runner, linux+windows on
a Linux runner), gzips them, generates `checksums.txt`, and creates the GitHub
release.

Versioning is automatic. `build.zig.zon`'s `version` is the single source of truth;
its `MAJOR.MINOR` plus the workflow run number forms the patch
(`MAJOR.MINOR.<run>`), passed into the binary via `-Dversion=` at build time
(`src/version.zig`). To start a new major/minor series, edit `version` in
`build.zig.zon`.
