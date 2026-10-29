//! Target text generation (words/sentences/code/vim snippets).

const std = @import("std");

const constants = @import("constants.zig");
const types = @import("types.zig");
const Config = types.Config;
const Lang = types.Lang;

const Rng = @import("rng.zig").Rng;

// Public-domain word list from dwyl/english-words, filtered to 1-8 lowercase letters.
const words_blob = @embedFile("words_en.txt");
var cached_words: ?[]const []const u8 = null;

fn getWordList(allocator: std.mem.Allocator) ![]const []const u8 {
    _ = allocator;
    if (cached_words) |words| return words;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, words_blob, '\n');
    while (it.next()) |word| {
        if (word.len == 0) continue;
        count += 1;
    }
    // Process-lifetime cache: page_allocator so leak-checking callers'
    // allocators don't report it at exit.
    var words = try std.heap.page_allocator.alloc([]const u8, count);
    var it_fill = std.mem.tokenizeScalar(u8, words_blob, '\n');
    var i: usize = 0;
    while (it_fill.next()) |word| {
        if (word.len == 0) continue;
        words[i] = word;
        i += 1;
    }
    cached_words = words;
    return words;
}

const sentences = [_][]const u8{
    "The quick brown fox jumps over the lazy dog.",
    "Pack my box with five dozen liquor jugs.",
    "How vexingly quick daft zebras jump.",
    "The five boxing wizards jump quickly.",
    "A journey of a thousand miles begins with a single step.",
    "Actions speak louder than words.",
    "Practice makes perfect when you stay consistent.",
    "Simple is better than complex.",
    "Readability counts more than cleverness.",
    "Now is better than never.",
    "Errors should never pass silently.",
    "In the face of ambiguity refuse to guess.",
    "First make it work then make it fast.",
    "Premature optimization is the root of all evil.",
    "Write code that humans can understand.",
    "The best code is no code at all.",
    "Debugging is twice as hard as writing code.",
    "Make it work make it right make it fast.",
    "Code is read more often than it is written.",
    "Keep it simple keep it working.",
};

// Multi-line code snippets for vim mode
const vim_snippets_zig = [_][]const u8{
    \\pub fn main() !void {
    \\    const stdout = std.io.getStdOut();
    \\    try stdout.print("Hello\n", .{});
    \\}
    ,
    \\const Config = struct {
    \\    name: []const u8,
    \\    value: i32,
    \\};
    ,
    \\fn process(items: []const u8) !void {
    \\    for (items) |item| {
    \\        try handle(item);
    \\    }
    \\}
    ,
    \\test "basic" {
    \\    const x = 42;
    \\    try std.testing.expect(x == 42);
    \\}
    ,
};

const vim_snippets_rust = [_][]const u8{
    \\fn main() -> Result<()> {
    \\    let args: Vec<String> = env::args().collect();
    \\    println!("{:?}", args);
    \\    Ok(())
    \\}
    ,
    \\impl Display for Error {
    \\    fn fmt(&self, f: &mut Formatter) -> Result {
    \\        write!(f, "{}", self.msg)
    \\    }
    \\}
    ,
    \\#[derive(Debug, Clone)]
    \\pub struct Config {
    \\    pub name: String,
    \\    pub value: i32,
    \\}
    ,
    \\async fn fetch(url: &str) -> Result<String> {
    \\    let resp = reqwest::get(url).await?;
    \\    Ok(resp.text().await?)
    \\}
    ,
};

const vim_snippets_go = [_][]const u8{
    \\func main() {
    \\    fmt.Println("Hello, World!")
    \\    os.Exit(0)
    \\}
    ,
    \\type Config struct {
    \\    Name  string
    \\    Value int
    \\}
    ,
    \\func (s *Server) Handle(w http.ResponseWriter, r *http.Request) {
    \\    json.NewEncoder(w).Encode(s.data)
    \\}
    ,
    \\func process(items []string) error {
    \\    for _, item := range items {
    \\        if err := handle(item); err != nil {
    \\            return err
    \\        }
    \\    }
    \\    return nil
    \\}
    ,
};

