//! Keystroke log of a typing session: one packed record per edit plus
//! running counters, so live stats are cheap and the result (per-second
//! series, corrected mistakes) is derived from what was actually typed.

const std = @import("std");

pub const Kind = enum(u4) {
    /// A letter (not space) inserted into the active word.
    char,
    /// Space or Enter that committed the active word (`correct` = the word
    /// was right).
    space,
    newline,
    /// One character removed; `correct` = it had been typed right.
    backspace,
    /// The active word cleared; `char` = how many wrong characters it held.
    delete_word,
    delete_line,
    /// Characters removed after the caret (`char` = wrong ones removed).
    delete_forward,
    /// Backspace moved back into the previous (committed) word; `correct` =
    /// that word had been right (only possible with backspace_into_correct).
    uncommit,
    /// Enter mid-line committed word `word` as typed (the keystroke itself
    /// is the `.newline` record before it); `correct` = the word was right,
    /// so it counts towards wpm like a commit. Not a keystroke.
    skip,
};

pub const Record = packed struct(u64) {
    /// Milliseconds since the test started.
    t_ms: u32,
    char: u8,
    kind: Kind,
    /// Whether the keystroke was right at that moment.
    correct: bool,
    /// Index of the word it applied to.
    word: u19,

    /// Char keystrokes count towards raw and accuracy.
    pub fn isTyped(self: Record) bool {
        return switch (self.kind) {
            .char, .space, .newline => true,
            else => false,
        };
    }
};

pub const KeyLog = struct {
    records: std.ArrayList(Record) = .empty,
    /// Char keystrokes (letters plus committing spaces/newlines).
    typed: u32 = 0,
    /// Char keystrokes that were right when typed.
    correct: u32 = 0,
    /// Wrong characters later removed (backspace, delete word/line/forward).
    corrected: u32 = 0,
    /// Every applied edit (caret moves included).
    edits: u32 = 0,

    pub fn deinit(self: *KeyLog, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }

    pub fn clear(self: *KeyLog) void {
        self.records.clearRetainingCapacity();
        self.* = .{ .records = self.records };
    }

    /// Records one edit. Counters are updated even if the record itself
    /// can't be stored (out of memory), so live stats stay right.
    pub fn add(self: *KeyLog, allocator: std.mem.Allocator, rec: Record) void {
        if (rec.isTyped()) {
            self.typed += 1;
            if (rec.correct) self.correct += 1;
        }
        self.records.append(allocator, rec) catch {};
    }

    pub fn addCorrected(self: *KeyLog, n: u32) void {
        self.corrected += n;
    }

    /// Accuracy in percent over char keystrokes (100 with none).
    pub fn accuracy(self: *const KeyLog) f32 {
        if (self.typed == 0) return 100;
        return @as(f32, @floatFromInt(self.correct)) / @as(f32, @floatFromInt(self.typed)) * 100;
    }
};

test "records pack into 8 bytes and counters track typed keys" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Record));
    var log: KeyLog = .{};
    defer log.deinit(std.testing.allocator);
    log.add(std.testing.allocator, .{ .t_ms = 1, .char = 'a', .kind = .char, .correct = true, .word = 0 });
    log.add(std.testing.allocator, .{ .t_ms = 2, .char = 'x', .kind = .char, .correct = false, .word = 0 });
    log.add(std.testing.allocator, .{ .t_ms = 3, .char = 'x', .kind = .backspace, .correct = false, .word = 0 });
    log.addCorrected(1);
    try std.testing.expectEqual(@as(u32, 2), log.typed);
    try std.testing.expectEqual(@as(u32, 1), log.correct);
    try std.testing.expectEqual(@as(u32, 1), log.corrected);
    try std.testing.expectApproxEqAbs(@as(f32, 50), log.accuracy(), 0.001);
    log.clear();
    try std.testing.expectEqual(@as(u32, 0), log.typed);
    try std.testing.expectEqual(@as(usize, 0), log.records.items.len);
}
