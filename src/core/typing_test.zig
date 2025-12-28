//! Typing test state machine and stats.

const std = @import("std");
const time = @import("../platform/time.zig");

const constants = @import("constants.zig");
const content = @import("content.zig");
const metrics = @import("metrics.zig");
const types = @import("types.zig");
const Config = types.Config;

const Rng = @import("rng.zig").Rng;
const VimEditor = @import("../vim/editor.zig").VimEditor;
const Key = @import("../platform/input.zig").Key;

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

    fn rebuildTargetLines(lines: *std.ArrayList([]const u8), allocator: std.mem.Allocator, target: []const u8) void {
        lines.clearRetainingCapacity();

        var start: usize = 0;
        for (target, 0..) |c, i| {
            if (c == '\n') {
                lines.append(allocator, target[start..i]) catch {};
                start = i + 1;
            }
        }
        if (start <= target.len) {
            lines.append(allocator, target[start..]) catch {};
        }
    }

    pub fn init(allocator: std.mem.Allocator, seed: u64, config: Config) !TypingTest {
        var rng = Rng.init(seed);
        const target = try content.generateTarget(&rng, allocator, config);

        var target_lines = std.ArrayList([]const u8){};
        rebuildTargetLines(&target_lines, allocator, target);

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

        var rng = Rng.init(seed);
        const target = try content.generateTarget(&rng, self.allocator, self.config);
        self.target_text = target;

        rebuildTargetLines(&self.target_lines, self.allocator, target);

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
                self.start_time = time.milliTimestamp();
            } else if (key >= 32 and key < 127) {
                self.state = .typing;
                self.start_time = time.milliTimestamp();
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
            self.deleteBackward();
        } else if (key >= 32 and key < 127) {
            self.insertByte(key);
        }
    }

    pub fn handleSimpleKey(self: *TypingTest, key: Key) void {
        if (self.config.mode == .vim) return;
        if (self.state == .finished) return;

        switch (key) {
            .ArrowLeft => self.moveCursorLeft(),
            .ArrowRight => self.moveCursorRight(),
            .AltArrowLeft => self.moveCursorWordLeft(),
            .AltArrowRight => self.moveCursorWordRight(),
            .Delete => self.deleteForward(),
            .AltBackspace => self.deletePrevWord(),
            .AltDelete => self.deleteNextWord(),
            else => {},
        }
    }

    fn insertByte(self: *TypingTest, byte: u8) void {
        self.typed.insert(self.allocator, self.cursor_pos, byte) catch return;
        self.cursor_pos += 1;
        if (self.typed.items.len >= self.target_text.len) {
            self.finishTest();
        }
    }

    pub fn moveCursorLeft(self: *TypingTest) void {
        if (self.cursor_pos > 0) self.cursor_pos -= 1;
    }

    pub fn moveCursorRight(self: *TypingTest) void {
        if (self.cursor_pos < self.typed.items.len) self.cursor_pos += 1;
    }

    pub fn moveCursorWordLeft(self: *TypingTest) void {
        var idx = self.cursor_pos;
        while (idx > 0 and std.ascii.isWhitespace(self.typed.items[idx - 1])) : (idx -= 1) {}
        while (idx > 0 and !std.ascii.isWhitespace(self.typed.items[idx - 1])) : (idx -= 1) {}
        self.cursor_pos = idx;
    }

    pub fn moveCursorWordRight(self: *TypingTest) void {
        const len = self.typed.items.len;
        var idx = self.cursor_pos;
        while (idx < len and std.ascii.isWhitespace(self.typed.items[idx])) : (idx += 1) {}
        while (idx < len and !std.ascii.isWhitespace(self.typed.items[idx])) : (idx += 1) {}
        self.cursor_pos = idx;
    }

    pub fn deleteBackward(self: *TypingTest) void {
        if (self.cursor_pos == 0) return;
        self.removeRange(self.cursor_pos - 1, self.cursor_pos);
        self.cursor_pos -= 1;
    }

    pub fn deleteForward(self: *TypingTest) void {
        if (self.cursor_pos >= self.typed.items.len) return;
        self.removeRange(self.cursor_pos, self.cursor_pos + 1);
    }

    pub fn deletePrevWord(self: *TypingTest) void {
        if (self.cursor_pos == 0) return;
        var start = self.cursor_pos;
        while (start > 0 and std.ascii.isWhitespace(self.typed.items[start - 1])) : (start -= 1) {}
        while (start > 0 and !std.ascii.isWhitespace(self.typed.items[start - 1])) : (start -= 1) {}
        if (start == self.cursor_pos) return;
        self.removeRange(start, self.cursor_pos);
        self.cursor_pos = start;
    }

    pub fn deleteNextWord(self: *TypingTest) void {
        const len = self.typed.items.len;
        var end = self.cursor_pos;
        while (end < len and std.ascii.isWhitespace(self.typed.items[end])) : (end += 1) {}
        while (end < len and !std.ascii.isWhitespace(self.typed.items[end])) : (end += 1) {}
        if (end == self.cursor_pos) return;
        self.removeRange(self.cursor_pos, end);
    }

    fn removeRange(self: *TypingTest, start: usize, end: usize) void {
        if (start >= end or end > self.typed.items.len) return;
        const len = self.typed.items.len;
        const remove_len = end - start;
        const tail_len = len - end;
        if (tail_len > 0) {
            std.mem.copyForwards(u8, self.typed.items[start .. start + tail_len], self.typed.items[end .. len]);
        }
        self.typed.items.len = len - remove_len;
    }

    fn checkVimCompletion(self: *TypingTest) void {
        // Allocation-free comparison using target_lines
        if (self.vim.buffer.matchesTarget(self.target_lines.items, self.target_text.len)) {
            self.finishTest();
        }
    }

    fn finishTest(self: *TypingTest) void {
        self.state = .finished;
        self.end_time = time.milliTimestamp();
        self.calculateStats();
    }

    pub fn checkTimeLimit(self: *TypingTest) void {
        if (self.config.time_limit == 0 or self.state != .typing) return;
        if (self.getElapsedSeconds() >= @as(f64, @floatFromInt(self.config.time_limit))) {
            self.finishTest();
        }
    }

    fn calculateStats(self: *TypingTest) void {
        const typed = if (self.config.mode == .vim)
            self.vim.buffer.toText(self.allocator) catch return
        else
            self.allocator.dupe(u8, self.typed.items) catch return;
        defer self.allocator.free(typed);

        const stats = metrics.compareTypedToTarget(typed, self.target_text);
        self.correct_chars = stats.correct_chars;
        self.errors = stats.errors;
    }

    pub fn getWPM(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse return 0;
        const ms = end - start;
        return metrics.wpm(self.correct_chars, ms);
    }

    pub fn getAccuracy(self: *const TypingTest) f64 {
        return metrics.accuracy(self.correct_chars, self.errors);
    }

    pub fn getElapsedSeconds(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse time.milliTimestamp();
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
        const ms = time.milliTimestamp() - start;
        if (ms < constants.MIN_WPM_MS) return 0;

        // Allocation-free character counting
        const correct_chars = if (self.config.mode == .vim) blk: {
            const result = self.vim.buffer.countMatchingChars(self.target_lines.items);
            break :blk result.correct;
        } else blk: {
            // For non-vim mode, compare directly without allocation
            const stats = metrics.compareTypedToTarget(self.typed.items, self.target_text);
            break :blk stats.correct_chars;
        };

        return metrics.wpm(correct_chars, ms);
    }
};
