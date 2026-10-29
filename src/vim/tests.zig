//! Engine tests. `expectKeys(start, keys, expected)` loads `start` (a '|'
//! marks the cursor), feeds `keys` in Vim notation and compares the buffer
//! with the cursor drawn as '|'. Cases are grouped by feature; the comments
//! name the regressions from the old engine they pin down.

const std = @import("std");
const editor = @import("editor.zig");
const drill = @import("drill.zig");
const key_mod = @import("key.zig");

const VimEditor = editor.VimEditor;
const FeedResult = editor.FeedResult;
const t = std.testing;
const alloc = t.allocator;

const Case = struct { []const u8, []const u8, []const u8 };

/// Options for the editors runCases() makes (runCasesWith sets them).
var case_opts: editor.Options = .{};

const Fx = struct {
    ed: VimEditor,

    fn init(start: []const u8) !Fx {
        var f = Fx{ .ed = VimEditor.init(alloc, case_opts) };
        errdefer f.ed.deinit();
        const m = try drill.parseMarked(alloc, start);
        defer m.deinit(alloc);
        try f.ed.load(m.text, m.cursor);
        return f;
    }

    fn deinit(self: *Fx) void {
        self.ed.deinit();
    }

    /// Feeds keys; returns the merged results (ex is the last one set).
    fn keys(self: *Fx, s: []const u8) FeedResult {
        var out = FeedResult{};
        var it = key_mod.Notation.init(s);
        while (it.next()) |k| {
            const r = self.ed.feed(k);
            out.changed = out.changed or r.changed;
            out.interrupt = out.interrupt or r.interrupt;
            out.rejected = out.rejected or r.rejected;
            if (r.ex) |e| out.ex = e;
        }
        return out;
    }

    fn render(self: *const Fx) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        const ed = &self.ed;
        var row: usize = 0;
        while (row < ed.buffer.lineCount()) : (row += 1) {
            if (row > 0) try out.append(alloc, '\n');
            const line = ed.buffer.getLine(row);
            for (line, 0..) |c, col| {
                if (row == ed.cursor.row and col == ed.cursor.col) try out.append(alloc, '|');
                try out.append(alloc, c);
            }
            if (row == ed.cursor.row and ed.cursor.col >= line.len) try out.append(alloc, '|');
        }
        return out.toOwnedSlice(alloc);
    }

    fn expect(self: *const Fx, expected: []const u8) !void {
        const got = try self.render();
        defer alloc.free(got);
        try t.expectEqualStrings(expected, got);
    }
};

fn expectKeys(start: []const u8, keys: []const u8, expected: []const u8) !void {
    var f = try Fx.init(start);
    defer f.deinit();
    _ = f.keys(keys);
    const got = try f.render();
    defer alloc.free(got);
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("\n  start: \"{f}\"\n  keys:  {s}\n  want:  \"{f}\"\n  got:   \"{f}\"\n", .{
            std.zig.fmtString(start), keys, std.zig.fmtString(expected), std.zig.fmtString(got),
        });
        return error.TestExpectedEqual;
    }
}

fn runCases(cases: []const Case) !void {
    var failed: usize = 0;
    for (cases) |c| expectKeys(c[0], c[1], c[2]) catch {
        failed += 1;
    };
    if (failed > 0) {
        std.debug.print("{d} of {d} cases failed\n", .{ failed, cases.len });
        return error.TestExpectedEqual;
    }
}

fn runCasesWith(opts: editor.Options, cases: []const Case) !void {
    case_opts = opts;
    defer case_opts = .{};
    return runCases(cases);
}

// -- 1. unified input -------------------------------------------------------

test "input: arrows, Home/End, Ctrl+[ and Ctrl+C" {
    try runCases(&.{
        // Arrows cancel a pending operator.
        .{ "a|bc", "d<Right>x", "a|b" },
        .{ "|abc", "ix<C-[>", "|xabc" },
        .{ "|abc", "ix<C-c>", "|xabc" },
        .{ "ab|cd", "<Home>x", "|bcd" },
        .{ "ab|cd", "<End>x", "ab|c" },
        .{ "ab|cd", "i<Home>X<Esc>", "|Xabcd" },
        .{ "ab|cd", "i<End>X<Esc>", "abcd|X" },
        .{ "foo |bar baz", "<C-Right>x", "foo bar |az" },
        .{ "foo bar |baz", "<S-Left>x", "foo |ar baz" },
        .{ "|a\nb\nc", "<C-Down>x", "a\nb\n|" },
        .{ "a\nb\n|c", "<C-Up>x", "|\nb\nc" },
        .{ "|abc", "<Del>", "|bc" },
        // Ctrl+C cancels a pending operator and visual mode.
        .{ "|abc", "d<C-c>x", "|bc" },
        .{ "|abc", "vl<C-c>x", "a|c" },
    });
}

test "input: Ctrl+C interrupt, stats and keylog" {
    var f = try Fx.init("|abc");
    defer f.deinit();
    try t.expect(f.keys("<C-c>").interrupt);
    try t.expect(!f.keys("d<C-c>").interrupt);
    _ = f.keys("ix<Esc>");
    try t.expectEqual(@as(u32, 6), f.ed.stats().keystrokes);
    try t.expectEqual(@as(u32, 1), f.ed.stats().inserted);
    try t.expectEqualStrings("<C-c>d<C-c>ix<Esc>", f.ed.keylog());
    // Legacy byte shim: 27 is Esc, 0x17 is Ctrl+W.
    f.ed.handleKey('A');
    f.ed.handleKey('y');
    f.ed.handleKey(0x17);
    f.ed.handleKey(27);
    try f.expect("xab|c");
}

// -- 2. word motions --------------------------------------------------------

test "words: w b e ge and their BIG forms" {
    try runCases(&.{
        // Old bug: w/e stuck on punctuation.
        .{ "|foo(bar)", "w", "foo|(bar)" },
        .{ "|foo(bar)", "www", "foo(bar|)" },
        .{ "|foo(bar)", "wwwb", "foo(|bar)" },
        .{ "|foo.bar baz", "W", "foo.bar |baz" },
        .{ "foo.bar |baz", "B", "|foo.bar baz" },
        .{ "|foo.bar", "e", "fo|o.bar" },
        .{ "|foo.bar", "ee", "foo|.bar" },
        .{ "|foo.bar", "eee", "foo.ba|r" },
        .{ "|foo.bar baz", "E", "foo.ba|r baz" },
        .{ "fo|o bar", "e", "foo ba|r" },
        .{ "foo |bar", "ge", "fo|o bar" },
        .{ "a.b c|d", "gE", "a.|b cd" },
        .{ "fo|o\nbar", "w", "foo\n|bar" },
        // Empty lines are words.
        .{ "fo|o\n\nbar", "w", "foo\n|\nbar" },
        .{ "foo\n\n|bar", "b", "foo\n|\nbar" },
        // Old bug: b at col 0 landed wrong.
        .{ "foo bar\n|baz", "b", "foo |bar\nbaz" },
        .{ "|a\tb", "w", "a\t|b" },
        .{ "|  foo", "w", "  |foo" },
        .{ "|a b c d", "3w", "a b c |d" },
        .{ "a b c |d", "2b", "a |b c d" },
        .{ "|x\n  y", "w", "x\n  |y" },
    });
}

// -- 3. motion kinds, operators, ranges across lines -------------------------

test "operators: exclusive, inclusive, linewise ranges" {
    try runCases(&.{
        // Old bug: every charwise operator was inclusive.
        .{ "|hello world", "dw", "|world" },
        .{ "hello |world", "dw", "hello| " },
        .{ "foo |bar\nbaz", "dw", "foo| \nbaz" },
        .{ "ab|c\ndef", "dw", "a|b\ndef" },
        // Old bug: cw was not ce.
        .{ "|hello world", "cwX<Esc>", "|X world" },
        .{ "|a.b c", "cWX<Esc>", "|X c" },
        .{ "a|  b", "cwX<Esc>", "a|Xb" },
        .{ "|a b", "cwX<Esc>", "|X b" },
        .{ "|foo bar", "de", "| bar" },
        .{ "foo b|ar", "db", "foo |ar" },
        .{ "ab|cd", "d0", "|cd" },
        .{ "  ab|cd", "d^", "  |cd" },
        .{ "ab|cd", "D", "a|b" },
        .{ "ab|cd", "CX<Esc>", "ab|X" },
        .{ "ab|cd", "d$", "a|b" },
        // Old bug: ranges across lines were no-ops.
        .{ "a|bc\ndef", "dj", "|" },
        .{ "abc\nd|ef\nghi", "dk", "|ghi" },
        .{ "|a\nb\n\nc", "d}", "|\nc" },
        .{ "foo b|ar\nbaz", "d}", "foo |b" },
        .{ "ab|c\ndef", "d/d<CR>", "a|b\ndef" },
        .{ "a\n|b\nc", "dd", "a\n|c" },
        .{ "a\nb\n|c", "dd", "a\n|b" },
        .{ "|a\nb", "dG", "|" },
        .{ "a\n|b\nc", "dgg", "|c" },
        .{ "  fo|o\nbar", "ccX<Esc>", "  |X\nbar" },
        // Old bug: cc/S on the last line opened the wrong line.
        .{ "a\n|b", "ccX<Esc>", "a\n|X" },
        .{ "a\n  |b", "SX<Esc>", "a\n  |X" },
        .{ "a|bc", "yy", "a|bc" },
        .{ "foo |bar", "yb", "|foo bar" },
        .{ "|ab\ncd", "Yp", "aa|bb\ncd" },
        .{ "a|bc", "yyP", "|abc\nabc" },
        .{ "ab|c\ndef", "yjP", "|abc\ndef\nabc\ndef" },
    });
}

// -- 4. counts --------------------------------------------------------------

test "counts" {
    try runCases(&.{
        // Old bug: a count before the operator was dropped.
        .{ "|a\nb\nc\nd", "2dd", "|c\nd" },
        .{ "|a\nb\nc\nd", "d2d", "|c\nd" },
        .{ "|a\nb\nc\nd\ne", "2d2d", "|e" },
        .{ "|a b c d e f g", "2d3w", "|g" },
        .{ "|abcdef", "3x", "|def" },
        .{ "abc|def", "2X", "a|def" },
        .{ "|abcd", "3rx", "xx|xd" },
        .{ "|abc", "yl3p", "aaa|abc" },
        .{ "|a\nb\nc\nd", "3J", "a b| c\nd" },
        .{ "|abcd", "3~", "ABC|d" },
        .{ "|a\nb\nc\nd\ne", "3G", "a\nb\n|c\nd\ne" },
        .{ "a\nb\n|c", "2gg", "a\n|b\nc" },
        .{ "ab|c", "0", "|abc" },
        .{ "|abcdefghijklm", "10x", "|klm" },
        .{ "|ab", "99999999x", "|" },
        .{ "|a\nb\nc", "2yyGp", "a\nb\nc\n|a\nb" },
        .{ "|a\nb\nc", "3>>", "    |a\n    b\n    c" },
        .{ "|a\nb\nc\nd", "3cc<Esc>", "|\nd" },
        .{ "|a b c", "2l", "a |b c" },
        .{ "|a\nb\nc", "5j", "a\nb\n|c" },
    });
}

// -- 5. find and match ------------------------------------------------------

test "find: f t ; , and %" {
    try runCases(&.{
        .{ "call(|a, b, c)", "dtc", "call(|c)" },
        .{ "|a,b,c", "cf,X<Esc>", "|Xb,c" },
        .{ "|a;b;c;d", "f;;", "a;b|;c;d" },
        .{ "|a;b;c;d", "f;;,", "a|;b;c;d" },
        // ; after t skips the adjacent match.
        .{ "|a.b.c", "t.;", "a.|b.c" },
        .{ "abc|d", "Fa", "|abcd" },
        .{ "abc|d", "Ta", "a|bcd" },
        .{ "abc|d", "dTa", "a|d" },
        .{ "|xa b a b", "2fa", "xa b |a b" },
        .{ "|foo(bar)", "%", "foo(bar|)" },
        .{ "foo(b|ar)", "%", "foo|(bar)" },
        .{ "|foo(bar) x", "d%", "| x" },
        .{ "|{\n  a\n}", "%", "{\n  a\n|}" },
        .{ "|x", "fz", "|x" },
    });
}

// -- 6. text objects ---------------------------------------------------------

test "text objects" {
    try runCases(&.{
        // Old bug: ciw cancelled the operator and corrupted the buffer.
        .{ "foo b|ar baz", "ciwX<Esc>", "foo |X baz" },
        .{ "foo b|ar baz", "diw", "foo | baz" },
        .{ "foo b|ar baz", "daw", "foo |baz" },
        .{ "foo |bar", "daw", "fo|o" },
        .{ "x |a.b y", "ciWZ<Esc>", "x |Z y" },
        .{ "foo(bar, |baz)", "ci(x<Esc>", "foo(|x)" },
        .{ "foo(bar, |baz)", "dib", "foo(|)" },
        .{ "foo(bar, |baz)", "da(", "fo|o" },
        .{ "say \"he|llo\" now", "di\"", "say \"|\" now" },
        .{ "say \"he|llo\" now", "da\"", "say |now" },
        .{ "|x = \"abc\"", "di\"", "x = \"|\"" },
        .{ "it's 'o|k'", "ci'X<Esc>", "it's '|X'" },
        .{ "a `b|c` d", "di`", "a `|` d" },
        .{ "a = [1, |2]; b", "da[", "a = |; b" },
        .{ "Vec<|u8>", "di<", "Vec<|>" },
        .{ "f(a, g(|b))", "d2i(", "f(|)" },
        .{ "x {a |b}", "diB", "x {|}" },
        .{ "fn x() {\n    |a;\n    b;\n}", "ci{X<Esc>", "fn x() {\n    |X\n}" },
        .{ "{\n  |a\n  b\n}", "di{", "{\n|}" },
        .{ "a\n|b\n\nc", "dip", "|\nc" },
        .{ "a\n|b\n\nc", "dap", "|c" },
        .{ "f|oo(a)", "yi(P", "foo(|aa)" },
        .{ "foo |bar baz", "viwd", "foo | baz" },
        .{ "a (b |c) d", "va(d", "a | d" },
    });
}