const vim_snippets_ts = [_][]const u8{
    \\async function fetchData(url: string): Promise<Data> {
    \\    const response = await fetch(url);
    \\    return response.json();
    \\}
    ,
    \\interface Config {
    \\    name: string;
    \\    value: number;
    \\    enabled?: boolean;
    \\}
    ,
    \\const Component: React.FC<Props> = ({ name }) => {
    \\    const [state, setState] = useState(0);
    \\    return <div>{name}: {state}</div>;
    \\};
    ,
    \\export class Service {
    \\    private cache = new Map<string, Data>();
    \\    async get(key: string): Promise<Data | undefined> {
    \\        return this.cache.get(key);
    \\    }
    \\}
    ,
};

const vim_snippets_python = [_][]const u8{
    \\def main():
    \\    parser = argparse.ArgumentParser()
    \\    parser.add_argument("--name", required=True)
    \\    args = parser.parse_args()
    \\    print(f"Hello, {args.name}!")
    ,
    \\class Config:
    \\    def __init__(self, name: str, value: int):
    \\        self.name = name
    \\        self.value = value
    ,
    \\async def fetch(url: str) -> dict:
    \\    async with aiohttp.ClientSession() as session:
    \\        async with session.get(url) as resp:
    \\            return await resp.json()
    ,
    \\@dataclass
    \\class Point:
    \\    x: float
    \\    y: float
    \\
    \\    def distance(self, other: "Point") -> float:
    \\        return ((self.x - other.x) ** 2 + (self.y - other.y) ** 2) ** 0.5
    ,
};

const vim_snippets_c = [_][]const u8{
    \\int main(int argc, char **argv) {
    \\    printf("Hello, World!\n");
    \\    return 0;
    \\}
    ,
    \\typedef struct {
    \\    char *name;
    \\    int value;
    \\} Config;
    ,
    \\void process(int *arr, size_t len) {
    \\    for (size_t i = 0; i < len; i++) {
    \\        arr[i] *= 2;
    \\    }
    \\}
    ,
    \\char *read_file(const char *path) {
    \\    FILE *f = fopen(path, "r");
    \\    if (!f) return NULL;
    \\    fseek(f, 0, SEEK_END);
    \\    long len = ftell(f);
    \\    rewind(f);
    \\    char *buf = malloc(len + 1);
    \\    fread(buf, 1, len, f);
    \\    buf[len] = '\0';
    \\    fclose(f);
    \\    return buf;
    \\}
    ,
};

const code_zig = [_][]const u8{
    "const std = @import(\"std\");",
    "pub fn main() !void {}",
    "var x: i32 = 42;",
    "defer allocator.free(ptr);",
    "for (items) |item| {}",
    "while (cond) : (i += 1) {}",
    "if (x) |val| {} else {}",
    "switch (v) { .a => {} }",
    "const T = struct { x: i32 };",
    "try file.readAll(buf);",
    "return error.InvalidInput;",
    "@memcpy(dst, src);",
    "std.mem.eql(u8, a, b)",
    "allocator.alloc(u8, n)",
    "errdefer cleanup();",
};

const code_rust = [_][]const u8{
    "fn main() -> Result<()> {}",
    "let mut v = Vec::new();",
    "impl Trait for T {}",
    "match x { Some(v) => v }",
    "pub struct S { n: i32 }",
    "#[derive(Debug, Clone)]",
    ".iter().map(|x| x * 2)",
    ".unwrap_or_else(|| 0)",
    "Box::new(value)",
    "Rc::clone(&rc)",
    "async fn fetch() {}",
    "tokio::spawn(task)",
    "&str -> String",
    "Option<T> -> T",
    "Result<T, E>",
};

const code_go = [_][]const u8{
    "func main() {}",
    "package main",
    "import \"fmt\"",
    "if err != nil {}",
    "defer f.Close()",
    "go func() {}()",
    "make(chan int, 10)",
    "type S struct {}",
    "for i := 0; i < n; i++",
    "map[string]int{}",
    "func (s *S) M() {}",
    "ctx context.Context",
    "json.Marshal(v)",
    "http.HandleFunc()",
    "sync.WaitGroup{}",
};

const code_ts = [_][]const u8{
    "const f = async () => {}",
    "export default function(){}",
    "import { x } from './m'",
    "const [s, setS] = useState()",
    "Promise.all([a, b])",
    "arr.filter(x => x > 0)",
    "?.optional?.chain",
    "{ ...obj, key: val }",
    "type T = { n: string }",
    "interface I { m(): void }",
    "async/await",
    "try { } catch (e) { }",
    "Object.keys(obj)",
    "Array.from(iter)",
    "new Map<K, V>()",
};

