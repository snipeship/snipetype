# Architecture

snipetype is a cross-platform typing test written in Zig. It runs natively in terminals and in browsers via WebAssembly.

## High-Level Overview

```mermaid
graph TB
    subgraph "Entry Points"
        CLI[CLI - main.zig]
        WASM[WASM - web/main.zig]
    end

    subgraph "Core"
        App[App State]
        TypingTest[Typing Test]
        Vim[Vim Editor]
        Content[Content Generator]
    end

    subgraph "Platform"
        Terminal[Terminal]
        Input[Input Handler]
        AnsiRenderer[ANSI Renderer]
        CellRenderer[Cell Renderer]
    end

    subgraph "UI"
        Render[Render Functions]
        Theme[Theme System]
        Settings[Settings Overlay]
    end

    CLI --> App
    WASM --> App
    App --> TypingTest
    App --> Vim
    TypingTest --> Content
    
    CLI --> Terminal
    CLI --> AnsiRenderer
    WASM --> CellRenderer
    
    App --> Render
    Render --> Theme
    App --> Settings
```

## Directory Structure

```
src/
├── main.zig              # Native CLI entry point
├── cli.zig               # Argument parsing
├── root.zig              # Library exports
│
├── core/
│   ├── app.zig           # Application state & logic
│   ├── typing_test.zig   # Typing test state machine
│   ├── content.zig       # Text generation (words, sentences, code)
│   ├── types.zig         # Shared types (Config, Mode, Lang)
│   ├── metrics.zig       # WPM, accuracy calculations
│   └── rng.zig           # Random number generator
│
├── vim/
│   ├── editor.zig        # Vim editor state & commands
│   ├── buffer.zig        # Text buffer (lines)
│   ├── cursor.zig        # Cursor position
│   ├── mode.zig          # normal/insert/visual modes
│   ├── motions.zig       # h,j,k,l,w,b,e,$,^,gg,G
│   ├── operators.zig     # d,c,y,x,p,J,r
│   └── undo.zig          # Undo/redo stack
│
├── platform/
│   ├── terminal.zig      # POSIX terminal (raw mode)
│   ├── input.zig         # Key parsing (escape sequences)
│   ├── renderer.zig      # Abstract renderer interface
│   ├── ansi_renderer.zig # ANSI escape codes (native)
│   ├── cell_renderer.zig # Cell grid (WASM)
│   └── time.zig          # Platform time abstraction
│
├── ui/
│   ├── render.zig        # UI rendering (simple & vim modes)
│   ├── theme.zig         # Color themes
│   ├── settings.zig      # Settings overlay
│   └── color.zig         # RGB color type
│
└── web/
    └── main.zig          # WASM exports for JavaScript
```

## Data Flow

```mermaid
sequenceDiagram
    participant User
    participant Input
    participant App
    participant TypingTest
    participant Renderer

    User->>Input: keystroke
    Input->>App: Key event
    App->>TypingTest: handleKey()
    TypingTest->>TypingTest: update state
    App->>Renderer: render()
    Renderer->>User: display
```

## Typing Test State Machine

```mermaid
stateDiagram-v2
    [*] --> Waiting
    Waiting --> Typing: first keystroke
    Typing --> Typing: correct/incorrect key
    Typing --> Finished: all text typed
    Typing --> Finished: time limit reached
    Finished --> Waiting: tab (restart)
```

## Vim Mode Architecture

```mermaid
graph LR
    subgraph "Vim Editor"
        Mode[Mode State]
        Buffer[Text Buffer]
        Cursor[Cursor]
        Undo[Undo Stack]
    end

    subgraph "Commands"
        Motions[Motions]
        Operators[Operators]
    end

    Mode --> |normal| Motions
    Mode --> |normal| Operators
    Operators --> Buffer
    Operators --> Undo
    Motions --> Cursor
```

## Renderer Abstraction

The `Renderer` interface allows the same UI code to work on both native terminals and web browsers.

```mermaid
graph TB
    subgraph "Interface"
        Renderer[Renderer Trait]
    end

    subgraph "Implementations"
        ANSI[AnsiRenderer]
        Cell[CellRenderer]
    end

    subgraph "Output"
        Terminal[Terminal stdout]
        WASM[WASM Memory Grid]
    end

    Renderer --> ANSI
    Renderer --> Cell
    ANSI --> Terminal
    Cell --> WASM
```

### Renderer Methods

| Method | Description |
|--------|-------------|
| `moveTo(x, y)` | Position cursor |
| `write(str)` | Write text |
| `setFg(color)` | Set foreground color |
| `setBg(color)` | Set background color |
| `clear()` | Clear screen |
| `flush()` | Flush buffer to output |

## Theme System

Themes define colors for UI elements:

```zig
pub const Theme = struct {
    fg: Color,          // default foreground
    bg: Color,          // default background
    accent: Color,      // highlights, header
    success: Color,     // correct characters
    danger: Color,      // errors
    warning: Color,     // vim normal mode
    // ...
};
```

Built-in themes: `system`, `one_dark`, `one_light`, `dracula`, `nord`, `gruvbox_dark`, `solarized_dark`

## npm Distribution

```mermaid
graph TB
    subgraph "Main Package"
        snipetype[snipetype]
    end

    subgraph "Platform Packages"
        darwin-arm64[@snipetype/darwin-arm64]
        darwin-x64[@snipetype/darwin-x64]
        linux-arm64[@snipetype/linux-arm64]
        linux-x64[@snipetype/linux-x64]
    end

    snipetype -->|optionalDependencies| darwin-arm64
    snipetype -->|optionalDependencies| darwin-x64
    snipetype -->|optionalDependencies| linux-arm64
    snipetype -->|optionalDependencies| linux-x64
```

The main `snipetype` package contains a JS wrapper that:
1. Detects the platform
2. Resolves the correct binary from optionalDependencies
3. Executes it with `execFileSync`

## Build Targets

| Target | Output | Usage |
|--------|--------|-------|
| `zig build` | `zig-out/bin/snipetype` | Native CLI |
| `zig build web` | `zig-out/bin/snipetype_web.wasm` | Browser |
| `node npm/build.mjs` | Platform binaries in `npm/*/bin/` | npm release |
