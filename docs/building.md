# Building

## Requirements

- [Zig](https://ziglang.org/) 0.15.2 or later

## Native CLI

```bash
# Debug build
zig build

# Run directly
zig build run

# Run with arguments
zig build run -- -m vim -l zig

# Release build
zig build -Doptimize=ReleaseSafe
```

Output: `zig-out/bin/snipetype`

## WebAssembly

```bash
# Build WASM
zig build web -Doptimize=ReleaseSmall

# Output
ls zig-out/bin/snipetype_web.wasm
```

### Running the Web Version

```bash
cd web
bun install
bun run dev
# Open http://localhost:3000
```

## Cross-Compilation

Zig supports cross-compilation out of the box:

```bash
# macOS ARM64
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos

# macOS x64
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos

# Linux ARM64
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux

# Linux x64
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux
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
zig build test
```

## Build Options

| Option | Description |
|--------|-------------|
| `-Doptimize=Debug` | Debug build (default) |
| `-Doptimize=ReleaseSafe` | Release with safety checks |
| `-Doptimize=ReleaseFast` | Maximum performance |
| `-Doptimize=ReleaseSmall` | Minimum size |
| `-Dtarget=<target>` | Cross-compile target |

## Build Steps

| Step | Command | Description |
|------|---------|-------------|
| default | `zig build` | Build CLI |
| run | `zig build run` | Build and run |
| test | `zig build test` | Run tests |
| web | `zig build web` | Build WASM |

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

```
error: expected minimum zig version 0.15.2
```

Update Zig to 0.15.2+:
```bash
# macOS
brew upgrade zig

# Or download from ziglang.org
```

### Windows not supported

The terminal uses POSIX APIs. Windows would require Windows Console API implementation.
