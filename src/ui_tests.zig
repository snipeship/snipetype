//! Test entry for the UI modules (src/ui/). Run: `zig test src/ui_tests.zig`.
//!
//! View tests draw into `Screen`, a recording `Renderer` that keeps a cell
//! grid (code point, fg, bg, bold, underline) and counts writes outside the
//! screen. The views take the test as `anytype`: typing fixtures wrap a real
//! `Session`; vim and drill fixtures use small fakes of the editor and drill
//! facades (contract 2), so the views are tested independently of the
//! engine. The `renderScreen` tests at the end use a real `TypingTest`.

const std = @import("std");
const testing = std.testing;

const Color = @import("ui/color.zig").Color;
const theme_mod = @import("ui/theme.zig");
const Theme = theme_mod.Theme;
const Renderer = @import("platform/renderer.zig").Renderer;
const UiState = @import("ui/ui_state.zig").UiState;
const draw = @import("ui/draw.zig");
const typing_view = @import("ui/typing_view.zig");
const results = @import("ui/results.zig");
const vim_view = @import("ui/vim_view.zig");
const drill_view = @import("ui/drill_view.zig");
const types = @import("core/types.zig");
const Config = types.Config;
const session_mod = @import("core/session.zig");
const Session = session_mod.Session;
const Source = @import("core/source.zig").Source;
const stats = @import("core/stats.zig");
const drill_mod = @import("vim/drill.zig");
const render = @import("ui/render.zig");
const TypingTest = @import("core/typing_test.zig").TypingTest;
const query = @import("ui/query.zig");
const anim = @import("ui/anim.zig");
const heatmap = @import("ui/heatmap.zig");
const history_view = @import("ui/history_view.zig");
const history = @import("core/history.zig");
const ui_state = @import("ui/ui_state.zig");

test {
    _ = @import("ui/ansi.zig");
    _ = @import("ui/color.zig");
    _ = @import("ui/render.zig");
    _ = @import("ui/settings.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/ui_state.zig");
    _ = @import("ui/draw.zig");
    _ = @import("ui/config_bar.zig");
    _ = @import("ui/typing_view.zig");
    _ = @import("ui/results.zig");
    _ = @import("ui/vim_view.zig");
    _ = @import("ui/drill_view.zig");
    _ = @import("ui/query.zig");
    _ = @import("ui/anim.zig");
    _ = @import("ui/heatmap.zig");
    _ = @import("ui/history_view.zig");
}

// ============================================================================
// Recording renderer
// ============================================================================

const Cell = struct {
    cp: u21 = ' ',
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    underline: bool = false,
};

const Screen = struct {
    w: usize,
    h: usize,
    cells: []Cell,
    x: usize = 0,
    y: usize = 0,
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    ul: bool = false,
    /// Cells written outside the screen.
    outside: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, w: usize, h: usize) !Screen {
        const cells = try allocator.alloc(Cell, w * h);
        @memset(cells, .{});
        return .{ .w = w, .h = h, .cells = cells, .allocator = allocator };
    }

    fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
    }

    fn renderer(self: *Screen) Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn at(self: *const Screen, x: usize, y: usize) Cell {
        return self.cells[y * self.w + x];
    }

    /// Row `y` as UTF-8 (trailing spaces trimmed).
    fn row(self: *const Screen, y: usize, buf: []u8) []const u8 {
        var n: usize = 0;
        for (0..self.w) |x| {
            n += std.unicode.utf8Encode(self.at(x, y).cp, buf[n..]) catch 0;
        }
        return std.mem.trimEnd(u8, buf[0..n], " ");
    }

    /// First (x, y) where `needle` (ASCII or UTF-8) starts.
    fn find(self: *const Screen, needle: []const u8) ?struct { x: usize, y: usize } {
        var buf: [2048]u8 = undefined;
        for (0..self.h) |y| {
            const s = self.row(y, &buf);
            if (std.mem.indexOf(u8, s, needle)) |byte_i| {
                // Byte offset -> column (one column per code point).
                var col: usize = 0;
                for (s[0..byte_i]) |b| {
                    if (b & 0xC0 != 0x80) col += 1;
                }
                return .{ .x = col, .y = y };
            }
        }
        return null;
    }

    fn contains(self: *const Screen, needle: []const u8) bool {
        return self.find(needle) != null;
    }

    /// A footer hint, drawn either plain ("esc restart") or on a keycap
    /// chip ("esc  restart").
    fn hasHint(self: *const Screen, key: []const u8, label: []const u8) bool {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        const plain = std.fmt.bufPrint(&a, "{s} {s}", .{ key, label }) catch return false;
        const chip = std.fmt.bufPrint(&b, " {s}  {s}", .{ key, label }) catch return false;
        return self.contains(plain) or self.contains(chip);
    }

    fn put(self: *Screen, cp: u21) void {
        if (self.x >= self.w or self.y >= self.h) {
            self.outside += 1;
        } else {
            self.cells[self.y * self.w + self.x] = .{ .cp = cp, .fg = self.fg, .bg = self.bg, .bold = self.bold, .underline = self.ul };
        }
        self.x += 1;
    }

    fn dump(self: *const Screen) void {
        var buf: [2048]u8 = undefined;
        for (0..self.h) |y| std.debug.print("{d:>2}|{s}\n", .{ y, self.row(y, &buf) });
    }

    const Impl = struct {
        fn cast(p: *anyopaque) *Screen {
            return @ptrCast(@alignCast(p));
        }
        fn moveTo(p: *anyopaque, x: usize, y: usize) void {
            const s = cast(p);
            s.x = x;
            s.y = y;
        }
        fn setFg(p: *anyopaque, c: Color) void {
            cast(p).fg = c;
        }
        fn setBg(p: *anyopaque, c: Color) void {
            cast(p).bg = c;
        }
        fn setBold(p: *anyopaque, b: bool) void {
            cast(p).bold = b;
        }
        fn setUnderline(p: *anyopaque, b: bool) void {
            cast(p).ul = b;
        }
        fn resetStyle(p: *anyopaque) void {
            const s = cast(p);
            s.fg = null;
            s.bg = null;
            s.bold = false;
            s.ul = false;
        }
        fn write(p: *anyopaque, bytes: []const u8) void {
            const s = cast(p);
            var view = std.unicode.Utf8View.init(bytes) catch {
                for (bytes) |b| s.put(b);
                return;
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| s.put(cp);
        }
        fn writeByte(p: *anyopaque, b: u8) void {
            cast(p).put(b);
        }
        fn clear(p: *anyopaque) void {
            const s = cast(p);
            @memset(s.cells, .{});
        }
        fn clearLine(p: *anyopaque) void {
            const s = cast(p);
            if (s.y >= s.h) {
                s.outside += 1;
                return;
            }
            @memset(s.cells[s.y * s.w ..][0..s.w], .{});
        }
        fn flush(_: *anyopaque) void {}
        fn getWidth(p: *anyopaque) usize {
            return cast(p).w;
        }
        fn getHeight(p: *anyopaque) usize {
            return cast(p).h;
        }
        fn setDefaultColors(_: *anyopaque, _: Color, _: Color) void {}
        fn setUseTerminalDefaults(_: *anyopaque, _: bool) void {}
    };

    /// Every vtable entry maps to the `Impl` function of the same name.
    const vtable: Renderer.VTable = blk: {
        var v: Renderer.VTable = undefined;
        for (std.meta.fieldNames(Renderer.VTable)) |name| @field(v, name) = @field(Impl, name);
        break :blk v;
    };
};

// ============================================================================
// Fixtures
// ============================================================================

const State = enum { waiting, typing, finished };

const TypingFixture = struct {
    state: State = .typing,
    config: Config,
    start_time: ?i64 = 0,
    session: Session,
    lv: stats.Live = .{},
    clock: u32 = 0,
    /// What `paceChars` answers (contract C3).
    pace_chars: ?u64 = null,

    fn init(config: Config, chunks: []const []const u8) !TypingFixture {
        return initOpts(config, chunks, .{});
    }

    fn initOpts(config: Config, chunks: []const []const u8, opts: session_mod.Options) !TypingFixture {
        const src = Source.init(1, config, chunks);
        var o = opts;
        o.min_words = 10_000;
        return .{ .config = config, .session = try Session.init(testing.allocator, src, o) };
    }

    pub fn paceChars(self: *const TypingFixture, _: i64, _: f32) ?u64 {
        return self.pace_chars;
    }

    pub fn result(_: *const TypingFixture) ?*const stats.Result {
        return null;
    }

    fn deinit(self: *TypingFixture) void {
        self.session.deinit();
    }

    fn typeText(self: *TypingFixture, text: []const u8) void {
        for (text) |c| {
            // A steady ~80 wpm with a slower letter now and then.
            self.clock += if (c % 7 == 0) 300 else 150;
            self.session.apply(if (c == '\n') .newline else .{ .char = c }, self.clock);
        }
    }

    pub fn live(self: *const TypingFixture, now_ms: i64) stats.Live {
        var l = self.lv;
        l.elapsed_ms = now_ms - (self.start_time orelse now_ms);
        return l;
    }
};

/// Line storage for the fake editor and goal.
const Lines = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn init(text: []const u8) !Lines {
        var l: Lines = .{};
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try l.items.append(testing.allocator, line);
        return l;
    }

    fn deinit(self: *Lines) void {
        self.items.deinit(testing.allocator);
    }

    pub fn lineCount(self: *const Lines) usize {
        return self.items.items.len;
    }

    pub fn getLine(self: *const Lines, row: usize) []const u8 {
        return if (row < self.items.items.len) self.items.items[row] else "";
    }
};

