# Building

## Requirements

- [Zig](https://ziglang.org/) 0.17.0 (`minimum_zig_version` in `build.zig.zon`).
  Zig has no stable API yet, so older releases (0.16 and earlier) cannot build
  this tree.

### Installing Zig 0.17.0

```bash
# mise (also writes a per-project pin to mise.toml)
mise use zig@0.17.0

# or download the tarball for your platform from
# https://ziglang.org/download/ (0.17.0 section), extract it, and put the
# directory containing the `zig` binary on your PATH

# Homebrew: `brew install zig` / `brew upgrade zig` once the formula ships 0.17

zig version   # must print 0.17.0
```

CI (`mlugg/setup-zig`) reads the version from `build.zig.zon`, so bumping
`minimum_zig_version` there is all CI needs.

## Native CLI

```bash
# Debug build
zig build

# Run directly
zig build run

# Run with arguments
zig build run -- -m vim -l zig

# Release build
zig build -Doptimize=safe

# Arcade straight from the build
zig build run -- arcade --game keys
```

Output: `zig-out/bin/snipetype`

## WebAssembly

```bash
# Build WASM (debug, into zig-out/bin/snipetype_web.wasm)
zig build web

# Build the ReleaseSmall wasm the web host serves (web/dist/snipetype_web.wasm)
zig build web-dist
```

### Running the Web Version

```bash
zig build web-dist        # or: cd web && bun run build:wasm
cd web
bun run dev
# Open http://localhost:8080 (PORT env overrides and the server falls back
# to 8081/8082 when the port is taken; see docs/web.md)
# Arcade: http://localhost:8080/?mode=arcade (&game=keys)
```

## Cross-Compilation

Zig supports cross-compilation out of the box:

```bash
# macOS ARM64
zig build -Doptimize=safe -Dtarget=aarch64-macos

# macOS x64
zig build -Doptimize=safe -Dtarget=x86_64-macos

# Linux ARM64
zig build -Doptimize=safe -Dtarget=aarch64-linux

# Linux x64
zig build -Doptimize=safe -Dtarget=x86_64-linux
```

## npm Packages

Build all platform binaries for npm release:

```bash
node npm/build.mjs
```

This cross-compiles for all supported platforms and copies binaries to:
- `npm/darwin-arm64/bin/snipetype`
- `npm/darwin-x64/bin/snipetype`
- `npm/linux-arm64/bin/snipetype`
- `npm/linux-x64/bin/snipetype`

## Tests

```bash
zig build test                  # everything (root module + CLI)
cd web && bun test              # web host: keys.js, host.js, audio.js
```

Each area also has its own entry point, which compiles only that area and
its dependencies (handy while another part of the tree is mid-change):

| Area | Command |
|---|---|
| Typing core, content, stats, history | `zig test src/core_tests.zig` |
| Vim engine and drills | `zig test src/vim_tests.zig` |
| Rendering and themes | `zig test src/ui_tests.zig` |
| Input, terminal, renderers (incl. the diffing renderer) | `zig test src/platform_tests.zig` |
| Native store (config, custom text, history streaming/compaction, symlinks) | `zig test src/platform/store_native.zig` |
| Web host pieces | `zig test src/web_tests.zig` |
| Arcade | `zig test src/game_tests.zig`, `src/fx_tests.zig`, `src/gfx_tests.zig` |

App routing, the key map, settings and the CLI (`src/core/app.zig`,
`src/core/keymap.zig`, `src/ui/settings.zig`, `src/cli.zig`) run under
`zig build test`. Tests never write to your home directory: the store tests
use a temporary directory. To try the binary without touching your saved
settings, run it with `SNIPETYPE_HOME=$(mktemp -d)` or `--no-save`.

## Build Options

| Option | Description |
|--------|-------------|
| `-Doptimize=debug` | Debug build |
| `-Doptimize=safe` | Release with safety checks (default; npm binaries) |
| `-Doptimize=fast` | Maximum performance |
| `-Doptimize=small` | Minimum size |
| `-Dtarget=<target>` | Cross-compile target |

Zig 0.17 renamed the optimize modes to `debug`, `safe`, `fast` and `small`
(`zig build --help` lists them). The old `Debug`/`ReleaseSafe`/`ReleaseFast`/
`ReleaseSmall` spellings are still accepted as deprecated aliases until Zig
0.18.

## Build Steps

| Step | Command | Description |
|------|---------|-------------|
| default | `zig build` | Build CLI |
| run | `zig build run` | Build and run |
| test | `zig build test` | Run tests |
| web | `zig build web` | Build WASM |
| web-dist | `zig build web-dist` | ReleaseSmall WASM copied into `web/dist/` |
| arcade-preview | `zig build arcade-preview -- <outdir>` | Render scripted arcade frames to PPM (`--bench` for timings) |

Your run history without a terminal (works in pipes and scripts):

```bash
zig build run -- stats              # totals, recent runs, bests, trend, weak keys
zig build run -- stats --csv > runs.csv
echo "some text" | zig build run    # type piped text (custom mode)
```

Arguments after `--` are forwarded to `run` and `arcade-preview`
(`Run.addPassthruArgs`; Zig 0.17 removed `b.args`, so a build script can no
longer see them at configure time).

## Project Structure

```
build.zig       # Build configuration
build.zig.zon   # Package manifest
src/            # Source code
├── main.zig    # CLI entry
└── web/
    └── main.zig # WASM entry
```

## Troubleshooting

### Zig version mismatch

Building with Zig 0.16 or older fails while compiling `build.zig`, for example:

```
build.zig:114:12: error: no field or member function named 'addPassthruArgs' in 'Build.Step.Run'
```

Install Zig 0.17.0 (see [Installing Zig 0.17.0](#installing-zig-0170)) and
check with `zig version`.

### Windows not supported

The terminal uses POSIX APIs. Windows would require Windows Console API implementation.
