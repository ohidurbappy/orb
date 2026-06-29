# orb

A growable, cross-platform CLI toolbox — an aggregate of small tools that share one
binary, one update mechanism, and one consistent UI. Written in [Zig](https://ziglang.org),
it compiles to a single dependency-free native executable per platform.

## Install

**macOS / Linux** — paste into your terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/ohidurbappy/orb/main/install.sh | sh
```

**Windows** — paste into PowerShell:

```powershell
irm https://raw.githubusercontent.com/ohidurbappy/orb/main/install.ps1 | iex
```

The installer detects your platform, downloads the latest release, and installs
it as `orb` on your `PATH`. Override the location with `ORB_INSTALL_DIR` if you
like. Re-run it any time to upgrade (or use `orb update`).

<details>
<summary>Manual install</summary>

Grab the `.gz` asset for your platform from the
[latest release](https://github.com/ohidurbappy/orb/releases/latest), decompress
it, mark it executable, and put it on your `PATH`:

```sh
# example: macOS arm64
curl -fsSL https://github.com/ohidurbappy/orb/releases/latest/download/orb-darwin-arm64.gz | gunzip > orb
chmod +x orb
sudo mv orb /usr/local/bin/orb
```

| Platform      | Asset                      |
| ------------- | -------------------------- |
| macOS (Apple) | `orb-darwin-arm64.gz`      |
| macOS (Intel) | `orb-darwin-x64.gz`        |
| Linux x64     | `orb-linux-x64.gz`         |
| Linux arm64   | `orb-linux-arm64.gz`       |
| Windows x64   | `orb-windows-x64.exe.gz`   |

</details>

## Usage

```sh
orb                  # interactive menu: type to fuzzy-search, ↑/↓ to move, Enter to run, Esc to quit
orb ip               # list local interface addresses
orb ip --local       # just the LAN IPv4, plain — e.g. IP=$(orb ip --local)
orb ip --public      # your public IP (looked up via an external service)
orb serve            # serve the current directory over HTTP (default port 8000)
orb serve 8080       # …on a specific port; prints the LAN URL + a QR to scan
orb sysinfo          # neofetch-style system info
orb update           # download & install the latest release
orb --help
orb --version
```

`orb ip --local` (`-l`) and `--public` (`-p`) print a bare address with no UI
chrome, so they're safe to capture in scripts.

orb checks GitHub for a newer release on startup (and every 10 minutes while the menu
is open). When one is found it shows a banner; run `orb update` to self-replace the
binary. Checks are cached at `~/.config/orb/state.json` and never block a command.

## Development

Requires [Zig](https://ziglang.org) 0.16.

```sh
zig build run -- ip        # run the CLI from source (args after `--`)
zig build test             # run the test suite
zig build                  # build a debug binary into zig-out/bin/orb
zig build -Doptimize=ReleaseSafe              # optimized native build
zig build -Dtarget=x86_64-linux-musl          # cross-compile a single target
```

Releases (`.github/workflows/release.yml`) cross-compile every target with
`-Doptimize=ReleaseSafe`, gzip each binary, and publish the `.gz` assets.

## Adding a command

Every tool lives in its own file and is registered in one place. To add `mytool`:

1. Create `src/commands/mytool.zig`:
   - **pure logic**, with side-effecting dependencies passed as parameters (see
     `ip.zig` / `sysinfo.zig`) so it's trivial to unit-test.
   - a `render(ctx: *Ctx)` function — the thin presentation layer.
   - optionally a `run(ctx: *Ctx) !?[]const u8` for plain-output one-shot use.
2. Register a `Command` for it in `src/commands` / `src/registry.zig`.
3. Add tests for the pure logic to `src/tests.zig`.

It then automatically appears in `--help`, the interactive menu, and CLI dispatch.

See [CLAUDE.md](./CLAUDE.md) for the full conventions.
