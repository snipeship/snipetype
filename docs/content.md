# Content Generation

snipetype generates typing content in multiple modes.

## Modes

| Mode | Description |
|------|-------------|
| **Words** | Random English words |
| **Sentences** | Coherent sentence fragments |
| **Code** | Programming language snippets |
| **Vim** | Multi-line code for vim practice |

## Words Mode

Generates random words from a curated list of common English words.

```
the quick brown fox jumps over lazy dog
```

Word list includes ~130k English words from a public-domain source, filtered for typing:
- Lowercase a-z only
- 1-8 characters long
- Large enough to avoid repetition
Source: `dwyl/english-words` (public domain), filtered locally.

## Sentences Mode

Generates coherent sentence fragments:

```
The quick brown fox jumps over the lazy dog while the cat watches.
```

Sentence templates combine:
- Subjects (the fox, a developer, etc.)
- Verbs (runs, writes, builds, etc.)
- Objects (the code, a function, etc.)

## Code Mode

Generates realistic code snippets in various languages.

### Supported Languages

| Language | Flag |
|----------|------|
| Zig | `-l zig` |
| Rust | `-l rust` |
| Go | `-l go` |
| TypeScript | `-l ts` |
| Python | `-l python` |
| C | `-l c` |
| Mixed | `-l mixed` (default) |

### Examples

**Zig:**
```zig
const std = @import("std");
pub fn main() !void {
    const allocator = std.heap.page_allocator;
```

**Rust:**
```rust
fn main() {
    let mut vec = Vec::new();
    vec.push(42);
```

**Go:**
```go
func main() {
    data := make(map[string]int)
    data["count"] = 0
```

## Vim Mode

Generates multi-line code for vim editing practice.

```
snipetype -m vim -l zig
```

Target code appears as "ghost text" that you must reproduce using vim commands.

## Implementation

Content is generated in `src/core/content.zig`:

```zig
pub fn generateWords(allocator: Allocator, rng: *Rng, count: usize) ![]const u8;
pub fn generateSentences(allocator: Allocator, rng: *Rng, count: usize) ![]const u8;
pub fn generateCode(allocator: Allocator, rng: *Rng, lang: Lang) ![]const u8;
pub fn generateVimContent(allocator: Allocator, rng: *Rng, lang: Lang) ![][]const u8;
```

### Random Number Generator

Uses a simple xorshift PRNG seeded from system time:

```zig
pub const Rng = struct {
    state: u64,
    
    pub fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }
    
    pub fn range(self: *Rng, max: usize) usize {
        return @intCast(self.next() % max);
    }
};
```

## Configuration

| Option | CLI Flag | Default |
|--------|----------|---------|
| Mode | `-m, --mode` | words |
| Word count | `-w, --words` | 10 |
| Time limit | `-t, --time` | none |
| Language | `-l, --lang` | mixed |

## Examples

```bash
# 10 random words (default)
snipetype

# 25 words
snipetype -w 25

# Sentences
snipetype -m sentences

# Rust code snippets
snipetype -m code -l rust

# 60-second challenge
snipetype -t 60

# Vim mode with Zig code
snipetype -m vim -l zig
```

## Word Tiers

Words mode picks from one of three lists (`Config.tier`):

| Tier | List | Notes |
|------|------|-------|
| `easy` | `src/core/wordlists/en_200.txt` | 200 of the most common English words |
| `common` (default) | `src/core/wordlists/en_1k.txt` | 1,000 common words, average length about 5 letters |
| `full` | `src/core/words_en.txt` | the ~131k-word list above, minus a small blocklist |

The `easy` and `common` lists are hand-written (plain lowercase a-z, one word
per line); they are not copied from any third-party frequency list. The
`full` tier is filtered at load time through `src/core/wordlists/blocklist.txt`
(profanity and slurs; `stem*` entries drop every word with that prefix), so
`words_en.txt` itself is never modified.

Picks never repeat a word within the last 10 words.

Untimed tests have exactly `word_count` words (1–250). Timed tests are
endless: more words are generated whenever fewer than 30 remain ahead of the
caret, so a test never ends by running out of text.

## Punctuation and Numbers

Two toggles decorate the words mode stream (`Config.punctuation`,
`Config.numbers`):

- **Punctuation**: sentences of 6–12 words start with a capital and end with
  `.`, `?` or `!` (the last word of an untimed test always ends one); about
  10% of words get a comma, a few get `;` or `:`; now and then a word is
  wrapped in quotes or parentheses, replaced by a contraction (`don't`,
  `it's`, …) or joined into a hyphenated pair.
- **Numbers**: about 10% of words become a number: a 1–4 digit integer, a
  year (1900–2030), a decimal (`3.14`), a percentage (`10%`) or a version
  (`v1.2`). A sentence never starts with a number.

```
The world can still, (help) open. Since part 1987 most hand?
```

## Sentences and Quotes

Sentences mode draws from the built-in sentences plus the public-domain
quotes of the arcade (`src/game/quotes.zig`, read-only). Picks don't repeat
until the whole pool has been used. When a quote is the last thing you typed,
the results show its attribution. Timed sentence tests keep pulling more.

## Multi-line Code

