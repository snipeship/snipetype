//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║  ONE - Lightning Fast Typing Speed Test                                   ║
//! ║                                                                           ║
//! ║  A beautiful, minimal TUI typing test built with pure Zig.                ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const posix = std.posix;

// ═══════════════════════════════════════════════════════════════════════════════
// WORD LIST - Common English words for typing practice
// ═══════════════════════════════════════════════════════════════════════════════

const words = [_][]const u8{
    "the",       "be",       "to",       "of",       "and",
    "a",         "in",       "that",     "have",     "I",
    "it",        "for",      "not",      "on",       "with",
    "he",        "as",       "you",      "do",       "at",
    "this",      "but",      "his",      "by",       "from",
    "they",      "we",       "say",      "her",      "she",
    "or",        "an",       "will",     "my",       "one",
    "all",       "would",    "there",    "their",    "what",
    "so",        "up",       "out",      "if",       "about",
    "who",       "get",      "which",    "go",       "me",
    "when",      "make",     "can",      "like",     "time",
    "no",        "just",     "him",      "know",     "take",
    "people",    "into",     "year",     "your",     "good",
    "some",      "could",    "them",     "see",      "other",
    "than",      "then",     "now",      "look",     "only",
    "come",      "its",      "over",     "think",    "also",
    "back",      "after",    "use",      "two",      "how",
    "our",       "work",     "first",    "well",     "way",
    "even",      "new",      "want",     "because",  "any",
    "these",     "give",     "day",      "most",     "us",
    "quick",     "brown",    "fox",      "jumps",    "lazy",
    "dog",       "pack",     "judge",    "vow",      "box",
    "sphinx",    "quartz",   "jockey",   "flame",    "wizard",
    "type",      "speed",    "test",     "fast",     "slow",
    "keyboard",  "finger",   "practice", "learn",    "master",
    "coding",    "program",  "compile",  "build",    "debug",
    "system",    "memory",   "stack",    "heap",     "pointer",
    "array",     "string",   "buffer",   "stream",   "file",
    "network",   "server",   "client",   "request",  "response",
    "algorithm", "function", "variable", "constant", "module",
};

// ═══════════════════════════════════════════════════════════════════════════════
// RENDER BUFFER - Double buffering for flicker-free rendering
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
