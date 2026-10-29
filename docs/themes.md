# Themes

snipetype includes 13 built-in color themes.

## Available Themes

| Theme | Slug | Background | Style |
|-------|------|------------|-------|
| **System** | `system` | Terminal's own | Uses the terminal's colors |
| **ONE Dark** | `one-dark` | `#282c34` | Atom One Dark |
| **ONE Light** | `one-light` | `#fafafa` | Atom One Light |
| **Dracula** | `dracula` | `#282a36` | Dracula |
| **Nord** | `nord` | `#2e3440` | Nord |
| **Gruvbox Dark** | `gruvbox-dark` | `#282828` | Gruvbox |
| **Solarized Dark** | `solarized-dark` | `#002b36` | Solarized |
| **Serika Dark** | `serika-dark` | `#323437` | Monkeytype's default |
| **Catppuccin Mocha** | `catppuccin-mocha` | `#1e1e2e` | Catppuccin |
| **Tokyo Night** | `tokyo-night` | `#1a1b26` | Tokyo Night ("night") |
| **Rose Pine** | `rose-pine` | `#191724` | Rosé Pine (main) |
| **Everforest** | `everforest` | `#2d353b` | Everforest dark, medium |
| **Gruvbox Light** | `gruvbox-light` | `#fbf1c7` | Gruvbox light, medium |

The slug is the name used in the saved config file and in URLs. `theme.slug(id)`
and `theme.fromSlug(s)` convert between the two; `fromSlug` also accepts the
snake_case name (`rose_pine`).

## Changing Themes

Press `ctrl+p` to open settings, then select a theme. The choice is saved with
the rest of the config.

## How colors are used

Every theme follows the same calm, Monkeytype-style rules for the typing text:

| What | Color |
|------|-------|
| Typed correctly | `fg` (the normal text color) |
| Not typed yet | `dim` |
| Mistyped letter | `danger` text, **no background** |
| Extra letter (typed past the end of a word) | `error_extra`, a darker `danger` |
| Letter skipped in a finished word (Space mid-word, or Enter mid-line in code) | `dim`, underlined |
| Caret on a mistake | `error_bg` behind the caret only |
| Caret, WPM, highlights | `accent` |
| Pace caret (where your PB or a fixed speed would be) | `pace`, underlined |
| Untyped code, by syntax class (when syntax colours are on) | `syn_keyword`, `syn_string`, `syn_comment`, `syn_number`, `syn_type`, `syn_punct` |

Separators between words are always drawn as plain spaces, so word gaps never
disappear. In code mode a dim `↵` marks each line break.

Syntax colours apply to untyped code only: in code mode, on the vim retype
ghost text (vim type, and code with vim keys), and, brightened toward `fg`, on
the drill goal pane. Typed letters keep their typed / mistyped colours. Each
`syn_*` colour is `dim` tinted 45% toward the theme's own hue for that class
(One Dark's purple keywords, Gruvbox's red, and so on), and comments sit
between `dim` and `dimmer`. That keeps untyped code muted, so typed text still
stands out.

The vim cursor cell is `cursor_fg` on `cursor_bg` in NORMAL and
`cursor_insert_fg` on `cursor_insert_bg` in INSERT and REPLACE. The insert
background is usually a light green, so `cursor_insert_fg` is usually the dark
`bg`.

The results heatmap and the history keys tab colour each key by accuracy:
`success` at 98% or more, blending through `warning` at 92% to `danger` at 85%
or less. Unused keys are `dimmer`.

`dim` has to stay readable, because it is what you read while typing. The
tests in `src/ui/theme.zig` check every theme for:

- `fg` on `bg`: WCAG contrast of at least 4.5;
- `dim` on `bg`: at least 2.4;
- `fg` against `dim`: at least 2.0, so typed and untyped text differ at a glance;
- `danger` on `bg`: at least 2.5;
- `error_extra` on `bg`: at least 2.0, so extra letters stay visible;
- `fg != dim` and `danger != error_extra`;
- each `syn_*` colour (except comments) and `pace` on `bg`: at least 2.4, and
  against `fg` at least 1.3, so untyped code never passes for typed text;