// -- 7. registers ---------------------------------------------------------

test "registers" {
    try runCases(&.{
        .{ "|ab", "xp", "b|a" },
        .{ "|b\na", "ddp", "a\n|b" },
        .{ "|x\ny", "\"ayyj\"ap", "x\ny\n|x" },
        .{ "|a\nb", "\"ayyj\"Ayy\"aP", "a\n|a\nb\nb" },
        .{ "|a\nb", "yyj\"_ddp", "a\n|a" },
        .{ "|a\nb", "yyjdd\"0p", "a\n|a" },
        .{ "|a\nb\nc", "dddd\"2p", "c\n|a" },
        .{ "|ab\ncd", "xjdd\"-p", "b|a" },
        // Old bug: an empty linewise register could not be pasted.
        .{ "|\nx", "yyjp", "\nx\n|" },
        .{ "|a\n  b", "jyykP", "  |b\na\n  b" },
        // Old bug: x/X/s did not write a register.
        .{ "|abc", "sX<Esc>p", "X|abc" },
        .{ "a|bc", "Xp", "b|ac" },
        .{ "a|bc", "DP", "b|ca" },
        .{ "|ab\ncd", "vjyP", "|ab\ncab\ncd" },
        .{ "|foo bar", "\"qyiww\"qP", "foo fo|obar" },
    });
}

// -- 8. undo and redo ------------------------------------------------------

test "undo and redo" {
    try runCases(&.{
        .{ "|abc", "xu", "|abc" },
        .{ "|abc", "xxu", "|bc" },
        .{ "|abc", "xu<C-r>", "|bc" },
        .{ "|a", "ifoo<Esc>u", "|a" },
        .{ "|a", "ia<Left>b<Esc>u", "|aa" },
        .{ "a\n|b\nc", "ddu", "a\n|b\nc" },
        .{ "|a b c", "dwdwuu", "|a b c" },
        .{ "|a b c", "dwdwuu<C-r>", "|b c" },
        .{ "|ab", "3x2u", "|ab" },
    });
}

test "undo: no-op changes are not recorded; messages and stats" {
    var f = try Fx.init("|ab");
    defer f.deinit();
    _ = f.keys("ra");
    _ = f.keys("u");
    try t.expectEqualStrings("Already at oldest change", f.ed.statusMsg());
    _ = f.keys("xu");
    try t.expectEqual(@as(u32, 1), f.ed.stats().undos);
    _ = f.keys("<C-r><C-r>");
    try t.expectEqualStrings("Already at newest change", f.ed.statusMsg());
    try f.expect("|b");
}

// -- 9. insert mode -----------------------------------------------------

test "insert: Ctrl+W, Ctrl+U, Backspace, Delete" {
    try runCases(&.{
        .{ "|", "ipub fn<C-w>X<Esc>", "pub |X" },
        // Stops once at the insert start, then continues.
        .{ "fo|o", "Abar<C-w>X<Esc>", "foo|X" },
        .{ "fo|o", "Abar<C-w><C-w>X<Esc>", "|X" },
        .{ "foo |bar", "ix<C-w><C-w><Esc>", "|bar" },
        .{ "a\n|b", "i<C-w>X<Esc>", "a|Xb" },
        .{ "|", "ifoo.bar<C-w><C-w>X<Esc>", "foo|X" },
        .{ "|", "ifoo bar  <C-w>X<Esc>", "foo |X" },
        .{ "|", "ifoo bar<C-u>X<Esc>", "|X" },
        .{ "|", "i  foo<C-u>X<Esc>", "  |X" },
        .{ "ab|c", "Adef<C-u>X<Esc>", "abc|X" },
        .{ "ab|c", "Adef<C-u><C-u>X<Esc>", "|X" },
        .{ "a\n|b", "i<BS>X<Esc>", "a|Xb" },
        .{ "|", "iab<C-h>X<Esc>", "a|X" },
        .{ "a|b\nc", "A<Del>X<Esc>", "ab|Xc" },
        .{ "|abc", "i<Del><Esc>", "|bc" },
        .{ "|", "ifoo<C-bs>X<Esc>", "|X" },
    });
}

test "insert: Enter, autoindent, Tab, Ctrl+T/D/R/O/E/Y, counts" {
    try runCases(&.{
        .{ "  |foo", "A<CR>bar<Esc>", "  foo\n  ba|r" },
        .{ "  |a", "ob<Esc>", "  a\n  |b" },
        .{ "  |a", "Ob<Esc>", "  |b\n  a" },
        .{ "  |a", "o<Esc>", "  a\n|" },
        .{ "        |a", "o<BS>x<Esc>", "        a\n    |x" },
        .{ "|ab", "a<CR><Esc>", "a\n|b" },
        .{ "|", "ia<Tab>b<Esc>", "a   |b" },
        .{ "ab|c", "a<C-t>X<Esc>", "    abc|X" },
        .{ "        a|b", "i<C-d>X<Esc>", "    a|Xb" },
        .{ "|foo", "yiwA <C-r>\"<Esc>", "foo fo|o" },
        .{ "|abc", "A<C-o>0X<Esc>", "|Xabc" },
        .{ "|abc", "A<C-o>~X<Esc>", "abC|X" },
        .{ "|abc\nxyz", "jI<C-y><C-y><Esc>", "abc\na|bxyz" },
        .{ "|xyz\nabc", "I<C-e><Esc>", "|axyz\nabc" },
        .{ "|", "3ix<Esc>", "xx|x" },
        .{ "|a", "2ab<Esc>", "ab|b" },
        .{ "|a", "2ob<Esc>", "a\nb\n|b" },
        .{ "|", "iab<Esc>", "a|b" },
        .{ "|ab", "a<Right>X<Esc>", "ab|X" },
        .{ "a\n|b", "i<Up>X<Esc>", "|Xa\nb" },
    });
}

// -- 10. lines, case, replace, curswant --------------------------------------

test "lines and case" {
    try runCases(&.{
        // Old bug: J added no space and kept the indent.
        .{ "|a\n    b", "J", "a| b" },
        .{ "|f(\n  )", "J", "f(|)" },
        .{ "|a \nb", "J", "a |b" },
        .{ "|a\n\nb", "J", "|a\nb" },
        .{ "|a\n  b", "gJ", "a|  b" },
        .{ "|a", ">>", "    |a" },
        .{ "|a\nb", "2>>", "    |a\n    b" },
        .{ "      |a", "<<", "  |a" },
        .{ "|a\nb\n\nc", ">ip", "    |a\n    b\n\nc" },
        .{ "|a\nb", ">j", "    |a\n    b" },
        .{ "|ab", "~", "A|b" },
        .{ "|ab cd", "g~w", "|AB cd" },
        .{ "f|oo", "gUiw", "|FOO" },
        .{ "|ABC", "guu", "|abc" },
        .{ "a|bc", "gUU", "|ABC" },
        .{ "a|Bc", "g~~", "|AbC" },
        .{ "a|bc", "r<CR>", "a\n|c" },
        .{ "|abc", "Rxy<BS><Esc>", "|xbc" },
        .{ "|ab", "Rxyz<Esc>", "xy|z" },
        .{ "|ab", "Rxyz<BS><BS><Esc>", "|xb" },
        // Old bug: no remembered column.
        .{ "abc|d\nx\nabcd", "jj", "abcd\nx\nabc|d" },
        .{ "|ab\nabcd", "$j", "ab\nabc|d" },
        .{ "abc|d\nx", "jk", "abc|d\nx" },
    });
}

// -- 11. dot repeat ---------------------------------------------------------

test "dot repeat" {
    try runCases(&.{
        .{ "|foo bar", "cwX<Esc>w.", "X |X" },
        .{ "|a b c d e", "dw3.", "|e" },
        .{ "|abc", "x..", "|" },
        .{ "|", "2ix<Esc>.", "xx|xx" },
        .{ "|a\nb", "A;<Esc>j.", "a;\nb|;" },
        .{ "|a", "ob<Esc>.", "a\nb\n|b" },
        .{ "|abcd", "vld.", "|" },
        .{ "|abcd", "rxl.", "x|xcd" },
        .{ "|a", ">>.", "        |a" },
        .{ "|a b c", "ciwX<Esc>ww.", "X b |X" },
        .{ "|a\nb\nc\nd", "dd.", "|c\nd" },
        .{ "|ab\ncd", "A!<C-c>j.", "ab!\ncd|!" },
        .{ "|a b c", "\"adw.\"aP", "b| c" },
    });
}

// -- 12. visual mode -----------------------------------------------------------

test "visual mode" {
    try runCases(&.{
        .{ "a|bc\ndef", "vjd", "a|f" },
        // Old bug: Vc ran a line delete.
        .{ "  |a\n  b\nc", "VjcX<Esc>", "  |X\nc" },
        .{ "|a\nb\nc", "Vjd", "|c" },
        .{ "a|b\ncd", "v$d", "a|cd" },
        .{ "a|bcd", "vlohd", "|d" },
        .{ "|abc", "vl<Esc>gvd", "|c" },
        .{ "|abcdef", "v3ld", "|ef" },
        .{ "|abc", "vlU", "|ABc" },
        .{ "ABC|D", "vhu", "AB|cd" },
        .{ "|abc", "vl~", "|ABc" },
        .{ "|a\nb\nc", "VjjJ", "a b| c" },
        .{ "|abc", "vlrx", "|xxc" },
        .{ "|foo bar", "yiwwviwp", "foo fo|o" },
        .{ "|a\nb", "Vj>", "    |a\n    b" },
        .{ "abc |def", "vgeD", "|" },
        .{ "abc |def", "vged", "ab|ef" },
        // Old bug: a single g jumped to the top.
        .{ "a\n|b\nc", "vg<Esc>", "a\n|b\nc" },
        .{ "foo |bar", "viwcX<Esc>", "foo |X" },
        .{ "ab|cd", "vhy", "a|bcd" },
        .{ "|a\nb\nc", "Vjy", "|a\nb\nc" },
        .{ "|a\nb\nc", "Vjyjp", "a\nb\n|a\nb\nc" },
        .{ "|ab\ncd", "vjs<Esc>", "|d" },
        .{ "|a\nb", "vjx", "|" },
    });
}

test "visual: selection, showcmd, gv and v$" {
    var f = try Fx.init("a|b\ncd");
    defer f.deinit();
    _ = f.keys("v");
    try t.expectEqual(editor.Mode.visual, f.ed.mode);
    try t.expectEqualStrings("1", f.ed.showcmd());
    _ = f.keys("$");
    const s = f.ed.selection().?;
    try t.expectEqual(@as(usize, 2), s.end.col);
    try t.expect(f.ed.isInSelection(0, 1));
    try t.expect(!f.ed.isInSelection(0, 0));
    _ = f.keys("<Esc>");
    try t.expectEqual(editor.Mode.normal, f.ed.mode);
    try t.expect(f.ed.selection() == null);
    _ = f.keys("Vj");
    try t.expect(f.ed.isInSelection(1, 0));
    try t.expectEqualStrings("2", f.ed.showcmd());
}

// -- 13. search -----------------------------------------------------------

test "search" {
    try runCases(&.{
        .{ "|foo x foo y foo", "/foo<CR>n", "foo x foo y |foo" },
        .{ "foo |x foo", "?foo<CR>", "|foo x foo" },
        .{ "|a foo foo", "/foo<CR>N", "a foo |foo" },
        .{ "|foo bar foo", "*", "foo bar |foo" },
        .{ "foo bar |foo", "#", "|foo bar foo" },
        .{ "|foo foobar foo", "*", "foo foobar |foo" },
        .{ "|abc foo", "d/foo<CR>", "|foo" },
        .{ "|abc", "/b<Esc>", "|abc" },
        .{ "|abc", "/b<C-c>", "|abc" },
        .{ "|abc bd", "/bx<BS>d<CR>", "abc |bd" },
        .{ "a\n|ab b", "/b$<CR>", "a\nab |b" },
        .{ "|ba\nab", "/^a<CR>", "ba\n|ab" },
        .{ "|x Foo foo", "/foo<CR>", "x |Foo foo" },
        .{ "|x foo Foo", "/Foo<CR>", "x foo |Foo" },
        .{ "|x Foo foo", "/\\Cfoo<CR>", "x Foo |foo" },
        .{ "|foobar foo", "/\\<foo\\><CR>", "foobar |foo" },
        .{ "|a.b axb", "/a.b<CR>", "a.b |axb" },
        .{ "|ab ab ab", "/ab<CR>2n", "|ab ab ab" },
        .{ "|xa xa", "c/a<CR>y<Esc>", "|ya xa" },
    });
}