const code_python = [_][]const u8{
    "def __init__(self):",
    "if __name__ == '__main__':",
    "from typing import Optional",
    "async def fetch(url):",
    "with open(p) as f:",
    "[x for x in items]",
    "lambda x: x * 2",
    "@property",
    "@staticmethod",
    "raise ValueError()",
    "yield from gen()",
    "try: except: finally:",
    "class C(Base):",
    "dict.get(k, default)",
    "f\"{var=}\"",
};

const code_c = [_][]const u8{
    "int main(int argc, char **argv)",
    "#include <stdio.h>",
    "malloc(sizeof(T))",
    "free(ptr);",
    "typedef struct {} T;",
    "void (*fn)(int);",
    "*ptr++ = val;",
    "memcpy(d, s, n);",
    "strlen(str)",
    "strcmp(a, b)",
    "printf(\"%d\", x);",
    "fopen(path, \"r\")",
    "NULL",
    "sizeof(arr)/sizeof(arr[0])",
    "#define MAX 100",
};

pub fn generateTarget(rng: *Rng, allocator: std.mem.Allocator, config: Config) ![]u8 {
    return switch (config.mode) {
        .words => try genWords(rng, allocator, config.word_count),
        .sentences => try genSentences(rng, allocator, config.word_count),
        .code => try genCode(rng, allocator, config.word_count, config.lang),
        .vim => try genVimSnippet(rng, allocator, config.lang),
        // Arcade has no typing target (the game sim generates its own caps).
        .arcade => try allocator.alloc(u8, 0),
        // Zen has no target; custom text and the daily words come from
        // source.zig (the TypingTest builds them).
        .zen, .custom => try allocator.alloc(u8, 0),
        .daily => try genWords(rng, allocator, config.word_count),
    };
}

