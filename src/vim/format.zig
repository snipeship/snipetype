//! `gq` / `gw` (format lines to 'textwidth') and `=` (reindent).
//!
//! Formatting works per paragraph (lines separated by blank lines): the
//! lines are joined as `J` does, then broken at the last blank that keeps a
//! line within 'textwidth'; a word longer than that gets a line of its
//! own. Continuation lines take the indent of the paragraph's first line
//! (as 'autoindent' does). Comment leaders are not continued.
//!
//! `=` is a "cindent-lite": a line is indented one 'shiftwidth' per
//! unclosed `{` or `[` above it, a `}` or `]` that starts a line goes back
//! to its opener's line, lines inside unclosed `(` get two 'shiftwidth's
//! (plus one per extra unclosed paren), statements under `case`/`default`
//! labels one more, and the single statement after a brace-less
//! `if (...)`, `for (...)`, `while (...)` or `else` one more. `#` lines go
//! to column 0 and ` *` lines inside a `/* */` comment line up under its
//! first `*`. Strings and comments are skipped when counting brackets.

const std = @import("std");
const editor_mod = @import("editor.zig");
const VimEditor = editor_mod.VimEditor;
const vcol = @import("vcol.zig");

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t");
}

fn isBlankLine(s: []const u8) bool {
    return trimLeft(s).len == 0;
}

/// Breaks one long line into lines of at most `tw` display columns.
fn breakLine(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, tw: usize, ts: u8) !void {
    const ind_len = text.len - trimLeft(text).len;
    const indent = text[0..ind_len];
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(alloc);
    try cur.appendSlice(alloc, text);
    while (true) {
        const line = cur.items;
        // Trailing blanks do not count.
        if (vcol.width(std.mem.trimEnd(u8, line, " \t"), ts) <= tw) break;
        // The last blank run that keeps the text before it within tw, else
        // the first one (a long word stays whole).
        var fit: ?[2]usize = null;
        var first: ?[2]usize = null;
        var i = ind_len;
        while (i < line.len) {
            if (!isBlank(line[i])) {
                i += 1;
                continue;
            }
            var e = i;
            while (e < line.len and isBlank(line[e])) e += 1;
            if (e == line.len) break; // trailing blanks: nothing after them
            if (i > ind_len) {
                if (first == null) first = .{ i, e };
                if (vcol.displayCol(line, i, ts) <= tw) fit = .{ i, e };
            }
            i = e;
        }
        const run = fit orelse first orelse break;
        try out.appendSlice(alloc, line[0..run[0]]);
        try out.append(alloc, '\n');
        const rest = try alloc.dupe(u8, line[run[1]..]);
        defer alloc.free(rest);
        cur.clearRetainingCapacity();
        try cur.appendSlice(alloc, indent);
        try cur.appendSlice(alloc, rest);
    }
    try out.appendSlice(alloc, cur.items);
}

