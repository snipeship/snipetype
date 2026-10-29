//! Vim drills: VimGolf-style challenges (start buffer → goal buffer within a
//! keystroke par) grouped into lessons, and the session that plays one.
//!
//! Challenge buffers mark the cursor with '|' ("\\|" is a literal bar).
//! Every challenge's `solutions` are replayed through the engine by the test
//! suite (src/vim/tests.zig), which keeps the par values honest.

const std = @import("std");
const editor_mod = @import("editor.zig");
const VimEditor = editor_mod.VimEditor;
const FeedResult = editor_mod.FeedResult;
const Pos = editor_mod.Pos;
const VimKey = @import("key.zig").VimKey;
const Notation = @import("key.zig").Notation;

pub const Lesson = enum {
    basics,
    words,
    find,
    line,
    operators,
    text_objects,
    visual,
    registers,
    dot,
    search,
    ex,
    macros,
    block,
    global,
    substitute,
    gn,
    sentences,

    pub fn title(self: Lesson) []const u8 {
        return switch (self) {
            .basics => "basics",
            .words => "word motions",
            .find => "find on the line",
            .line => "line motions",
            .operators => "operators",
            .text_objects => "text objects",
            .visual => "visual mode",
            .registers => "registers",
            .dot => "dot repeat",
            .search => "search",
            .ex => "ex commands",
            .macros => "macros",
            .block => "visual block",
            .global => ":g and :norm",
            .substitute => ":s with groups",
            .gn => "gn and dot",
            .sentences => "sentences",
        };
    }

    pub fn tip(self: Lesson) []const u8 {
        return switch (self) {
            .basics => "h j k l move by one; a count in front (3j) repeats the motion",
            .words => "w/b/e jump by words, W/B/E by WORDs (anything between spaces)",
            .find => "f{c}/t{c} jump to (or before) a char on the line; ; repeats, , reverses",
            .line => "0 line start, ^ first non-blank, $ line end, % matching bracket, gg/G top/bottom",
            .operators => "an operator (d c y) takes any motion: dw, c$, d2j; doubled (dd) means the line",
            .text_objects => "i/a + object picks a whole thing wherever the cursor is: ciw, di(, da[",
            .visual => "v/V select first, then operate; > and < shift lines",
            .registers => "deletes and yanks fill registers; p/P put them back; \"_ is the black hole",
            .dot => ". repeats the last change; make one change, then move and press .",
            .search => "/text<CR> jumps to text, n/N repeat, * searches the word under the cursor",
            .ex => ":s/old/new/ replaces on the line; g replaces all, % runs on every line",
            .macros => "q{a-z} records keys, q stops, @{a-z} replays, a count repeats",
            .block => "Ctrl+V selects a rectangle; I/A type on every row, $ reaches each line end",
            .global => ":g/pat/cmd runs cmd on every matching line (:v on the others); :norm types keys there",
            .substitute => "\\( \\) capture, \\1 puts the group back, & is the whole match, \\r breaks the line",
            .gn => "gn selects the next match; cgn then . changes one match at a time",
            .sentences => "( ) jump by sentences; is/as pick one (as takes the space after it)",
        };
    }
};

pub const Forbid = packed struct(u8) {
    hjkl: bool = false,
    arrows: bool = false,
    _pad: u6 = 0,
};

pub const Challenge = struct {
    /// Stable id (personal-best key), e.g. "textobj/ci-paren-01".
    id: []const u8,
    lesson: Lesson,
    title: []const u8,
    prompt: []const u8,
    /// Start buffer; '|' marks the cursor ("\\|" is a literal bar).
    start: []const u8,
    goal: []const u8,
    par: u16,
    /// Vim notation; solutions[0] is the reference.
    solutions: []const []const u8,
    why: []const u8 = "",
    forbid: Forbid = .{},
};

const challenges = @import("challenges/all.zig");

/// Every challenge, in lesson order.
pub const all: []const Challenge = &challenges.list;

pub fn byId(id: []const u8) ?*const Challenge {
    const i = indexOf(id) orelse return null;
    return &all[i];
}

pub fn indexOf(id: []const u8) ?usize {
    for (all, 0..) |*c, i| {
        if (std.mem.eql(u8, c.id, id)) return i;
    }
    return null;
}