test "search: wrap message, highlight, incsearch, :noh" {
    var f = try Fx.init("x foo\n|y");
    defer f.deinit();
    _ = f.keys("/fo");
    try t.expectEqualStrings("/fo", f.ed.cmdline().?);
    // Incremental: the cursor previews the match while typing.
    try t.expectEqual(@as(usize, 0), f.ed.cursor.row);
    try t.expect(f.ed.isSearchMatch(0, 3));
    _ = f.keys("o<CR>");
    try t.expectEqualStrings("search hit BOTTOM, continuing at TOP", f.ed.statusMsg());
    try f.expect("x |foo\ny");
    try t.expect(f.ed.isSearchMatch(0, 2));
    try t.expect(!f.ed.isSearchMatch(0, 1));
    _ = f.keys(":noh<CR>");
    try t.expect(!f.ed.isSearchMatch(0, 2));
    var g = try Fx.init("|abc");
    defer g.deinit();
    _ = g.keys("n");
    try t.expectEqualStrings("E35: No previous regular expression", g.ed.statusMsg());
    _ = g.keys("/zz<CR>");
    try t.expectEqualStrings("E486: Pattern not found: zz", g.ed.statusMsg());
}

// -- 14. ex commands --------------------------------------------------------

test "ex commands" {
    try runCases(&.{
        .{ "|a a\na", ":%s/a/b/g<CR>", "b b\n|b" },
        .{ "|a_b a_b a_b", ":s/_/-/g<CR>", "|a-b a-b a-b" },
        .{ "|aa", ":s/a/b/<CR>", "|ba" },
        .{ "|a\na\na", ":2,3s/a/b/<CR>", "a\nb\n|b" },
        .{ "|a\na\na", "Vj:s/a/b/<CR>", "b\n|b\na" },
        .{ "|foo", ":s/o/[&]/g<CR>", "|f[o][o]" },
        .{ "|aA", ":s/a/x/gi<CR>", "|xx" },
        .{ "|a\nb\nc", ":3<CR>", "a\nb\n|c" },
        .{ "|a\nb", ":d<CR>", "|b" },
        .{ "|a\nb\nc", ":2d<CR>", "a\n|c" },
        .{ "a\n|b", ":m0<CR>", "|b\na" },
        .{ "|a\nb", ":m$<CR>", "b\n|a" },
        .{ "|a\nb", ":t.<CR>", "a\n|a\nb" },
        .{ "|a\nb", ":co$<CR>", "a\nb\n|a" },
        .{ "|a", ":><CR>", "    |a" },
        .{ "    |a", ":<<CR>", "|a" },
        .{ "|a\nb", ":j<CR>", "|a b" },
        .{ "|a a\na a", ":s/a/b/<CR>j&", "b a\n|b a" },
        .{ "|a", ":s/x/y/<CR>", "|a" },
        .{ "|abc", "xx:u<CR>", "|bc" },
    });
}

// -- review: differences found by replaying keys in Neovim ------------------
// Every expected value here was produced by nvim --clean (sw=4 et ai sol).

test "review: undo cursor, numbered-register dot, :join, visual end of line" {
    try runCases(&.{
        .{ "one two\n  three |four five\nsix seven\neight", "ddu", "one two\n  |three four five\nsix seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", "dku", "one tw|o\n  three four five\nsix seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", "Ju", "one two\n  three |four five\nsix seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", "ddu<C-r>", "one two\nsi|x seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", "Vjdu", "one two\n|  three four five\nsix seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", "Vkdu", "one tw|o\n  three four five\nsix seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", ":s/e/E/g<CR>u", "one two\n|  three four five\nsix seven\neight" },
        .{ "one two\n  three |four five\nsix seven\neight", "Goz<Esc>ggu", "one two\n  three four five\nsix seven\n|eight" },
        .{ "one |two three\nfour five", "itest<Esc>u", "one |two three\nfour five" },
        .{ "one |two three\nfour five", "Oabc<Esc>u", "one |two three\nfour five" },
        .{ "one |two three\nfour five", "ofoo<CR>bar<Esc>u", "one |two three\nfour five" },
        .{ "one |two three\nfour five", "dwdwuu<C-r>", "one |three\nfour five" },
        .{ "|alpha beta", "Rab<Esc>u", "|alpha beta" },
        .{ "abc\nd|ef", "ddu<C-r>", "|abc" },
        .{ "|a\nb\nc\nd", "dddddd\"1p..", "d\nc\nb\n|a" },
        .{ "one |two\nfour\nsix", "dd..\"1pu.u.", "\n|one two" },
        .{ "|a\nb", ":j<CR>", "|a b" },
        .{ "  one |two\n  three", ":j<CR>", "  |one two three" },
        .{ "x 0|07", "<C-a>", "x 00|8" },
        .{ "x 0|07", "20<C-x>", "x -01|3" },
        .{ "  |indent here\nsecond", "r<CR>", "  \n | ndent here\nsecond" },
        .{ "|a b\nc", "Vp", "|c" },
        .{ "  ab|c\ndef", "A<C-t><Esc>", "    ab|c\ndef" },
        .{ "  ab|c\ndef", "A<C-t><C-t>x<Esc>", "        abc|x\ndef" },
        .{ "      ab|c", "A<C-d><Esc>", "    ab|c" },
        .{ "foo   |bar", "i<C-o>dwZ<Esc>", "foo   |Z" },
        .{ "  ab|c\ndef", "i<C-o>dwZ<Esc>", "  ab|Z\ndef" },
        .{ "|x\ny\nz", "vld", "|y\nz" },
        .{ "|abc\ny\nz", "v$hd", "|\ny\nz" },
        .{ "  foo |qux\n  next", "vjhhd", "  foo |t" },
        .{ "x\n   |y\nz", "vjokd", "|x" },
        .{ "|ab\ncdef", "vjj$d", "|" },
    });
}

test "review: edges with an operator, g* g# g&, ex ranges, :s n flag and \\r" {
    try runCases(&.{
        .{ "|\n\nb", "qqdljq@q", "\n\n|b" },
        .{ "|\n\nb", "qqXjq@q", "\n\n|b" },
        .{ "|\n\nb", "qqdhjq@q", "\n\n|b" },
        .{ "|\n\nb", "qq<C-a>jq@q", "\n\n|b" },
        .{ "|\nb", "sx<Esc>", "|x\nb" },
        .{ "|\nb", "clx<Esc>", "|x\nb" },
        .{ "x = |\"a\" + ab", "g*", "x = \"a\" + |ab" },
        .{ "ab x |ab", "g#", "|ab x ab" },
        .{ "ab x |ab", "#", "|ab x ab" },
        .{ "|aXbX\nX", ":s/X/-/<CR>g&", "a-b-\n|-" },
        .{ "|a\nb\nc", ":1;+1d<CR>", "|c" },
        .{ "|a\nb\nc", ":2;+5d<CR>", "a\n|b\nc" },
        .{ "|a\nb", ":2,3d<CR>", "|a\nb" },
        .{ "|a\nb", ":3m0<CR>", "|a\nb" },
        .{ "x\n|ab a\na", ":%s/a//gn<CR>", "x\n|ab a\na" },
        .{ "|a, b, c\nx, y", ":%s/, /,\\r/g<CR>", "a,\nb,\nc\nx,\n|y" },
        .{ "|a, b, c\nx, y", ":%s/b/\\r\\r/<CR>", "a, \n\n|, c\nx, y" },
        .{ "|a, b, c\nx, y", ":%s/, /\\r/g<CR>u", "|a, b, c\nx, y" },
    });
}

test "review: visual ip/ap extension, insert start after arrows, Ctrl+C in <C-o>, inverted objects" {
    try runCases(&.{
        .{ "|one\n\n\ntwo\nthree\n\nfour", "vipipd", "|two\nthree\n\nfour" },
        .{ "|one\n\n\ntwo\nthree\n\nfour", "vapapd", "|four" },
        .{ "one\n\n\ntwo\n|three\n\nfour\nfive", "vkipd", "one\n|hree\n\nfour\nfive" },
        .{ "one\n\n\ntwo\n|three\n\nfour\nfive", "Vipipd", "one\n\n\n|four\nfive" },
        .{ "foo(baz, |qux)", "iab<Left><C-u><Esc>", "foo(baz,| bqux)" },
        .{ "|abc def\nxyz", "ia<C-o><C-c>x", "a|bc def\nxyz" },
        .{ "abc de|f\nxyz", "A<C-o><C-c>x", "abc d|e\nxyz" },
        .{ "|foo(a,\n) \"x\" 1", "Vi(d", "foo(|) \"x\" 1" },
        .{ "|foo(a,\n) \"x\" 1", "vi(d", "foo(|) \"x\" 1" },
        .{ "foo(a,\nb,\n|c) \"x\" 1", "vi(d", "foo(|) \"x\" 1" },
        .{ "x\n|", "diw", "|" },
        .{ "x\n|", "yiwP", "|x\nx\n" },
        .{ "x\n|", ">iw", "    |x\n" },
        .{ "ab\n|", "ciwZ<Esc>", "a|Z" },
        // A change that contains `.` must not recurse when repeated.
        .{ "  (|x)", "o<C-o>.<C-c>.", "  (x)\n\n|" },
    });
}

test "ex: results for :w :q and friends, errors" {
    const Pair = struct { []const u8, editor.ExCommand };
    const pairs = [_]Pair{
        .{ ":w<CR>", .write },   .{ ":wq<CR>", .write_quit }, .{ ":x<CR>", .write_quit },
        .{ ":q<CR>", .quit },    .{ ":q!<CR>", .quit_force }, .{ ":e!<CR>", .restart },
        .{ ":hint<CR>", .hint }, .{ "ZZ", .write_quit },
    };
    for (pairs) |p| {
        var f = try Fx.init("|a");
        defer f.deinit();
        try t.expectEqual(@as(?editor.ExCommand, p[1]), f.keys(p[0]).ex);
    }
    var f = try Fx.init("|a");
    defer f.deinit();
    _ = f.keys(":foo<CR>");
    try t.expectEqualStrings("E492: Not an editor command: foo", f.ed.statusMsg());
    _ = f.keys(":s/a");
    try t.expectEqualStrings(":s/a", f.ed.cmdline().?);
    try t.expectEqual(editor.Mode.cmdline, f.ed.mode);
    _ = f.keys("<Esc>");
    try t.expect(f.ed.cmdline() == null);
}

// -- 15. macros -------------------------------------------------------------

test "macros" {
    try runCases(&.{
        .{ "|a\nb\nc", "qqI- <Esc>A,<Esc>jq2@q", "- a,\n- b,\n- c|," },
        .{ "|a\nb\nc", "qqA!<Esc>jq@q@@", "a!\nb!\nc|!" },
        .{ "|ab", "qqx@qq@q", "|" },
        .{ "|1\n1\n1", "qa<C-a>jq2@a", "2\n2\n|2" },
        .{ "|a b c", "qwdwq.", "|c" },
        .{ "|a\nb\nc\nd", "qqddjq@q", "b\n|d" },
    });
}

test "macros: recording() and recursion limit" {
    var f = try Fx.init("|abc");
    defer f.deinit();
    _ = f.keys("qa");
    try t.expectEqual(@as(?u8, 'a'), f.ed.recording());
    _ = f.keys("q");
    try t.expect(f.ed.recording() == null);
    _ = f.keys("qq@qq@q");
    try t.expectEqualStrings("E169: Command too recursive", f.ed.statusMsg());
    try f.expect("|abc");
}

// -- 16. scrolling ---------------------------------------------------------

fn numbered(comptime n: usize) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var s: []const u8 = "|0";
        for (1..n) |i| s = s ++ std.fmt.comptimePrint("\n{d}", .{i});
        break :blk s;
    };
}

test "scrolling: Ctrl+D/U/E/Y/F/B, zz zt zb, H M L" {
    var f = try Fx.init(numbered(40));
    defer f.deinit();
    f.ed.setViewport(10);
    try t.expectEqual(@as(usize, 0), f.ed.viewTop());
    _ = f.keys("<C-d>");
    try t.expectEqual(@as(usize, 7), f.ed.cursor.row);
    try t.expectEqual(@as(usize, 5), f.ed.viewTop());
    _ = f.keys("<C-u>");
    try t.expectEqual(@as(usize, 2), f.ed.cursor.row);
    try t.expectEqual(@as(usize, 0), f.ed.viewTop());
    _ = f.keys("<C-e>");
    try t.expectEqual(@as(usize, 1), f.ed.viewTop());
    try t.expectEqual(@as(usize, 3), f.ed.cursor.row);
    _ = f.keys("<C-y>");
    try t.expectEqual(@as(usize, 0), f.ed.viewTop());
    _ = f.keys("<C-f>");
    try t.expectEqual(@as(usize, 8), f.ed.viewTop());
    try t.expectEqual(@as(usize, 10), f.ed.cursor.row);
    _ = f.keys("<C-b>");
    try t.expectEqual(@as(usize, 0), f.ed.viewTop());
    _ = f.keys("20Gzz");
    try t.expectEqual(@as(usize, 14), f.ed.viewTop());
    _ = f.keys("zt");
    try t.expectEqual(@as(usize, 17), f.ed.viewTop());
    _ = f.keys("zb");
    try t.expectEqual(@as(usize, 12), f.ed.viewTop());
    _ = f.keys("H");
    try t.expectEqual(@as(usize, 14), f.ed.cursor.row);
    _ = f.keys("L");
    try t.expectEqual(@as(usize, 19), f.ed.cursor.row);
    _ = f.keys("M");
    try t.expectEqual(@as(usize, 16), f.ed.cursor.row);
    // The cursor keeps a 2-line margin.
    _ = f.keys("gg");
    _ = f.keys("8j");
    try t.expectEqual(@as(usize, 1), f.ed.viewTop());
    _ = f.keys("G");
    try t.expectEqual(@as(usize, 30), f.ed.viewTop());
}

