//! Cursor motions over a Buffer, ported from Vim's word/char/bracket
//! search (search.c, textobject.c). Positions may sit on the end of a line
//! (col == len, Vim's NUL); the editor clamps the cursor afterwards.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Pos = @import("buffer.zig").Pos;
const classify = @import("classify.zig");

/// Walks positions the way Vim's inc()/dec() do, including the NUL
/// position at the end of every line.
pub const Walker = struct {
    buf: *const Buffer,
    p: Pos,
    big: bool = false,

    pub fn char(self: *const Walker) u8 {
        return self.buf.charAt(self.p);
    }

    pub fn cls(self: *const Walker) u8 {
        return classify.cls(self.char(), self.big);
    }

    pub fn atEmptyLine(self: *const Walker) bool {
        return self.p.col == 0 and self.buf.lineLen(self.p.row) == 0;
    }

    /// 0: moved within the line, 2: moved onto the line end, 1: moved to the
    /// next line, -1: at the end of the buffer.
    pub fn inc(self: *Walker) i8 {
        const len = self.buf.lineLen(self.p.row);
        if (self.p.col < len) {
            self.p.col += 1;
            return if (self.p.col < len) 0 else 2;
        }
        if (self.p.row < self.buf.lastRow()) {
            self.p.row += 1;
            self.p.col = 0;
            return 1;
        }
        return -1;
    }

    /// 0: moved within the line, 1: moved to the end of the previous line,
    /// -1: at the start of the buffer.
    pub fn dec(self: *Walker) i8 {
        if (self.p.col > 0) {
            self.p.col = @min(self.p.col, self.buf.lineLen(self.p.row) + 1) - 1;
            return 0;
        }
        if (self.p.row > 0) {
            self.p.row -= 1;
            self.p.col = self.buf.lineLen(self.p.row);
            return 1;
        }
        return -1;
    }

    /// Vim's incl(): like inc() but skips over the line end.
    pub fn incl(self: *Walker) i8 {
        var r = self.inc();
        if (r >= 1 and self.p.col != 0) r = self.inc();
        return r;
    }

    /// Vim's decl(): like dec() but skips over the line end.
    pub fn decl(self: *Walker) i8 {
        var r = self.dec();
        if (r == 1 and self.p.col != 0) r = self.dec();
        return r;
    }

    /// Returns true when the buffer edge was hit.
    fn skipChars(self: *Walker, cclass: u8, forward: bool) bool {
        while (self.cls() == cclass) {
            if ((if (forward) self.inc() else self.dec()) == -1) return true;
        }
        return false;
    }
};

pub const Result = struct { pos: Pos, ok: bool };

/// `w`/`W`. With `eol` (an operator is pending) the last count stops at the
/// end of the line instead of crossing it.
pub fn fwdWord(buf: *const Buffer, from: Pos, count: usize, big: bool, eol: bool) Result {
    var w = Walker{ .buf = buf, .p = from, .big = big };
    var n = count;
    while (n > 0) {
        n -= 1;
        const sclass = w.cls();
        const last_line = w.p.row == buf.lastRow();
        var i = w.inc();
        if (i == -1 or (i >= 1 and last_line)) return .{ .pos = w.p, .ok = false };
        if (i >= 1 and eol and n == 0) return .{ .pos = w.p, .ok = true };
        if (sclass != classify.blank) {
            while (w.cls() == sclass) {
                i = w.inc();
                if (i == -1 or (i >= 1 and eol and n == 0)) return .{ .pos = w.p, .ok = true };
            }
        }
        while (w.cls() == classify.blank) {
            if (w.atEmptyLine()) break;
            i = w.inc();
            if (i == -1 or (i >= 1 and eol and n == 0)) return .{ .pos = w.p, .ok = true };
        }
    }
    return .{ .pos = w.p, .ok = true };
}