/// The challenge after `id` in `all`, or null at the end (or unknown id).
pub fn next(id: []const u8) ?*const Challenge {
    const i = indexOf(id) orelse return null;
    if (i + 1 >= all.len) return null;
    return &all[i + 1];
}

/// 3: ≤ par and not hinted; 2: ≤ ceil(1.5·par); 1: solved.
pub fn stars(strokes: u32, par: u16, hinted_run: bool) u2 {
    if (strokes <= par and !hinted_run) return 3;
    const two = (@as(u32, par) * 3 + 1) / 2;
    if (strokes <= two) return 2;
    return 1;
}

/// A start buffer with its '|' cursor marker removed.
pub const Marked = struct {
    text: []u8,
    cursor: Pos,

    pub fn deinit(self: Marked, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Strips the first unescaped '|' (the cursor) and unescapes "\\|".
/// Without a marker the cursor is at 0:0.
pub fn parseMarked(allocator: std.mem.Allocator, s: []const u8) !Marked {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var cursor: Pos = .{};
    var found = false;
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and s[i + 1] == '|') {
            out.appendAssumeCapacity('|');
            i += 1;
            col += 1;
            continue;
        }
        if (c == '|' and !found) {
            found = true;
            cursor = .{ .row = row, .col = col };
            continue;
        }
        out.appendAssumeCapacity(c);
        if (c == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
    }
    return .{ .text = try out.toOwnedSlice(allocator), .cursor = cursor };
}

pub const DrillSession = struct {
    editor: VimEditor,
    challenge: ?*const Challenge = null,
    hint_level: u2 = 0,
    hint_buf: [320]u8 = undefined,
    hint_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) DrillSession {
        return .{ .editor = VimEditor.init(allocator, .{}) };
    }

    pub fn deinit(self: *DrillSession) void {
        self.editor.deinit();
    }

    /// Loads the challenge's start buffer with a fresh editor (registers,
    /// undo, search and stats cleared) and clears the hints.
    pub fn start(self: *DrillSession, ch: *const Challenge) !void {
        const m = try parseMarked(self.editor.allocator, ch.start);
        defer m.deinit(self.editor.allocator);
        self.editor.reset();
        try self.editor.load(m.text, m.cursor);
        self.challenge = ch;
        self.hint_level = 0;
        self.hint_len = 0;
    }

    /// Feeds one key unless the challenge forbids it (then `rejected`, a
    /// status message, and the key is not counted).
    pub fn feed(self: *DrillSession, key: VimKey) FeedResult {
        if (self.challenge) |ch| {
            if (ch.forbid.arrows and isArrowKey(key)) {
                self.editor.setStatus("arrow keys are off in this drill");
                return .{ .rejected = true };
            }
            if (ch.forbid.hjkl and self.editor.acceptsMotion()) {
                switch (key) {
                    .char => |c| if (c == 'h' or c == 'j' or c == 'k' or c == 'l') {
                        self.editor.setStatus("hjkl are off in this drill");
                        return .{ .rejected = true };
                    },
                    else => {},
                }
            }
        }
        return self.editor.feed(key);
    }

    /// The buffer equals the goal (any mode). With `!isSolved()` the UI
    /// can say "press esc to finish".
    pub fn matchesGoal(self: *const DrillSession) bool {
        const ch = self.challenge orelse return false;
        const n = self.editor.buffer.lineCount();
        if (n != lineCountOf(ch.goal)) return false;
        var it = std.mem.splitScalar(u8, ch.goal, '\n');
        var row: usize = 0;
        while (it.next()) |line| : (row += 1) {
            if (!std.mem.eql(u8, line, self.editor.buffer.getLine(row))) return false;
        }
        return true;
    }

    /// `matchesGoal()` and the editor is back in NORMAL with nothing
    /// pending: an insert was left with Esc/Ctrl+C/Ctrl+[ and the command
    /// line is closed.
    pub fn isSolved(self: *const DrillSession) bool {
        const ed = &self.editor;
        if (ed.mode != .normal or ed.isPending() or ed.ins.ctrl_o) return false;
        return self.matchesGoal();
    }

    pub fn strokes(self: *const DrillSession) u32 {
        return self.editor.stats().keystrokes;
    }

    pub fn keylog(self: *const DrillSession) []const u8 {
        return self.editor.keylog();
    }

    pub fn goalLineCount(self: *const DrillSession) usize {
        const ch = self.challenge orelse return 0;
        return lineCountOf(ch.goal);
    }

    pub fn goalLine(self: *const DrillSession, row: usize) []const u8 {
        const ch = self.challenge orelse return "";
        var it = std.mem.splitScalar(u8, ch.goal, '\n');
        var r: usize = 0;
        while (it.next()) |line| : (r += 1) {
            if (r == row) return line;
        }
        return "";
    }

    /// Buffer char at row:col differs from the goal (or the goal has none).
    pub fn charDiffers(self: *const DrillSession, row: usize, col: usize) bool {
        if (row >= self.goalLineCount()) return true;
        const g = self.goalLine(row);
        const b = self.editor.buffer.getLine(row);
        if (col >= g.len or col >= b.len) return true;
        return g[col] != b[col];
    }

    pub fn lineMatches(self: *const DrillSession, row: usize) bool {
        if (row >= self.goalLineCount() or row >= self.editor.buffer.lineCount()) return false;
        return std.mem.eql(u8, self.goalLine(row), self.editor.buffer.getLine(row));
    }

    /// Levels: 1 = lesson tip + why, 2 = first keys of solutions[0],
    /// 3 = full solution. A hinted run cannot earn 3 stars.
    pub fn revealHint(self: *DrillSession) void {
        const ch = self.challenge orelse return;
        if (self.hint_level < 3) self.hint_level += 1;
        const sol = if (ch.solutions.len > 0) ch.solutions[0] else "";
        const text = switch (self.hint_level) {
            0 => return,
            1 => if (ch.why.len > 0)
                std.fmt.bufPrint(&self.hint_buf, "{s} · {s}", .{ ch.lesson.tip(), ch.why })
            else
                std.fmt.bufPrint(&self.hint_buf, "{s}", .{ch.lesson.tip()}),
            2 => std.fmt.bufPrint(&self.hint_buf, "starts with: {s}", .{prefixKeys(sol)}),
            3 => std.fmt.bufPrint(&self.hint_buf, "solution: {s}", .{sol}),
        };
        self.hint_len = if (text) |t| t.len else |_| 0;
    }

    pub fn hint(self: *const DrillSession) ?[]const u8 {
        if (self.hint_level == 0) return null;
        return self.hint_buf[0..self.hint_len];
    }

    pub fn hinted(self: *const DrillSession) bool {
        return self.hint_level > 0;
    }
};