Code mode types whole, real multi-line snippets: the vim banks above plus at
least eight more per language in `src/core/snippets.zig` (3–12 lines each,
4-space indentation, balanced brackets). Snippets are joined with a blank
line and don't repeat within a test; `-l mixed` picks one language per test.

- **Enter** ends a line (Space works there too).
- The next line's **indentation is skipped automatically** and drawn dim.
- Runs of spaces inside a line count as one space.

The one-line `code_*` banks are kept in `content.zig` but no longer used.

## Typing Engine

Text is typed word by word (`src/core/session.zig`), like Monkeytype:

- Space commits the current word; untyped letters count as **missed** and
  letters past the end as **extra** (at most 20), so one slip no longer turns
  the rest of the test red.
- Backspace at the start of a word goes back into the previous word only if
  that word is wrong.
- Ctrl+W / Ctrl+Backspace / Alt+Backspace clear the word; Ctrl+U clears back
  to the start of the line (stopping at a correct word).
- Arrow keys and Delete work inside the current word.
- An untimed test ends when the last word is committed or typed exactly.

Results come from a keystroke log (`src/core/keylog.zig`,
`src/core/stats.zig`):

| Stat | Definition |
|------|------------|
| wpm | characters of correct words plus their spaces, plus the correct start of the current word, / 5 / minutes |
| raw | every typed character, including corrected ones, / 5 / minutes |
| acc | correct keystrokes / all keystrokes (corrected mistakes count) |
| corrected | wrong characters later deleted |
| consistency | 100 × (1 − coefficient of variation) of per-second raw |

A run counts towards history and personal bests (`src/core/history.zig`) only
if it lasted at least 1 s and nothing was pasted.

## Round 2 additions

### More word lists and languages

- **5k tier** (`--tier 5k`, `src/core/wordlists/en_5k.txt`): exactly 5,000
  everyday words between `common` and `full`: the common list plus 4,000
  hand-picked words. `words_en.txt` is alphabetical, not ordered by
  frequency, so the list is not a slice of it; a test checks that every word
  the 5k list adds to the common list appears in `words_en.txt` (the common
  list itself has words such as "be" and "of" that `words_en.txt` lacks),
  that all 5,000 are unique and that none is on the blocklist.
- **More code languages:** bash (`-l bash`, also `sh`/`shell`), Lua
  (`-l lua`), SQL (`-l sql`), Java (`-l java`) and YAML (`-l yaml`, also
  `yml`), each with hand-written, realistic snippets (printable ASCII,
  balanced brackets). `-l mixed` picks from every language.

| Language | Flag |
|----------|------|
| Bash | `-l bash` |
| Lua | `-l lua` |
| SQL | `-l sql` |
| Java | `-l java` |
| YAML | `-l yaml` |

### Enter mid-line skips the rest of the line

In code mode (and custom text with line breaks), **Enter** before the end of
a line commits the current word and every remaining word of the line as
typed: the untyped letters count as **missed**, the same way Space mid-word
skips the rest of a word. One Enter keystroke is recorded as an error, and
the caret moves to the first word of the next line with its indentation
skipped. Enter on the last line ends the test. Enter on a line where nothing
has been typed yet does nothing, so a double Enter is harmless. Skipped words
are drawn as skipped.

### Code with vim keys

With `--keys vim` (`-m code --vim`, Ctrl+K on the code idle screen,
Ctrl+P → code → keys) code mode builds one snippet of the selected language
(`content.codeTarget`) and retypes it in the vim editor, exactly like
`-m vim --vim type`; the personal best is kept per language
(`code|<lang>|vim`).

### Daily challenge

`--daily` (`-m daily`, URL `mode=daily`) is 50 words (`DAILY_WORDS`) from
the common list with punctuation on and numbers off, seeded with
`daily.seedFor(day)` where `day` is the UTC day number (days since
1970-01-01). Everyone gets the same text on the same UTC date, natively and
on the web, whatever their own word options are. A session that crosses
midnight UTC gets the new day on its next test. Its personal best is per day
(`daily|yyyy-mm-dd`).

### Custom text

`-m custom` types your own text: `--text "..."`, `--file notes.md`, piped
stdin (`echo hi | snipetype`), a paste on the custom idle screen, or the web
dialog. The text is sanitized before use: CRLF and CR become LF, tabs become
four spaces, other control and non-ASCII bytes are dropped, trailing blanks
are trimmed, and it is cut at 64 KiB (at a line or word break when
possible). Untimed, it is typed once; with `-t` it repeats until the time is
up. Lines are kept, so Enter-skips-line applies. Without any text the mode
uses a built-in sample and says so. The personal best is keyed by a hash of
the text (`custom|<fnv1a>|all` or `|t30`).

### Zen and weak keys

- **Zen** (`-m zen`) has no target text: every letter you type is right,
  Space and Enter commit words, and Esc or Shift+Enter ends the run and
  shows the results. Zen runs are kept in the history but have no personal
  best.
- **Weak keys:** every typing record carries per-key hits, misses and
  timing (`"pk"`). Summed over the history they give each key a weakness
  weight; `--weak` (focus weak) and `w` on the results build a words test
  weighted toward the weakest keys. Practice runs are never recorded.