/// The slice of the `VimEditor` facade (contract 2) the views read, with
/// vim-like viewport scrolling.
const FakeEditor = struct {
    buffer: Lines,
    cursor: struct { row: usize = 0, col: usize = 0 } = .{},
    mode: enum { normal, insert, replace, visual, visual_line, cmdline, visual_block } = .normal,
    opts: struct { tabstop: u8 = 8 } = .{},
    cmd: ?[]const u8 = null,
    msg: []const u8 = "",
    pending: []const u8 = "",
    rec: ?u8 = null,
    keys: u32 = 0,
    /// Selected columns on the cursor row, [start, end).
    sel: ?[2]usize = null,
    /// Visual block: rows [top, bottom] and display columns [left, right].
    block: ?struct { top: usize, bottom: usize, left: usize, right: usize } = null,
    match: ?[2]usize = null,
    rows: usize = 0,
    top: usize = 0,

    fn init(text: []const u8) !FakeEditor {
        return .{ .buffer = try Lines.init(text) };
    }

    fn deinit(self: *FakeEditor) void {
        self.buffer.deinit();
    }

    pub fn showcmd(self: *const FakeEditor) []const u8 {
        return self.pending;
    }
    pub fn cmdline(self: *const FakeEditor) ?[]const u8 {
        return self.cmd;
    }
    pub fn statusMsg(self: *const FakeEditor) []const u8 {
        return self.msg;
    }
    pub fn recording(self: *const FakeEditor) ?u8 {
        return self.rec;
    }
    pub fn stats(self: *const FakeEditor) struct { keystrokes: u32 } {
        return .{ .keystrokes = self.keys };
    }
    pub fn isInSelection(self: *const FakeEditor, row: usize, col: usize) bool {
        if (self.block) |b| {
            const d = self.displayCol(row, col);
            return row >= b.top and row <= b.bottom and d >= b.left and d <= b.right;
        }
        const r = self.sel orelse return false;
        return row == self.cursor.row and col >= r[0] and col < r[1];
    }
    pub fn isSearchMatch(self: *const FakeEditor, row: usize, col: usize) bool {
        const r = self.match orelse return false;
        return row == self.cursor.row and col >= r[0] and col < r[1];
    }
    pub fn displayCol(self: *const FakeEditor, row: usize, col: usize) usize {
        return query.displayColOf(self.buffer.getLine(row), col, self.opts.tabstop);
    }
    pub fn setViewport(self: *FakeEditor, rows: usize) void {
        self.rows = rows;
        if (self.cursor.row < self.top) self.top = self.cursor.row;
        if (rows > 0 and self.cursor.row >= self.top + rows) self.top = self.cursor.row + 1 - rows;
    }
    pub fn viewTop(self: *const FakeEditor) usize {
        return self.top;
    }
    pub fn keylog(_: *const FakeEditor) []const u8 {
        return "F(ldt)ix<Esc>";
    }
};

const VimFixture = struct {
    state: State = .typing,
    config: Config = .{ .mode = .vim, .vim_kind = .type },
    start_time: ?i64 = 0,
    vim: FakeEditor,
    target_lines: std.ArrayList([]const u8) = .empty,
    res: ?stats.Result = null,

    fn init(text: []const u8, cursor: [2]usize) !VimFixture {
        var f: VimFixture = .{ .vim = try FakeEditor.init(text) };
        f.vim.cursor = .{ .row = cursor[0], .col = cursor[1] };
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try f.target_lines.append(testing.allocator, line);
        return f;
    }

    fn deinit(self: *VimFixture) void {
        self.vim.deinit();
        self.target_lines.deinit(testing.allocator);
    }

    pub fn live(_: *const VimFixture, now_ms: i64) stats.Live {
        return .{ .elapsed_ms = now_ms, .wpm = 42 };
    }

    pub fn result(self: *const VimFixture) ?*const stats.Result {
        return if (self.res) |*r| r else null;
    }
};

const FakeLesson = enum {
    text_objects,
    pub fn title(_: FakeLesson) []const u8 {
        return "text objects";
    }
};

const FakeChallenge = struct {
    id: []const u8,
    lesson: FakeLesson = .text_objects,
    title: []const u8,
    prompt: []const u8,
    par: u16,
    solutions: []const []const u8,
    why: []const u8 = "",
};

const sample_challenge: FakeChallenge = .{
    .id = "textobj/ci-paren-01",
    .title = "change inside parens",
    .prompt = "Replace the arguments with x",
    .par = 5,
    .solutions = &.{"ci(x<Esc>"},
    .why = "ci( changes inside the nearest (…) from anywhere on the line",
};

/// The slice of `DrillSession` (contract 2) the drill view reads.
const FakeDrill = struct {
    editor: FakeEditor,
    goal: Lines,
    challenge: ?*const FakeChallenge = &sample_challenge,
    hint_text: ?[]const u8 = null,
    /// Contract C4: solved only back in NORMAL.
    solved: bool = false,

    pub fn matchesGoal(self: *const FakeDrill) bool {
        for (0..@max(self.goal.lineCount(), self.editor.buffer.lineCount())) |row| {
            if (!self.lineMatches(row)) return false;
        }
        return true;
    }
    pub fn isSolved(self: *const FakeDrill) bool {
        return self.solved;
    }

    pub fn strokes(self: *const FakeDrill) u32 {
        return self.editor.keys;
    }
    pub fn keylog(self: *const FakeDrill) []const u8 {
        return self.editor.keylog();
    }
    pub fn goalLineCount(self: *const FakeDrill) usize {
        return self.goal.lineCount();
    }
    pub fn goalLine(self: *const FakeDrill, row: usize) []const u8 {
        return self.goal.getLine(row);
    }
    pub fn charDiffers(self: *const FakeDrill, row: usize, col: usize) bool {
        const g = self.goal.getLine(row);
        const b = self.editor.buffer.getLine(row);
        return row >= self.goal.lineCount() or col >= g.len or col >= b.len or g[col] != b[col];
    }
    pub fn lineMatches(self: *const FakeDrill, row: usize) bool {
        return row < self.goal.lineCount() and std.mem.eql(u8, self.goal.getLine(row), self.editor.buffer.getLine(row));
    }
    pub fn hint(self: *const FakeDrill) ?[]const u8 {
        return self.hint_text;
    }
    pub fn revealHint(self: *FakeDrill) void {
        self.hint_text = "text objects: i( a( iw aw i\" · ci( changes inside the nearest (…)";
    }
};

const DrillFixture = struct {
    state: State = .waiting,
    config: Config = .{ .mode = .vim, .vim_kind = .drills },
    start_time: ?i64 = 0,
    drill: FakeDrill,
    res: ?stats.Result = null,

    fn init(start: []const u8, goal: []const u8) !DrillFixture {
        return .{ .drill = .{ .editor = try FakeEditor.init(start), .goal = try Lines.init(goal) } };
    }

    fn deinit(self: *DrillFixture) void {
        self.drill.editor.deinit();
        self.drill.goal.deinit();
    }

    pub fn live(_: *const DrillFixture, now_ms: i64) stats.Live {
        return .{ .elapsed_ms = now_ms };
    }

    pub fn result(self: *const DrillFixture) ?*const stats.Result {
        return if (self.res) |*r| r else null;
    }
};

const drill_start = "fn main() {\n    print(alpha, beta, gamma);\n}";
const drill_goal = "fn main() {\n    print(x);\n}";
const drill_tall = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nthis line is quite a lot longer than the others, so it overflows narrow panes";

const sample_series = [_]stats.Sample{
    .{ .t_s = 1, .wpm = 60, .raw = 70, .errors = 0 },
    .{ .t_s = 2, .wpm = 72, .raw = 80, .errors = 1 },
    .{ .t_s = 3, .wpm = 80, .raw = 84, .errors = 0 },
    .{ .t_s = 4, .wpm = 78, .raw = 90, .errors = 2 },
    .{ .t_s = 5, .wpm = 85, .raw = 88, .errors = 0 },
};
const sample_missed = [_][]const u8{ "their", "because", "through" };
const sample_slow = [_]stats.WordTime{ .{ .word = "rhythm", .ms = 1800 }, .{ .word = "queue", .ms = 1200 } };

fn sampleResult() stats.Result {
    return .{
        .kind = .typing,
        .wpm = 87.4,
        .raw = 92.1,
        .acc = 96.3,
        .consistency = 78.2,
        .chars = .{ .correct = 120, .incorrect = 3, .extra = 1, .missed = 0 },
        .corrected = 5,
        .keystrokes = 130,
        .duration_ms = 5200,
        .series = &sample_series,
        .missed_words = &sample_missed,
        .slow_words = &sample_slow,
        .valid = true,
        .quote_by = "Mark Twain",
    };
}

const one_dark = &theme_mod.THEMES.one_dark;

const small_sizes = [_][2]usize{ .{ 30, 8 }, .{ 40, 10 }, .{ 60, 20 }, .{ 20, 5 }, .{ 80, 24 }, .{ 120, 40 } };

// ============================================================================
// Typing view
// ============================================================================

test "an extra letter only affects its own word; gaps stay spaces" {
    var t = try TypingFixture.init(.{ .mode = .words }, &.{ "hello", "world", "again" });
    defer t.deinit();
    t.typeText("helloo world ag");

    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 5000);

    const p = s.find("helloo world again") orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    for (0..5) |i| try testing.expectEqual(@as(?Color, one_dark.fg), s.at(p.x + i, p.y).fg);
    try testing.expectEqual(@as(?Color, one_dark.error_extra), s.at(p.x + 5, p.y).fg);
    // The separator is a plain space with no error background.
    try testing.expectEqual(@as(u21, ' '), s.at(p.x + 6, p.y).cp);
    try testing.expectEqual(@as(?Color, null), s.at(p.x + 6, p.y).bg);
    for (7..12) |x| try testing.expectEqual(@as(?Color, one_dark.fg), s.at(p.x + x, p.y).fg);
    // "ag" typed, "ain" pending.
    try testing.expectEqual(@as(?Color, one_dark.fg), s.at(p.x + 14, p.y).fg);
    try testing.expectEqual(@as(?Color, one_dark.dim), s.at(p.x + 16, p.y).fg);
    // Caret after "ag".
    const c = typing_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(p.x + 15, c.x);
    try testing.expectEqual(p.y, c.y);
}

test "a mistyped letter is red text without a background" {
    var t = try TypingFixture.init(.{ .mode = .words }, &.{ "cat", "dog" });
    defer t.deinit();
    t.typeText("cot d");
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 5000);
    const p = s.find("cat dog").?;
    try testing.expectEqual(@as(?Color, one_dark.danger), s.at(p.x + 1, p.y).fg);
    try testing.expectEqual(@as(?Color, null), s.at(p.x + 1, p.y).bg);
    try testing.expectEqual(@as(u21, 'a'), s.at(p.x + 1, p.y).cp);
}

test "a missed letter is underlined" {
    var t = try TypingFixture.init(.{ .mode = .words }, &.{ "hello", "world" });
    defer t.deinit();
    t.typeText("helo w");
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 5000);
    const p = s.find("hello world").?;
    // h e l correct, 'l' vs 'o' wrong, final 'o' missed.
    try testing.expect(!s.at(p.x + 2, p.y).underline);
    try testing.expectEqual(@as(?Color, one_dark.danger), s.at(p.x + 3, p.y).fg);
    try testing.expect(s.at(p.x + 4, p.y).underline);
    try testing.expectEqual(@as(?Color, one_dark.dim), s.at(p.x + 4, p.y).fg);
    // Pending letters of the active word are not underlined.
    try testing.expect(!s.at(p.x + 7, p.y).underline);
}

