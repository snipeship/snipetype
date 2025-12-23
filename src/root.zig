//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║  ONE - Lightning Fast Typing Speed Test with Full Vim Editor              ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const posix = std.posix;

// ═══════════════════════════════════════════════════════════════════════════════
// MODES & LANGUAGES
// ═══════════════════════════════════════════════════════════════════════════════

pub const Mode = enum {
    words,
    sentences,
    code,
    vim,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .words => "words",
            .sentences => "sentences",
            .code => "code",
            .vim => "vim",
        };
    }

    pub fn fromString(s: []const u8) ?Mode {
        inline for (@typeInfo(Mode).@"enum".fields) |field| {
            if (std.mem.eql(u8, s, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Lang = enum {
    mixed,
    zig,
    rust,
    go,
    typescript,
    python,
    c,

    pub fn name(self: Lang) []const u8 {
        return switch (self) {
            .mixed => "mixed",
            .zig => "zig",
            .rust => "rust",
            .go => "go",
            .typescript => "ts",
            .python => "python",
            .c => "c",
        };
    }

    pub fn fromString(s: []const u8) ?Lang {
        if (std.mem.eql(u8, s, "mixed")) return .mixed;
        if (std.mem.eql(u8, s, "zig")) return .zig;
        if (std.mem.eql(u8, s, "rust") or std.mem.eql(u8, s, "rs")) return .rust;
        if (std.mem.eql(u8, s, "go")) return .go;
        if (std.mem.eql(u8, s, "typescript") or std.mem.eql(u8, s, "ts") or std.mem.eql(u8, s, "js")) return .typescript;
        if (std.mem.eql(u8, s, "python") or std.mem.eql(u8, s, "py")) return .python;
        if (std.mem.eql(u8, s, "c")) return .c;
        return null;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// WORD/SENTENCE/CODE BANKS
// ═══════════════════════════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════════════════════════
// RENDER BUFFER
// ═══════════════════════════════════════════════════════════════════════════════

pub const RenderBuffer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderBuffer {
        return .{ .data = std.ArrayList(u8){}, .allocator = allocator };
    }

    pub fn deinit(self: *RenderBuffer) void {
        self.data.deinit(self.allocator);
    }

    pub fn clear(self: *RenderBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn write(self: *RenderBuffer, s: []const u8) void {
        self.data.appendSlice(self.allocator, s) catch {};
    }

    pub fn writeByte(self: *RenderBuffer, b: u8) void {
        self.data.append(self.allocator, b) catch {};
    }

    pub fn print(self: *RenderBuffer, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.data.writer(self.allocator), fmt, args) catch {};
    }

    pub fn moveTo(self: *RenderBuffer, x: usize, y: usize) void {
        self.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    pub fn flush(self: *RenderBuffer) void {
        if (self.data.items.len > 0) {
            _ = posix.write(posix.STDOUT_FILENO, self.data.items) catch {};
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TERMINAL
// ═══════════════════════════════════════════════════════════════════════════════

pub const Terminal = struct {
    original: posix.termios,
    width: usize,
    height: usize,

    pub fn init() !Terminal {
        const current = try posix.tcgetattr(posix.STDIN_FILENO);
        var ws: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        return .{
            .original = current,
            .width = if (ws.col > 0) ws.col else 80,
            .height = if (ws.row > 0) ws.row else 24,
        };
    }

    pub fn enableRawMode(self: *Terminal) !void {
        var raw = self.original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    }

    pub fn restore(self: *Terminal) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

pub fn readKey() ?u8 {
    var buf: [1]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;
    return buf[0];
}

// ═══════════════════════════════════════════════════════════════════════════════
// RNG
// ═══════════════════════════════════════════════════════════════════════════════

pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed | 1 };
    }

    pub fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    pub fn range(self: *Rng, max: usize) usize {
        if (max == 0) return 0;
        return @intCast(self.next() % @as(u64, @intCast(max)));
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TYPING TEST STATE
// ═══════════════════════════════════════════════════════════════════════════════

pub const TestState = enum {
    waiting,
    typing,
    finished,
};

pub const TypingTest = struct {
    target: []const u8,
    typed: std.ArrayList(u8),
    state: TestState,
    start_time: ?i64,
    end_time: ?i64,
    errors: usize,
    correct_chars: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !TypingTest {
        var rng = Rng.init(seed);

        // Select 10 random words and build target string
        var total_len: usize = 0;
        var selected: [10][]const u8 = undefined;
        for (&selected) |*word| {
            word.* = words[rng.range(words.len)];
            total_len += word.len;
        }
        total_len += 9; // spaces between words

        const target = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (selected, 0..) |word, i| {
            @memcpy(target[pos..][0..word.len], word);
            pos += word.len;
            if (i < 9) {
                target[pos] = ' ';
                pos += 1;
            }
        }

        return .{
            .target = target,
            .typed = std.ArrayList(u8){},
            .state = .waiting,
            .start_time = null,
            .end_time = null,
            .errors = 0,
            .correct_chars = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypingTest) void {
        self.allocator.free(self.target);
        self.typed.deinit(self.allocator);
    }

    pub fn reset(self: *TypingTest, seed: u64) !void {
        var rng = Rng.init(seed);

        // Free old target
        self.allocator.free(self.target);

        // Select new words
        var total_len: usize = 0;
        var selected: [10][]const u8 = undefined;
        for (&selected) |*word| {
            word.* = words[rng.range(words.len)];
            total_len += word.len;
        }
        total_len += 9;

        const target = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (selected, 0..) |word, i| {
            @memcpy(target[pos..][0..word.len], word);
            pos += word.len;
            if (i < 9) {
                target[pos] = ' ';
                pos += 1;
            }
        }
        self.target = target;

        // Reset state
        self.typed.clearRetainingCapacity();
        self.state = .waiting;
        self.start_time = null;
        self.end_time = null;
        self.errors = 0;
        self.correct_chars = 0;
    }

    pub fn handleKey(self: *TypingTest, key: u8) void {
        if (self.state == .finished) return;

        // Start timer on first printable keypress
        if (self.state == .waiting and key >= 32 and key < 127) {
            self.state = .typing;
            self.start_time = std.time.milliTimestamp();
        }

        if (self.state != .typing) return;

        if (key == 127 or key == 8) {
            // Backspace
            if (self.typed.items.len > 0) {
                _ = self.typed.pop();
            }
        } else if (key >= 32 and key < 127) {
            // Printable character
            self.typed.append(self.allocator, key) catch return;

            // Check if finished
            if (self.typed.items.len >= self.target.len) {
                self.state = .finished;
                self.end_time = std.time.milliTimestamp();
                self.calculateStats();
            }
        }
    }

    fn calculateStats(self: *TypingTest) void {
        self.correct_chars = 0;
        self.errors = 0;

        const len = @min(self.typed.items.len, self.target.len);
        for (0..len) |i| {
            if (self.typed.items[i] == self.target[i]) {
                self.correct_chars += 1;
            } else {
                self.errors += 1;
            }
        }

        if (self.typed.items.len > self.target.len) {
            self.errors += self.typed.items.len - self.target.len;
        }
    }

    pub fn getWPM(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse return 0;
        const elapsed_ms = end - start;
        if (elapsed_ms <= 0) return 0;

        const elapsed_min = @as(f64, @floatFromInt(elapsed_ms)) / 60000.0;
        const word_count = @as(f64, @floatFromInt(self.correct_chars)) / 5.0;
        return word_count / elapsed_min;
    }

    pub fn getAccuracy(self: *const TypingTest) f64 {
        const total = self.correct_chars + self.errors;
        if (total == 0) return 100.0;
        return @as(f64, @floatFromInt(self.correct_chars)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    pub fn getElapsedSeconds(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse std.time.milliTimestamp();
        const elapsed = end - start;
        if (elapsed < 0) return 0;
        return @as(f64, @floatFromInt(elapsed)) / 1000.0;
    }

    pub fn getLiveWPM(self: *const TypingTest) f64 {
        if (self.state != .typing) return 0;
        const start = self.start_time orelse return 0;
        const now = std.time.milliTimestamp();
        const elapsed_ms = now - start;
        if (elapsed_ms <= 0) return 0;

        // Count correct chars so far
        var correct: usize = 0;
        const len = @min(self.typed.items.len, self.target.len);
        for (0..len) |i| {
            if (self.typed.items[i] == self.target[i]) {
                correct += 1;
            }
        }

        const elapsed_min = @as(f64, @floatFromInt(elapsed_ms)) / 60000.0;
        const word_count = @as(f64, @floatFromInt(correct)) / 5.0;
        return word_count / elapsed_min;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "Rng produces different values" {
    var rng = Rng.init(12345);
    const a = rng.next();
    const b = rng.next();
    try std.testing.expect(a != b);
}

test "TypingTest initialization" {
    var test_instance = try TypingTest.init(std.testing.allocator, 42);
    defer test_instance.deinit();

    try std.testing.expect(test_instance.target.len > 0);
    try std.testing.expectEqual(TestState.waiting, test_instance.state);
}