/// `b`/`B` (stop = false), also used by text objects.
pub fn bckWord(buf: *const Buffer, from: Pos, count: usize, big: bool, stop0: bool) Result {
    var w = Walker{ .buf = buf, .p = from, .big = big };
    var stop = stop0;
    var n = count;
    outer: while (n > 0) : (stop = false) {
        n -= 1;
        const sclass = w.cls();
        if (w.dec() == -1) return .{ .pos = w.p, .ok = false };
        if (!stop or sclass == w.cls() or sclass == classify.blank) {
            while (w.cls() == classify.blank) {
                if (w.atEmptyLine()) continue :outer;
                if (w.dec() == -1) return .{ .pos = w.p, .ok = true };
            }
            if (w.skipChars(w.cls(), false)) return .{ .pos = w.p, .ok = true };
        }
        _ = w.inc();
    }
    return .{ .pos = w.p, .ok = true };
}

/// `e`/`E`. `stop`: stay on the end of the current word; `empty`: stop at
/// an empty line.
pub fn endWord(buf: *const Buffer, from: Pos, count: usize, big: bool, stop0: bool, empty: bool) Result {
    var w = Walker{ .buf = buf, .p = from, .big = big };
    var stop = stop0;
    var n = count;
    outer: while (n > 0) : (stop = false) {
        n -= 1;
        const sclass = w.cls();
        if (w.inc() == -1) return .{ .pos = w.p, .ok = false };
        if (w.cls() == sclass and sclass != classify.blank) {
            if (w.skipChars(sclass, true)) return .{ .pos = w.p, .ok = false };
        } else if (!stop or sclass == classify.blank) {
            while (w.cls() == classify.blank) {
                if (w.atEmptyLine() and empty) continue :outer;
                if (w.inc() == -1) return .{ .pos = w.p, .ok = false };
            }
            if (w.skipChars(w.cls(), true)) return .{ .pos = w.p, .ok = false };
        }
        _ = w.dec();
    }
    return .{ .pos = w.p, .ok = true };
}

/// `ge`/`gE`.
pub fn bckendWord(buf: *const Buffer, from: Pos, count: usize, big: bool, eol: bool) Result {
    var w = Walker{ .buf = buf, .p = from, .big = big };
    var n = count;
    while (n > 0) {
        n -= 1;
        const sclass = w.cls();
        var i = w.dec();
        if (i == -1) return .{ .pos = w.p, .ok = false };
        if (eol and i == 1) return .{ .pos = w.p, .ok = true };
        if (sclass != classify.blank) {
            while (w.cls() == sclass) {
                i = w.dec();
                if (i == -1 or (eol and i == 1)) return .{ .pos = w.p, .ok = true };
            }
        }
        while (w.cls() == classify.blank) {
            if (w.atEmptyLine()) break;
            i = w.dec();
            if (i == -1 or (eol and i == 1)) return .{ .pos = w.p, .ok = true };
        }
    }
    return .{ .pos = w.p, .ok = true };
}

pub const FindKind = enum {
    f,
    F,
    t,
    T,

    pub fn forward(self: FindKind) bool {
        return self == .f or self == .t;
    }

    pub fn till(self: FindKind) bool {
        return self == .t or self == .T;
    }

    pub fn reversed(self: FindKind) FindKind {
        return switch (self) {
            .f => .F,
            .F => .f,
            .t => .T,
            .T => .t,
        };
    }
};

/// f/F/t/T on one line. `repeat` (from ; or ,) with count 1 makes t/T skip
/// a match right next to the cursor, as Vim does without cpo-;.
pub fn findChar(line: []const u8, col0: usize, c: u8, kind: FindKind, count: usize, repeat: bool) ?usize {
    const fwd = kind.forward();
    var col = col0;
    var stop = !(repeat and count == 1 and kind.till());
    var n = count;
    while (n > 0) : (n -= 1) {
        while (true) {
            if (fwd) {
                col += 1;
                if (col >= line.len) return null;
            } else {
                if (col == 0) return null;
                col = @min(col, line.len) - 1;
            }
            if (line[col] == c and stop) break;
            stop = true;
        }
    }
    if (kind.till()) {
        if (fwd) col -= 1 else col += 1;
    }
    return col;
}