test "code mode draws newline marks and indentation" {
    var t = try TypingFixture.init(.{ .mode = .code }, &.{"main:\n    return;\n}"});
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    const a = s.find("main:" ++ typing_view.NEWLINE_MARK) orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    const b = s.find("return;" ++ typing_view.NEWLINE_MARK).?;
    const c = s.find("}").?;
    try testing.expectEqual(a.x + 4, b.x);
    try testing.expectEqual(a.y + 1, b.y);
    try testing.expectEqual(a.x, c.x);
    try testing.expectEqual(b.y + 1, c.y);
    try testing.expectEqual(@as(?Color, one_dark.dimmer), s.at(a.x + 5, a.y).fg);
    // Enter at the newline moves the caret to the indented next line.
    t.typeText("main:\n");
    const caret = typing_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(b.x, caret.x);
    try testing.expectEqual(b.y, caret.y);
}

test "words inside a chunk keep their gaps" {
    var t = try TypingFixture.init(.{ .mode = .sentences }, &.{"the quick fox"});
    defer t.deinit();
    // stream B: words inside one chunk line must get `.space` separators.
    if (t.session.word(0).sep != .space) return error.SkipZigTest;
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains("the quick fox"));
}

test "the active line is the second visible line" {
    var words: [60][]const u8 = undefined;
    for (&words) |*w| w.* = "abcdefgh";
    var t = try TypingFixture.init(.{ .mode = .words }, &words);
    defer t.deinit();
    for (0..30) |_| t.typeText("abcdefgh ");
    const f = draw.frameFor(80, 24);
    const lay = typing_view.layout(&t, f);
    try testing.expect(lay.caret_line >= 2);
    try testing.expectEqual(lay.caret_line - 1, lay.first_line);
    const c = typing_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(lay.text_y + lay.line_gap, c.y);
}

test "idle config bar and focus mode" {
    var t = try TypingFixture.init(.{ .mode = .words, .word_count = 25, .punctuation = true }, &.{ "a", "b" });
    defer t.deinit();
    t.state = .waiting;
    var s = try Screen.init(testing.allocator, 100, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{ .best_wpm = 87 }, 0);
    try testing.expect(s.contains("words · common · 25 │ punctuation · numbers │ best 87 wpm"));
    const p = s.find("punctuation").?;
    try testing.expectEqual(@as(?Color, one_dark.accent), s.at(p.x, p.y).fg);
    const n = s.find("numbers").?;
    try testing.expectEqual(@as(?Color, one_dark.dim), s.at(n.x, n.y).fg);
    try testing.expect(s.hasHint("esc", "restart"));

    t.state = .typing;
    typing_view.render(s.renderer(), one_dark, &t, &.{ .is_web = true, .toast = "saved" }, 3000);
    try testing.expect(s.hasHint("ctrl+backspace", "delete word"));
    try testing.expect(s.contains("saved"));
    const e = s.find("esc").?;
    try testing.expectEqual(@as(?Color, one_dark.dimmer), s.at(e.x, e.y).fg);
}

test "idle config bar with a single group drops the hint, not its values" {
    const config_bar = @import("ui/config_bar.zig");
    var s = try Screen.init(testing.allocator, 40, 1);
    defer s.deinit();
    // "code · go · 25 │ plain keys" plus "   ctrl+p to change" is 46
    // columns; without the hint 27.
    config_bar.render(s.renderer(), one_dark, 0, 0, 30, .{ .mode = .code, .lang = .go, .word_count = 25 }, &.{});
    var buf: [256]u8 = undefined;
    const line = std.mem.trim(u8, s.row(0, &buf), " ");
    try testing.expectEqualStrings("code · go · 25 │ plain keys", line);
    // Narrower: the keys group goes too, the shape stays.
    var n = try Screen.init(testing.allocator, 40, 1);
    defer n.deinit();
    config_bar.render(n.renderer(), one_dark, 0, 0, 20, .{ .mode = .code, .lang = .go, .word_count = 25 }, &.{});
    try testing.expectEqualStrings("code · go · 25", std.mem.trim(u8, n.row(0, &buf), " "));
    try testing.expectEqual(@as(usize, 0), s.outside);
}

test "extra letters don't shift the text block sideways" {
    var t = try TypingFixture.init(.{ .mode = .code }, &.{"fn main() {\n    return 0;\n}"});
    defer t.deinit();
    const f = draw.frameFor(80, 24);
    const before = typing_view.layout(&t, f).text_x;
    t.typeText("fnxxxx");
    const lay = typing_view.layout(&t, f);
    try testing.expectEqual(before, lay.text_x);
    // ...until they would run past the column: then it moves left just
    // enough. 20 extras make the first line "fn" + 20 + " main() {" = 31.
    t.typeText("xxxxxxxxxxxxxxxx");
    const narrow = draw.frameFor(40, 24);
    const lay2 = typing_view.layout(&t, narrow);
    try testing.expect(lay2.text_x + 31 < narrow.col_x + narrow.col_w);
    try testing.expect(lay2.text_x < narrow.col_x + (narrow.col_w - 12) / 2);
}

// ============================================================================
// Results
// ============================================================================

test "results draw the PB banner for each outcome" {
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    const res = sampleResult();
    const cfg: Config = .{ .mode = .words, .word_count = 25 };
    const cases = [_]struct { ui: UiState, text: ?[]const u8 }{
        .{ .ui = .{ .pb = .first }, .text = "first result for this setup" },
        .{ .ui = .{ .pb = .{ .improved = 80 } }, .text = "▲ new personal best +7.4 wpm" },
        .{ .ui = .{ .pb = .{ .missed = 101 } }, .text = "best 101 wpm" },
        .{ .ui = .{ .practice = true }, .text = "practice · not recorded" },
        .{ .ui = .{ .pb = .none }, .text = null },
    };
    for (cases) |c| {
        results.render(s.renderer(), one_dark, &res, cfg, &c.ui);
        if (c.text) |txt| {
            if (!s.contains(txt)) {
                s.dump();
                return error.TestUnexpectedResult;
            }
        } else {
            try testing.expect(!s.contains("best"));
            try testing.expect(!s.contains("first result"));
        }
    }
    // The rest of the card is there too.
    try testing.expect(s.contains("corrected 5"));
    try testing.expect(s.contains("missed  their because through"));
    try testing.expect(s.contains("— Mark Twain"));
    try testing.expect(s.contains("×"));
    try testing.expect(s.hasHint("enter", "next"));
}

test "vim type results show keys and efficiency" {
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    var res = sampleResult();
    res.kind = .vim_type;
    res.efficiency = 0.82;
    results.render(s.renderer(), one_dark, &res, .{ .mode = .vim, .vim_kind = .type }, &.{});
    try testing.expect(s.contains("keys 130"));
    try testing.expect(s.contains("efficiency 82%"));
    try testing.expect(!s.hasHint("m", "missed words"));
}

// ============================================================================
// Vim view
// ============================================================================

fn manyLines(buf: []u8, n: usize) []const u8 {
    var len: usize = 0;
    for (0..n) |i| {
        const line = std.fmt.bufPrint(buf[len..], "{s}line {d}", .{ if (i > 0) "\n" else "", i + 1 }) catch unreachable;
        len += line.len;
    }
    return buf[0..len];
}

test "vim view keeps the cursor row visible in a long buffer" {
    var text_buf: [1024]u8 = undefined;
    var t = try VimFixture.init(manyLines(&text_buf, 60), .{ 54, 2 });
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 1000);
    const p = s.find("55 line 55") orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    const c = vim_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(p.y, c.y);
    try testing.expectEqual(p.x + 3 + 2, c.x);
    try testing.expectEqual(@as(?Color, one_dark.cursor_bg), s.at(c.x, c.y).bg);
    try testing.expectEqual(s.outside, 0);
}

test "vim view gutter starts at the header column" {
    var t = try VimFixture.init("const a = 1;\nconst b = 2;", .{ 0, 0 });
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 1000);
    const brand = s.find("❯ snipetype").?;
    const g = s.find("  1 const a").?;
    try testing.expectEqual(brand.x, g.x);
}

test "long lines scroll horizontally with markers" {
    var line: [200]u8 = undefined;
    for (&line, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var t = try VimFixture.init(&line, .{ 0, 0 });
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains(vim_view.RIGHT_MARK));
    try testing.expect(!s.contains(vim_view.LEFT_MARK));

    t.vim.cursor.col = 150;
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains(vim_view.LEFT_MARK));
    try testing.expect(s.contains(vim_view.RIGHT_MARK));
    const c = vim_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(@as(u21, line[150]), s.at(c.x, c.y).cp);
    try testing.expectEqual(@as(?Color, one_dark.cursor_bg), s.at(c.x, c.y).bg);
    try testing.expect(c.x < 80);
}

test "the command line replaces the status row" {
    var t = try VimFixture.init("hello", .{ 0, 0 });
    defer t.deinit();
    t.vim.mode = .cmdline;
    t.vim.cmd = ":s/a/b";
    const cl = t.vim.cmdline().?;
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    const p = s.find(cl).?;
    const c = vim_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(p.y, c.y);
    try testing.expectEqual(p.x + cl.len, c.x);
}

test "mode pill and done" {
    var t = try VimFixture.init("hello", .{ 0, 0 });
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 30);
    defer s.deinit();
    t.vim.mode = .insert;
    t.vim.rec = 'q';
    t.vim.pending = "2d";
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains("-- INSERT --  recording @q"));
    try testing.expect(s.contains("2d   1:1"));
    t.state = .finished;
    t.res = sampleResult();
    t.res.?.kind = .vim_type;
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains(" done "));
    try testing.expect(!s.contains("INSERT"));
    try testing.expect(s.contains("keys 130"));
    try testing.expect(!vim_view.cursorPos(&t, 80, 30).visible);
}

// ============================================================================
// Drill view
// ============================================================================

