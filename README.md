# snipetype

A terminal typing test with a vim mode, and an arcade: keycaps and words fall
toward a glowing RGB keyboard, and you type them before they land.

**Web:** [snipetype.com](https://snipetype.com) · add `?mode=arcade` for the arcade

## Arcade

```bash
snipetype arcade                     # Words game: lines of words and quotes fall
snipetype arcade --game keys         # Keys game: keycaps, vim motions, Ctrl chords, :wq
snipetype arcade --pace 10x --speed 2
```

Your shift runs from 09:00 to 18:00, one new stage every 30 seconds, and then
Overtime. You lose health when a word or keycap lands, or when you press a
wrong key. Combos raise your multiplier and make the hit effects bigger, from
confetti and frost up to supernovas and black holes. The shift ends with a
results card and a rank.

| Screen | Keys |
|---|---|
| Title | `tab` game (words / keys) · `←`/`→` pace (junior, senior, staff, 10x) · `↑`/`↓` speed ×1–×16 · `enter` clock in · `esc` quit (native) |
| Playing | type what falls · `esc` pause |
| Paused | `esc` resume · `q` title |
| Results | `enter` again · `esc` title |

Options: `--game words|keys` · `--pace junior|senior|staff|10x` ·
`--speed 1|2|4|8|16` · `--gfx auto|kitty|cells`.
On the web: `?mode=arcade&game=keys`.

### Terminals

The arcade draws real pixels, so it looks best in a terminal that supports the
kitty graphics protocol:

| Terminal | Rendering |
|---|---|
| Ghostty, kitty, WezTerm, Konsole | kitty graphics (smooth pixel layer with bloom) |
| tmux (any terminal) | half-block cells |
| other truecolor terminals (iTerm2, Alacritty, foot, …) | half-block cells |

- **Auto-detection:** `--gfx auto` probes the terminal at startup.
- **Forcing a backend:** `--gfx cells` / `SNIPETYPE_GFX=cells` forces
  half-blocks. `--gfx kitty` forces kitty graphics.
- **Truecolor:** half-block rendering needs 24-bit color.
- **Three-key chords** (Keys game, 17:00) need the kitty keyboard protocol.
  Other terminals get a vim-macro stage instead.

Game design, scoring and rendering: [docs/arcade.md](docs/arcade.md).

## Install

```bash
bunx snipetype@latest
# or
npx snipetype@latest
```

## Typing test

```bash
snipetype                      # 10 common words
snipetype -w 25 --punct        # 25 words with capitals and punctuation
snipetype -t 30 --numbers      # 30 seconds, numbers mixed in
snipetype --tier easy          # the 200 most common words (also: common, 5k, full)
snipetype -m sentences         # sentences and quotes
snipetype -m code -l rust      # multi-line code snippets
snipetype -m code --vim -l go  # retype code snippets with real vim keys
snipetype -m vim               # vim drills
snipetype --daily              # today's daily challenge
snipetype -m zen               # free typing, esc for the results
echo "your text" | snipetype   # type your own text (also --text, --file)
snipetype stats                # your history in the terminal (--csv to export)
```

The engine works word by word, like Monkeytype: a typo stays in its word, and
space moves to the next one. Extra letters show up after the word and skipped
letters are underlined. Accuracy counts every keystroke, so mistakes you fixed
still count. The results show wpm, raw, accuracy, consistency, the correct /
incorrect / extra / missed letters, a per-second graph, your missed and
slowest words, and how the run compares with your personal best for the same
setup.

- **Word lists** (`--tier`): `easy` is the 200 most common words; `common` is a
  1k list and the default; `5k` is a hand-curated 5,000-word list; `full` is
  the big dictionary in `src/core/words_en.txt`.
- **Timed tests** (`-t 15|30|60|120`) never run out of words.
- **Punctuation and numbers** (`--punct`, `--numbers`) add capitals, sentence
  marks, commas, quotes, years and decimals to words mode (`--no-punct`,
  `--no-numbers` turn a saved setting off for one run).
- **Code mode** types real multi-line snippets (zig, rust, go, ts, python,
  c, bash, lua, sql, java, yaml): `enter` goes to the next line and the
  indentation is skipped for you. **Enter mid-line skips the rest of the
  line**: the untyped letters count as missed (like space mid-word skips the
  rest of a word) and the caret moves to the next line. On a line you haven't
  started, enter does nothing, so a double enter is harmless. Untyped code is
  syntax-coloured (`--no-syntax` turns it off).
- **Code with vim keys** (`--keys vim`, `-m code --vim`, `ctrl+k` on the code
  idle screen, or `ctrl+p` → code → keys): the snippet is retyped in the real
  vim engine instead, scored on keystrokes like `--vim type`.
- **Pace caret** (`--pace off|pb|<wpm>`, `ctrl+p` → options): a second caret
  moves at your personal best for the current setup (on by default once you
  have one) or at a fixed speed.
- **Strict typing:** `--stop-on-error letter` doesn't type a wrong letter,
  `--stop-on-error word` won't let you leave a wrong word, and
  `--no-backspace` turns corrections off (with `word` it stops on the letter
  instead, since a wrong letter could never be removed).
- **Layout emulation** (`--layout dvorak|colemak|colemak-dh`): practise a
  layout on a QWERTY keyboard. Leave it at `qwerty` when your OS layout is
  already switched, or every key is remapped twice.
- **Weak keys:** the results show a per-key accuracy heatmap and per-key
  speed; `w` on the results (or `--weak`) gives you words weighted toward
  your weakest keys, from all your history.
- **Zen** (`-m zen`): free typing with no target; `esc` or `shift+enter` shows
  the results (terminals without the kitty keyboard protocol, such as
  Terminal.app, send `shift+enter` as a plain `enter`, so use `esc` there).
- **Custom text** (`-m custom`, `--text`, `--file`, piped stdin, or a paste on
  the custom idle screen; on the web an "edit text" dialog): the whole text
  once, or timed with `-t`. It is kept in `custom.txt` next to the config.
- **Daily challenge** (`--daily`): 50 common words with punctuation, the same
  for everyone on a UTC date, with its own personal best.

| While typing | |
|---|---|
| `ctrl+w`, `ctrl+backspace`, `alt+backspace` | delete the word |
| `ctrl+u` (web on macOS: `cmd+backspace`) | delete back to the line start |
| `←`/`→`, `ctrl+←`/`ctrl+→` | move inside the current word |
| `enter` | code: next line; mid-line it skips the rest of the line |
| `esc`, `tab` | restart with new text (zen: `esc` finishes) |
| `ctrl+k` | code idle screen: switch plain keys ↔ vim keys |
| `f2` | history (idle screen) |
| `ctrl+p` | settings: theme, mode, test options, options |
| `ctrl+c` | quit (web: restart) |

| On the results | |
|---|---|
| `enter`, `space` | next test |
| `r` | retry the same text |
| `m` | practise the words you missed |
| `w` | practise your weakest keys |
| `h`, `f2` | history |
| `tab`, `esc` | new text |
| `q`, `ctrl+c` | quit |

`ctrl+p` sets the length (10 / 25 / 50 / 100 words or 15 / 30 / 60 / 120 s),
the word list, punctuation, numbers and word focus, the code language, keys
and syntax colours, and the vim drill lesson without leaving the app. Its
**options** panel (`tab` to it) holds the pace caret, stop on error,
backspace, layout and (web) typing sounds. Pasted text is never typed, except
on the custom idle screen, where a paste becomes the custom text.

### History

`f2` (idle or results) or `h` (results) opens the history screen: recent runs,
personal bests per setup with a wpm trend sparkline, and per-key accuracy.
`tab`/`←`/`→` switch tabs, `j`/`k`/`pgup`/`pgdn`/`g`/`G` scroll, `esc` closes.

```bash
snipetype stats                # totals, last 10 runs, bests, trend, weakest keys
snipetype stats --limit 30     # more recent runs
snipetype stats --csv > runs.csv
```

`snipetype stats` needs no terminal, so it works in scripts and pipes.

Legacy terminals send `^H` for `ctrl+backspace`, so `ctrl+h` deletes a word
too. When the tty's erase character is `^H` (`stty erase ^H`, a terminal
whose backspace key sends `^H`), `^H` is read as a plain backspace instead.

