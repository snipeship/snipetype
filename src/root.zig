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
// CONFIG
// ═══════════════════════════════════════════════════════════════════════════════

pub const Config = struct {
    mode: Mode = .words,
    word_count: usize = 10,
    time_limit: usize = 0,
    lang: Lang = .mixed,
};

// ═══════════════════════════════════════════════════════════════════════════════
// VIM BUFFER - Multi-line text buffer with cursor
// ═══════════════════════════════════════════════════════════════════════════════

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,

    pub fn lessThan(a: Cursor, b: Cursor) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }

    pub fn equals(a: Cursor, b: Cursor) bool {
        return a.row == b.row and a.col == b.col;
    }
};

pub const VimMode = enum {
    normal,
    insert,
    visual,
    visual_line,

    pub fn name(self: VimMode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
        };
    }
};

pub const Operator = enum {
    none,
    delete, // d
    change, // c
    yank, // y
};

const Line = std.ArrayList(u8);

pub const Buffer = struct {
    lines: std.ArrayList(Line),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        var lines = std.ArrayList(Line){};
        // Start with one empty line
        var first_line = Line{};
        lines.append(allocator, first_line) catch {};
        _ = &first_line;
        return .{ .lines = lines, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn clear(self: *Buffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.clearRetainingCapacity();
        var first_line = Line{};
        self.lines.append(self.allocator, first_line) catch {};
        _ = &first_line;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn getLine(self: *const Buffer, row: usize) []const u8 {
        if (row >= self.lines.items.len) return "";
        return self.lines.items[row].items;
    }

    pub fn getLineMut(self: *Buffer, row: usize) *Line {
        return &self.lines.items[row];
    }

    pub fn lineLen(self: *const Buffer, row: usize) usize {
        if (row >= self.lines.items.len) return 0;
        return self.lines.items[row].items.len;
    }

    pub fn insertChar(self: *Buffer, cursor: Cursor, char: u8) void {
        if (cursor.row >= self.lines.items.len) return;
        const line = self.getLineMut(cursor.row);
        const col = @min(cursor.col, line.items.len);
        line.insert(self.allocator, col, char) catch {};
    }

    pub fn deleteChar(self: *Buffer, cursor: Cursor) void {
        if (cursor.row >= self.lines.items.len) return;
        const line = self.getLineMut(cursor.row);
        if (cursor.col < line.items.len) {
            _ = line.orderedRemove(cursor.col);
        }
    }

    pub fn insertNewline(self: *Buffer, cursor: Cursor) void {
        if (cursor.row >= self.lines.items.len) return;
        const line = self.getLineMut(cursor.row);
        const col = @min(cursor.col, line.items.len);

        // Create new line with content after cursor
        var new_line = Line{};
        if (col < line.items.len) {
            new_line.appendSlice(self.allocator, line.items[col..]) catch {};
            line.shrinkRetainingCapacity(col);
        }
        self.lines.insert(self.allocator, cursor.row + 1, new_line) catch {};
    }

    pub fn joinLines(self: *Buffer, row: usize) void {
        if (row + 1 >= self.lines.items.len) return;
        const next_line = self.lines.items[row + 1].items;
        self.lines.items[row].appendSlice(self.allocator, next_line) catch {};
        self.lines.items[row + 1].deinit(self.allocator);
        _ = self.lines.orderedRemove(row + 1);
    }

    pub fn deleteLine(self: *Buffer, row: usize) void {
        if (row >= self.lines.items.len) return;
        if (self.lines.items.len == 1) {
            // Can't delete last line, just clear it
            self.lines.items[0].clearRetainingCapacity();
            return;
        }
        var line = self.lines.orderedRemove(row);
        line.deinit(self.allocator);
    }

    pub fn insertLine(self: *Buffer, row: usize, content: []const u8) void {
        var new_line = Line{};
        new_line.appendSlice(self.allocator, content) catch {};
        const insert_row = @min(row, self.lines.items.len);
        self.lines.insert(self.allocator, insert_row, new_line) catch {};
    }

    pub fn deleteRange(self: *Buffer, start: Cursor, end: Cursor) []u8 {
        // For simplicity, only handle single-line range for now
        if (start.row != end.row) return &[_]u8{};
        if (start.row >= self.lines.items.len) return &[_]u8{};

        const line = self.getLineMut(start.row);
        const from = @min(start.col, line.items.len);
        const to = @min(end.col, line.items.len);
        if (from >= to) return &[_]u8{};

        const content = self.allocator.dupe(u8, line.items[from..to]) catch return &[_]u8{};
        // Remove chars from 'to' down to 'from'
        var i: usize = to;
        while (i > from) {
            i -= 1;
            _ = line.orderedRemove(i);
        }
        return content;
    }

    pub fn deleteToEndOfLine(self: *Buffer, cursor: Cursor) []u8 {
        if (cursor.row >= self.lines.items.len) return &[_]u8{};
        const line = self.getLineMut(cursor.row);
        const col = @min(cursor.col, line.items.len);
        const content = self.allocator.dupe(u8, line.items[col..]) catch return &[_]u8{};
        line.shrinkRetainingCapacity(col);
        return content;
    }

    pub fn toText(self: *const Buffer, allocator: std.mem.Allocator) []u8 {
        var total: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total += line.items.len;
            if (i < self.lines.items.len - 1) total += 1; // newline
        }
        const buf = allocator.alloc(u8, total) catch return &[_]u8{};
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(buf[pos..][0..line.items.len], line.items);
            pos += line.items.len;
            if (i < self.lines.items.len - 1) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
        return buf;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// VIM EDITOR - Full vim implementation
// ═══════════════════════════════════════════════════════════════════════════════

pub const VimEditor = struct {
    buffer: Buffer,
    cursor: Cursor,
    mode: VimMode,
    visual_start: Cursor,
    pending_op: Operator,
    yank_register: std.ArrayList(u8),
    yank_is_line: bool,
    status_msg: []const u8,
    allocator: std.mem.Allocator,
    count: usize, // For number prefixes like 3j, 5w

    pub fn init(allocator: std.mem.Allocator) VimEditor {
        return .{
            .buffer = Buffer.init(allocator),
            .cursor = .{},
            .mode = .normal,
            .visual_start = .{},
            .pending_op = .none,
            .yank_register = std.ArrayList(u8){},
            .yank_is_line = false,
            .status_msg = "",
            .allocator = allocator,
            .count = 0,
        };
    }

    pub fn deinit(self: *VimEditor) void {
        self.buffer.deinit();
        self.yank_register.deinit(self.allocator);
    }

    pub fn reset(self: *VimEditor) void {
        self.buffer.clear();
        self.cursor = .{};
        self.mode = .normal;
        self.visual_start = .{};
        self.pending_op = .none;
        self.yank_register.clearRetainingCapacity();
        self.yank_is_line = false;
        self.status_msg = "";
        self.count = 0;
    }

    pub fn handleKey(self: *VimEditor, key: u8) void {
        self.status_msg = "";

        switch (self.mode) {
            .normal => self.handleNormal(key),
            .insert => self.handleInsert(key),
            .visual, .visual_line => self.handleVisual(key),
        }
    }

    fn handleNormal(self: *VimEditor, key: u8) void {
        // Handle count prefix
        if (key >= '1' and key <= '9' and self.count == 0) {
            self.count = key - '0';
            return;
        }
        if (key >= '0' and key <= '9' and self.count > 0) {
            self.count = self.count * 10 + (key - '0');
            if (self.count > 999) self.count = 999;
            return;
        }

        const count = if (self.count == 0) 1 else self.count;
        self.count = 0;

        // Handle pending operator
        if (self.pending_op != .none) {
            self.handleOperatorMotion(key, count);
            return;
        }

        switch (key) {
            // Motion
            'h' => self.moveLeft(count),
            'j' => self.moveDown(count),
            'k' => self.moveUp(count),
            'l' => self.moveRight(count),
            'w' => self.moveWordForward(count),
            'W' => self.moveWordForward(count), // Same as w for now
            'b' => self.moveWordBackward(count),
            'B' => self.moveWordBackward(count),
            'e' => self.moveWordEnd(count),
            'E' => self.moveWordEnd(count),
            '0' => self.cursor.col = 0,
            '^' => self.moveToFirstNonBlank(),
            '$' => self.moveToEndOfLine(),
            'g' => self.pending_op = .none, // Will handle gg with state
            'G' => self.moveToLastLine(),

            // Insert mode
            'i' => self.mode = .insert,
            'I' => {
                self.moveToFirstNonBlank();
                self.mode = .insert;
            },
            'a' => {
                self.moveRight(1);
                self.mode = .insert;
            },
            'A' => {
                self.moveToEndOfLine();
                self.cursor.col = self.buffer.lineLen(self.cursor.row);
                self.mode = .insert;
            },
            'o' => {
                self.buffer.insertLine(self.cursor.row + 1, "");
                self.cursor.row += 1;
                self.cursor.col = 0;
                self.mode = .insert;
            },
            'O' => {
                self.buffer.insertLine(self.cursor.row, "");
                self.cursor.col = 0;
                self.mode = .insert;
            },
            's' => {
                self.buffer.deleteChar(self.cursor);
                self.mode = .insert;
            },
            'S' => {
                self.buffer.deleteLine(self.cursor.row);
                self.buffer.insertLine(self.cursor.row, "");
                self.cursor.col = 0;
                self.mode = .insert;
            },

            // Visual mode
            'v' => {
                self.mode = .visual;
                self.visual_start = self.cursor;
            },
            'V' => {
                self.mode = .visual_line;
                self.visual_start = self.cursor;
            },

            // Operators
            'd' => self.pending_op = .delete,
            'c' => self.pending_op = .change,
            'y' => self.pending_op = .yank,

            // Single-key actions
            'x' => {
                for (0..count) |_| {
                    if (self.cursor.col < self.buffer.lineLen(self.cursor.row)) {
                        self.buffer.deleteChar(self.cursor);
                    }
                }
                self.clampCursor();
            },
            'X' => {
                for (0..count) |_| {
                    if (self.cursor.col > 0) {
                        self.cursor.col -= 1;
                        self.buffer.deleteChar(self.cursor);
                    }
                }
            },
            'D' => {
                const content = self.buffer.deleteToEndOfLine(self.cursor);
                self.setYank(content, false);
                self.clampCursor();
            },
            'C' => {
                const content = self.buffer.deleteToEndOfLine(self.cursor);
                self.setYank(content, false);
                self.mode = .insert;
            },
            'J' => {
                self.buffer.joinLines(self.cursor.row);
            },

            // Paste
            'p' => self.pasteAfter(),
            'P' => self.pasteBefore(),

            // Replace single char
            'r' => self.status_msg = "r",

            // Undo placeholder
            'u' => self.status_msg = "undo (not implemented)",

            else => {},
        }
    }

    fn handleOperatorMotion(self: *VimEditor, key: u8, count: usize) void {
        const op = self.pending_op;
        self.pending_op = .none;

        // Double key (dd, cc, yy)
        switch (key) {
            'd' => if (op == .delete) {
                self.opLineRange(op, self.cursor.row, self.cursor.row + count - 1);
                return;
            },
            'c' => if (op == .change) {
                self.opLineRange(op, self.cursor.row, self.cursor.row + count - 1);
                return;
            },
            'y' => if (op == .yank) {
                self.opLineRange(op, self.cursor.row, self.cursor.row + count - 1);
                return;
            },
            else => {},
        }

        // Motion
        const start = self.cursor;
        switch (key) {
            'w' => self.moveWordForward(count),
            'b' => self.moveWordBackward(count),
            'e' => self.moveWordEnd(count),
            'j' => self.moveDown(count),
            'k' => self.moveUp(count),
            'h' => self.moveLeft(count),
            'l' => self.moveRight(count),
            '$' => self.moveToEndOfLine(),
            '0' => self.cursor.col = 0,
            '^' => self.moveToFirstNonBlank(),
            'G' => self.moveToLastLine(),
            'g' => {
                // gg
                self.cursor.row = 0;
                self.cursor.col = 0;
            },
            else => return,
        }

        // Apply operator to range
        if (key == 'j' or key == 'k' or key == 'G' or key == 'g') {
            // Line-wise
            const from = @min(start.row, self.cursor.row);
            const to = @max(start.row, self.cursor.row);
            self.opLineRange(op, from, to);
        } else {
            // Character-wise
            self.opCharRange(op, start, self.cursor);
        }
    }

    fn opLineRange(self: *VimEditor, op: Operator, from_row: usize, to_row: usize) void {
        const from = @min(from_row, self.buffer.lineCount() -| 1);
        const to = @min(to_row, self.buffer.lineCount() -| 1);

        // Collect content
        var content = std.ArrayList(u8){};
        for (from..to + 1) |row| {
            const line = self.buffer.getLine(row);
            content.appendSlice(self.allocator, line) catch {};
            if (row < to) content.append(self.allocator, '\n') catch {};
        }
        self.yank_register.clearRetainingCapacity();
        self.yank_register.appendSlice(self.allocator, content.items) catch {};
        self.yank_is_line = true;
        content.deinit(self.allocator);

        if (op == .delete or op == .change) {
            // Delete lines from bottom up
            var row = to;
            while (row >= from) : (row -|= 1) {
                self.buffer.deleteLine(row);
                if (row == 0) break;
            }
            self.cursor.row = from;
            self.cursor.col = 0;
            self.clampCursor();
            if (op == .change) {
                if (self.buffer.lineCount() == 0 or (self.cursor.row == 0 and self.buffer.lineLen(0) == 0)) {
                    // Line was cleared
                } else {
                    self.buffer.insertLine(self.cursor.row, "");
                }
                self.mode = .insert;
            }
        }
    }

    fn opCharRange(self: *VimEditor, op: Operator, start: Cursor, end: Cursor) void {
        var from = start;
        var to = end;
        if (!Cursor.lessThan(from, to)) {
            const tmp = from;
            from = to;
            to = tmp;
        }

        // Single line for now
        if (from.row == to.row) {
            const content = self.buffer.deleteRange(from, .{ .row = to.row, .col = to.col + 1 });
            self.setYank(content, false);
            self.cursor = from;
            self.clampCursor();
            if (op == .change) self.mode = .insert;
        }
    }

    fn handleInsert(self: *VimEditor, key: u8) void {
        switch (key) {
            27 => { // Escape
                self.mode = .normal;
                if (self.cursor.col > 0) self.cursor.col -= 1;
                self.clampCursor();
            },
            127, 8 => { // Backspace
                if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                    self.buffer.deleteChar(self.cursor);
                } else if (self.cursor.row > 0) {
                    // Join with previous line
                    const prev_len = self.buffer.lineLen(self.cursor.row - 1);
                    self.buffer.joinLines(self.cursor.row - 1);
                    self.cursor.row -= 1;
                    self.cursor.col = prev_len;
                }
            },
            '\r', '\n' => {
                self.buffer.insertNewline(self.cursor);
                self.cursor.row += 1;
                self.cursor.col = 0;
            },
            '\t' => {
                // Insert 4 spaces
                for (0..4) |_| {
                    self.buffer.insertChar(self.cursor, ' ');
                    self.cursor.col += 1;
                }
            },
            else => {
                if (key >= 32 and key < 127) {
                    self.buffer.insertChar(self.cursor, key);
                    self.cursor.col += 1;
                }
            },
        }
    }

    fn handleVisual(self: *VimEditor, key: u8) void {
        switch (key) {
            27, 'v', 'V' => { // Escape or toggle
                self.mode = .normal;
            },
            'h' => self.moveLeft(1),
            'j' => self.moveDown(1),
            'k' => self.moveUp(1),
            'l' => self.moveRight(1),
            'w' => self.moveWordForward(1),
            'b' => self.moveWordBackward(1),
            'e' => self.moveWordEnd(1),
            '0' => self.cursor.col = 0,
            '$' => self.moveToEndOfLine(),
            'G' => self.moveToLastLine(),
            'g' => {
                self.cursor.row = 0;
                self.cursor.col = 0;
            },
            'd', 'x' => {
                self.deleteVisualSelection();
                self.mode = .normal;
            },
            'c' => {
                self.deleteVisualSelection();
                self.mode = .insert;
            },
            'y' => {
                self.yankVisualSelection();
                self.mode = .normal;
            },
            else => {},
        }
    }

    fn deleteVisualSelection(self: *VimEditor) void {
        if (self.mode == .visual_line) {
            const from = @min(self.visual_start.row, self.cursor.row);
            const to = @max(self.visual_start.row, self.cursor.row);
            self.opLineRange(.delete, from, to);
        } else {
            var from = self.visual_start;
            var to = self.cursor;
            if (!Cursor.lessThan(from, to)) {
                const tmp = from;
                from = to;
                to = tmp;
            }
            if (from.row == to.row) {
                const content = self.buffer.deleteRange(from, .{ .row = to.row, .col = to.col + 1 });
                self.setYank(content, false);
            }
            self.cursor = from;
            self.clampCursor();
        }
    }

    fn yankVisualSelection(self: *VimEditor) void {
        if (self.mode == .visual_line) {
            const from = @min(self.visual_start.row, self.cursor.row);
            const to = @max(self.visual_start.row, self.cursor.row);
            var content = std.ArrayList(u8){};
            for (from..to + 1) |row| {
                const line = self.buffer.getLine(row);
                content.appendSlice(self.allocator, line) catch {};
                if (row < to) content.append(self.allocator, '\n') catch {};
            }
            self.yank_register.clearRetainingCapacity();
            self.yank_register.appendSlice(self.allocator, content.items) catch {};
            self.yank_is_line = true;
            content.deinit(self.allocator);
        } else {
            var from = self.visual_start;
            var to = self.cursor;
            if (!Cursor.lessThan(from, to)) {
                const tmp = from;
                from = to;
                to = tmp;
            }
            if (from.row == to.row) {
                const line = self.buffer.getLine(from.row);
                const start = @min(from.col, line.len);
                const end = @min(to.col + 1, line.len);
                self.yank_register.clearRetainingCapacity();
                self.yank_register.appendSlice(self.allocator, line[start..end]) catch {};
                self.yank_is_line = false;
            }
        }
        self.cursor = self.visual_start;
        if (Cursor.lessThan(self.cursor, self.visual_start)) {} else {
            self.cursor = self.visual_start;
        }
    }

    fn setYank(self: *VimEditor, content: []u8, is_line: bool) void {
        self.yank_register.clearRetainingCapacity();
        self.yank_register.appendSlice(self.allocator, content) catch {};
        self.yank_is_line = is_line;
        self.allocator.free(content);
    }

    fn pasteAfter(self: *VimEditor) void {
        if (self.yank_register.items.len == 0) return;
        if (self.yank_is_line) {
            self.buffer.insertLine(self.cursor.row + 1, self.yank_register.items);
            self.cursor.row += 1;
            self.cursor.col = 0;
        } else {
            for (self.yank_register.items) |char| {
                self.cursor.col += 1;
                self.buffer.insertChar(.{ .row = self.cursor.row, .col = self.cursor.col - 1 }, char);
            }
        }
    }

    fn pasteBefore(self: *VimEditor) void {
        if (self.yank_register.items.len == 0) return;
        if (self.yank_is_line) {
            self.buffer.insertLine(self.cursor.row, self.yank_register.items);
            self.cursor.col = 0;
        } else {
            const start_col = self.cursor.col;
            for (self.yank_register.items, 0..) |char, i| {
                self.buffer.insertChar(.{ .row = self.cursor.row, .col = start_col + i }, char);
            }
        }
    }

    fn moveLeft(self: *VimEditor, count: usize) void {
        self.cursor.col -|= count;
    }

    fn moveRight(self: *VimEditor, count: usize) void {
        const max_col = self.buffer.lineLen(self.cursor.row);
        const target = if (self.mode == .insert) max_col else max_col -| 1;
        self.cursor.col = @min(self.cursor.col + count, target);
    }

    fn moveUp(self: *VimEditor, count: usize) void {
        self.cursor.row -|= count;
        self.clampCursor();
    }

    fn moveDown(self: *VimEditor, count: usize) void {
        self.cursor.row = @min(self.cursor.row + count, self.buffer.lineCount() -| 1);
        self.clampCursor();
    }

    fn moveWordForward(self: *VimEditor, count: usize) void {
        for (0..count) |_| {
            const line = self.buffer.getLine(self.cursor.row);
            var col = self.cursor.col;

            // Skip current word
            while (col < line.len and !isWordBoundary(line[col])) col += 1;
            // Skip whitespace
            while (col < line.len and line[col] == ' ') col += 1;

            if (col >= line.len and self.cursor.row + 1 < self.buffer.lineCount()) {
                self.cursor.row += 1;
                self.cursor.col = 0;
                // Skip leading whitespace on new line
                const new_line = self.buffer.getLine(self.cursor.row);
                while (self.cursor.col < new_line.len and new_line[self.cursor.col] == ' ') {
                    self.cursor.col += 1;
                }
            } else {
                self.cursor.col = col;
            }
        }
    }

    fn moveWordBackward(self: *VimEditor, count: usize) void {
        for (0..count) |_| {
            if (self.cursor.col == 0) {
                if (self.cursor.row > 0) {
                    self.cursor.row -= 1;
                    self.cursor.col = self.buffer.lineLen(self.cursor.row);
                }
                continue;
            }

            const line = self.buffer.getLine(self.cursor.row);
            var col = self.cursor.col -| 1;

            // Skip whitespace
            while (col > 0 and line[col] == ' ') col -= 1;
            // Skip word
            while (col > 0 and !isWordBoundary(line[col - 1])) col -= 1;

            self.cursor.col = col;
        }
    }

    fn moveWordEnd(self: *VimEditor, count: usize) void {
        for (0..count) |_| {
            const line = self.buffer.getLine(self.cursor.row);
            var col = self.cursor.col + 1;

            // Skip whitespace
            while (col < line.len and line[col] == ' ') col += 1;
            // Skip to end of word
            while (col < line.len and !isWordBoundary(line[col])) col += 1;

            if (col > 0) col -= 1;
            self.cursor.col = col;
        }
    }

    fn moveToFirstNonBlank(self: *VimEditor) void {
        const line = self.buffer.getLine(self.cursor.row);
        self.cursor.col = 0;
        while (self.cursor.col < line.len and line[self.cursor.col] == ' ') {
            self.cursor.col += 1;
        }
    }

    fn moveToEndOfLine(self: *VimEditor) void {
        self.cursor.col = self.buffer.lineLen(self.cursor.row) -| 1;
    }

    fn moveToLastLine(self: *VimEditor) void {
        self.cursor.row = self.buffer.lineCount() -| 1;
        self.clampCursor();
    }

    fn clampCursor(self: *VimEditor) void {
        if (self.cursor.row >= self.buffer.lineCount()) {
            self.cursor.row = self.buffer.lineCount() -| 1;
        }
        const max_col = self.buffer.lineLen(self.cursor.row);
        if (self.mode == .insert) {
            if (self.cursor.col > max_col) self.cursor.col = max_col;
        } else {
            if (self.cursor.col >= max_col and max_col > 0) {
                self.cursor.col = max_col - 1;
            } else if (max_col == 0) {
                self.cursor.col = 0;
            }
        }
    }

    fn isWordBoundary(c: u8) bool {
        return c == ' ' or c == '.' or c == ',' or c == ';' or c == ':' or
            c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}' or
            c == '<' or c == '>' or c == '"' or c == '\'' or c == '=' or c == '+' or
            c == '-' or c == '*' or c == '/' or c == '\\' or c == '|' or c == '&';
    }

    pub fn isInVisualRange(self: *const VimEditor, row: usize, col: usize) bool {
        if (self.mode != .visual and self.mode != .visual_line) return false;

        if (self.mode == .visual_line) {
            const from = @min(self.visual_start.row, self.cursor.row);
            const to = @max(self.visual_start.row, self.cursor.row);
            return row >= from and row <= to;
        }

        // Character visual
        var from = self.visual_start;
        var to = self.cursor;
        if (!Cursor.lessThan(from, to)) {
            const tmp = from;
            from = to;
            to = tmp;
        }

        if (row < from.row or row > to.row) return false;
        if (from.row == to.row) {
            return col >= from.col and col <= to.col;
        }
        if (row == from.row) return col >= from.col;
        if (row == to.row) return col <= to.col;
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TYPING TEST STATE
// ═══════════════════════════════════════════════════════════════════════════════

pub const TestState = enum { waiting, typing, finished };

pub const TypingTest = struct {
    // Target text (what user needs to type)
    target_lines: std.ArrayList([]const u8),
    target_text: []u8,

    // For non-vim modes
    typed: std.ArrayList(u8),
    cursor_pos: usize,

    // For vim mode
    vim: VimEditor,

    // Common state
    state: TestState,
    start_time: ?i64,
    end_time: ?i64,
    errors: usize,
    correct_chars: usize,
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, seed: u64, config: Config) !TypingTest {
        var rng = Rng.init(seed);
        const target = generateTarget(&rng, allocator, config);

        var target_lines = std.ArrayList([]const u8){};
        var start: usize = 0;
        for (target, 0..) |c, i| {
            if (c == '\n') {
                target_lines.append(allocator, target[start..i]) catch {};
                start = i + 1;
            }
        }
        if (start <= target.len) {
            target_lines.append(allocator, target[start..]) catch {};
        }

        return .{
            .target_lines = target_lines,
            .target_text = target,
            .typed = std.ArrayList(u8){},
            .cursor_pos = 0,
            .vim = VimEditor.init(allocator),
            .state = .waiting,
            .start_time = null,
            .end_time = null,
            .errors = 0,
            .correct_chars = 0,
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *TypingTest) void {
        self.allocator.free(self.target_text);
        self.target_lines.deinit(self.allocator);
        self.typed.deinit(self.allocator);
        self.vim.deinit();
    }

    pub fn reset(self: *TypingTest, seed: u64) !void {
        self.allocator.free(self.target_text);
        self.target_lines.clearRetainingCapacity();

        var rng = Rng.init(seed);
        const target = generateTarget(&rng, self.allocator, self.config);
        self.target_text = target;

        var start: usize = 0;
        for (target, 0..) |c, i| {
            if (c == '\n') {
                self.target_lines.append(self.allocator, target[start..i]) catch {};
                start = i + 1;
            }
        }
        if (start <= target.len) {
            self.target_lines.append(self.allocator, target[start..]) catch {};
        }

        self.typed.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.vim.reset();
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