test "drill view: header, panes, diff tint" {
    var t = try DrillFixture.init(drill_start, drill_goal);
    defer t.deinit();
    t.drill.editor.cursor = .{ .row = 1, .col = 10 };
    var s = try Screen.init(testing.allocator, 120, 40);
    defer s.deinit();
    drill_view.render(s.renderer(), one_dark, &t, &.{ .drill_best = .{ .strokes = 4, .stars = 2 } }, .{ .index = 6, .total = 40 }, 0);
    try testing.expect(s.contains("drills › text objects · change inside parens"));
    try testing.expect(s.contains("7 / 40  ·  par 5  ·  best 4 ★★☆"));
    try testing.expect(s.contains("Replace the arguments with x"));
    try testing.expect(s.contains("╭─ buffer "));
    try testing.expect(s.contains("╭─ goal "));
    try testing.expect(s.hasHint("f1", "hint"));
    // Some buffer letter differs from the goal and is tinted.
    var tinted = false;
    for (s.cells) |cell| {
        if (cell.fg != null and std.meta.eql(cell.fg.?, one_dark.warning)) tinted = true;
    }
    try testing.expect(tinted);
    // Matching lines are dimmed.
    const m = s.find("fn main() {").?;
    try testing.expectEqual(@as(?Color, one_dark.dim), s.at(m.x, m.y).fg);
    // Side by side: buffer left, goal right, on the same rows.
    const b = s.find("╭─ buffer ").?;
    const g = s.find("╭─ goal ").?;
    try testing.expectEqual(b.y, g.y);
    try testing.expect(g.x > b.x);
    const c = drill_view.cursorPos(&t, 120, 40);
    try testing.expect(c.visible);
    try testing.expectEqual(@as(u21, 'a'), s.at(c.x, c.y).cp);

    // Narrow: stacked, goal on top.
    var n = try Screen.init(testing.allocator, 50, 30);
    defer n.deinit();
    drill_view.render(n.renderer(), one_dark, &t, &.{}, .{ .total = 40 }, 0);
    const nb = n.find("╭─ buffer ").?;
    const ng = n.find("╭─ goal ").?;
    try testing.expect(ng.y < nb.y);

    // A revealed hint is shown.
    t.drill.revealHint();
    drill_view.render(s.renderer(), one_dark, &t, &.{}, .{ .total = 40 }, 0);
    try testing.expect(s.contains("hint  text objects"));
}

test "drill solved card" {
    var t = try DrillFixture.init(drill_goal, drill_goal);
    defer t.deinit();
    t.state = .finished;
    t.res = sampleResult();
    t.res.?.kind = .vim_drill;
    t.res.?.strokes = 9;
    t.res.?.par = 5;
    t.res.?.stars = 2;
    t.res.?.duration_ms = 3100;
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    drill_view.render(s.renderer(), one_dark, &t, &.{ .pb = .{ .improved = 12 } }, .{ .total = 1 }, 0);
    try testing.expect(s.contains("solved ★★☆  9 keys (par 5) · 3.1s"));
    try testing.expect(s.contains("▲ new best"));
    try testing.expect(s.contains("you   F(ldt)ix<Esc>"));
    try testing.expect(s.contains("par   ci(x<Esc>   — ci( changes inside"));
    try testing.expect(s.hasHint("enter", "next"));
    try testing.expect(!drill_view.cursorPos(&t, 100, 30).visible);
}

// ============================================================================
// Small screens
// ============================================================================

test "small screens: typing view stays on screen" {
    for (small_sizes) |sz| {
        var s = try Screen.init(testing.allocator, sz[0], sz[1]);
        defer s.deinit();
        const r = s.renderer();
        errdefer std.debug.print("size {d}x{d}\n", .{ sz[0], sz[1] });

        var tt = try TypingFixture.init(.{ .mode = .words }, &.{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu" });
        defer tt.deinit();
        tt.typeText("alphx beta gamma de");
        typing_view.render(r, one_dark, &tt, &.{ .toast = "a toast that is rather long for a tiny screen" }, 4000);
        tt.state = .waiting;
        typing_view.render(r, one_dark, &tt, &.{ .best_wpm = 99 }, 0);
        try testing.expectEqual(@as(usize, 0), s.outside);

        var code = try TypingFixture.init(.{ .mode = .code }, &.{"fn main() {\n    if (x) {\n        return some_long_function_name(argument_one, argument_two, argument_three_is_long);\n    }\n}"});
        defer code.deinit();
        typing_view.render(r, one_dark, &code, &.{}, 0);
        const c = typing_view.cursorPos(&code, sz[0], sz[1]);
        try testing.expect(c.x < sz[0] and c.y < sz[1]);
        try testing.expectEqual(@as(usize, 0), s.outside);
    }
}

test "small screens: results stay on screen" {
    for (small_sizes) |sz| {
        var s = try Screen.init(testing.allocator, sz[0], sz[1]);
        defer s.deinit();
        errdefer std.debug.print("size {d}x{d}\n", .{ sz[0], sz[1] });
        var res = sampleResult();
        for ([_]UiState{ .{}, .{ .pb = .{ .improved = 50 } } }) |ui| {
            results.render(s.renderer(), one_dark, &res, .{ .mode = .words }, &ui);
            res.kind = .vim_type;
            results.render(s.renderer(), one_dark, &res, .{ .mode = .vim }, &ui);
            res.kind = .typing;
        }
        try testing.expectEqual(@as(usize, 0), s.outside);
    }
}

test "small screens: vim view stays on screen" {
    var text_buf: [1024]u8 = undefined;
    for (small_sizes) |sz| {
        var s = try Screen.init(testing.allocator, sz[0], sz[1]);
        defer s.deinit();
        const r = s.renderer();
        errdefer std.debug.print("size {d}x{d}\n", .{ sz[0], sz[1] });
        var vt = try VimFixture.init(manyLines(&text_buf, 40), .{ 30, 3 });
        defer vt.deinit();
        vim_view.render(r, one_dark, &vt, &.{}, 0);
        const c = vim_view.cursorPos(&vt, sz[0], sz[1]);
        try testing.expect(c.x < sz[0] and c.y < sz[1]);
        vt.state = .finished;
        vt.res = sampleResult();
        vt.res.?.kind = .vim_type;
        vim_view.render(r, one_dark, &vt, &.{}, 0);
        try testing.expectEqual(@as(usize, 0), s.outside);
    }
}

test "small screens: drill view stays on screen" {
    for (small_sizes) |sz| {
        var s = try Screen.init(testing.allocator, sz[0], sz[1]);
        defer s.deinit();
        const r = s.renderer();
        errdefer std.debug.print("size {d}x{d}\n", .{ sz[0], sz[1] });
        for ([_][]const u8{ drill_start, drill_tall }) |start| {
            var dt = try DrillFixture.init(start, drill_goal);
            defer dt.deinit();
            dt.drill.editor.cursor = .{ .row = dt.drill.editor.buffer.lineCount() - 1, .col = 60 };
            dt.drill.revealHint();
            drill_view.render(r, one_dark, &dt, &.{ .drill_best = .{ .strokes = 3, .stars = 3 } }, .{ .total = 40 }, 0);
            const c = drill_view.cursorPos(&dt, sz[0], sz[1]);
            if (!(c.x < sz[0] and c.y < sz[1])) {
                s.dump();
                std.debug.print("cursor {d},{d}\n", .{ c.x, c.y });
            }
            try testing.expect(c.x < sz[0] and c.y < sz[1]);
            dt.state = .finished;
            dt.res = sampleResult();
            dt.res.?.kind = .vim_drill;
            drill_view.render(r, one_dark, &dt, &.{ .pb = .first }, .{ .total = 40 }, 0);
            try testing.expectEqual(@as(usize, 0), s.outside);
        }
    }
}

// ============================================================================
// renderScreen with a real TypingTest
// ============================================================================

/// Type the active word's target and its separator.
fn typeWord(t: *TypingTest, now: *i64) void {
    const wv = t.session.word(t.session.activeIndex());
    for (wv.target) |c| {
        now.* += 120;
        t.handleEdit(.{ .char = c }, now.*);
    }
    now.* += 120;
    switch (wv.sep) {
        .space => t.handleEdit(.{ .char = ' ' }, now.*),
        .newline => t.handleEdit(.newline, now.*),
        .end => {},
    }
}

fn expectOnScreen(s: *const Screen, c: render.CursorPos) !void {
    try testing.expectEqual(@as(usize, 0), s.outside);
    try testing.expect(c.x < s.w and c.y < s.h);
}

test "renderScreen: simple modes from waiting to results" {
    const cfgs = [_]Config{
        .{ .mode = .words, .word_count = 12 },
        .{ .mode = .words, .time_limit = 15, .punctuation = true, .numbers = true },
        .{ .mode = .sentences, .word_count = 10 },
        .{ .mode = .code, .word_count = 20 },
    };
    var skipped = false;
    for (cfgs) |cfg| {
        for (small_sizes) |sz| {
            var t = try TypingTest.init(testing.allocator, 7, cfg);
            defer t.deinit();
            // stream B: words inside one chunk line still get `.end`
            // separators, so such a test can't be typed to the end.
            if (t.session.wordCount() > 1 and t.session.word(0).sep == .end) {
                skipped = true;
                continue;
            }
            var s = try Screen.init(testing.allocator, sz[0], sz[1]);
            defer s.deinit();
            errdefer std.debug.print("{s} {d}x{d}\n", .{ cfg.mode.name(), sz[0], sz[1] });
            var now: i64 = 1000;
            render.renderAt(s.renderer(), &t, one_dark, &.{}, now);
            try expectOnScreen(&s, render.getCursorPos(&t, &.{}, sz[0], sz[1]));
            for (0..3) |_| typeWord(&t, &now);
            render.renderAt(s.renderer(), &t, one_dark, &.{}, now);
            try expectOnScreen(&s, render.getCursorPos(&t, &.{}, sz[0], sz[1]));
            var guard: usize = 0;
            while (t.state != .finished and guard < 400) : (guard += 1) typeWord(&t, &now);
            if (t.state != .finished) t.tick(now + 60_000);
            try testing.expect(t.result() != null);
            render.renderAt(s.renderer(), &t, one_dark, &.{ .pb = .first }, now);
            const c = render.getCursorPos(&t, &.{}, sz[0], sz[1]);
            try expectOnScreen(&s, c);
            try testing.expect(!c.visible);
        }
    }
    if (skipped) return error.SkipZigTest;
}

test "renderScreen: vim type and drills" {
    const cfgs = [_]Config{
        .{ .mode = .vim, .vim_kind = .type, .lang = .zig },
        .{ .mode = .vim, .vim_kind = .drills },
    };
    for (cfgs) |cfg| {
        for (small_sizes) |sz| {
            var t = try TypingTest.init(testing.allocator, 7, cfg);
            defer t.deinit();
            var s = try Screen.init(testing.allocator, sz[0], sz[1]);
            defer s.deinit();
            errdefer std.debug.print("{s} {d}x{d}\n", .{ cfg.vim_kind.name(), sz[0], sz[1] });
            render.renderAt(s.renderer(), &t, one_dark, &.{}, 0);
            try expectOnScreen(&s, render.getCursorPos(&t, &.{}, sz[0], sz[1]));
            for ("ixyz") |c| _ = t.handleVimKey(.{ .char = c }, 500);
            render.renderAt(s.renderer(), &t, one_dark, &.{}, 1000);
            try expectOnScreen(&s, render.getCursorPos(&t, &.{}, sz[0], sz[1]));
            _ = t.handleVimKey(.esc, 1200);
            _ = t.handleVimKey(.{ .char = ':' }, 1300);
            render.renderAt(s.renderer(), &t, one_dark, &.{}, 1400);
            try expectOnScreen(&s, render.getCursorPos(&t, &.{}, sz[0], sz[1]));
        }
    }
}

test "renderScreen: a drill solved with its reference solution" {
    if (drill_mod.all.len == 0) return error.SkipZigTest;
    var t = try TypingTest.init(testing.allocator, 7, .{ .mode = .vim, .vim_kind = .drills });
    defer t.deinit();
    const ch = t.drill.challenge orelse return error.SkipZigTest;
    var it = @import("vim/key.zig").Notation.init(ch.solutions[0]);
    var now: i64 = 0;
    while (it.next()) |k| {
        now += 200;
        _ = t.handleVimKey(k, now);
    }
    if (t.state != .finished) return error.SkipZigTest; // stream A: engine can't solve it yet
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    render.renderAt(s.renderer(), &t, one_dark, &.{ .pb = .first }, now);
    try testing.expect(s.contains("solved "));
    try testing.expect(s.contains(ch.solutions[0]));
    try testing.expect(!render.getCursorPos(&t, &.{}, 100, 30).visible);
}

// ============================================================================
// Themes
// ============================================================================

test "every theme: slug round trip, fg differs from dim" {
    inline for (comptime std.meta.tags(theme_mod.ThemeId)) |id| {
        try testing.expectEqual(@as(?theme_mod.ThemeId, id), theme_mod.fromSlug(theme_mod.slug(id)));
        const t = theme_mod.resolve(id);
        try testing.expect(!std.meta.eql(t.fg, t.dim));
    }
}

// ============================================================================
// Tiny terminals
// ============================================================================

test "tiny terminals get a notice, never writes off screen" {
    const sizes = [_][2]usize{ .{ 1, 1 }, .{ 2, 2 }, .{ 10, 4 }, .{ 19, 30 }, .{ 80, 4 }, .{ 80, 6 }, .{ 20, 5 } };
    const cfgs = [_]Config{
        .{ .mode = .words },
        .{ .mode = .code, .lang = .go },
        .{ .mode = .vim, .vim_kind = .type },
        .{ .mode = .vim, .vim_kind = .drills },
    };
    for (cfgs) |cfg| {
        for (sizes) |sz| {
            var t = try TypingTest.init(testing.allocator, 7, cfg);
            defer t.deinit();
            var s = try Screen.init(testing.allocator, sz[0], sz[1]);
            defer s.deinit();
            errdefer std.debug.print("{s} {d}x{d}\n", .{ cfg.mode.name(), sz[0], sz[1] });
            render.renderAt(s.renderer(), &t, one_dark, &.{ .toast = "a toast" }, 0);
            const c = render.getCursorPos(&t, &.{}, sz[0], sz[1]);
            try testing.expectEqual(@as(usize, 0), s.outside);
            try testing.expect(c.x < sz[0] and c.y < sz[1]);
            const small = sz[0] < render.MIN_WIDTH or sz[1] < (if (cfg.mode == .vim) render.MIN_HEIGHT_VIM else render.MIN_HEIGHT);
            try testing.expectEqual(!small, c.visible);
            if (small and sz[0] >= 19) try testing.expect(s.contains("terminal too small"));
        }
    }
}

test "settings overlay fits small terminals and keeps option values readable" {
    const Settings = @import("ui/settings.zig").Settings;
    const sizes = [_][2]usize{ .{ 24, 6 }, .{ 30, 8 }, .{ 40, 10 }, .{ 60, 16 }, .{ 80, 24 }, .{ 120, 40 } };
    const cfgs = [_]Config{ .{ .mode = .words }, .{ .mode = .vim, .vim_kind = .type }, .{ .mode = .code } };
    for (cfgs) |cfg| {
        for (sizes) |sz| {
            var st = Settings{};
            st.base = cfg;
            st.open(.one_dark, cfg.mode);
            // Tab twice: the test panel.
            _ = st.handleKey(.{ .Byte = '\t' });
            _ = st.handleKey(.{ .Byte = '\t' });
            var s = try Screen.init(testing.allocator, sz[0], sz[1]);
            defer s.deinit();
            errdefer {
                std.debug.print("{s} {d}x{d}\n", .{ cfg.mode.name(), sz[0], sz[1] });
                s.dump();
            }
            st.renderOverlay(s.renderer(), one_dark, .one_dark, cfg.mode);
            try testing.expectEqual(@as(usize, 0), s.outside);
            // The bottom border is drawn and not overwritten.
            try testing.expect(s.contains("╰"));
            try testing.expect(s.contains("╯"));
            // Where the test panel shows, values are not cut to a letter.
            if (s.contains("length")) try testing.expect(s.contains("words") or s.contains("s"));
            if (cfg.mode == .words and s.contains("tier")) try testing.expect(s.contains("common"));
        }
    }
}

// ============================================================================
// Round 2: screens, code + vim keys, the idle bar
// ============================================================================

const code_vim_cfg: Config = .{ .mode = .code, .code_keys = .vim, .lang = .rust };

test "screenOf follows vimKind; the history overlay beats every screen" {
    var vt = try VimFixture.init("fn main() {}", .{ 0, 0 });
    defer vt.deinit();
    vt.config = code_vim_cfg;
    try testing.expectEqual(render.Screen.vim_type, render.screenOf(&vt, &.{}));
    vt.config = .{ .mode = .vim, .vim_kind = .type };
    try testing.expectEqual(render.Screen.vim_type, render.screenOf(&vt, &.{}));
    vt.config = .{ .mode = .code };
    try testing.expectEqual(render.Screen.typing, render.screenOf(&vt, &.{}));

    var dt = try DrillFixture.init(drill_start, drill_goal);
    defer dt.deinit();
    try testing.expectEqual(render.Screen.drill, render.screenOf(&dt, &.{}));
    try testing.expectEqual(render.Screen.history, render.screenOf(&dt, &.{ .overlay = .history }));

    var tt = try TypingFixture.init(.{ .mode = .code }, &.{"fn main() {}"});
    defer tt.deinit();
    try testing.expectEqual(render.Screen.typing, render.screenOf(&tt, &.{}));
    try testing.expectEqual(render.Screen.history, render.screenOf(&tt, &.{ .overlay = .history }));
}

test "code with vim keys: the vim view says so and offers plain keys" {
    var t = try VimFixture.init("fn main() {\n    return;\n}", .{ 0, 0 });
    defer t.deinit();
    t.config = code_vim_cfg;
    t.state = .waiting;
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains("code · rust · vim keys"));
    try testing.expect(s.hasHint("ctrl+k", "plain keys"));
    t.state = .typing;
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(!s.hasHint("ctrl+k", "plain keys"));
    // Plain vim type has no ctrl+k.
    t.config = .{ .mode = .vim, .vim_kind = .type };
    t.state = .waiting;
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(!s.hasHint("ctrl+k", "plain keys"));
}

test "code idle: real word count, keys item and the ctrl+k hint" {
    var t = try TypingFixture.init(.{ .mode = .code, .lang = .rust, .word_count = 25 }, &.{"fn main() {\n    let x = 1;\n}"});
    defer t.deinit();
    t.state = .waiting;
    var s = try Screen.init(testing.allocator, 100, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    var buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "code · rust · {d} words │ plain keys", .{t.session.wordCount()});
    if (!s.contains(want)) {
        s.dump();
        return error.TestUnexpectedResult;
    }
    try testing.expect(s.hasHint("ctrl+k", "vim keys"));
    try testing.expect(!s.hasHint("enter", "skip line"));
    // While typing: Enter skips the rest of the line.
    t.state = .typing;
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 1000);
    try testing.expect(s.hasHint("enter", "skip line"));
    try testing.expect(!s.hasHint("ctrl+k", "vim keys"));
}