/// gq / gw on rows first..last. Returns the row the last line of the range
/// ends up on.
pub fn format(ed: *VimEditor, first: usize, last0: usize) !usize {
    const buf = &ed.buffer;
    const alloc = ed.allocator;
    const tw: usize = if (ed.opts.textwidth == 0) 79 else ed.opts.textwidth;
    const ts = ed.opts.tabstop;
    var last = @min(last0, buf.lastRow());
    var row = first;
    while (row <= last) {
        if (isBlankLine(buf.getLine(row))) {
            row += 1;
            continue;
        }
        var p = row;
        while (p + 1 <= last and !isBlankLine(buf.getLine(p + 1))) p += 1;
        // Join the paragraph as J does.
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(alloc);
        try joined.appendSlice(alloc, buf.getLine(row));
        for (row + 1..p + 1) |r| {
            const l = trimLeft(buf.getLine(r));
            if (l.len == 0) continue;
            const items = joined.items;
            if (items.len > 0 and items[items.len - 1] != ' ' and l[0] != ')') try joined.append(alloc, ' ');
            try joined.appendSlice(alloc, l);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try breakLine(alloc, &out, joined.items, tw, ts);
        const old = try buf.copyLines(alloc, row, p);
        defer alloc.free(old);
        const n_new = std.mem.count(u8, out.items, "\n") + 1;
        if (!std.mem.eql(u8, old, out.items)) {
            // Insert first, so the buffer never runs empty.
            try buf.insertLines(row, out.items);
            try buf.deleteLines(row + n_new, p + n_new);
        }
        const n_old = p - row + 1;
        last = last + n_new - n_old;
        row += n_new;
    }
    return last;
}

// -- reindent ---------------------------------------------------------------

const Opener = struct {
    ch: u8,
    /// Indent (display columns) of the line holding the opener.
    indent: usize,
    /// A `case`/`default` label was seen in this `{` block.
    in_case: bool = false,
};

const Scan = struct {
    stack: [64]Opener = undefined,
    n: usize = 0,
    in_comment: bool = false,
    /// Display column of the `/*` that opened the comment.
    comment_col: usize = 0,
    /// The previous code line wants the next one indented once more
    /// (brace-less if/for/while/else).
    dangling: bool = false,

    fn top(s: *Scan) ?*Opener {
        return if (s.n > 0) &s.stack[s.n - 1] else null;
    }

    fn push(s: *Scan, o: Opener) void {
        if (s.n < s.stack.len) {
            s.stack[s.n] = o;
            s.n += 1;
        }
    }

    /// Pops up to the innermost opener of `close`.
    fn pop(s: *Scan, open: u8) void {
        var i = s.n;
        while (i > 0) {
            i -= 1;
            if (s.stack[i].ch == open) {
                s.n = i;
                return;
            }
        }
    }

    /// Updates the state with one (already indented) line.
    fn line(s: *Scan, text: []const u8, ts: u8) void {
        var ind = vcol.displayCol(text, text.len - trimLeft(text).len, ts);
        // A line continuing unclosed parens belongs to the statement that
        // opened them: brackets opened here are indented from its line.
        var k = s.n;
        while (k > 0 and s.stack[k - 1].ch == '(') : (k -= 1) ind = s.stack[k - 1].indent;
        const t = trimLeft(text);
        if (!s.in_comment and t.len > 0 and t[0] == '#') return;
        if (!s.in_comment and isLabel(t)) {
            if (s.top()) |o| o.in_case = true;
        }
        var code_end: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (s.in_comment) {
                if (c == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    s.in_comment = false;
                    i += 1;
                }
                continue;
            }
            switch (c) {
                '/' => if (i + 1 < text.len and text[i + 1] == '/') break else if (i + 1 < text.len and text[i + 1] == '*') {
                    s.in_comment = true;
                    s.comment_col = vcol.displayCol(text, i, ts);
                    i += 1;
                    continue;
                },
                '"', '`' => {
                    i += 1;
                    while (i < text.len and text[i] != c) : (i += 1) {
                        if (text[i] == '\\') i += 1;
                    }
                },
                '\'' => {
                    // A char literal: 'x' or '\x'; a lone quote is text.
                    if (i + 2 < text.len and text[i + 1] != '\\' and text[i + 2] == '\'') {
                        i += 2;
                    } else if (i + 3 < text.len and text[i + 1] == '\\' and text[i + 3] == '\'') i += 3;
                },
                '{', '[', '(' => s.push(.{ .ch = c, .indent = ind }),
                '}' => s.pop('{'),
                ']' => s.pop('['),
                ')' => s.pop('('),
                else => {},
            }
            if (!isBlank(c)) code_end = i + 1;
        }
        const code = std.mem.trimEnd(u8, text[0..code_end], " \t");
        const ct = trimLeft(code);
        if (ct.len == 0) return;
        s.dangling = (s.top() == null or s.top().?.ch != '(') and dangles(ct);
    }
};

fn isLabel(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "case ") or std.mem.startsWith(u8, t, "case\t")) return true;
    if (!std.mem.startsWith(u8, t, "default")) return false;
    return trimLeft(t["default".len..]).len > 0 and trimLeft(t["default".len..])[0] == ':';
}

