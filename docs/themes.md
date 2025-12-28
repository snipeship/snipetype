# Themes

snipetype includes 7 built-in color themes.

## Available Themes

| Theme | Background | Style |
|-------|------------|-------|
| **System** | Auto-detect | Follows OS preference |
| **One Dark** | `#282c34` | Atom One Dark |
| **One Light** | `#fafafa` | Atom One Light |
| **Dracula** | `#282a36` | Dracula |
| **Nord** | `#2e3440` | Nord |
| **Gruvbox Dark** | `#282828` | Gruvbox |
| **Solarized Dark** | `#002b36` | Solarized |

## Changing Themes

Press `ctrl+p` to open settings, then select a theme.

## Theme Structure

Each theme defines colors for UI elements:

```zig
pub const Theme = struct {
    // Base colors
    fg: Color,              // Default text
    bg: Color,              // Background
    
    // Text states
    dim: Color,             // Untyped text
    dimmer: Color,          // UI hints
    
    // Feedback
    success: Color,         // Correct characters
    danger: Color,          // Errors
    warning: Color,         // Vim normal mode
    info: Color,            // Vim visual mode
    
    // Accents
    accent: Color,          // Header, highlights
    extra: Color,           // Secondary accent
    
    // Cursor
    cursor_bg: Color,       // Normal mode cursor
    cursor_fg: Color,       // Cursor text
    cursor_insert_bg: Color, // Insert mode cursor
    
    // Vim visual selection
    visual_bg: Color,
    visual_fg: Color,
    
    // Errors
    error_bg: Color,        // Error background
    
    // Terminal integration
    use_terminal_defaults: bool,
};
```

## Color Type

Colors are RGB:

```zig
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const WHITE = Color{ .r = 255, .g = 255, .b = 255 };
    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0 };
};
```

## System Theme

The "System" theme uses `use_terminal_defaults = true`, which:

1. Uses terminal's default foreground/background
2. Respects user's terminal color scheme
3. Falls back to One Dark (dark mode) or One Light (light mode) for accents

## Example: One Dark

```zig
pub const one_dark = Theme{
    .fg = Color{ .r = 171, .g = 178, .b = 191 },      // #abb2bf
    .bg = Color{ .r = 40, .g = 44, .b = 52 },         // #282c34
    .accent = Color{ .r = 97, .g = 175, .b = 239 },   // #61afef
    .success = Color{ .r = 152, .g = 195, .b = 121 }, // #98c379
    .danger = Color{ .r = 224, .g = 108, .b = 117 },  // #e06c75
    // ...
};
```

## Web Themes

The web version syncs the page background with the selected theme:

```javascript
const THEME_COLORS_BY_ID = {
    0: null,                              // system
    1: { bg: "#282c34", fg: "#abb2bf" },  // one_dark
    2: { bg: "#fafafa", fg: "#0f172a" },  // one_light
    // ...
};
```

## Adding a New Theme

1. Add theme ID to `ThemeId` enum in `src/ui/theme.zig`
2. Add theme definition to `THEMES` struct
3. Add to `THEME_MENU` for settings UI
4. Update `resolve()` function
5. For web: add to `THEME_COLORS_BY_ID` in `web/app.js`