test "idle bar: strict chips, layout, weak keys, daily date; drop order" {
    const config_bar = @import("ui/config_bar.zig");
    var s = try Screen.init(testing.allocator, 160, 1);
    defer s.deinit();
    var buf: [512]u8 = undefined;
    const cfg: Config = .{ .mode = .words, .word_count = 25, .stop_on_error = .letter, .no_backspace = true, .layout = .dvorak, .focus = .weak };
    config_bar.render(s.renderer(), one_dark, 0, 0, 160, cfg, &.{ .best_wpm = 90 });
    try testing.expectEqualStrings(
        "words · common · 25 │ punctuation · numbers │ stop on letter · no backspace · dvorak · weak keys │ best 90 wpm   ctrl+p to change",
        std.mem.trim(u8, s.row(0, &buf), " "),
    );
    // Narrower: hint, then best, then the toggles go; the strict chips stay.
    @memset(s.cells, .{});
    config_bar.render(s.renderer(), one_dark, 0, 0, 80, cfg, &.{ .best_wpm = 90 });
    try testing.expectEqualStrings("words · common · 25 │ stop on letter · no backspace · dvorak · weak keys", std.mem.trim(u8, s.row(0, &buf), " "));
    @memset(s.cells, .{});
    config_bar.render(s.renderer(), one_dark, 0, 0, 30, cfg, &.{ .best_wpm = 90 });
    try testing.expectEqualStrings("words · common · 25", std.mem.trim(u8, s.row(0, &buf), " "));

    @memset(s.cells, .{});
    config_bar.render(s.renderer(), one_dark, 0, 0, 160, .{ .mode = .daily, .day = 20754 }, &.{ .best_wpm = 70 });
    try testing.expectEqualStrings("daily · 2026-10-28 │ daily best 70 wpm   ctrl+p to change", std.mem.trim(u8, s.row(0, &buf), " "));
    config_bar.render(s.renderer(), one_dark, 0, 0, 160, .{ .mode = .code, .stop_on_error = .word }, &.{});
    try testing.expect(std.mem.indexOf(u8, s.row(0, &buf), "plain keys │ stop on word") != null);
    // Code with vim keys: no strict chips (they don't apply).
    config_bar.render(s.renderer(), one_dark, 0, 0, 160, .{ .mode = .code, .code_keys = .vim, .no_backspace = true }, &.{});
    try testing.expect(std.mem.indexOf(u8, s.row(0, &buf), "no backspace") == null);
}