// -- 17. Ctrl+A / Ctrl+X ------------------------------------------------------

test "Ctrl+A and Ctrl+X" {
    try runCases(&.{
        .{ "x = |9", "<C-a>", "x = 1|0" },
        .{ "|abc 5", "<C-a>", "abc |6" },
        .{ "|10", "5<C-x>", "|5" },
        .{ "|x -1", "<C-a>", "x |0" },
        .{ "|x 1", "3<C-x>", "x -|2" },
        .{ "|0xff", "<C-a>", "0x10|0" },
        .{ "|abc", "<C-a>", "|abc" },
        .{ "|7 8", "<C-a>w.", "8 |9" },
    });
}

// -- 18. visual block (expected results replayed in Neovim) ----------------

test "visual block: d c I A $ with short lines" {
    try runCases(&.{
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjld", "a|d\neh\nil" },
        .{ "a|bcd\nef\nijkl", "<C-v>jjld", "a|d\ne\nil" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jj$d", "|a\ne\ni" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlx", "a|d\neh\nil" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlD", "|a\ne\ni" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jj$A;<Esc>", "a|bcd;\nefgh;\nijkl;" },
        .{ "a|bcd\nef\nijkl", "<C-v>jj$AZ<Esc>", "a|bcdZ\nefZ\nijklZ" },
        // A pads short lines up to the block's right edge.
        .{ "a|bcd\nef\nijkl", "<C-v>jjlA;<Esc>", "a|bc;d\nef ;\nijk;l" },
        .{ "a|bcd\nef\nijkl", "<C-v>jjAZ<Esc>", "a|bZcd\nefZ\nijZkl" },
        // I skips lines that end before the block.
        .{ "a|bcd\ne\nijkl", "<C-v>jjIfoo<Esc>", "a|foobcd\nefoo\nifoojkl" },
        .{ "a|bcd\n\nijkl", "<C-v>jjIZ<Esc>", "a|Zbcd\n\niZjkl" },
        .{ "|abcd\n\nijkl", "<C-v>jjIZ<Esc>", "|Zabcd\nZ\nZijkl" },
        // c replicates the typed text; a line break typed stops that.
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlcXY<Esc>", "aX|Yd\neXYh\niXYl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlsZ<Esc>", "a|Zd\neZh\niZl" },
        .{ "a|bcd\ne\nijkl", "<C-v>jj$cZ<Esc>", "a|Z\neZ\niZ" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlCZ<Esc>", "a|Z\neZ\niZ" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlcX<CR>Y<Esc>", "aX\n|Yd\neh\nil" },
        // Ctrl+C copies too (Neovim).
        .{ "a|bcd\nefgh", "<C-v>jIZ<C-c>", "a|Zbcd\neZfgh" },
    });
}

test "visual block: y p P, block registers, put over a block" {
    try runCases(&.{
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlyP", "a|bcbcd\nefgfgh\nijkjkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlyp", "ab|bccd\neffggh\nijjkkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlYP", "a|bcbcd\nefgfgh\nijkjkl" },
        // Past the end: short lines are padded, new lines are added.
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlyG$p", "abcd\nefgh\nijkl|bc\n    fg\n    jk" },
        .{ "a|bcd\nefgh", "<C-v>jlyjp", "abcd\nef|bcgh\n  fg" },
        .{ "|abcd\nefgh\nijkl", "l<C-v>jjlyGo<Esc>p", "abcd\nefgh\nijkl\n|bc\nfg\njk" },
        .{ "|abcd\nefgh\nijkl", "l<C-v>jjly3P", "a|bcbcbcbcd\nefgfgfgfgh\nijkjkjkjkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjl\"ay\"aP", "a|bcbcd\nefgfgh\nijkjkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jj$y$p", "abcd|bcd\nefghfgh\nijkljkl" },
        // Put over a block: a block, a one-line text on every row, lines below.
        .{ "x|yz\nabcd\nefgh\nijkl", "<C-v>lyj<C-v>jlp", "xyz\na|yzd\neh\nijkl" },
        .{ "x|yz\nabcd\nefgh\nijkl", "yiwj<C-v>jlp", "xyz\nxy|zcd\nxyzgh\nijkl" },
        .{ "x|yz\nabcd\nefgh\nijkl", "ylj<C-v>jjlp", "xyz\na|yd\neyh\niyl" },
        .{ "x|yz\nabcd\nefgh\nijkl", "yyj<C-v>jlp", "xyz\nad\neh\n|xyz\nijkl" },
        .{ "x|y\nabcd\nefgh", "<C-v>jylljjP", "xy\nabcd\ne|yfgh\n b" },
    });
    var f = try Fx.init("a|bcd\nefgh\nijkl");
    defer f.deinit();
    _ = f.keys("<C-v>jjly");
    try t.expectEqualStrings("block of 3 lines yanked", f.ed.statusMsg());
    const r = f.ed.regs.get(null).?;
    try t.expectEqual(@import("register.zig").Kind.block, r.kind);
    try t.expectEqualStrings("bc\nfg\njk", r.slice());
    try t.expectEqual(@as(usize, 2), r.width);
}

