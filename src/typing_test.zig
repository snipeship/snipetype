const std = @import("std");

const content = @import("content.zig");
const types = @import("types.zig");
const Config = types.Config;

const Rng = @import("rng.zig").Rng;
const VimEditor = @import("vim.zig").VimEditor;

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
        const target = content.generateTarget(&rng, allocator, config);

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
        const target = content.generateTarget(&rng, self.allocator, self.config);
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

        // Start timer on first input
        if (self.state == .waiting) {
            if (self.config.mode == .vim) {
                // In vim mode, start on any key
                self.state = .typing;
                self.start_time = std.time.milliTimestamp();
            } else if (key >= 32 and key < 127) {
                self.state = .typing;
                self.start_time = std.time.milliTimestamp();
            }
        }

        if (self.state != .typing) return;

        if (self.config.mode == .vim) {
            self.vim.handleKey(key);
            self.checkVimCompletion();
        } else {
            self.handleNormalKey(key);
        }
    }

    fn handleNormalKey(self: *TypingTest, key: u8) void {
        if (key == 127 or key == 8) {
            if (self.typed.items.len > 0) _ = self.typed.pop();
        } else if (key >= 32 and key < 127) {
            self.typed.append(self.allocator, key) catch return;
            if (self.typed.items.len >= self.target_text.len) {
                self.finishTest();
            }
        }
    }

    fn checkVimCompletion(self: *TypingTest) void {
        // Get current buffer text and compare to target
        const typed = self.vim.buffer.toText(self.allocator);
        defer self.allocator.free(typed);

        if (std.mem.eql(u8, typed, self.target_text)) {
            self.finishTest();
        }
    }

    fn finishTest(self: *TypingTest) void {
        self.state = .finished;
        self.end_time = std.time.milliTimestamp();
        self.calculateStats();
    }

    pub fn checkTimeLimit(self: *TypingTest) void {
        if (self.config.time_limit == 0 or self.state != .typing) return;
        if (self.getElapsedSeconds() >= @as(f64, @floatFromInt(self.config.time_limit))) {
            self.finishTest();
        }
    }

    fn calculateStats(self: *TypingTest) void {
        self.correct_chars = 0;
        self.errors = 0;

        const typed = if (self.config.mode == .vim)
            self.vim.buffer.toText(self.allocator)
        else
            self.allocator.dupe(u8, self.typed.items) catch return;
        defer self.allocator.free(typed);

        const len = @min(typed.len, self.target_text.len);
        for (0..len) |i| {
            if (typed[i] == self.target_text[i]) {
                self.correct_chars += 1;
            } else {
                self.errors += 1;
            }
        }
        if (typed.len > self.target_text.len) {
            self.errors += typed.len - self.target_text.len;
        } else if (typed.len < self.target_text.len) {
            self.errors += self.target_text.len - typed.len;
        }
    }

    pub fn getWPM(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse return 0;
        const ms = end - start;
        if (ms <= 0) return 0;
        return @as(f64, @floatFromInt(self.correct_chars)) / 5.0 / (@as(f64, @floatFromInt(ms)) / 60000.0);
    }

    pub fn getAccuracy(self: *const TypingTest) f64 {
        const total = self.correct_chars + self.errors;
        if (total == 0) return 100.0;
        return @as(f64, @floatFromInt(self.correct_chars)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    pub fn getElapsedSeconds(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse std.time.milliTimestamp();
        const ms = end - start;
        return if (ms > 0) @as(f64, @floatFromInt(ms)) / 1000.0 else 0;
    }

    pub fn getRemainingSeconds(self: *const TypingTest) f64 {
        if (self.config.time_limit == 0) return 0;
        return @max(0, @as(f64, @floatFromInt(self.config.time_limit)) - self.getElapsedSeconds());
    }

    pub fn getLiveWPM(self: *const TypingTest) f64 {
        if (self.state != .typing) return 0;
        const start = self.start_time orelse return 0;
        const ms = std.time.milliTimestamp() - start;
        if (ms < 1000) return 0;

        const typed = if (self.config.mode == .vim)
            self.vim.buffer.toText(self.allocator)
        else
            self.allocator.dupe(u8, self.typed.items) catch return 0;
        defer self.allocator.free(typed);

        var correct: usize = 0;
        const len = @min(typed.len, self.target_text.len);
        for (0..len) |i| {
            if (typed[i] == self.target_text[i]) correct += 1;
        }
        return @as(f64, @floatFromInt(correct)) / 5.0 / (@as(f64, @floatFromInt(ms)) / 60000.0);
    }
};