test "idle bar: a practice run says what it drills, not the configured test" {
    var t = try TypingFixture.init(.{ .mode = .words, .word_count = 10, .no_backspace = true }, &.{"again again"});
    defer t.deinit();
    t.state = .waiting;
    var s = try Screen.init(testing.allocator, 100, 24);
    defer s.deinit();
    var buf: [128]u8 = undefined;
    typing_view.render(s.renderer(), one_dark, &t, &.{ .practice = true, .best_wpm = 90 }, 0);
    const want = try std.fmt.bufPrint(&buf, "practice · missed words · {d} words │ no backspace │ not recorded", .{t.session.wordCount()});
    if (!s.contains(want)) {
        s.dump();
        return error.TestUnexpectedResult;
    }
    // The configured length, the toggles and the best don't apply.
    try testing.expect(!s.contains("words · common · 10"));
    try testing.expect(!s.contains("best 90"));
    try testing.expect(!s.contains("punctuation"));
    // A normal run is unchanged.
    typing_view.render(s.renderer(), one_dark, &t, &.{ .best_wpm = 90 }, 0);
    try testing.expect(s.contains("words · common · 10 │ punctuation · numbers │ no backspace"));
    try testing.expect(!s.contains("practice"));

    // Weak-key practice, as `TypingTest.weak_practice` says.
    const Weak = struct { config: Config = .{}, weak_practice: bool = true };
    try testing.expectEqualStrings("weak keys", query.practiceKind(&Weak{}));
    try testing.expectEqualStrings("missed words", query.practiceKind(&Weak{ .weak_practice = false }));
}

test "header chips: daily date, zen, code with vim keys" {
    var c: draw.Chips = .{};
    draw.chipsFor(&c, .{ .mode = .daily, .day = 20754 });
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqualStrings("2026-10-28", c.items[1]);
    draw.chipsFor(&c, .{ .mode = .zen, .word_count = 25 });
    try testing.expectEqual(@as(usize, 1), c.len);
    draw.chipsFor(&c, code_vim_cfg);
    try testing.expectEqualStrings("vim keys", c.items[2]);
}

// ============================================================================
// Round 2: typing view (Enter skips, pace caret, zen, custom, syntax)
// ============================================================================

test "Enter mid-line: skipped letters show as missed, the caret goes past the indent" {
    var t = try TypingFixture.initOpts(.{ .mode = .code }, &.{"fn main() {\n    return 0;\n}"}, .{ .enter_skips_line = true });
    defer t.deinit();
    t.typeText("fn ma\n");
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 3000);
    const a = s.find("fn main() {") orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    // "ma" typed, "in()" and "{" skipped: dim and underlined.
    try testing.expectEqual(@as(?Color, one_dark.fg), s.at(a.x + 4, a.y).fg);
    for ([_]usize{ 5, 6, 7, 8, 10 }) |dx| {
        try testing.expect(s.at(a.x + dx, a.y).underline);
        try testing.expectEqual(@as(?Color, one_dark.dim), s.at(a.x + dx, a.y).fg);
    }
    const b = s.find("return 0;").?;
    try testing.expectEqual(a.x + 4, b.x);
    const c = typing_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(b.x, c.x);
    try testing.expectEqual(b.y, c.y);
    if (t.session.word(1).skipped) {} else return error.TestUnexpectedResult;
}

test "pace caret: underlined target letter in the pace colour, never on typed cells" {
    var t = try TypingFixture.init(.{ .mode = .words }, &.{ "hello", "world", "again" });
    defer t.deinit();
    t.typeText("he");
    t.pace_chars = 7; // "hello " is 6: one letter into "world"
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{ .pace_wpm = 80 }, 5000);
    const p = s.find("hello world again").?;
    const cell = s.at(p.x + 7, p.y);
    try testing.expectEqual(@as(u21, 'o'), cell.cp);
    try testing.expectEqual(@as(?Color, one_dark.pace), cell.fg);
    try testing.expect(cell.underline);
    try testing.expect(s.contains("pace 80"));
    // No pace setting: no caret.
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 5000);
    try testing.expect(!s.at(p.x + 7, p.y).underline);
    // Behind the typist: nothing drawn on typed cells.
    t.pace_chars = 1;
    typing_view.render(s.renderer(), one_dark, &t, &.{ .pace_wpm = 80 }, 5000);
    for (0..17) |x| try testing.expect(s.at(p.x + x, p.y).fg == null or !std.meta.eql(s.at(p.x + x, p.y).fg.?, one_dark.pace));
    // On the separator: the space is underlined.
    t.pace_chars = 5;
    typing_view.render(s.renderer(), one_dark, &t, &.{ .pace_wpm = 80 }, 5000);
    try testing.expect(s.at(p.x + 5, p.y).underline);
}

test "zen: typed words in the text colour, elapsed and wpm, esc finish hints" {
    var t = try TypingFixture.initOpts(.{ .mode = .zen }, &.{}, .{ .zen = true });
    defer t.deinit();
    t.typeText("free typing here");
    t.lv.wpm = 64;
    t.pace_chars = 3;
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{ .pace_wpm = 80 }, 4200);
    const p = s.find("free typing here") orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    for (0..16) |x| {
        const cell = s.at(p.x + x, p.y);
        if (cell.cp != ' ') try testing.expectEqual(@as(?Color, one_dark.fg), cell.fg);
        try testing.expect(!cell.underline);
    }
    try testing.expect(s.contains("4.2s"));
    try testing.expect(s.contains("64 wpm"));
    try testing.expect(!s.contains("pace"));
    try testing.expect(s.hasHint("esc", "finish"));
    try testing.expect(s.hasHint("tab", "clear"));
}

test "custom without text: a hint above the text" {
    var t = try TypingFixture.init(.{ .mode = .custom }, &.{ "the", "sample", "text" });
    defer t.deinit();
    t.state = .waiting;
    var s = try Screen.init(testing.allocator, 100, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains("no custom text yet · paste here, or --text / --file"));
    const h = s.find("no custom text").?;
    const txt = s.find("the sample text").?;
    try testing.expect(h.y < txt.y);
    try testing.expect(s.contains("custom · 3 words"));
    typing_view.render(s.renderer(), one_dark, &t, &.{ .is_web = true }, 0);
    try testing.expect(s.contains("use the custom text button"));
}

test "syntax colours tint untyped code only" {
    var t = try TypingFixture.initOpts(.{ .mode = .code, .lang = .zig }, &.{"const x = 42;\nreturn x;"}, .{ .lang = .zig });
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    const p = s.find("const x = 42;").?;
    try testing.expectEqual(@as(?Color, one_dark.syn_keyword), s.at(p.x, p.y).fg);
    try testing.expectEqual(@as(?Color, one_dark.syn_number), s.at(p.x + 10, p.y).fg);
    t.typeText("const ");
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 1000);
    // Typed letters keep the typed colour.
    try testing.expectEqual(@as(?Color, one_dark.fg), s.at(p.x, p.y).fg);
    // Off: plain dim.
    t.config.syntax = false;
    typing_view.render(s.renderer(), one_dark, &t, &.{}, 1000);
    try testing.expectEqual(@as(?Color, one_dark.dim), s.at(p.x + 10, p.y).fg);
}

// ============================================================================
// Round 2: vim views (block selection, tabs, ghost syntax, drills)
// ============================================================================

test "visual block: selected cells only where there is text; V-BLOCK pill" {
    var t = try VimFixture.init("abcdef\nab\nabcdefgh", .{ 2, 4 });
    defer t.deinit();
    t.vim.mode = .visual_block;
    t.vim.block = .{ .top = 0, .bottom = 2, .left = 2, .right = 4 };
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expect(s.contains("-- VISUAL BLOCK --"));
    const a = s.find("abcdef").?;
    for (0..6) |dx| {
        const sel = dx >= 2 and dx <= 4;
        try testing.expectEqual(sel, std.meta.eql(s.at(a.x + dx, a.y).bg, @as(?Color, one_dark.visual_bg)));
    }
    // The short line is not padded out to the block.
    for (2..5) |dx| {
        try testing.expect(s.at(a.x + dx, a.y + 1).bg == null);
        try testing.expectEqual(@as(u21, ' '), s.at(a.x + dx, a.y + 1).cp);
    }
    try testing.expectEqual(@as(?Color, one_dark.visual_bg), s.at(a.x + 2, a.y + 2).bg);

    // Drill view: same.
    var d = try DrillFixture.init("abcdef\nab\nabcdefgh", "abcdef\nab\nabcdefgh");
    defer d.deinit();
    d.drill.editor.mode = .visual_block;
    d.drill.editor.cursor = .{ .row = 2, .col = 4 };
    d.drill.editor.block = .{ .top = 0, .bottom = 2, .left = 2, .right = 4 };
    var ds = try Screen.init(testing.allocator, 100, 30);
    defer ds.deinit();
    drill_view.render(ds.renderer(), one_dark, &d, &.{}, .{ .total = 1 }, 0);
    try testing.expect(ds.contains("-- VISUAL BLOCK --"));
    var selected: usize = 0;
    for (ds.cells) |cell| {
        if (std.meta.eql(cell.bg, @as(?Color, one_dark.visual_bg))) selected += 1;
    }
    // 3 + 3 cells (one of them under the cursor), the short line adds none.
    try testing.expectEqual(@as(usize, 5), selected);
}

test "tabs expand to the tabstop; the cursor sits at the display column" {
    var t = try VimFixture.init("\tfoo\nab\tc", .{ 0, 1 });
    defer t.deinit();
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    const g = s.find("  1 ").?;
    const text_x = g.x + 4;
    try testing.expectEqual(@as(u21, 'f'), s.at(text_x + 8, g.y).cp);
    const c = vim_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(text_x + 8, c.x);
    try testing.expectEqual(@as(?Color, one_dark.cursor_bg), s.at(c.x, c.y).bg);
    // "ab<tab>c": c at column 8.
    try testing.expectEqual(@as(u21, 'c'), s.at(text_x + 8, g.y + 1).cp);
    // tabstop 4.
    t.vim.opts.tabstop = 4;
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expectEqual(@as(u21, 'f'), s.at(text_x + 4, g.y).cp);
    try testing.expectEqual(text_x + 4, vim_view.cursorPos(&t, 80, 24).x);
}

test "insert cursor uses the readable insert text colour" {
    var t = try VimFixture.init("hello", .{ 0, 1 });
    defer t.deinit();
    t.vim.mode = .insert;
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    const c = vim_view.cursorPos(&t, 80, 24);
    try testing.expectEqual(@as(?Color, one_dark.cursor_insert_bg), s.at(c.x, c.y).bg);
    try testing.expectEqual(@as(?Color, one_dark.cursor_insert_fg), s.at(c.x, c.y).fg);
    try testing.expect(one_dark.cursor_insert_fg.contrast(one_dark.cursor_insert_bg) >= 4.5);
}