Results keys are ignored for half a second after a test ends, so a trailing
space or the next word of a timed test doesn't skip the results (or quit).

### Vim drills

`snipetype -m vim` is vim practice. Each drill gives you a buffer and a goal:
edit the buffer until it matches, in as few keystrokes as you can. Beat par
for three stars. The drills are grouped in lessons, from `hjkl` and word
motions to text objects, registers, the dot command, search, `:s` and macros
(`ctrl+p` picks a lesson). You start at the first drill you haven't 3-starred
yet.

| Key | |
|---|---|
| `f1` or `:hint` | show a hint (a hinted run can't get 3 stars) |
| `:e!` | retry the drill |
| `:w` | submit |
| `:q`, `tab` (normal mode) | skip to the next drill |
| `ctrl+c` | `esc`; twice in normal mode quits |
| `--drill <id or lesson>` | start somewhere else, e.g. `--drill text_objects` |

A drill counts as solved once the buffer matches **and** you are back in
normal mode (press `esc` after the last insert). `--vim type` keeps the old
mode: retype a code snippet into an empty buffer
with vim keys, scored on keystrokes and efficiency. Code mode can do the
same with its own snippets (`-m code --vim`). The engine covers counts,
motions, operators, text objects, registers, visual mode, search, undo/redo,
`.`, macros and insert-mode `ctrl+w`/`ctrl+u`, plus visual block mode
(`ctrl+v`), `:g`/`:v` with `:normal`, `:s` capture groups, `gn`, sentence
motions, search offsets and the jump list (`ctrl+o`/`ctrl+i`; legacy
terminals send `tab` for `ctrl+i`, so jumping forward needs the kitty
keyboard protocol). Details: [docs/vim.md](docs/vim.md).

### Saved settings and history

The theme, mode and test options you pick are saved, and every valid run is
appended to a history file that personal bests come from:

| | Native | Web |
|---|---|---|
| Settings | `~/.config/snipetype/config.json` | `localStorage["snipetype.config.v1"]` |
| History | `~/.local/state/snipetype/history.jsonl` | `localStorage["snipetype.history.v1"]` (newest 1,000 runs + one line per personal best) |
| Custom text | `~/.config/snipetype/custom.txt` | `localStorage["snipetype.custom.v1"]` |

`XDG_CONFIG_HOME` and `XDG_STATE_HOME` move the native files (macOS uses the
same paths), and `SNIPETYPE_HOME=<dir>` puts both in one directory.
`--no-save` writes nothing. Command-line flags and URL parameters
(`?mode=code&words=25&theme=nord`) beat the saved settings; `-w`/`words=`
without a time means a word-count test even when a time limit is saved, and
`--drill`/`drill=` switches to vim drills. Runs shorter than a second and
pasted runs are not recorded. A symlinked `config.json` (dotfiles) stays a
symlink when settings are saved. A history file over 16 MB is compacted at
startup to one line per personal best plus the newest 5,000 runs.

### Ctrl+W on the web

On Windows and Linux the browser keeps `ctrl+w` (close tab), `ctrl+t` and
`ctrl+n` for itself, and a page can't stop that. Use `ctrl+backspace` or
`alt+backspace` to delete a word; they work everywhere, including vim insert
mode. If you are mid-run, the page asks before it closes. In fullscreen (the
page's fullscreen button) Chromium browsers let the page keep `ctrl+w`, so
it deletes a word there. In vim mode (and code with vim keys) on the web,
`ctrl+r` (redo) and `ctrl+v` reach the app; `ctrl+shift+v` still pastes and
`f5` still reloads. `ctrl+k` reaches the app too.

## Build from source

Requires [Zig](https://ziglang.org/) **0.17.0**. The easiest way to get it is
[mise](https://mise.jdx.dev):

```bash
mise use zig@0.17.0
zig build run -- arcade            # native
zig build test

zig build web-dist                 # wasm → web/dist/
cd web && bun run dev              # http://localhost:8080/?mode=arcade
```

More: [docs/building.md](docs/building.md) · [docs/web.md](docs/web.md) ·
[docs/architecture.md](docs/architecture.md).

## License

MIT