/// A brace-less `if (...)`, `for (...)`, `while (...)` or `else`.
fn dangles(t: []const u8) bool {
    var s = t;
    if (std.mem.startsWith(u8, s, "}")) s = trimLeft(s[1..]);
    if (std.mem.eql(u8, s, "else") or std.mem.eql(u8, s, "do")) return true;
    if (s.len == 0 or s[s.len - 1] != ')') return false;
    if (std.mem.startsWith(u8, s, "else ")) s = trimLeft(s[5..]);
    for ([_][]const u8{ "if", "for", "while" }) |kw| {
        if (std.mem.startsWith(u8, s, kw) and s.len > kw.len and (s[kw.len] == ' ' or s[kw.len] == '(')) return true;
    }
    return false;
}

/// The indent (display columns) for `text` given the state above it.
fn amount(s: *Scan, text: []const u8, sw: usize) usize {
    const t = trimLeft(text);
    if (s.in_comment) return if (t.len > 0 and t[0] == '*') s.comment_col + 1 else s.comment_col + 3;
    if (t.len > 0 and t[0] == '#') return 0;
    const o = s.top() orelse return if (s.dangling and !startsWith(t, '{')) sw else 0;
    switch (o.ch) {
        '(' => {
            if (startsWith(t, ')')) return o.indent;
            // Unclosed parens of this statement: 2 sw, plus one per extra.
            var n: usize = 0;
            var i = s.n;
            var base = o.indent;
            while (i > 0 and s.stack[i - 1].ch == '(') : (i -= 1) {
                n += 1;
                base = s.stack[i - 1].indent;
            }
            return base + 2 * sw + (n - 1) * sw;
        },
        else => {
            const close: u8 = if (o.ch == '{') '}' else ']';
            if (startsWith(t, close)) return o.indent;
            var a = o.indent + sw;
            if (o.ch == '{' and o.in_case and !isLabel(t)) a += sw;
            if (s.dangling and !startsWith(t, '{')) a += sw;
            return a;
        },
    }
}

fn startsWith(t: []const u8, c: u8) bool {
    return t.len > 0 and t[0] == c;
}

/// `=` on rows first..last.
pub fn reindent(ed: *VimEditor, first: usize, last0: usize) !void {
    const buf = &ed.buffer;
    const ts = ed.opts.tabstop;
    const sw: usize = ed.opts.shiftwidth;
    const last = @min(last0, buf.lastRow());
    var s = Scan{};
    for (0..first) |r| s.line(buf.getLine(r), ts);
    var tmp: [256]u8 = undefined;
    for (first..last + 1) |r| {
        const text = buf.getLine(r);
        const t = trimLeft(text);
        if (t.len == 0) {
            if (!s.in_comment) try buf.setLine(r, "");
            continue;
        }
        const ind = ed.makeIndent(&tmp, amount(&s, text, sw));
        if (text.len - t.len != ind.len or !std.mem.eql(u8, text[0 .. text.len - t.len], ind)) {
            const new = try std.mem.concat(ed.allocator, u8, &.{ ind, t });
            defer ed.allocator.free(new);
            try buf.setLine(r, new);
        }
        s.line(buf.getLine(r), ts);
    }
}

/// Formatting only changes blanks: a position is kept as the number of
/// non-blank chars before it (gw puts the cursor back on the same text).
pub fn textIndex(buf: *const @import("buffer.zig").Buffer, p: @import("buffer.zig").Pos) usize {
    var n: usize = 0;
    for (0..p.row + 1) |r| {
        const l = buf.getLine(r);
        const end = if (r == p.row) @min(p.col, l.len) else l.len;
        for (l[0..end]) |c| n += @intFromBool(!isBlank(c));
    }
    return n;
}

/// The position of the char after `n` non-blank chars (inverse of textIndex).
pub fn textPos(buf: *const @import("buffer.zig").Buffer, n0: usize) @import("buffer.zig").Pos {
    var n = n0;
    for (0..buf.lineCount()) |r| {
        const l = buf.getLine(r);
        for (l, 0..) |c, col| {
            if (isBlank(c)) continue;
            if (n == 0) return .{ .row = r, .col = col };
            n -= 1;
        }
    }
    return .{ .row = buf.lastRow(), .col = buf.lineLen(buf.lastRow()) };
}