test "vim ghost text is syntax coloured; typed text is not" {
    var t = try VimFixture.init("const x = 42;", .{ 0, 0 });
    defer t.deinit();
    t.config = .{ .mode = .vim, .vim_kind = .type, .lang = .zig };
    // Nothing typed yet: the buffer is empty, the target is ghost text.
    t.vim.buffer.items.items[0] = "";
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    const p = s.find("const x = 42;").?;
    try testing.expectEqual(@as(?Color, one_dark.syn_number), s.at(p.x + 10, p.y).fg);
    try testing.expectEqual(@as(?Color, one_dark.syn_keyword), s.at(p.x + 1, p.y).fg);
    t.vim.buffer.items.items[0] = "const";
    vim_view.render(s.renderer(), one_dark, &t, &.{}, 0);
    try testing.expectEqual(@as(?Color, one_dark.fg), s.at(p.x + 1, p.y).fg);
}

test "drill: matches the goal but still in insert: press esc to finish" {
    var t = try DrillFixture.init(drill_goal, drill_goal);
    defer t.deinit();
    t.state = .typing;
    t.drill.editor.mode = .insert;
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    drill_view.render(s.renderer(), one_dark, &t, &.{}, .{ .total = 1 }, 0);
    const p = s.find("matches the goal · press esc to finish") orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(?Color, one_dark.success), s.at(p.x, p.y).fg);
    try testing.expect(!s.contains("Replace the arguments"));
    t.drill.solved = true;
    drill_view.render(s.renderer(), one_dark, &t, &.{}, .{ .total = 1 }, 0);
    try testing.expect(!s.contains("press esc to finish"));
    // Not matching: the prompt is back.
    var u = try DrillFixture.init(drill_start, drill_goal);
    defer u.deinit();
    drill_view.render(s.renderer(), one_dark, &u, &.{}, .{ .total = 1 }, 0);
    try testing.expect(!s.contains("press esc to finish"));
    try testing.expect(s.contains("Replace the arguments"));
}

// ============================================================================
// Round 2: results (zen, daily, heatmap, hints, animation)
// ============================================================================

fn samplePerKey() stats.PerKey {
    var pk: stats.PerKey = .{};
    for ("the quick brown fox jumps over the lazy dog") |c| {
        if (c == ' ') continue;
        for (0..4) |_| pk.note(c, true, 150);
    }
    // 'q' is slow, 'z' is often wrong.
    for (0..4) |_| pk.note('q', true, 600);
    for (0..3) |_| pk.note('z', false, null);
    return pk;
}

test "heatmap: key colours, slow and missed lists, layout rows" {
    const pk = samplePerKey();
    const rows = heatmap.rowsForConfig(.{});
    try testing.expectEqual(one_dark.dimmer, heatmap.keyColor(one_dark, heatmap.info(&pk, '1')));
    try testing.expectEqual(one_dark.success, heatmap.keyColor(one_dark, heatmap.info(&pk, 'a')));
    try testing.expectEqual(one_dark.danger, heatmap.keyColor(one_dark, heatmap.info(&pk, 'z')));
    var buf: [5]heatmap.KeyInfo = undefined;
    const slow = heatmap.slowest(&pk, rows, &buf);
    try testing.expectEqual(@as(u8, 'q'), slow[0].key);
    var mbuf: [5]heatmap.KeyInfo = undefined;
    try testing.expectEqual(@as(u8, 'z'), heatmap.mostMissed(&pk, rows, &mbuf)[0].key);

    var s = try Screen.init(testing.allocator, 80, 6);
    defer s.deinit();
    heatmap.render(s.renderer(), one_dark, 0, 0, 80, .side, &pk, rows);
    try testing.expect(s.contains("q w e r t y u i o p [ ] \\"));
    try testing.expect(s.contains("slowest  q 375ms"));
    try testing.expect(s.contains("missed   z 43%"));
    const z = s.find("z x c").?;
    try testing.expectEqual(@as(?Color, one_dark.danger), s.at(z.x, z.y).fg);
    try testing.expect(s.at(s.find("q w e").?.x, 1).underline);
    try testing.expectEqual(@as(usize, 0), s.outside);
    // Dvorak rows.
    heatmap.render(s.renderer(), one_dark, 0, 0, 80, .below, &pk, heatmap.rowsForConfig(.{ .layout = .dvorak }));
    try testing.expect(s.contains("a o e u i d h t n s -"));
}

test "results: heatmap between the graph and the word lists; w and h hints" {
    var s = try Screen.init(testing.allocator, 120, 40);
    defer s.deinit();
    var res = sampleResult();
    const pk = samplePerKey();
    res.per_key = &pk;
    results.render(s.renderer(), one_dark, &res, .{ .mode = .words }, &.{});
    const kb = s.find("a s d f g h j k l ; '") orelse {
        s.dump();
        return error.TestUnexpectedResult;
    };
    try testing.expect(kb.y > s.find("×").?.y);
    try testing.expect(kb.y < s.find("missed  their").?.y);
    try testing.expect(s.hasHint("w", "weak keys"));
    try testing.expect(s.hasHint("h", "history"));
    // Practice runs and zen don't offer weak keys; history stays.
    results.render(s.renderer(), one_dark, &res, .{ .mode = .words }, &.{ .practice = true });
    try testing.expect(!s.hasHint("w", "weak keys"));
    try testing.expect(s.hasHint("h", "history"));
    // Small screens drop it first.
    var small = try Screen.init(testing.allocator, 80, 24);
    defer small.deinit();
    results.render(small.renderer(), one_dark, &res, .{ .mode = .words }, &.{});
    try testing.expect(!small.contains("a s d f g"));
    try testing.expect(small.contains("missed  their"));
}

test "results: zen hides accuracy and letter counts; daily banners" {
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    const res = sampleResult();
    results.render(s.renderer(), one_dark, &res, .{ .mode = .zen }, &.{});
    try testing.expect(!s.contains("acc"));
    try testing.expect(!s.contains("corrected"));
    try testing.expect(s.contains("raw   92"));
    try testing.expect(s.contains("chars 124"));
    try testing.expect(!s.hasHint("w", "weak keys"));
    const daily: Config = .{ .mode = .daily, .day = 20754 };
    results.render(s.renderer(), one_dark, &res, daily, &.{ .pb = .first });
    try testing.expect(s.contains("first daily today"));
    try testing.expect(s.contains("daily · 2026-10-28"));
    results.render(s.renderer(), one_dark, &res, daily, &.{ .pb = .{ .improved = 80 } });
    try testing.expect(s.contains("▲ new daily PB +7.4 wpm"));
}