fn pairOf(c: u8) ?struct { open: u8, close: u8, is_open: bool } {
    return switch (c) {
        '(' => .{ .open = '(', .close = ')', .is_open = true },
        ')' => .{ .open = '(', .close = ')', .is_open = false },
        '[' => .{ .open = '[', .close = ']', .is_open = true },
        ']' => .{ .open = '[', .close = ']', .is_open = false },
        '{' => .{ .open = '{', .close = '}', .is_open = true },
        '}' => .{ .open = '{', .close = '}', .is_open = false },
        else => null,
    };
}

/// Searches for an unmatched `target` bracket (excluding the char at
/// `from`), backwards when `target` is an opening bracket.
pub fn findUnmatched(buf: *const Buffer, from: Pos, open: u8, close: u8, target: u8) ?Pos {
    const backward = target == open;
    var w = Walker{ .buf = buf, .p = from };
    var depth: usize = 0;
    while (true) {
        if ((if (backward) w.dec() else w.inc()) == -1) return null;
        const c = w.char();
        if (w.p.col >= buf.lineLen(w.p.row)) continue;
        if (c == target) {
            if (depth == 0) return w.p;
            depth -= 1;
        } else if ((backward and c == close) or (!backward and c == open)) {
            depth += 1;
        }
    }
}

/// `%`: the first bracket at or after the cursor on the line, jumped to
/// its match.
pub fn matchPair(buf: *const Buffer, from: Pos) ?Pos {
    const line = buf.getLine(from.row);
    var col = from.col;
    while (col < line.len) : (col += 1) {
        if (pairOf(line[col])) |pr| {
            const at = Pos{ .row = from.row, .col = col };
            return findUnmatched(buf, at, pr.open, pr.close, if (pr.is_open) pr.close else pr.open);
        }
    }
    return null;
}

/// `}` / `{`: next/previous empty line. Returns the target and whether the
/// motion became inclusive (it ran to the end of the last line).
pub fn paragraph(buf: *const Buffer, from: Pos, count: usize, forward: bool) ?struct { pos: Pos, inclusive: bool } {
    var curr = from.row;
    var n = count;
    while (n > 0) {
        n -= 1;
        var did_skip = false;
        var first = true;
        while (true) : (first = false) {
            if (buf.lineLen(curr) != 0) did_skip = true;
            if (!first and did_skip and buf.lineLen(curr) == 0) break;
            if (forward) {
                if (curr >= buf.lastRow()) {
                    if (n > 0) return null;
                    break;
                }
                curr += 1;
            } else {
                if (curr == 0) {
                    if (n > 0) return null;
                    break;
                }
                curr -= 1;
            }
        }
    }
    if (curr == buf.lastRow() and forward and buf.lineLen(curr) != 0) {
        return .{ .pos = .{ .row = curr, .col = buf.lineLen(curr) - 1 }, .inclusive = true };
    }
    return .{ .pos = .{ .row = curr, .col = 0 }, .inclusive = false };
}

const testing = std.testing;

fn bufOf(text: []const u8) !Buffer {
    var b = Buffer.init(testing.allocator);
    try b.setText(text);
    return b;
}

test "w stops at punctuation runs" {
    var b = try bufOf("foo(bar) baz");
    defer b.deinit();
    var p = Pos{};
    const want = [_]usize{ 3, 4, 7, 9 };
    for (want) |c| {
        p = fwdWord(&b, p, 1, false, false).pos;
        try testing.expectEqual(c, p.col);
    }
    p = fwdWord(&b, .{}, 1, true, false).pos;
    try testing.expectEqual(@as(usize, 9), p.col);
}

test "b crosses lines to the start of the last word" {
    var b = try bufOf("one two\nthree");
    defer b.deinit();
    const r = bckWord(&b, .{ .row = 1, .col = 0 }, 1, false, false);
    try testing.expectEqual(Pos{ .row = 0, .col = 4 }, r.pos);
}

test "find char with ; after t" {
    const line = "a,b,c,d";
    try testing.expectEqual(@as(?usize, 0), findChar(line, 0, ',', .t, 1, false));
    try testing.expectEqual(@as(?usize, 2), findChar(line, 0, ',', .t, 1, true));
    try testing.expectEqual(@as(?usize, 3), findChar(line, 0, ',', .f, 2, false));
    try testing.expectEqual(@as(?usize, null), findChar(line, 0, 'z', .f, 1, false));
}