fn genWords(rng: *Rng, allocator: std.mem.Allocator, count: usize) ![]u8 {
    const n = @min(count, constants.MAX_WORDS);
    if (n == 0) return allocator.alloc(u8, 0);
    var len: usize = 0;
    var sel: [constants.MAX_WORDS][]const u8 = undefined;
    const words = try getWordList(allocator);
    if (words.len == 0) return allocator.alloc(u8, 0);
    if (n <= words.len) {
        var used = std.AutoHashMap(usize, void).init(allocator);
        defer used.deinit();
        var i: usize = 0;
        while (i < n) {
            const idx = rng.range(words.len);
            if (used.contains(idx)) continue;
            try used.put(idx, {});
            sel[i] = words[idx];
            len += sel[i].len;
            i += 1;
        }
    } else {
        for (0..n) |i| {
            sel[i] = words[rng.range(words.len)];
            len += sel[i].len;
        }
    }
    const buf = try allocator.alloc(u8, len + n - 1);
    var pos: usize = 0;
    for (0..n) |i| {
        @memcpy(buf[pos..][0..sel[i].len], sel[i]);
        pos += sel[i].len;
        if (i < n - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    return buf;
}

fn genSentences(rng: *Rng, allocator: std.mem.Allocator, word_target: usize) ![]u8 {
    var len: usize = 0;
    var sel: [constants.MAX_SENTENCES][]const u8 = undefined;
    var cnt: usize = 0;
    var words: usize = 0;
    while (words < word_target and cnt < constants.MAX_SENTENCES) {
        sel[cnt] = sentences[rng.range(sentences.len)];
        len += sel[cnt].len + 1;
        for (sel[cnt]) |c| if (c == ' ') {
            words += 1;
        };
        words += 1;
        cnt += 1;
    }
    if (cnt == 0) return allocator.alloc(u8, 0);
    const buf = try allocator.alloc(u8, len - 1);
    var pos: usize = 0;
    for (0..cnt) |i| {
        @memcpy(buf[pos..][0..sel[i].len], sel[i]);
        pos += sel[i].len;
        if (i < cnt - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    return buf;
}

fn genCode(rng: *Rng, allocator: std.mem.Allocator, count: usize, lang: Lang) ![]u8 {
    const banks = [_][]const []const u8{ &code_zig, &code_rust, &code_go, &code_ts, &code_python, &code_c };
    const bank: []const []const u8 = switch (lang) {
        .zig => &code_zig,
        .rust => &code_rust,
        .go => &code_go,
        .typescript => &code_ts,
        .python => &code_python,
        .c => &code_c,
        .mixed => banks[rng.range(banks.len)],
        .bash => &snippets.bash,
        .lua => &snippets.lua,
        .sql => &snippets.sql,
        .java => &snippets.java,
        .yaml => &snippets.yaml,
    };

    const n = @min(count, constants.MAX_CODE_SNIPPETS);
    if (n == 0) return allocator.alloc(u8, 0);
    var len: usize = 0;
    var sel: [constants.MAX_CODE_SNIPPETS][]const u8 = undefined;
    for (0..n) |i| {
        sel[i] = bank[rng.range(bank.len)];
        len += sel[i].len;
    }
    const buf = try allocator.alloc(u8, len + n - 1);
    var pos: usize = 0;
    for (0..n) |i| {
        @memcpy(buf[pos..][0..sel[i].len], sel[i]);
        pos += sel[i].len;
        if (i < n - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    return buf;
}

fn genVimSnippet(rng: *Rng, allocator: std.mem.Allocator, lang: Lang) ![]u8 {
    const all_snippets = [_][]const []const u8{
        &vim_snippets_zig,
        &vim_snippets_rust,
        &vim_snippets_go,
        &vim_snippets_ts,
        &vim_snippets_python,
        &vim_snippets_c,
    };

    const bank: []const []const u8 = switch (lang) {
        .zig => &vim_snippets_zig,
        .rust => &vim_snippets_rust,
        .go => &vim_snippets_go,
        .typescript => &vim_snippets_ts,
        .python => &vim_snippets_python,
        .c => &vim_snippets_c,
        .mixed => all_snippets[rng.range(all_snippets.len)],
        .bash => &snippets.bash,
        .lua => &snippets.lua,
        .sql => &snippets.sql,
        .java => &snippets.java,
        .yaml => &snippets.yaml,
    };

    const snippet = bank[rng.range(bank.len)];
    return try allocator.dupe(u8, snippet);
}

// ---------------------------------------------------------------------------
// Word tiers, sentence pool and multi-line code banks for the word-by-word
// engine (src/core/source.zig). Additions only: everything above is kept.

const WordTier = types.WordTier;
const snippets = @import("snippets.zig");

/// Hand-written lists (plain lowercase a-z, one word per line).
const en_200_blob = @embedFile("wordlists/en_200.txt");
const en_1k_blob = @embedFile("wordlists/en_1k.txt");
/// Hand-curated ~5k common words (a superset of en_1k.txt; every word is
/// also in words_en.txt).
const en_5k_blob = @embedFile("wordlists/en_5k.txt");
/// Words dropped from the "full" tier at load time ("stem*" = prefix).
const blocklist_blob = @embedFile("wordlists/blocklist.txt");

var cached_tiers: [std.meta.tags(WordTier).len]?[]const []const u8 = @splat(null);

/// True when `word` matches an entry of `wordlists/blocklist.txt`.
pub fn isBlocked(word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, blocklist_blob, "\r\n");
    while (it.next()) |entry| {
        if (entry[0] == '#') continue;
        if (entry[entry.len - 1] == '*') {
            if (std.mem.startsWith(u8, word, entry[0 .. entry.len - 1])) return true;
        } else if (std.mem.eql(u8, word, entry)) return true;
    }
    return false;
}

/// The word list of a tier: easy (200), common (1k, the default) or full
/// (`words_en.txt` minus the blocklist). Cached for the process lifetime.
pub fn wordList(tier: WordTier) ![]const []const u8 {
    const slot = &cached_tiers[@backingInt(tier)];
    if (slot.*) |words| return words;
    const blob = switch (tier) {
        .easy => en_200_blob,
        .common => en_1k_blob,
        .full => words_blob,
        .k5 => en_5k_blob,
    };
    // Same process-lifetime cache rule as getWordList (page_allocator so
    // leak-checking callers' allocators don't report it).
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(std.heap.page_allocator);
    var it = std.mem.tokenizeAny(u8, blob, "\r\n");
    while (it.next()) |word| {
        if (tier == .full and isBlocked(word)) continue;
        try list.append(std.heap.page_allocator, word);
    }
    const words = try list.toOwnedSlice(std.heap.page_allocator);
    slot.* = words;
    return words;
}

/// The built-in sentences (the arcade quotes are added by source.zig).
pub fn sentenceList() []const []const u8 {
    return &sentences;
}

/// The multi-line vim snippet bank of a language (`.mixed` → all of them).
pub fn vimSnippets(lang: Lang) []const []const u8 {
    return switch (lang) {
        .zig => &vim_snippets_zig,
        .rust => &vim_snippets_rust,
        .go => &vim_snippets_go,
        .typescript => &vim_snippets_ts,
        .python => &vim_snippets_python,
        .c => &vim_snippets_c,
        .mixed => &all_vim_snippets,
        .bash => &snippets.bash,
        .lua => &snippets.lua,
        .sql => &snippets.sql,
        .java => &snippets.java,
        .yaml => &snippets.yaml,
    };
}

const all_vim_snippets = vim_snippets_zig ++ vim_snippets_rust ++ vim_snippets_go ++
    vim_snippets_ts ++ vim_snippets_python ++ vim_snippets_c;

const code_bank_zig = vim_snippets_zig ++ snippets.zig;
const code_bank_rust = vim_snippets_rust ++ snippets.rust;
const code_bank_go = vim_snippets_go ++ snippets.go;
const code_bank_ts = vim_snippets_ts ++ snippets.ts;
const code_bank_python = vim_snippets_python ++ snippets.python;
const code_bank_c = vim_snippets_c ++ snippets.c;
const code_bank_mixed = code_bank_zig ++ code_bank_rust ++ code_bank_go ++
    code_bank_ts ++ code_bank_python ++ code_bank_c ++ snippets.bash ++
    snippets.lua ++ snippets.sql ++ snippets.java ++ snippets.yaml;

/// Whole multi-line snippets for code mode: the vim banks plus snippets.zig.
pub fn codeSnippets(lang: Lang) []const []const u8 {
    return switch (lang) {
        .zig => &code_bank_zig,
        .rust => &code_bank_rust,
        .go => &code_bank_go,
        .typescript => &code_bank_ts,
        .python => &code_bank_python,
        .c => &code_bank_c,
        .mixed => &code_bank_mixed,
        .bash => &snippets.bash,
        .lua => &snippets.lua,
        .sql => &snippets.sql,
        .java => &snippets.java,
        .yaml => &snippets.yaml,
    };
}

/// Every concrete code language (what "mixed" picks from).
pub const code_langs = [_]Lang{ .zig, .rust, .go, .typescript, .python, .c, .bash, .lua, .sql, .java, .yaml };

/// "mixed": one language per test.
pub fn pickLang(rng: *Rng) Lang {
    return code_langs[rng.range(code_langs.len)];
}

/// Code with vim keys: ONE snippet of `codeSnippets(lang)` (`.mixed` picks
/// a language first; callers that need to know it pick it themselves).
pub fn codeTarget(rng: *Rng, allocator: std.mem.Allocator, lang: Lang) ![]u8 {
    const l = if (lang == .mixed) pickLang(rng) else lang;
    const bank = codeSnippets(l);
    return allocator.dupe(u8, bank[rng.range(bank.len)]);
}

/// Custom mode without a custom text: a short note on where text comes from.
pub const custom_sample =
    "This is custom mode. Give it your own text with --text, --file or a pipe, " ++
    "paste it on this screen, or set it in the settings. It is typed once, or " ++
    "over and over in a timed test.";

/// Vim `.type` target text (same picks as `generateTarget` in vim mode).
pub fn vimTarget(rng: *Rng, allocator: std.mem.Allocator, lang: Lang) ![]u8 {
    return genVimSnippet(rng, allocator, lang);
}

test "word tiers load and are plain lowercase" {
    const easy = try wordList(.easy);
    const common = try wordList(.common);
    const full = try wordList(.full);
    try std.testing.expectEqual(@as(usize, 200), easy.len);
    try std.testing.expectEqual(@as(usize, 1000), common.len);
    try std.testing.expect(full.len > 100_000);
    for ([_][]const []const u8{ easy, common }) |list| {
        for (list) |w| {
            try std.testing.expect(w.len > 0);
            for (w) |ch| try std.testing.expect(ch >= 'a' and ch <= 'z');
        }
    }
    const everyday = [_][]const u8{ "be", "of", "it", "for", "do", "at", "but", "will", "my", "so", "up", "if", "can", "time", "good", "work", "new", "day" };
    for (everyday) |w| {
        var found = false;
        for (common) |c| found = found or std.mem.eql(u8, c, w);
        try std.testing.expect(found);
    }
}

test "the full tier drops blocklisted words" {
    try std.testing.expect(isBlocked("fucking"));
    try std.testing.expect(isBlocked("spic"));
    try std.testing.expect(!isBlocked("spice"));
    try std.testing.expect(!isBlocked("cockpit"));
    const full = try wordList(.full);
    for (full) |w| try std.testing.expect(!isBlocked(w));
    // The source file still has them: only the loaded list is filtered.
    try std.testing.expect(std.mem.indexOf(u8, words_blob, "\nfuck\n") != null);
    try std.testing.expect(full.len < (try getWordList(std.testing.allocator)).len);
}

test "every code snippet is printable ASCII with balanced brackets" {
    for (codeSnippets(.mixed)) |snip| {
        var depth = [_]i32{ 0, 0, 0 };
        for (snip) |ch| {
            try std.testing.expect(ch == '\n' or (ch >= 0x20 and ch <= 0x7e));
            switch (ch) {
                '(' => depth[0] += 1,
                ')' => depth[0] -= 1,
                '[' => depth[1] += 1,
                ']' => depth[1] -= 1,
                '{' => depth[2] += 1,
                '}' => depth[2] -= 1,
                else => {},
            }
            for (depth) |d| try std.testing.expect(d >= 0);
        }
        try std.testing.expectEqual([_]i32{ 0, 0, 0 }, depth);
    }
    for ([_][]const []const u8{ &snippets.zig, &snippets.rust, &snippets.go, &snippets.ts, &snippets.python, &snippets.c }) |bank| {
        try std.testing.expect(bank.len >= 8);
        for (bank) |snip| {
            const lines = std.mem.count(u8, snip, "\n") + 1;
            try std.testing.expect(lines >= 3 and lines <= 12);
        }
    }
}

test "the 5k tier: superset of 1k, dictionary words, no blocklist hits, no duplicates" {
    const k5 = try wordList(.k5);
    const common = try wordList(.common);
    try std.testing.expectEqual(@as(usize, 5000), k5.len);
    var dict = std.StringHashMap(void).init(std.testing.allocator);
    defer dict.deinit();
    var it = std.mem.tokenizeScalar(u8, words_blob, '\n');
    while (it.next()) |w| try dict.put(w, {});
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (k5) |w| {
        try std.testing.expect(!seen.contains(w));
        try seen.put(w, {});
        try std.testing.expect(w.len > 0);
        for (w) |ch| try std.testing.expect(ch >= 'a' and ch <= 'z');
        try std.testing.expect(!isBlocked(w));
    }
    var in_common = std.StringHashMap(void).init(std.testing.allocator);
    defer in_common.deinit();
    for (common) |w| {
        try std.testing.expect(seen.contains(w));
        try in_common.put(w, {});
    }
    // The hand-written 1k list predates words_en.txt checks (it has "be",
    // "of", ...); every word the 5k list adds is in the dictionary.
    for (k5) |w| {
        if (!in_common.contains(w)) try std.testing.expect(dict.contains(w));
    }
}

test "the new code banks: 8+ snippets, 3-12 lines, printable, balanced, tidy" {
    for ([_][]const []const u8{ &snippets.bash, &snippets.lua, &snippets.sql, &snippets.java, &snippets.yaml }) |bank| {
        try std.testing.expect(bank.len >= 8);
        for (bank) |snip| {
            const lines = std.mem.count(u8, snip, "\n") + 1;
            try std.testing.expect(lines >= 3 and lines <= 12);
            var it = std.mem.splitScalar(u8, snip, '\n');
            while (it.next()) |line| {
                try std.testing.expect(!std.mem.endsWith(u8, line, " "));
                try std.testing.expect(std.mem.indexOfScalar(u8, line, '\t') == null);
            }
        }
    }
    // codeSnippets/vimSnippets cover every language; mixed holds all 11.
    for (code_langs) |l| {
        try std.testing.expect(codeSnippets(l).len >= 8);
        try std.testing.expect(vimSnippets(l).len >= 4);
        for (codeSnippets(l)) |snip| {
            var found = false;
            for (codeSnippets(.mixed)) |m| found = found or m.ptr == snip.ptr;
            try std.testing.expect(found);
        }
    }
    var rng = Rng.init(1);
    var seen: [code_langs.len]bool = @splat(false);
    for (0..400) |_| seen[@backingInt(pickLang(&rng)) - 1] = true;
    for (seen) |b| try std.testing.expect(b);
    const t = try codeTarget(&rng, std.testing.allocator, .sql);
    defer std.testing.allocator.free(t);
    var found = false;
    for (codeSnippets(.sql)) |snip| found = found or std.mem.eql(u8, snip, t);
    try std.testing.expect(found);
}