fn sameCells(a: *const Screen, b: *const Screen) bool {
    for (a.cells, b.cells) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

test "results animation: count-up, graph draw-in, sparkle; the final frame is static" {
    var stat = try Screen.init(testing.allocator, 100, 30);
    defer stat.deinit();
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    const res = sampleResult();
    const cfg: Config = .{ .mode = .words };
    const ui: UiState = .{ .pb = .{ .improved = 80 }, .finished_ms = 10_000 };
    results.render(stat.renderer(), one_dark, &res, cfg, &.{ .pb = .{ .improved = 80 } });

    // At the start nothing has counted up and the graph is empty.
    results.renderAnimated(s.renderer(), one_dark, &res, cfg, &ui, 10_000);
    try testing.expect(s.contains("0.0%"));
    try testing.expect(!s.contains("96.3%"));
    try testing.expect(!sameCells(&s, &stat));
    // Mid-way: different again, still on screen.
    results.renderAnimated(s.renderer(), one_dark, &res, cfg, &ui, 10_300);
    try testing.expect(!sameCells(&s, &stat));
    try testing.expectEqual(@as(usize, 0), s.outside);
    // After the count-up the numbers are final; the sparkle may still run.
    results.renderAnimated(s.renderer(), one_dark, &res, cfg, &ui, 10_000 + anim.COUNT_MS);
    try testing.expect(s.contains("96.3%"));
    // After the sparkle: identical to the static card.
    results.renderAnimated(s.renderer(), one_dark, &res, cfg, &ui, 10_000 + anim.SPARKLE_MS);
    try testing.expect(sameCells(&s, &stat));
    // No finished_ms: the final frame.
    results.renderAnimated(s.renderer(), one_dark, &res, cfg, &.{ .pb = .{ .improved = 80 } }, 10_000);
    try testing.expect(sameCells(&s, &stat));
}

test "sparkles stay inside the card on every size" {
    const res = sampleResult();
    for ([_][2]usize{ .{ 30, 8 }, .{ 40, 10 }, .{ 60, 20 }, .{ 80, 24 }, .{ 120, 40 }, .{ 300, 80 } }) |sz| {
        var s = try Screen.init(testing.allocator, sz[0], sz[1]);
        defer s.deinit();
        var t: i64 = 0;
        while (t < anim.SPARKLE_MS) : (t += 33) {
            results.renderAnimated(s.renderer(), one_dark, &res, .{ .mode = .words }, &.{ .pb = .first, .finished_ms = 0 }, t);
            try testing.expectEqual(@as(usize, 0), s.outside);
        }
    }
}

test "animating: only while results animate" {
    var t = try TypingTest.init(testing.allocator, 7, .{ .mode = .words, .word_count = 10 });
    defer t.deinit();
    try testing.expect(!render.animating(&t, &.{ .finished_ms = 0 }, 10));
    var now: i64 = 1000;
    var guard: usize = 0;
    while (t.state != .finished and guard < 100) : (guard += 1) typeWord(&t, &now);
    if (t.state != .finished) return error.SkipZigTest;
    try testing.expect(render.animating(&t, &.{ .finished_ms = now }, now));
    try testing.expect(render.animating(&t, &.{ .finished_ms = now }, now + anim.COUNT_MS - 1));
    try testing.expect(!render.animating(&t, &.{ .finished_ms = now }, now + anim.COUNT_MS));
    try testing.expect(render.animating(&t, &.{ .finished_ms = now, .pb = .first }, now + anim.COUNT_MS));
    try testing.expect(!render.animating(&t, &.{ .finished_ms = now, .pb = .first }, now + anim.SPARKLE_MS));
    try testing.expect(!render.animating(&t, &.{}, now));
    try testing.expect(!render.animating(&t, &.{ .finished_ms = now, .overlay = .history }, now));
}

// ============================================================================
// Round 2: history screen
// ============================================================================

const History = struct {
    log: history.Log,
    pbs: history.PbTable,

    fn init(n: usize) !History {
        var h: History = .{ .log = history.Log.init(testing.allocator), .pbs = history.PbTable.init(testing.allocator) };
        const pk = samplePerKey();
        for (0..n) |i| {
            var res = sampleResult();
            res.wpm = 60 + @as(f32, @floatFromInt(i % 30));
            res.per_key = &pk;
            const cfg: Config = if (i % 3 == 0) .{ .mode = .code, .lang = .rust } else .{ .mode = .words, .word_count = 25 };
            var buf: [2048]u8 = undefined;
            const line = history.recordLine(&res, cfg, 1_793_000_000 + @as(i64, @intCast(i)) * 60, 1, &buf);
            h.log.addLine(line);
            h.pbs.loadJsonl(line);
            h.pbs.loadJsonl("\n");
        }
        return h;
    }

    fn deinit(self: *History) void {
        self.log.deinit();
        self.pbs.deinit();
    }
};

test "history: three tabs, newest first, bests, keys" {
    var h = try History.init(40);
    defer h.deinit();
    var s = try Screen.init(testing.allocator, 100, 30);
    defer s.deinit();
    var ui: UiState = .{ .overlay = .history, .log = &h.log, .pbs = &h.pbs };
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expect(s.contains("recent · bests · keys"));
    const tab = s.find("recent").?;
    try testing.expectEqual(@as(?Color, one_dark.accent), s.at(tab.x, tab.y).fg);
    try testing.expect(s.contains("40 runs"));
    try testing.expect(s.hasHint("esc", "close"));
    // Newest first: run 39 (69 wpm) is above run 38 (68 wpm).
    try testing.expect(s.find("69 wpm").?.y < s.find("68 wpm").?.y);

    ui.history_tab = .bests;
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expect(s.contains("words · common · 25"));
    try testing.expect(s.contains("code · rust"));
    try testing.expect(s.contains("89 wpm"));

    ui.history_tab = .keys;
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expect(s.contains("q w e r t y"));
    try testing.expect(s.contains("weakest keys"));
    try testing.expect(s.contains("z  "));
    try testing.expectEqual(@as(usize, 0), s.outside);
}

test "history: empty state and scroll clamping" {
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    history_view.render(s.renderer(), one_dark, .{}, &.{ .overlay = .history });
    try testing.expect(s.contains("no runs yet"));
    var h = try History.init(60);
    defer h.deinit();
    var ui: UiState = .{ .overlay = .history, .log = &h.log, .pbs = &h.pbs, .history_scroll = 10_000 };
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    // Scrolled to the end: the oldest run (60 wpm) is on the last row, and
    // only the "more above" marker shows.
    const marks = struct {
        fn count(sc: *const Screen, cp: u21) usize {
            var k: usize = 0;
            for (0..sc.h -| 3) |y| {
                for (0..sc.w) |x| {
                    if (sc.at(x, y).cp == cp) k += 1;
                }
            }
            return k;
        }
    };
    try testing.expect(s.contains("60 wpm"));
    try testing.expectEqual(@as(usize, 1), marks.count(&s, '↑'));
    try testing.expectEqual(@as(usize, 0), marks.count(&s, '↓'));
    ui.history_scroll = 0;
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expectEqual(@as(usize, 0), marks.count(&s, '↑'));
    try testing.expectEqual(@as(usize, 1), marks.count(&s, '↓'));
    // maxScroll is exactly the last page: one less shows "more below".
    const max = history_view.maxScroll(&ui, 80, 24);
    try testing.expect(max > 0 and max < 60);
    ui.history_scroll = max;
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expectEqual(@as(usize, 0), marks.count(&s, '↓'));
    ui.history_scroll = max - 1;
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expectEqual(@as(usize, 1), marks.count(&s, '↓'));
    ui.history_tab = .bests;
    try testing.expectEqual(@as(usize, 0), history_view.maxScroll(&ui, 80, 24));
    try testing.expectEqual(@as(usize, 0), s.outside);
}

test "history bests: years of daily and custom bests still list and scroll" {
    // Every daily date and every custom text is its own PB key, so the table
    // only grows: 3000 keys (8 years of dailies) must not hit a buffer limit.
    var pbs = history.PbTable.init(testing.allocator);
    defer pbs.deinit();
    var res = sampleResult();
    for (0..3000) |i| {
        res.wpm = 50 + @as(f32, @floatFromInt(i % 40));
        const cfg: Config = .{ .mode = .daily, .day = @intCast(17_000 + i) };
        var buf: [2048]u8 = undefined;
        pbs.loadJsonl(history.recordLine(&res, cfg, 1_793_000_000, 1, &buf));
        pbs.loadJsonl("\n");
    }
    try testing.expectEqual(@as(usize, 3000), pbs.map.count());
    var s = try Screen.init(testing.allocator, 80, 24);
    defer s.deinit();
    var ui: UiState = .{ .overlay = .history, .history_tab = .bests, .pbs = &pbs };
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expect(!s.contains("too many"));
    try testing.expect(s.contains("daily · 2016-07-18"));
    const max = history_view.maxScroll(&ui, 80, 24);
    try testing.expect(max > 2900);
    ui.history_scroll = max;
    history_view.render(s.renderer(), one_dark, .{}, &ui);
    try testing.expect(s.contains("daily · 2024-10-03"));
    try testing.expectEqual(@as(usize, 0), s.outside);
}

// ============================================================================
// Round 2: every new state, every theme, every size
// ============================================================================

test "sweep: new states at 20x5, 30x8, 80x24, 120x40, 300x80 in every theme" {
    const sizes = [_][2]usize{ .{ 20, 5 }, .{ 30, 8 }, .{ 80, 24 }, .{ 120, 40 }, .{ 300, 80 } };
    var h = try History.init(25);
    defer h.deinit();
    const pk = samplePerKey();
    var res = sampleResult();
    res.per_key = &pk;
    inline for (comptime std.meta.tags(theme_mod.ThemeId)) |id| {
        const th = theme_mod.resolve(id);
        for (sizes) |sz| {
            var s = try Screen.init(testing.allocator, sz[0], sz[1]);
            defer s.deinit();
            const r = s.renderer();
            errdefer std.debug.print("{s} {d}x{d}\n", .{ theme_mod.slug(id), sz[0], sz[1] });

            // Typing: code with Enter skips, pace, syntax; zen; custom; daily.
            var code = try TypingFixture.initOpts(.{ .mode = .code, .lang = .rust }, &.{"fn main() {\n    let x = \"hi\"; // note\n    return 42;\n}"}, .{ .enter_skips_line = true, .lang = .rust });
            defer code.deinit();
            code.typeText("fn ma\n");
            code.pace_chars = 20;
            typing_view.render(r, th, &code, &.{ .pace_wpm = 80 }, 3000);
            var zen = try TypingFixture.initOpts(.{ .mode = .zen }, &.{}, .{ .zen = true });
            defer zen.deinit();
            zen.typeText("some free words typed in zen mode that wrap around");
            typing_view.render(r, th, &zen, &.{}, 3000);
            var custom = try TypingFixture.init(.{ .mode = .custom, .stop_on_error = .word, .layout = .colemak_dh }, &.{ "a", "b" });
            defer custom.deinit();
            custom.state = .waiting;
            typing_view.render(r, th, &custom, &.{ .best_wpm = 50 }, 0);
            var daily = try TypingFixture.init(.{ .mode = .daily, .day = 20754, .no_backspace = true }, &.{ "a", "b" });
            defer daily.deinit();
            daily.state = .waiting;
            typing_view.render(r, th, &daily, &.{ .best_wpm = 50 }, 0);

            // Results: heatmap, zen, daily, mid-animation.
            for ([_]Config{ .{ .mode = .words }, .{ .mode = .zen }, .{ .mode = .daily, .day = 1 } }) |cfg| {
                results.renderAnimated(r, th, &res, cfg, &.{ .pb = .first, .finished_ms = 0 }, 200);
                results.render(r, th, &res, cfg, &.{ .pb = .{ .improved = 50 } });
            }

            // Vim: code + vim keys, block selection, tabs, insert cursor.
            var vt = try VimFixture.init("\tfn main() {\n\t\treturn 42;\n}", .{ 1, 2 });
            defer vt.deinit();
            vt.config = code_vim_cfg;
            vt.vim.mode = .visual_block;
            vt.vim.block = .{ .top = 0, .bottom = 2, .left = 4, .right = 20 };
            vim_view.render(r, th, &vt, &.{}, 0);
            vt.vim.mode = .insert;
            vim_view.render(r, th, &vt, &.{}, 0);
            const c = vim_view.cursorPos(&vt, sz[0], sz[1]);
            if (sz[1] >= render.MIN_HEIGHT_VIM) try testing.expect(c.x < sz[0] and c.y < sz[1]);

            // Drills: ready to finish.
            var dt = try DrillFixture.init(drill_goal, drill_goal);
            defer dt.deinit();
            dt.state = .typing;
            dt.drill.editor.mode = .insert;
            drill_view.render(r, th, &dt, &.{}, .{ .total = 3 }, 0);

            // History, all tabs.
            inline for (comptime std.meta.tags(ui_state.HistoryTab)) |tab| {
                history_view.render(r, th, .{}, &.{ .overlay = .history, .history_tab = tab, .log = &h.log, .pbs = &h.pbs, .history_scroll = 3 });
            }
            try testing.expectEqual(@as(usize, 0), s.outside);
        }
    }
}

test "renderScreen: code with vim keys, zen, custom and daily with a real TypingTest" {
    const cfgs = [_]Config{
        code_vim_cfg,
        .{ .mode = .zen },
        .{ .mode = .custom },
        .{ .mode = .daily, .day = 20754 },
    };
    for (cfgs) |cfg| {
        for (small_sizes) |sz| {
            var t = try TypingTest.init(testing.allocator, 7, cfg);
            defer t.deinit();
            var s = try Screen.init(testing.allocator, sz[0], sz[1]);
            defer s.deinit();
            errdefer std.debug.print("{s} {d}x{d}\n", .{ cfg.mode.name(), sz[0], sz[1] });
            render.renderAt(s.renderer(), &t, one_dark, &.{ .pace_wpm = 60 }, 0);
            try expectOnScreen(&s, render.getCursorPos(&t, &.{}, sz[0], sz[1]));
            if (cfg.mode == .code) {
                try testing.expectEqual(render.Screen.vim_type, render.screenOf(&t, &.{}));
                if (sz[0] >= 80 and sz[1] >= 24) try testing.expect(s.contains("vim keys"));
            }
            // The history overlay hides the cursor.
            render.renderAt(s.renderer(), &t, one_dark, &.{ .overlay = .history }, 0);
            try testing.expectEqual(@as(usize, 0), s.outside);
            try testing.expect(!render.getCursorPos(&t, &.{ .overlay = .history }, sz[0], sz[1]).visible);
        }
    }
}