- `syn_comment`: at least 2.0 on `bg` and against `fg`;
- `cursor_insert_fg` on `cursor_insert_bg`: at least 4.5 (WCAG AA for text),
  and `cursor_fg` on `cursor_bg` at least 4.0.

Some published palettes were nudged to pass: Serika's sub color is a little
lighter (`#6c6e71`) and its error-extra is `#a4424d` (Monkeytype's `#7e2a33`
is 1.3:1 on the background), Nord's dim text is `#6e798f` (Nord's `#4c566a` is
unreadable as text), ONE Light's dim text is lighter so pending text reads as
pending, and Solarized uses `base1` for typed text.

## Theme Structure

```zig
pub const Theme = struct {
    name: []const u8,
    use_terminal_defaults: bool = false, // System theme

    bg: Color,
    fg: Color,              // typed-correct text

    accent: Color,          // caret, WPM, brand, highlights
    success: Color,         // good accuracy, insert-mode cursor, "solved"
    danger: Color,          // mistyped letters
    warning: Color,         // drill diff tint, toasts
    extra: Color,           // timer warnings, settings values (orange)
    info: Color,            // vim visual pill, hints
    error_extra: Color,     // extra letters

    dim: Color,             // untyped text, labels
    dimmer: Color,          // rules, unit labels, inactive chrome

    cursor_bg: Color,       // vim normal-mode block cursor
    cursor_insert_bg: Color,
    cursor_fg: Color,
    cursor_insert_fg: Color, // text on the insert cursor (contrast ≥ 4.5)

    error_bg: Color,        // only behind the caret on a mistake
    visual_bg: Color,       // vim visual selection (char, line and block)
    visual_fg: Color,
    border: Color,          // cards and panes

    pace: Color,            // pace caret: a muted accent

    syn_keyword: Color,     // untyped code by syntax class: muted, so it
    syn_string: Color,      // still reads as untyped
    syn_comment: Color,
    syn_number: Color,
    syn_type: Color,
    syn_punct: Color,
};
```

Helpers:

- `theme.text()` is `fg`, or null (the terminal's own color) for System.
- `theme.surface(amount)` is `bg` nudged toward `fg`, used for keycap chips
  and search highlights.
- `theme.muted()` is readable secondary text.
- `draw.syntaxColor(theme, kind)` maps a `syntax.Kind` to its colour (`dim`
  for plain text).

## System Theme

The "System" theme uses `use_terminal_defaults = true`, which:

1. Uses the terminal's default foreground and background.
2. Respects the user's terminal color scheme (including transparency).
3. Uses neutral fallbacks for the accents.

## Web Themes

The web version syncs the page background with the selected theme through
`THEME_COLORS_BY_ID` in `web/app.js`. The vim cursor cell is drawn by the
renderer, so the `cursor_insert_fg` fix needs no web change. Only the
hardware cursor colours (`cursor`, `cursorText`) are mirrored there.

## Adding a New Theme

1. Append an ID to `ThemeId` in `src/ui/theme.zig` (never renumber).
2. Add the definition to `THEMES`, under the same name as the enum tag
   (`resolve` and `slug` find it by name). Every field is required. For the
   derived ones:
   - `pace`: `accent` mixed 30% toward `dim`.
   - `syn_keyword`, `syn_string`, `syn_number`, `syn_type`: `dim` mixed 45%
     toward the palette's keyword, string, number and type colours.
   - `syn_comment`: `dim` mixed 30% toward `dimmer`.
   - `syn_punct`: `dim` mixed 15% toward `fg`.
   - `cursor_insert_fg`: `bg` if it reaches 4.5:1 on `cursor_insert_bg`,
     else `fg`, else black or white.

   `Color.mix` and `Color.contrast` compute these.
3. Add it to `OPTIONS` so the settings overlay lists it.
4. Run `zig test src/ui_tests.zig`; the contrast tests must pass.
5. For web: add it to `THEME_IDS` and `THEME_COLORS_BY_ID` in `web/app.js`.
