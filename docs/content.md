# Content Generation

snipetype generates typing content in multiple modes.

## Modes

| Mode | Description |
|------|-------------|
| **Words** | Random common words |
| **Sentences** | Coherent sentence fragments |
| **Code** | Programming language snippets |
| **Vim** | Multi-line code for vim practice |

## Words Mode

Generates random words from a curated list of common English words.

```
the quick brown fox jumps over lazy dog
```

Word list includes ~200 common words optimized for typing practice:
- Common letter combinations
- Varied word lengths
- No obscure words

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