test "visual block: r o O ~ u U > < J gv and mode switches" {
    try runCases(&.{
        .{ "a|bcd\nef\nijkl", "<C-v>jjlrX", "a|XXd\neX\niXXl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlo<Esc>", "a|bcd\nefgh\nijkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlO<Esc>", "abcd\nefgh\ni|jkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjl~", "a|BCd\neFGh\niJKl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlU", "a|BCd\neFGh\niJKl" },
        .{ "a|BCD\nEFGH", "<C-v>jlu", "a|bcD\nEfgH" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjgU", "a|Bcd\neFgh\niJkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjl>", "a|    bcd\ne    fgh\ni    jkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjl3>", "a|            bcd\ne            fgh\ni            jkl" },
        .{ "a|bcd\nef\nijkl", "<C-v>jj>", "a|    bcd\ne    f\ni    jkl" },
        .{ "a  |  bcd\nef\nij      kl", "<C-v>jj<", "a  |bcd\nef\nij  kl" },
        .{ "a|b   cd\nef   gh\nijkl", "<C-v>jl<", "a|b   cd\nef   gh\nijkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlJ", "abcd efgh| ijkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jld<Esc>ggjgvd", "|a\ne\nijkl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjl<C-v>", "abcd\nefgh\nij|kl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlvd", "a|l" },
        .{ "a|bcd\nefgh\nijkl", "vjj<C-v>d", "a|cd\negh\nikl" },
        .{ "a|bcd\nefgh\nijkl", "<C-v>jjlS<Esc>", "|" },
    });
}

test "visual block: dot repeats a same-sized block at the cursor" {
    try runCases(&.{
        .{ "a|bcd\nefgh\nijkl\nmnop", "<C-v>jlcX<Esc>jj.", "aXd\neXh\ni|Xl\nmXp" },
        .{ "a|bcd\nefgh\nijkl\nmnop", "<C-v>jldj.", "ad\n|e\nil\nmnop" },
        .{ "a|bcd\nefgh\nijkl\nmnop", "<C-v>jlIX<Esc>jj.", "aXbcd\neXfgh\ni|Xjkl\nmXnop" },
        .{ "a|bcd\nefgh\nijkl\nmnop", "<C-v>j$A;<Esc>jj.", "abcd;\nefgh;\ni|jkl;\nmnop;" },
    });
}

test "visual block: tabs split at the edges, display columns" {
    try runCases(&.{
        .{ "|a\tbcd\nefghijklmn", "l<C-v>jd", "a|bcd\nemn" },
        .{ "efghijklmn\n|a\tbcd", "l<C-v>kd", "e|mn\nabcd" },
        .{ "abcdefghijkl\n|a\tbcd", "4l<C-v>kd", "abcdefghij|l\na\tbc" },
        .{ "abcdefghijklmnop\na|b\tcd", "ll<C-v>kd", "abcdefgh|jklmnop\nab\td" },
        .{ "abcdefghijklmnop\na|b\tcd", "ll<C-v>kIX<Esc>", "abcdefgh|Xijklmnop\nab\tXcd" },
        // A tab straddling the block's edges is split into spaces.
        .{ "ab|cdefghij\na\tb\nabcdefghij", "<C-v>ljjd", "ab|efghij\na     b\nabefghij" },
        .{ "ab|cdefghij\na\tb\nabcdefghij", "<C-v>ljjrX", "ab|XXefghij\na XX    b\nabXXefghij" },
        .{ "ab|cdefghij\na\tb\nabcdefghij", "<C-v>ljjIX<Esc>", "ab|Xcdefghij\na X      b\nabXcdefghij" },
    });
}

test "visual block: selection(), isInSelection, showcmd" {
    var f = try Fx.init("a|bcd\nef\nijkl");
    defer f.deinit();
    _ = f.keys("<C-v>jjl");
    try t.expectEqual(editor.Mode.visual_block, f.ed.mode);
    try t.expectEqualStrings("V-BLOCK", f.ed.mode.label());
    try t.expect(f.ed.mode.isVisual());
    const s = f.ed.selection().?;
    try t.expect(s.kind == .block and !s.to_eol);
    try t.expectEqual(editor.Pos{ .row = 0, .col = 1 }, s.start);
    try t.expectEqual(editor.Pos{ .row = 2, .col = 2 }, s.end);
    try t.expectEqualStrings("3x2", f.ed.showcmd());
    try t.expect(!f.ed.isInSelection(0, 0));
    try t.expect(f.ed.isInSelection(0, 2));
    try t.expect(!f.ed.isInSelection(0, 3));
    try t.expect(f.ed.isInSelection(1, 1));
    try t.expect(!f.ed.isInSelection(1, 2));
    _ = f.keys("$");
    try t.expect(f.ed.selection().?.to_eol);
    try t.expect(f.ed.isInSelection(0, 3));
    try t.expectEqualStrings("3x3", f.ed.showcmd());
    _ = f.keys("<Esc>");
    // A tab is inside when any of its cells are.
    var g = try Fx.init("|a\tb\nabcdefghij");
    defer g.deinit();
    _ = g.keys("j4l<C-v>k");
    try t.expect(g.ed.isInSelection(0, 1));
    try t.expect(!g.ed.isInSelection(0, 2));
    try t.expect(g.ed.isInSelection(1, 7));
    try t.expect(!g.ed.isInSelection(1, 8));
    try t.expect(!g.ed.isInSelection(1, 0));
}

// -- 19. :g, :v, :norm and | ------------------------------------------------

test "ex: :g and :v run a command on every matching line" {
    try runCases(&.{
        .{ "a\n\nb\n\n\nc|", ":g/^$/d<CR>", "a\nb\n|c" },
        // :g/x/m0 reverses the matching lines.
        .{ "|1x\n2\n3x\n4x", ":g/x/m0<CR>", "|4x\n3x\n1x\n2" },
        .{ "|keep a\ndrop\nkeep b\ndrop", ":v/keep/d<CR>", "keep a\n|keep b" },
        .{ "|ax\nbx\ncx", ":g!/b/d<CR>", "|bx" },
        .{ "|x = 1\ny = 2\nx = 3", ":g/x/norm A;<CR>", "x = 1;\ny = 2\nx = 3|;" },
        .{ "|a x a\nb\na x a", ":g/x/s/a/b/g<CR>", "b x b\nb\n|b x b" },
        .{ "|ax\nb\ncx", ":g/x/<CR>", "ax\nb\n|cx" },
        .{ "|a1\nb\na2\nc\na3", ":g/a/t$<CR>", "a1\nb\na2\nc\na3\na1\na2\n|a3" },
        .{ "|ax\nb\ncx", ":g/x/><CR>", "    ax\nb\n    |cx" },
        .{ "|a\nb\nc\nd", ":2,3g/./d<CR>", "a\n|d" },
        .{ "|foo\nbar\nfoo", "/foo<CR>:g//d<CR>", "|bar" },
        // Deleted lines drop out of the marked set; an error stops :g.
        .{ "|ax\nbx\ncx", ":g/x/.,+1d<CR>", "|cx" },
        .{ "|ax\nb\ncx\nd", ":g/x/+1d<CR>", "ax\n|cx" },
        .{ "|a\nb\na\nb", ":g/a/norm ddp<CR>", "b\na\nb\n|a" },
        // A line without a match is not an error for :s inside :g.
        .{ "|ab\nab", ":g/a/s/z/y/<CR>", "ab\n|ab" },
        .{ "|a\nb", ":g/a/g/b/d<CR>", "|a\nb" },
    });
    var f = try Fx.init("y\n|ax\nbx\ncx\nd");
    defer f.deinit();
    _ = f.keys(":g/x/d<CR>");
    try f.expect("y\n|d");
    try t.expectEqualStrings("3 fewer lines", f.ed.statusMsg());
    // One undo step for the whole :g.
    _ = f.keys("u");
    try f.expect("y\n|ax\nbx\ncx\nd");
    _ = f.keys(":g/zz/d<CR>");
    try t.expectEqualStrings("Pattern not found: zz", f.ed.statusMsg());
    _ = f.keys(":v/./d<CR>");
    try t.expectEqualStrings("Pattern found in every line: .", f.ed.statusMsg());
    _ = f.keys(":g/x/s/x/y/ | s/^/-/<CR>");
    try t.expectEqualStrings("6 substitutions on 6 lines", f.ed.statusMsg());
    _ = f.keys(":g/a/g/b/d<CR>");
    try t.expectEqualStrings("E147: Cannot do :global recursive", f.ed.statusMsg());
    _ = f.keys(":g axa<CR>");
    try t.expectEqualStrings("E146: Regular expressions can't be delimited by letters", f.ed.statusMsg());
}

test "ex: :norm and | between commands" {
    try runCases(&.{
        // A failing command drops the rest of the keys.
        .{ "|abc", ":norm fzx<CR>", "|abc" },
        .{ "|abc\nabc\nabc", ":%norm Ax<CR>", "abcx\nabcx\nabc|x" },
        .{ "|abc\nabc\nabc", ":2,3norm! 0x<CR>", "abc\nbc\n|bc" },
        // An unfinished insert is completed.
        .{ "|abc\nabc", ":norm ix<CR>", "|xabc\nabc" },
        .{ "|ab\ncd", ":g/./norm $x<CR>", "a\n|c" },
        .{ "|abc\nabc", ":s/a/X/ | s/b/Y/<CR>", "|XYc\nabc" },
        .{ "|abc\nabc", ":s/a/X/|2s/b/Y/<CR>", "Xbc\n|aYc" },
        .{ "|abc\nabc", ":%s/a/X/|%s/b/Y/<CR>", "XYc\n|XYc" },
        .{ "|ax\nbx\ncx", ":g/x/s/x/y/ | s/^/-/<CR>", "-ay\n-by\n|-cy" },
        // :g and :norm take the rest of the line, | included.
        .{ "|abc\nabc\nab", ":g/c/norm Ax|<CR>", "abcx|\nabcx||\nab" },
        // An error stops the chain.
        .{ "|abc", ":s/z/y/|s/a/X/<CR>", "|abc" },
    });
    var f = try Fx.init("|one");
    defer f.deinit();
    _ = f.keys(":norm<CR>");
    try t.expectEqualStrings("E471: Argument required", f.ed.statusMsg());
}

// -- 20. :s groups and replacement specials (replayed in Neovim) -----------

test "ex: :s with groups, &, case modifiers, \\r, word boundaries" {
    try runCases(&.{
        // Swap the operands of an assignment.
        .{ "|let a = b;", ":s/\\(\\w\\+\\) = \\(\\w\\+\\)/\\2 = \\1/<CR>", "|let b = a;" },
        .{ "|x = 1\ny = 2", ":%s/\\(\\w\\+\\) = \\(\\w\\+\\)/\\2 = \\1/<CR>", "1 = x\n|2 = y" },
        .{ "|fooBar", ":s/\\(foo\\)\\(Bar\\)/\\2\\1/<CR>", "|Barfoo" },
        .{ "|abc", ":s/\\(a\\)\\(b\\)\\(c\\)/\\3\\2\\1\\9/<CR>", "|cba" },
        .{ "|ab", ":s/\\(a\\|b\\)/<\\1>/g<CR>", "|<a><b>" },
        .{ "|foo bar", ":s/\\w\\+/[&]/g<CR>", "|[foo] [bar]" },
        .{ "|foo bar", ":s/\\w\\+/<\\0>/g<CR>", "|<foo> <bar>" },
        .{ "|a&b", ":s/&/\\&\\&/<CR>", "|a&&b" },
        .{ "|a,b,c", ":s/,/\\r/g<CR>", "a\nb\n|c" },
        // \n breaks the line too (Vim inserts a NUL).
        .{ "|a,b,c", ":s/,/\\n/g<CR>", "a\nb\n|c" },
        .{ "|aXbXc", ":s/X/\\t/g<CR>", "|a\tb\tc" },
        .{ "|cat concat cat", ":s/\\<cat\\>/dog/g<CR>", "|dog concat dog" },
        .{ "|cat concat cat", ":s/cat/dog/g<CR>", "|dog condog dog" },
        .{ "|hello world", ":s/\\w\\+/\\u&/g<CR>", "|Hello World" },
        .{ "|hello world", ":s/\\w\\+/\\U&/<CR>", "|HELLO world" },
        .{ "|hello world", ":s/\\(\\w\\+\\) \\(\\w\\+\\)/\\U\\1\\E \\2/<CR>", "|HELLO world" },
        .{ "|HELLO", ":s/.*/\\L\\u&/<CR>", "|Hello" },
        .{ "|function_name", ":s/_\\(\\l\\)/\\u\\1/g<CR>", "|functionName" },
        // ~ is the previous replacement.
        .{ "|foo foo", ":s/foo/bar/<CR>:s/foo/~x/<CR>", "|bar barx" },
        .{ "|a1b22c333", ":s/\\d\\{2,}/N/g<CR>", "|a1bNcN" },
        .{ "|one two three", ":s/one\\|three/X/g<CR>", "|X two X" },
        .{ "|foo(bar)", ":s/foo\\zs(bar)/[x]/<CR>", "|foo[x]" },
        // Empty matches, as Vim's do_sub counts them.
        .{ "|aaa", ":s/a*/-/g<CR>", "|-" },
        .{ "|abc", ":s/x*/-/g<CR>", "|-a-b-c" },
        .{ "|a,b", ":s/,*/-/g<CR>", "|-a-b" },
        .{ "|foo", ":s/o\\zs/-/g<CR>", "|fo-o-" },
        .{ "|abc", ":s/$/;/g<CR>", "|abc;" },
        .{ "|ab", ":s/b*$/X/g<CR>", "|aX" },
    });
    var f = try Fx.init("|abc");
    defer f.deinit();
    _ = f.keys(":s/\\(a/x/<CR>");
    try t.expectEqualStrings("E54: Unmatched \\(", f.ed.statusMsg());
    _ = f.keys(":s/a\\)/x/<CR>");
    try t.expectEqualStrings("E55: Unmatched \\)", f.ed.statusMsg());
    _ = f.keys("/\\(b<CR>");
    try t.expectEqualStrings("E54: Unmatched \\(", f.ed.statusMsg());
    try f.expect("|abc");
}

// -- 21. gn / gN (replayed in Neovim) ---------------------------------------

test "gn: select, operate on and repeat on the next match" {
    try runCases(&.{
        // cgn then . changes one match at a time.
        .{ "|foo x foo y foo", "/foo<CR>cgnbar<Esc>..", "ba|r x bar y bar" },
        .{ "|a foo b foo\nc foo", "/foo<CR>ggcgnX<Esc>j0.", "a X b foo\nc |X" },
        .{ "|ab ab", "/b<CR>0cgnX<Esc>.", "aX a|X" },
        .{ "|a.b.c", "/\\.<CR>0cgn-<Esc>.", "a-b|-c" },
        // The match under the cursor counts.
        .{ "|a foo b foo", "/foo<CR>ggdgn", "a | b foo" },
        .{ "|a foo b foo", "/foo<CR>$dgn", "a foo b| " },
        .{ "a foo b f|oo", "/foo<CR>dgn", "a | b foo" },
        .{ "|xfooy", "/foo<CR>0dgn", "x|y" },
        .{ "|a foo b foo", "/foo<CR>ggygnP", "a fo|ofoo b foo" },
        // gN goes backwards; a second gn extends the selection.
        .{ "|a foo b foo", "/foo<CR>$gNd", "a foo b| " },
        .{ "|a foo b foo", "/foo<CR>ggwgNd", "a | b foo" },
        .{ "|a foo b foo", "/foo<CR>$gN<Esc>", "a foo b |foo" },
        .{ "|a foo b foo", "/foo<CR>gggn<Esc>", "a fo|o b foo" },
        .{ "|a foo b foo", "/foo<CR>gggngnd", "a| " },
        .{ "|a foo b foo", "/foo<CR>$gNgNd", "a| " },
        .{ "|foo\nbar\nfoo", "/foo<CR>ggjdgN", "|\nbar\nfoo" },
    });
    // At the last match, dgn wraps to the first with Vim's message.
    var f = try Fx.init("a foo b foo |c");
    defer f.deinit();
    _ = f.keys("/foo<CR>$dgn");
    try f.expect("a | b foo c");
    try t.expectEqualStrings("search hit BOTTOM, continuing at TOP", f.ed.statusMsg());
    var g = try Fx.init("|abc");
    defer g.deinit();
    _ = g.keys("gn");
    try t.expectEqualStrings("E35: No previous regular expression", g.ed.statusMsg());
}

// -- 22. sentences ( ) is as (replayed in Neovim) --------------------------

test "sentences: ( ) with counts, paragraphs and closing quotes" {
    try runCases(&.{
        .{ "|One two. Three four. Five six.", ")x", "One two. |hree four. Five six." },
        .{ "|One two. Three four. Five six.", "2)x", "One two. Three four. |ive six." },
        .{ "One two. Three four. Five |six.", "(x", "One two. Three four. |ive six." },
        .{ "One two. Three four. Five |six.", "2(x", "One two. |hree four. Five six." },
        .{ "One two. Three |four. Five six.", "(x", "One two. |hree four. Five six." },
        .{ "|One two. Three four.\nFive six.", "3)x", "One two. Three four.\nFive si|x" },
        // An empty line is a sentence boundary of its own.
        .{ "|One two.\n\nThree four.", ")x", "One two.\n|\nThree four." },
        .{ "|One two.\n\nThree four.", "2)x", "One two.\n\n|hree four." },
        .{ "One two.\n\n|Three four.", "(x", "One two.\n|\nThree four." },
        .{ "|He said \"Hi.\" She left.", ")x", "He said \"Hi.\" |he left." },
        .{ "|Hi! Bye? Ok.", "2)x", "Hi! Bye? |k." },
        // A period inside a word does not end a sentence.
        .{ "|a.b c. d", ")x", "a.b c.| " },
        .{ "|One. Two.", ")))x", "One. Tw|o" },
    });
}

test "sentences: d( d) is as with counts, operators and Visual mode" {
    try runCases(&.{
        .{ "|One two. Three four. Five six.", "d)", "|Three four. Five six." },
        .{ "One two. Three |four. Five six.", "d(", "One two. |four. Five six." },
        .{ "One two. Three |four. Five six.", "dis", "One two. | Five six." },
        .{ "One two. Three |four. Five six.", "das", "One two. |Five six." },
        .{ "One two. Three |four. Five six.", "d2as", "One two|." },
        .{ "One two. Three |four. Five six.", "d2is", "One two. |Five six." },
        .{ "One two. Three |four. Five six.", "cisX.<Esc>", "One two. X|. Five six." },
        // On the blanks between sentences.
        .{ "One two.| Three four. Five six.", "dis", "One two.|Three four. Five six." },
        .{ "One two.| Three four. Five six.", "das", "One two.| Five six." },
        // The last sentence takes the blanks before it.
        .{ "One two. Three four. Five |six.", "das", "One two. Three four|." },
        .{ "|One two.\nThree four.\nFive.", "das", "|Three four.\nFive." },
        .{ "One two.\n|Three four.\nFive.", "das", "One two.\n|Five." },
        .{ "One two. Three |four.\n\nNext.", "das", "One two|.\n\nNext." },
        .{ "One two. Three |four. Five six.", "visd", "One two. | Five six." },
        .{ "One two. Three |four. Five six.", "vasd", "One two. |Five six." },
        .{ "One |two.  Three four.", "das", "|Three four." },
    });
}

// -- 23. search offsets, chained searches (replayed in Neovim) -------------

test "search: matches on a line do not overlap (cpoptions c)" {
    try runCases(&.{
        .{ "|aaaa", "/aa<CR>x", "aa|a" },
        .{ "a|aaa", "/aa<CR>x", "aa|a" },
        .{ "aaa|a", "?aa<CR>x", "aa|a" },
        .{ "aa|aa", "?aa<CR>x", "|aaa" },
    });
}

test "search offsets: /pat/e s b +N, n N reuse them, // drops them, ; chains" {
    try runCases(&.{
        .{ "|x foo\nbar foo\n  baz", "/foo/+1<CR>x", "x foo\n|ar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>x", "x f|o\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>nx", "x foo\nbar f|o\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e+1<CR>x", "x foo\n|ar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e-1<CR>nx", "x foo\nbar f|o\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/s+2<CR>nx", "x foo\nbar f|o\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/b-1<CR>nx", "x foo\nbar|foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/-<CR>x", "| foo\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/1<CR>x", "x foo\n|ar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/+<CR>nx", "x foo\nbar foo\n| baz" },
        .{ "x foo\nbar foo\n  |baz", "?foo?e<CR>x", "x foo\nbar f|o\n  baz" },
        .{ "x foo\nbar foo\n  |baz", "?foo?e<CR>nx", "x f|o\nbar foo\n  baz" },
        .{ "x foo\nbar foo\n  |baz", "?foo?s-1<CR>nx", "x|foo\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>//<CR>x", "x foo\nbar |oo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>/<CR>x", "x foo\nbar f|o\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo<CR>//e<CR>x", "x f|o\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "d/foo/e<CR>", "|\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "d/foo/+1<CR>", "  |baz" },
        .{ "|x foo\nbar foo\n  baz", "d/foo/s-1<CR>", "| foo\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>Nx", "x foo\nbar f|o\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>*x", "x foo\nbar |oo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>Gnx", "x f|o\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e+3<CR>x", "x foo\nba| foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "2/foo/e<CR>x", "x foo\nbar f|o\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/e<CR>?<CR>x", "x foo\nbar f|o\n  baz" },
        .{ "|ab ab ab", "/ab/e<CR>nnx", "ab ab |a" },
        .{ "|ab ab ab", "/ab/s+1<CR>nnx", "ab ab |a" },
        .{ "|ab ab ab", "/ab/e+1<CR>nx", "ab ab|ab" },
        .{ "|x foo\nbar foo\n  baz", "/foo/+5<CR>x", "x foo\nbar foo\n| baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/ e<CR>x", "x |oo\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/;x<CR>x", "| foo\nbar foo\n  baz" },
        .{ "|x foo\nbar foo\n  baz", "/foo/-1<CR>nx", "| foo\nbar foo\n  baz" },
        .{ "|a foo bar\nbar foo\n  baz", "/foo/;/bar<CR>x", "a foo |ar\nbar foo\n  baz" },
        .{ "|a foo bar\nbar foo\n  baz", "/foo/e;?a?<CR>x", "| foo bar\nbar foo\n  baz" },
        .{ "|a foo bar\nbar foo\n  baz", "/bar/;/foo/e<CR>nx", "a fo| bar\nbar foo\n  baz" },
        .{ "|a foo bar\nbar foo\n  baz", "d/foo/;/bar/e<CR>", "|\nbar foo\n  baz" },
        .{ "|a foo bar\nbar foo\n  baz", "/baz/-1<CR>nx", "a foo bar\n|ar foo\n  baz" },
    });
}

// -- 24. jump list, change list, marks across line changes (Neovim) ------

test "jumps: Ctrl-O Ctrl-I Tab, '' ``, g; g, '. `. `^, marks follow lines" {
    try runCases(&.{
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "G<C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "G<C-o><C-i>x", "l0\nl1 x\nl2\nl3 y\nl4\n|5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "G<C-o><Tab>x", "l0\nl1 x\nl2\nl3 y\nl4\n|5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "3GG<C-o><C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "3GG<C-o><C-o><C-i>x", "l0\nl1 x\n|2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "3GG2<C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "3GG<C-o><C-o><C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "/y<CR><C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "3G5G3G<C-o><C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "G''x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "G``x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jmajjmbggdd'ax", "|1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jjmaggdd'ax", "l1 x\n|2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jmaggjdd'ax", "l0\n|2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jjmaggO<Esc>'ax", "\nl0\nl1 x\n|2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxjjjxggg;x", "l0\n1 x\nl2\nl3 y\n|\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxjjjxggg;g;x", "l0\n| x\nl2\nl3 y\n4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxjjjxggg;g;g,x", "l0\n1 x\nl2\nl3 y\n|\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxjjjxgg2g;x", "l0\n| x\nl2\nl3 y\n4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "g;", "|l0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxggg;g;", "l0\n|1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxjjjxgg'.x", "l0\n1 x\nl2\nl3 y\n|\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jxjjjxgg`.x", "l0\n1 x\nl2\nl3 y\n|\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jAzz<Esc>gg`^x", "l0\nl1 x|z\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jAzz<Esc>gggix<Esc>", "l0\nl1 xzz|x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jx5GggO<Esc>g;x", "|\nl0\n1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "*<C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "3Gjj<C-o>x", "|0\nl1 x\nl2\nl3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jjjmaggdj'ax", "l2\n|3 y\nl4\nl5" },
        .{ "|l0\nl1 x\nl2\nl3 y\nl4\nl5", "jjjmaggddu'ax", "l0\nl1 x\nl2\n|3 y\nl4\nl5" },
        // :s (when it substitutes), :g, :d and :> are jumps; :s with | chains.
        .{ "x\n|a b\nc\ny", ":3s/c/d/<CR>''x", "x\n| b\nd\ny" },
        .{ "x\n|a b\nc\ny", ":g/c/s/c/d/<CR>''x", "x\n| b\nd\ny" },
        .{ "x\n|a b\nc\ny", ":g/c/<CR>''x", "x\n| b\nc\ny" },
        .{ "x\n|a b\nc\ny", ":3d<CR>''x", "x\n| b\ny" },
        .{ "x\n|a b\nc\ny", ":%s/c/d/<CR><C-o>x", "x\n| b\nd\ny" },
        .{ "x\n|a b\nc\ny", ":3s/c/d/<CR>u''x", "x\n| b\nc\ny" },
        .{ "x\n|a b\nc\ny", ":3><CR>''x", "x\n| b\n    c\ny" },
        .{ "|a/b\nc", ":s#/#-#<CR>", "|a-b\nc" },
        .{ "|a/b\nc", ":s+/+-+g<CR>", "|a-b\nc" },
        .{ "x\n|a b\nc", ":%s/c/d/<CR><C-o>x", "x\n| b\nd" },
        .{ "x\n|a b\nc", ":%s/c/d/<CR>''x", "x\n| b\nd" },
        .{ "|(a\nb)", "%<C-o>x", "|a\nb)" },
        .{ "|a\nb\nc\nd", ":2,3p<CR>x", "a\nb\n|\nd" },
        .{ "|a\nb\nc", ":2p<CR>x", "a\n|\nc" },
        .{ "|a b\nc", ":s/a/x/|s/b/y/<CR>", "|x y\nc" },
        .{ "|ab\nab\nab", "<C-v>jjlygvd", "|\n\n" },
        .{ "|ab\ncd", "<C-v>jJ", "ab| cd" },
        // `:N` is not a jump.
        .{ "l0\nl1 x\n|l2\nl3 y", ":4<CR>''x", "l0\nl1 x\nl2\n|3 y" },
    });
}

// -- 25. U, the undo tree (g- g+ :earlier :later), marks restored by u ---

test "U: undoes the latest changes on one line, is itself undoable" {
    try runCases(&.{
        .{ "a|bcdef\nghij\nklm", "xxU", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xxUU", "a|def\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xxUu", "a|def\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xxUux", "a|ef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjxkU", "acdef\ng|hij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjxU", "acdef\ng|hij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xddU", "|ghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xOfoo<Esc>U", "|\nacdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjOfoo<Esc>U", "acdef\n|\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xifoo<Esc>U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xlllU", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjddU", "acdef\n|klm" },
        .{ "a|bcdef\nghij\nklm", "xjJU", "a|bcdef\nghij klm" },
        .{ "a|bcdef\nghij\nklm", "xkJU", "a|bcdef\nklm" },
        .{ "a|bcdef\nghij\nklm", "xu<C-r>U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xuU", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xxuU", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "cwX<Esc>U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "x:s/c/Q/<CR>U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xp0U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "x>>U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "x~~U", "a|bcdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjoq<Esc>U", "acdef\nghij\n|\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjyypU", "a|bcdef\nghij\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xyypU", "a|bcdef\nacdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xyyPU", "a|bcdef\nacdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xo<Esc>U", "acdef\n|\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "x:2d<CR>U", "acdef\n|klm" },
        .{ "a|bcdef\nghij\nklm", "x:2t0<CR>U", "|ghij\nacdef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjdkU", "|klm" },
        .{ "a|bcdef\nghij\nklm", "xjrZkU", "acdef\ng|hij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xjxkkU", "acdef\ng|hij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xxlUU", "ad|ef\nghij\nklm" },
        .{ "a|bcdef\nghij\nklm", "xxlUUu", "a|bcdef\nghij\nklm" },
    });
}

test "undo tree: g- g+ across branches, :earlier :later, u restores marks" {
    try runCases(&.{
        .{ "|one\ntwo\nthree", "xjxjxg-", "ne\nwo\n|three" },
        .{ "|one\ntwo\nthree", "xjxjxg-g-", "ne\n|two\nthree" },
        .{ "|one\ntwo\nthree", "xjxjx3g-", "|one\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xjxjx3g-g+", "|ne\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xjxjx3g-2g+", "ne\n|wo\nthree" },
        .{ "|one\ntwo\nthree", "xxuxg-", "|e\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxuxg-g-", "|ne\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxuxg-g-g+g+", "|e\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxuxg-g-uu<C-r>", "|ne\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxuxuu<C-r><C-r>", "|e\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxuxg-<C-r>", "|e\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxux:earlier 2<CR>", "|ne\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xxux:ea<CR>:lat<CR>", "|e\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "g-", "|one\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "xg+", "|ne\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "jmaggddu", "|one\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "jjmaggddu'ax", "one\ntwo\n|hree" },
        .{ "|one\ntwo\nthree", "jjmaggdd'ax", "two\n|hree" },
        .{ "|one\ntwo\nthree", "jjmaggddu<C-r>'ax", "two\n|hree" },
        .{ "|one\ntwo\nthree", "jjmaggdduggx'ax", "ne\ntwo\n|hree" },
        .{ "|one\ntwo\nthree", "xxux2g-x", "|e\ntwo\nthree" },
        .{ "|one\ntwo\nthree", "ddjddg-g-g+", "|two\nthree" },
        .{ "|one\ntwo\nthree", "ddjddugg-", "|two\nthree" },
    });
}

// -- 26. bracket and tag objects (replayed in Neovim) --------------------

test "bracket objects: counts, next block forward, quotes, Visual grows outward" {
    try runCases(&.{
        .{ "[1, [2, |3]]", "va[a[a[d", "[1, |]" },
        .{ "[1, [2, |3]]", "vi[i[i[d", "[|]" },
        .{ "{\n  a {\n    |b\n  }\n}", "va{a{d", "|" },
        .{ "{\n  a {\n    |b\n  }\n}", "vi{i{d", "{\n|}" },
        .{ "{\n|}\n", "di{", "{\n|}\n" },
        .{ "<a <b|> c>", "da>", "<a | c>" },
        .{ "<a <b|> c>", "di<", "<a <|> c>" },
        .{ "|()", "da(", "|" },
        .{ "|foo(a, b) bar(c)", "da(", "foo| bar(c)" },
        .{ "|foo(a, b) bar(c)", "di(", "foo(|) bar(c)" },
        .{ "|foo(a)", "yi(P", "foo(|aa)" },
        .{ "|x = [1, [2, 3]]", "d2i[", "x = [1, [|]]" },
        .{ "|x = [1, [2, 3]]", "di[", "x = [|]" },
        .{ "a |b c d", "vawawd", "a |d" },
        .{ "a[1][|2]", "di[", "a[1][|]" },
        .{ "a[1]|[2]", "di]", "a[1][|]" },
        .{ "f('(', |b)", "di(", "f('(|)" },
        .{ "f(\"a(b|c\", 1)", "di(", "f(\"a(b|c\", 1)" },
        .{ "f(\"a(b|c)d\")", "di(", "f(\"a(|)d\")" },
        .{ "f(\n  a,\n  |b\n)", "ci(<Esc>", "f(\n|\n)" },
        .{ "f(\n  a,\n  |b\n)", "di(", "f(\n|)" },
        .{ "f(\n|)", "di(", "f(\n|)" },
        .{ "f(|)", "ci(x<Esc>", "f(|x)" },
        .{ "f(|)", "di(", "f(|)" },
        .{ "f(|a, \")\", b)", "di(", "f(|)" },
        .{ "f(a, '(', |b)", "di(", "f(a, '(|)" },
        .{ "f(a, \"(\", |b)", "di(", "f(a, \"(\", |b)" },
        .{ "f(a, \"(\", b)\n|x)", "di(", "f(|)\nx)" },
        .{ "f(a, \"(\", b|)", "di(", "f(a, \"(\", b|)" },
        .{ "f(a, \"(|\", b)", "di(", "f(a, \"(|\", b)" },
        .{ "f(a, \")\", |b)", "di(", "f(a, \")\", |b)" },
        .{ "f(a, \"x\", |b)", "di(", "f(|)" },
        .{ "f(a, (b|, c), d)", "2di(", "f(|)" },
        .{ "f(a, (b|, c), d)", "d2i(", "f(|)" },
        .{ "f(a, (b|, c), d)", "di(", "f(a, (|), d)" },
        .{ "f(a, (b|, c), d)", "va(a(d", "|f" },
        .{ "f(a, (b|, c), d)", "vhi(d", "f(a, (|), d)" },
        .{ "f(a, (b|, c), d)", "vi(d", "f(a, (|), d)" },
        .{ "f(a, (b|, c), d)", "vi(i(d", "f(|)" },
        .{ "f(a, (b|, c), d)", "vlli(d", "f(a, (|), d)" },
        .{ "f(a, |\"(\", b)", "di(", "f(|)" },
        .{ "foo |x\n(bar)", "di(", "foo x\n(|)" },
        .{ "foo(a, b) |bar(c)", "ci(X<Esc>", "foo(a, b) bar(|X)" },
        .{ "if (x) {\n    |foo();\n    bar();\n}", "ci{X<Esc>", "if (x) {\n    |X\n}" },
        .{ "if (x) {\n    |foo();\n    bar();\n}", "da{", "if (x)| " },
        .{ "if (x) {\n    |foo();\n    bar();\n}", "di{", "if (x) {\n|}" },
        .{ "if (x) {\n    |foo();\n    bar();\n}", "vi{d", "if (x) {\n|}" },
        .{ "if (x) {\n    |foo();\n    bar();\n}", "vi{i{d", "if (x) {\n|}" },
        .{ "x \"(\" y (a |b)", "di(", "x \"(\" y (|)" },
        .{ "x (a) |y", "di(", "x (a) |y" },
        .{ "x (a\n|b) y", "di(", "x (|) y" },
    });
}

test "tag objects: it at, nesting, unclosed tags, Visual repeat, line breaks" {
    try runCases(&.{
        .{ "<div><p>he|llo</p></div>", "dit", "<div><p>|</p></div>" },
        .{ "<div><p>he|llo</p></div>", "dat", "<div>|</div>" },
        .{ "<div><p>he|llo</p></div>", "d2it", "<div>|</div>" },
        .{ "<div><p>he|llo</p></div>", "d2at", "|" },
        .{ "<div><p>he|llo</p></div>", "vititd", "<div>|</div>" },
        .{ "<div><p>he|llo</p></div>", "vatatd", "|" },
        .{ "<div><p>he|llo</p></div>", "vitd", "<div><p>|</p></div>" },
        .{ "<div><p>he|llo</p></div>", "vitit<Esc>x", "<div><p>hello</p|</div>" },
        .{ "<d|iv><p>hello</p></div>", "dit", "<div>|</div>" },
        .{ "<div><p>hello</p></d|iv>", "dit", "<div>|</div>" },
        .{ "<div><p>hello</p|></div>", "dit", "<div><p>|</p></div>" },
        .{ "<div>|<p>hello</p></div>", "dit", "<div><p>|</p></div>" },
        .{ "<a>|</a>", "dit", "<a>|</a>" },
        .{ "<a>|</a>", "cit<Esc>", "<a|></a>" },
        .{ "<a>|</a>", "vitd", "|" },
        .{ "<div>\n  <p>|x</p>\n</div>", "dit", "<div>\n  <p>|</p>\n</div>" },
        .{ "<div>\n  <p>x</p>\n  |y\n</div>", "dit", "<div>|</div>" },
        .{ "<div>\n  <p>x</p>\n  |y\n</div>", "dat", "|" },
        .{ "<div>\n  <p>x</p>\n  |y\n</div>", "vitd", "<div>|</div>" },
        .{ "<div>\n  |<p>x</p>\n</div>", "dit", "<div>\n  <p>|</p>\n</div>" },
        .{ "<div>\n  |<p>x</p>\n</div>", "cit<Esc>", "<div>\n  <p|></p>\n</div>" },
        .{ "<ul><li>a<li>|b</ul>", "dit", "<ul>|</ul>" },
        .{ "<p>a<br>|b</p>", "dit", "<p>|</p>" },
        .{ "<p>a<br/>|b</p>", "dit", "<p>|</p>" },
        .{ "<A>x|y</a>", "dit", "<A>|</a>" },
        .{ "<a href=\"x\">l|ink</a>", "dit", "<a href=\"x\">|</a>" },
        .{ "<a href=\"x\">l|ink</a>", "dat", "|" },
        .{ "<a\n href=\"x\">l|ink</a>", "dit", "<a\n href=\"x\">|</a>" },
        .{ "|plain text", "dit", "|plain text" },
        .{ "<b>one</b> |two <i>three</i>", "dit", "<b>one</b> |two <i>three</i>" },
        .{ "<div><div>a</div>|b</div>", "dit", "<div>|</div>" },
        .{ "<x>a<x>b|</x>c</x>", "dat", "<x>a|c</x>" },
        .{ "<x>a<x>b|</x>c</x>", "2dit", "<x>|</x>" },
        .{ "<div>\n  <p>x</p>\n  |y\n</div>", "cit<Esc>", "<div|></div>" },
        .{ "<div>\n  <p>x</p>\n  |y\n</div>", "yitP", "<di|v\n  <p>x</p>\n  y\n>\n  <p>x</p>\n  y\n</div>" },
        .{ "<div>\n  <p>x</p>\n  |y\n  </div>", "dit", "<div>|</div>" },
        .{ "  <div>\n  |y\n  </div>", "dit", "  <div>|</div>" },
        .{ "<div>\n|y</div>", "dit", "<div>|</div>" },
        .{ "<a>x</a> <b>|y</b>", "dit", "<a>x</a> <b>|</b>" },
    });
}

// -- 27. display columns: j k | $ over tabs (replayed in Neovim) ---------

test "columns: j/k keep the display column across tabs, | counts screen cells" {
    try runCases(&.{
        .{ "\tab|c\nabcdefghijkl", "jx", "\tabc\nabcdefghij|l" },
        .{ "abcdefghi|jkl\n\tabc", "jx", "abcdefghijkl\n\ta|c" },
        .{ "abcd|efghijkl\n\tabc", "jx", "abcdefghijkl\n|abc" },
        .{ "abcd|efghijkl\n\tabc\nabcdefghijkl", "jjx", "abcdefghijkl\n\tabc\nabcd|fghijkl" },
        .{ "|a\tb\nabcdefghijkl", "lljx", "a\tb\nabcdefgh|jkl" },
        .{ "ab|c\n\t\tx\nabcdefghijklmnopqrstu", "$jjx", "abc\n\t\tx\nabcdefghijklmnopqrs|t" },
        .{ "\tx|y\nab\tcd", "jx", "\txy\nab\t|c" },
        .{ "|a\tb\tc", "9|x", "a\t|\tc" },
        .{ "|a\tb\tc", "10|x", "a\tb|c" },
        .{ "|a\tb\tc", "3|x", "a|b\tc" },
        .{ "|a\tb\tc", "100|x", "a\tb|\t" },
        .{ "\t|x\nabcdefghijk", "kjx", "\tx\nabcdefgh|jk" },
        .{ "abcdefgh|ij\n\tx\nabcdefghijk", "jjx", "abcdefghij\n\tx\nabcdefgh|jk" },
        .{ "ab|c\n\t\nabcdefghijk", "jjx", "abc\n\t\nab|defghijk" },
        .{ "a\tbc|d\nabcdefghijklmn", "jx", "a\tbcd\nabcdefghij|lmn" },
        .{ "abcdefghijklm|n\na\tbcd", "kjx", "abcdefghijklmn\na\tb|c" },
    });
}

// -- 28. gq gw (textwidth 20) and = (replayed in Neovim) -------------------

test "gq gw: paragraphs joined and broken at textwidth, cursor, dot, Visual" {
    try runCasesWith(.{ .textwidth = 20 }, &.{
        .{ "|one two three four five six seven eight", "gqq", "one two three four\n|five six seven eight" },
        .{ "one two |three four five six seven eight", "gqq", "one two three four\n|five six seven eight" },
        .{ "|one two\nthree four five\nsix seven eight nine ten\n\nnext para", "gqip", "one two three four\nfive six seven eight\n|nine ten\n\nnext para" },
        .{ "|one two\nthree four five\nsix seven eight nine ten\n\nnext para", "gqap", "one two three four\nfive six seven eight\nnine ten\n|\nnext para" },
        .{ "|one two\nthree four five\nsix seven eight nine ten\n\nnext para", "gqG", "one two three four\nfive six seven eight\nnine ten\n\n|next para" },
        .{ "  |one two three four five six seven eight", "gqq", "  one two three four\n  five six seven\n  |eight" },
        .{ "|one two\n  three four five six seven", "gqj", "one two three four\n|five six seven" },
        .{ "|averyveryverylongwordthatexceeds the width", "gqq", "averyveryverylongwordthatexceeds\n|the width" },
        .{ "|a averyveryverylongwordthatexceeds b", "gqq", "a\naveryveryverylongwordthatexceeds\n|b" },
        .{ "|one.  two three   four five six seven", "gqq", "one.  two three\n|four five six seven" },
        .{ "|one two three\n\n\nfour", "gqG", "one two three\n\n\n|four" },
        .{ "|one two three four five six seven eight", "Vgq", "one two three four\n|five six seven eight" },
        .{ "|one two three four five six seven eight", "gqqu", "|one two three four five six seven eight" },
        .{ "|one two three four five six seven eight", "gqq.", "one two three four\n|five six seven eight" },
        .{ "|x\ny", "2gqq", "|x y" },
        .{ "|one two three four five six seven eight", "gwwx", "|ne two three four\nfive six seven eight" },
        .{ "|one two three four five six seven eight", "gqqx", "one two three four\n|ive six seven eight" },
        .{ "|one\ttwo three four five six seven eight", "gqq", "one\ttwo three\nfour five six seven\n|eight" },
        .{ "a b\n|one two three four five six seven eight\nc d", "gqgqx", "a b\none two three four\n|ive six seven eight\nc d" },
        .{ "|a\nb\nc\nd", "gqj", "|a b\nc\nd" },
        .{ "x\n|one two three four five six seven eight nine ten eleven", "gwip", "x |one two three four\nfive six seven eight\nnine ten eleven" },
        .{ "|one two three four five six seven eight nine\nten", "vjgqx", "one two three four\nfive six seven eight\n|ine ten" },
        .{ "|one two three four five six seven eight nine\nten", "vjgw", "one two three four\nfive six seven eight\nnine |ten" },
        .{ "|one two three four five six seven eight", "gqqjgqq", "one two three four\n|five six seven eight" },
        .{ "|one two three four five six seven eight\nnine ten eleven twelve thirteen fourteen", "gqq.", "one two three four\n|five six seven eight\nnine ten eleven twelve thirteen fourteen" },
        .{ "|one   \ntwo", "gqj", "|one   two" },
        .{ "|one\n)two", "gqj", "|one)two" },
        .{ "|one two three four five six seven eight  ", "gqq", "one two three four\n|five six seven eight  " },
        .{ "|one two three four five six seven eighty", "gqq", "one two three four\nfive six seven\n|eighty" },
        .{ "|one two three four five six seven eight", "VVgq", "|one two three four five six seven eight" },
    });
}

test "=: braces, brackets, parens, case labels, if without braces, # and comments" {
    try runCases(&.{
        .{ "|int f() {\nreturn 1;\n}", "=G", "|int f() {\n    return 1;\n}" },
        .{ "|fn main() void {\n        const x = 1;\nif (x) {\nfoo();\n}\n  }", "=G", "|fn main() void {\n    const x = 1;\n    if (x) {\n        foo();\n    }\n}" },
        .{ "|if (a) {\nb();\n} else {\nc();\n}", "=G", "|if (a) {\n    b();\n} else {\n    c();\n}" },
        .{ "|switch (x) {\ncase 1:\nfoo();\nbreak;\ndefault:\nbar();\n}", "=G", "|switch (x) {\n    case 1:\n        foo();\n        break;\n    default:\n        bar();\n}" },
        .{ "|#include <a>\n  #define X\nint y;", "=G", "|#include <a>\n#define X\nint y;" },
        .{ "|/*\n* doc\n*/\nint x;", "=G", "|/*\n * doc\n */\nint x;" },
        .{ "|f(a,\nb,\nc);", "=G", "|f(a,\n        b,\n        c);" },
        .{ "|{\n    a;\n        b;\n}", "=ip", "|{\n    a;\n    b;\n}" },
        .{ "|{\n    a;\n        b;\n}", "jj==", "{\n    a;\n    |b;\n}" },
        .{ "|{\n    a;\n        b;\n}", "jjVj=", "{\n    a;\n    |b;\n}" },
        .{ "|a {\nb {\nc;\n}\n}", "=G", "|a {\n    b {\n        c;\n    }\n}" },
        .{ "|let s = \"{\";\nfoo();", "=G", "|let s = \"{\";\nfoo();" },
        .{ "|// {\nfoo();", "=G", "|// {\nfoo();" },
        .{ "|x = 1 +\n2;", "=G", "|x = 1 +\n2;" },
        .{ "|foo(bar(\nbaz));", "=G", "|foo(bar(\n            baz));" },
        .{ "|if (a &&\nb) {\nc;\n}", "=G", "|if (a &&\n        b) {\n    c;\n}" },
        .{ "|  a;\nb;", "=G", "|a;\nb;" },
        .{ "|{\na;\n}", "=Gu", "|{\na;\n}" },
        .{ "|{\na;\n}", "j==", "{\n    |a;\n}" },
        .{ "|{\na;\n}", "=G.", "|{\n    a;\n}" },
        .{ "|function f() {\nif (x)\nfoo();\nbar();\n}", "=G", "|function f() {\n    if (x)\n        foo();\n    bar();\n}" },
        .{ "|function f() {\nif (x) {\nfoo();\n} else\nbar();\nbaz();\n}", "=G", "|function f() {\n    if (x) {\n        foo();\n    } else\n        bar();\n    baz();\n}" },
        .{ "|const x = [\n1,\n];", "=G", "|const x = [\n    1,\n];" },
        .{ "|fn f() {\n    let c = '{';\nx();\n}", "=G", "|fn f() {\n    let c = '{';\n    x();\n}" },
        .{ "|a {\n\n   \nb;\n}", "=G", "|a {\n\n\n    b;\n}" },
        .{ "|{\na;\n}", "=2j", "|{\n    a;\n}" },
        .{ "|{\n  /* c\n  * d */\na;\n}", "=G", "|{\n    /* c\n     * d */\n    a;\n}" },
    });
}

// -- 29. review: tabs, sentence growth, ex ranges, regex, blocks (Neovim) --

test "columns: a Normal-mode cursor on a tab keeps the tab's last cell for j/k" {
    try runCases(&.{
        .{ "|\tabc\nabcdefghijkl", "jx", "\tabc\nabcdefg|ijkl" },
        .{ "x|\tabc\nabcdefghijkl", "hljx", "x\tabc\nabcdefg|ijkl" },
        .{ "|\tabc\nabcdefghijkl", "$0jx", "\tabc\nabcdefg|ijkl" },
        .{ "a\tb\nabcdefghijkl", "fbhjx", "a\tb\nabcdefg|ijkl" },
        .{ "|\tabc\nabcdefghijkl", "A<Esc>0jx", "\tabc\nabcdefg|ijkl" },
        .{ "|\t\tabc\nabcdefghijklmnopqrstuvwxyz", "lhjx", "\t\tabc\nabcdefg|ijklmnopqrstuvwxyz" },
        .{ "|\tabc\nabcdefghijkl", "vjd", "|ijkl" },
        .{ "|\tabc\nabcdefghijkl", "i<Esc>jx", "\tabc\nabcdefg|ijkl" },
    });
}

test "sentences: is/as on a Visual area grow it by sentences or the gaps" {
    try runCases(&.{
        .{ "|One two. Three four. Five.", "visisd", "|Three four. Five." },
        .{ "|One two. Three four. Five.", "vasasd", "|Five." },
        .{ "|One two. Three four. Five.", "vis2isd", "| Five." },
        .{ "|One two. Three four. Five.", "visasd", "| Five." },
        .{ "|One two. Three four. Five. Six.", "$visisd", "One two. Three four. Five.| " },
        .{ "|One two. Three four. Five. Six.", "))e3hvbisd", "One two. |ive. Six." },
        .{ "|One two. Three four. Five. Six.", "))evbbasd", "One two.|. Six." },
        .{ "|One two.\nThree four.\nFive.", "vasasd", "|\nFive." },
    });
}

test "ex: | inside :s, /pat/ and ?pat? addresses, :&&, a count after :s flags" {
    try runCases(&.{
        .{ "|a\\|b", ":s/a|b/X/<CR>", "|X" },
        // (The result has a literal '|': render() does not escape it.)
        .{ "|ab\nab", ":s/a/x|y/|2s/b/Z/<CR>", "x|yb\n|aZ" },
        .{ "|ax\nb\ncx\nd", ":g/b/,/x/d<CR>", "ax\n|d" },
        .{ "|ax\nb\ncx\nd", "G:?a?d<CR>", "|b\ncx\nd" },
        .{ "|ax\nb\ncx\nd", ":/b/;/x/d<CR>", "ax\n|d" },
        .{ "|ax\nb\ncx\nd", ":/b/+1d<CR>", "ax\nb\n|d" },
        .{ "|ax\nb\ncx\nd", "/c<CR>gg://d<CR>", "ax\nb\n|d" },
        .{ "|ax\nb\ncx\nd", ":m/c/<CR>", "b\ncx\n|ax\nd" },
        .{ "|a/b\nc", ":/\\//d<CR>", "|c" },
        .{ "|ab a\nab a", ":s/a/X/g<CR>j:&&<CR>", "Xb X\n|Xb X" },
        .{ "|ab a\nab a\nab a", ":s/a/X/g<CR>:%&&<CR>", "Xb X\nXb X\n|Xb X" },
        .{ "|a b\nc d\ne f", ":s/ /_/ 2<CR>", "a_b\n|c_d\ne f" },
        .{ "|a b\nc d\ne f", ":s/ /_/g2<CR>", "a_b\n|c_d\ne f" },
        .{ "|a.b.c", ":s/\\./-/2<CR>", "|a-b.c" },
        .{ "|a b\nc d\ne f", ":2s/ /_/ 2<CR>", "a b\nc_d\n|e_f" },
    });
}

test "regex: back references \\1..\\9, \\v \\m \\M \\V" {
    try runCases(&.{
        .{ "|aa\nb\nbb\nd", ":g/\\(.\\)\\1/d<CR>", "b\n|d" },
        .{ "|the the cat", ":s/\\<\\(\\w\\+\\) \\1\\>/\\1/<CR>", "|the cat" },
        .{ "|aXa bXc", ":s/\\(.\\)X\\1/-/g<CR>", "|- bXc" },
        .{ "|ab", ":s/\\(x\\)\\=b\\1/Z/<CR>", "|aZ" },
        .{ "|abc abc", ":s/\\v(a)(b)/\\2\\1/g<CR>", "|bac bac" },
        .{ "|foo\nbar", "/\\vb(a)r<CR>x", "foo\n|ar" },
        .{ "|a1 b22 c333", ":s/\\v\\d{2,}/#/g<CR>", "|a1 b# c#" },
        .{ "|colour color", ":s/\\vcolou?r/X/g<CR>", "|X X" },
        .{ "|f(x)", ":s/\\v\\(x\\)/[x]/<CR>", "|f[x]" },
        .{ "|f(x)", ":s/\\v%(f)\\(/G(/<CR>", "|G(x)" },
        .{ "|a.b", ":s/\\V./!/<CR>", "|a!b" },
        .{ "|axb", ":s/\\Va.b/!/<CR>", "|axb" },
        .{ "|a*b", ":s/\\Va*b/!/<CR>", "|!" },
        .{ "|a.b", ":s/\\M./!/<CR>", "|a!b" },
        .{ "|abc", ":s/\\M\\[b]/!/<CR>", "|a!c" },
        .{ "|ab cd", ":s/\\v(\\w+) (\\w+)/\\2 \\1/<CR>", "|cd ab" },
        .{ "|path", ":s/\\vpa\\mth/!/<CR>", "|!" },
        .{ "|foo bar", ":s/\\v<ba/X/<CR>", "|foo Xr" },
        .{ "|abar bar", ":s/\\vbar>/X/<CR>", "|aX bar" },
    });
}

test "@: repeats the last command line; :g ends on the first non-blank after :s" {
    try runCases(&.{
        .{ "|abc\nabc", ":s/b/X/<CR>j@:", "aXc\n|aXc" },
        .{ "|abc\nabc\nabc", ":s/b/X/<CR>j@:j@@", "aXc\naXc\n|aXc" },
        .{ "|abc\nabc\nabc\nabc", ":s/b/X/<CR>j2@:", "aXc\n|aXc\nabc\nabc" },
        .{ "|abc\nabc\nabc", ":d<CR>@:", "|abc" },
        .{ "|abc\nabc\nabc", ":d<CR>2@:", "|" },
        .{ "|abc\nabc\nabc", "@:", "|abc\nabc\nabc" },
        .{ "|abc\nabc\nabc", ":s/b/X/<CR>qajq@a@:", "aXc\nabc\n|aXc" },
        .{ "|abc\nabd\nabc", ":g/c/s/b/X/|norm Ax<CR>", "aXcx\nabd\n|aXcx" },
        .{ "|  abc\nabd\n  abc", ":g/c/s/b/X/|norm Ax<CR>", "  aXcx\nabd\n  |aXcx" },
        .{ "|abc\nabd\nabc", ":g/c/norm Ax<CR>", "abcx\nabd\nabc|x" },
        .{ "|abc\nabd\nabc", ":g/c/s/b/X/n<CR>", "abc\nabd\n|abc" },
    });
}

test "visual block: a count on I and A, the U line after block changes" {
    try runCases(&.{
        .{ "a|bcdef\nabcdef\nabcdef", "<C-v>jj3IX<Esc>", "a|XXXbcdef\naXXXbcdef\naXXXbcdef" },
        .{ "a|bcdef\nabcdef\nabcdef", "<C-v>jj2AX<Esc>", "a|bXXcdef\nabXXcdef\nabXXcdef" },
        .{ "a|bcdef\nabcdef\nabcdef\nabcdef\nabcdef\nabcdef", "<C-v>jj2AX<Esc>jjj.", "abXXcdef\nabXXcdef\nabXXcdef\na|bXXcdef\nabXXcdef\nabXXcdef" },
        .{ "a|bcdef\nabcdef\nabcdef", "<C-v>jjlcX<Esc>U", "a|def\naXdef\naXdef" },
        .{ "a|bcdef\nabcdef\nabcdef", "x<C-v>jjlcX<Esc>U", "a|bcdef\naXdef\naXdef" },
        .{ "a|bcdef\nabcdef\nabcdef", "<C-v>jlIX<Esc>U", "aXbcdef\n|abcdef\nabcdef" },
        .{ "a|bcdef\nabcdef\nabcdef", "<C-v>jlcX<Esc>U", "a|def\naXdef\nabcdef" },
        .{ "a|bcdef\nabcdef\nabcdef", "jx<C-v>jjldU", "abcdef\na|bcdef\nadef" },
        .{ "a|bcdef\nabcdef\nabcdef", "<C-v>ldU", "a|bcdef\nabcdef\nabcdef" },
        .{ "a|bcdef\nabcdef\nabcdef\nxyz\nxyz\nxyz", "<C-v>lyjjjpU", "abcdef\nabcdef\nabcdef\nxy|bcz\nxyz\nxyz" },
    });
}

// -- drills -----------------------------------------------------------------

test "drills: every solution solves its challenge within par" {
    // Each solution reaches isSolved() exactly on its last key (back in
    // NORMAL, nothing pending), and solutions[0] takes exactly par strokes.
    var failed: usize = 0;
    for (drill.all) |*ch| {
        for (ch.solutions, 0..) |sol, i| {
            var s = drill.DrillSession.init(alloc);
            defer s.deinit();
            try s.start(ch);
            var it = key_mod.Notation.init(sol);
            const n = key_mod.Notation.count(sol);
            var k: usize = 0;
            while (it.next()) |key| : (k += 1) {
                const r = s.feed(key);
                if (r.rejected) {
                    std.debug.print("{s}: solution {d} uses a forbidden key\n", .{ ch.id, i });
                    failed += 1;
                }
                if (k + 1 < n and s.isSolved()) {
                    std.debug.print("{s}: solution {d} is solved after {d} of {d} keys\n", .{ ch.id, i, k + 1, n });
                    failed += 1;
                    break;
                }
            }
            if (!s.isSolved()) {
                const got = try s.editor.buffer.toText(alloc);
                defer alloc.free(got);
                std.debug.print("{s}: solution {d} \"{s}\" gives \"{f}\" in {s}\n", .{ ch.id, i, sol, std.zig.fmtString(got), s.editor.mode.label() });
                failed += 1;
            } else if (i == 0 and s.strokes() != ch.par) {
                std.debug.print("{s}: {d} strokes != par {d}\n", .{ ch.id, s.strokes(), ch.par });
                failed += 1;
            } else if (s.strokes() > ch.par) {
                std.debug.print("{s}: solution {d} takes {d} strokes > par {d}\n", .{ ch.id, i, s.strokes(), ch.par });
                failed += 1;
            }
        }
    }
    try t.expectEqual(@as(usize, 0), failed);
}

test "drills: lesson shortcuts that skip the taught command do not solve" {
    // A drill a 3-key trick solves teaches nothing: gUG / VGU must not
    // solve the :norm drill (the values after '=' are words too).
    const shortcuts = [_]struct { []const u8, []const u8 }{
        .{ "global/norm-01", "gUG" },
        .{ "global/norm-01", "VGU" },
    };
    for (shortcuts) |sc| {
        const ch = for (drill.all) |*c| {
            if (std.mem.eql(u8, c.id, sc[0])) break c;
        } else return error.TestUnexpectedResult;
        var s = drill.DrillSession.init(alloc);
        defer s.deinit();
        try s.start(ch);
        var it = key_mod.Notation.init(sc[1]);
        while (it.next()) |key| _ = s.feed(key);
        try t.expect(!s.isSolved());
    }
}

test "drills: library size and lesson coverage" {
    var per: [std.meta.tags(drill.Lesson).len]usize = @splat(0);
    for (drill.all) |ch| per[@backingInt(ch.lesson)] += 1;
    for (per) |n| try t.expect(n >= 3);
    try t.expect(drill.all.len >= 67);
}

test "drills: forbidden keys, solved only back in NORMAL, hints" {
    const ch = drill.Challenge{
        .id = "test/forbid",
        .lesson = .basics,
        .title = "t",
        .prompt = "p",
        .start = "|ab",
        .goal = "Xab",
        .par = 3,
        .solutions = &.{"iX"},
        .forbid = .{ .hjkl = true, .arrows = true },
    };
    var s = drill.DrillSession.init(alloc);
    defer s.deinit();
    try s.start(&ch);
    try t.expect(s.feed(.{ .char = 'l' }).rejected);
    try t.expect(s.feed(.right).rejected);
    try t.expect(s.editor.statusMsg().len > 0);
    try t.expectEqual(@as(u32, 0), s.strokes());
    // `fl` is a char argument, not a motion: allowed.
    _ = s.feed(.{ .char = 'f' });
    try t.expect(!s.feed(.{ .char = 'l' }).rejected);
    _ = s.feed(.{ .char = 'i' });
    _ = s.feed(.{ .char = 'X' });
    // The buffer matches, but an open insert is not a finished solve.
    try t.expect(s.matchesGoal());
    try t.expect(!s.isSolved());
    _ = s.feed(.esc);
    try t.expect(s.isSolved());
    // A pending operator or an open command line is not finished either.
    _ = s.feed(.{ .char = 'd' });
    try t.expect(s.matchesGoal() and !s.isSolved());
    _ = s.feed(.esc);
    _ = s.feed(.{ .char = ':' });
    try t.expect(!s.isSolved());
    _ = s.feed(.esc);
    try t.expect(s.isSolved());
    try t.expect(s.lineMatches(0));
    try t.expect(!s.hinted());
    s.revealHint();
    try t.expect(s.hinted());
    try t.expect(s.hint() != null);
    try t.expect(drill.stars(1, 3, true) < 3);
}
