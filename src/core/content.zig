//! Target text generation (words/sentences/code/vim snippets).

const std = @import("std");

const types = @import("types.zig");
const Config = types.Config;
const Lang = types.Lang;

const Rng = @import("rng.zig").Rng;

const common_words = [_][]const u8{
    "the",   "be",    "to",   "of",     "and",     "a",     "in",    "that",
    "have",  "it",    "for",  "not",    "on",      "with",  "as",    "you",
    "do",    "at",    "this", "but",    "by",      "from",  "they",  "we",
    "say",   "or",    "an",   "will",   "my",      "all",   "would", "there",
    "their", "what",  "so",   "up",     "out",     "if",    "about", "who",
    "get",   "which", "go",   "when",   "make",    "can",   "like",  "time",
    "just",  "know",  "take", "people", "into",    "year",  "your",  "good",
    "some",  "could", "them", "see",    "other",   "than",  "then",  "now",
    "look",  "only",  "come", "its",    "over",    "think", "also",  "back",
    "after", "use",   "two",  "how",    "our",     "work",  "first", "well",
    "way",   "even",  "new",  "want",   "because", "any",   "these", "give",
    "day",   "most",  "us",   "quick",  "brown",   "fox",   "jumps", "lazy",
};

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
    };
}

fn genWords(rng: *Rng, allocator: std.mem.Allocator, count: usize) ![]u8 {
    const n = @min(count, 50);
    if (n == 0) return allocator.alloc(u8, 0);
    var len: usize = 0;
    var sel: [50][]const u8 = undefined;
    for (0..n) |i| {
        sel[i] = common_words[rng.range(common_words.len)];
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

fn genSentences(rng: *Rng, allocator: std.mem.Allocator, word_target: usize) ![]u8 {
    var len: usize = 0;
    var sel: [10][]const u8 = undefined;
    var cnt: usize = 0;
    var words: usize = 0;
    while (words < word_target and cnt < 10) {
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
    };

    const n = @min(count, 20);
    if (n == 0) return allocator.alloc(u8, 0);
    var len: usize = 0;
    var sel: [20][]const u8 = undefined;
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
    };

    const snippet = bank[rng.range(bank.len)];
    return try allocator.dupe(u8, snippet);
}