/// The first third of a solution's keys (at least one), as notation.
fn prefixKeys(sol: []const u8) []const u8 {
    const n = Notation.count(sol);
    const want = @max(1, (n + 2) / 3);
    var it = Notation.init(sol);
    var k: usize = 0;
    while (k < want) : (k += 1) _ = it.next();
    return sol[0..it.i];
}

fn lineCountOf(s: []const u8) usize {
    return std.mem.count(u8, s, "\n") + 1;
}

fn isArrowKey(k: VimKey) bool {
    return switch (k) {
        .up, .down, .left, .right, .word_left, .word_right, .home, .end, .page_up, .page_down, .doc_top, .doc_bottom => true,
        else => false,
    };
}

const testing = std.testing;

test "parseMarked" {
    const m = try parseMarked(testing.allocator, "ab\nc|d \\| e");
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("ab\ncd | e", m.text);
    try testing.expectEqual(@as(usize, 1), m.cursor.row);
    try testing.expectEqual(@as(usize, 1), m.cursor.col);
}

test "stars" {
    try testing.expectEqual(@as(u2, 3), stars(5, 5, false));
    try testing.expectEqual(@as(u2, 2), stars(5, 5, true));
    try testing.expectEqual(@as(u2, 2), stars(8, 5, false));
    try testing.expectEqual(@as(u2, 1), stars(9, 5, false));
}

test "ids are unique and lessons are in order" {
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.id, b.id));
        if (i > 0) try testing.expect(@backingInt(all[i - 1].lesson) <= @backingInt(a.lesson));
    }
    try testing.expect(next(all[all.len - 1].id) == null);
    try testing.expect(byId(all[0].id) == &all[0]);
}
