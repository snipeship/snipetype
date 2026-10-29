//! Text objects (iw aw iW aW, quotes, brackets, ip ap), ported from Vim's
//! textobject.c. Each returns a range in motion terms; the editor applies
//! the same exclusive/inclusive/linewise rules as for motions.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Pos = @import("buffer.zig").Pos;
const classify = @import("classify.zig");
const motion = @import("motion.zig");
const Walker = motion.Walker;

pub const Kind = enum { exclusive, inclusive, linewise };

pub const Obj = struct { start: Pos, end: Pos, kind: Kind };

fn backInLine(w: *Walker) void {
    const sclass = w.cls();
    while (w.p.col > 0) {
        _ = w.dec();
        if (w.cls() != sclass) {
            _ = w.inc();
            break;
        }
    }
}

fn oneLeft(w: *Walker) bool {
    if (w.p.col == 0) return false;
    w.p.col -= 1;
    return true;
}

/// iw/aw/iW/aW. `extend`: grow an existing visual selection whose end is
/// `cur` instead of selecting from scratch.
pub fn word(buf: *const Buffer, cur: Pos, count0: usize, include: bool, big: bool, extend: bool) ?Obj {
    var w = Walker{ .buf = buf, .p = cur, .big = big };
    var start = cur;
    var inclusive = true;
    var include_white = false;
    var count = @max(count0, 1);
    if (!extend) {
        backInLine(&w);
        start = w.p;
        if ((w.cls() == classify.blank) == include) {
            const r = motion.endWord(buf, w.p, 1, big, true, true);
            if (!r.ok) return null;
            w.p = r.pos;
        } else {
            w.p = motion.fwdWord(buf, w.p, 1, big, true).pos;
            if (w.p.col == 0) _ = w.decl() else _ = oneLeft(&w);
            if (include) include_white = true;
        }
        count -= 1;
    }
    while (count > 0) : (count -= 1) {
        inclusive = true;
        if (w.incl() == -1) return null;
        if (include != (w.cls() == classify.blank)) {
            const r = motion.fwdWord(buf, w.p, 1, big, true);
            w.p = r.pos;
            if (!r.ok and count > 1) return null;
            if (!oneLeft(&w)) inclusive = false;
        } else {
            const r = motion.endWord(buf, w.p, 1, big, true, true);
            if (!r.ok) return null;
            w.p = r.pos;
        }
    }
    if (include_white and (w.cls() != classify.blank or (w.p.col == 0 and !inclusive))) {
        // No trailing white space: take the white space before the word
        // instead (but not an indent).
        var s = Walker{ .buf = buf, .p = start, .big = big };
        if (oneLeft(&s)) {
            backInLine(&s);
            if (s.cls() == classify.blank and s.p.col > 0) start = s.p;
        }
    }
    return .{ .start = start, .end = w.p, .kind = if (inclusive) .inclusive else .exclusive };
}

fn findNextQuote(line: []const u8, col0: usize, q: u8, escape: bool) ?usize {
    var col = col0;
    while (col < line.len) : (col += 1) {
        const c = line[col];
        if (escape and c == '\\') {
            col += 1;
            if (col >= line.len) return null;
        } else if (c == q) return col;
    }
    return null;
}

fn findPrevQuote(line: []const u8, col0: usize, q: u8) usize {
    var col = col0;
    while (col > 0) {
        col -= 1;
        var n: usize = 0;
        while (col > n and line[col - n - 1] == '\\') n += 1;
        if (n & 1 == 1) {
            col -= n;
        } else if (line[col] == q) break;
    }
    return col;
}

/// i" a" i' a' i` a` (line-local, Vim's quote pairing and white-space rule).
pub fn quote(buf: *const Buffer, cur: Pos, count: usize, include: bool, q: u8) ?Obj {
    const line = buf.getLine(cur.row);
    if (line.len == 0) return null;
    const first_col = @min(cur.col, line.len - 1);
    var cs: usize = undefined;
    var ce: usize = undefined;
    if (line[first_col] == q) {
        // On a quote: pair quotes from the line start to know which it is.
        cs = 0;
        while (true) {
            cs = findNextQuote(line, cs, q, false) orelse return null;
            if (cs > first_col) return null;
            ce = findNextQuote(line, cs + 1, q, true) orelse return null;
            if (cs <= first_col and first_col <= ce) break;
            cs = ce + 1;
        }
    } else {
        cs = findPrevQuote(line, first_col, q);
        if (line[cs] != q) cs = findNextQuote(line, first_col, q, false) orelse return null;
        ce = findNextQuote(line, cs + 1, q, true) orelse return null;
    }
    const row = cur.row;
    if (include) {
        if (ce + 1 < line.len and classify.isBlank(line[ce + 1])) {
            while (ce + 1 < line.len and classify.isBlank(line[ce + 1])) ce += 1;
        } else {
            while (cs > 0 and classify.isBlank(line[cs - 1])) cs -= 1;
        }
        return .{ .start = .{ .row = row, .col = cs }, .end = .{ .row = row, .col = ce + 1 }, .kind = .exclusive };
    }
    if (count >= 2) return .{ .start = .{ .row = row, .col = cs }, .end = .{ .row = row, .col = ce + 1 }, .kind = .exclusive };
    return .{ .start = .{ .row = row, .col = cs + 1 }, .end = .{ .row = row, .col = ce }, .kind = .exclusive };
}

/// Cursor char and everything before it on the line is white space.
fn inIndent1(buf: *const Buffer, p: Pos) bool {
    return buf.firstNonBlank(p.row) >= p.col + 1;
}

/// A double quote that counts (Vim's findmatchlimit): not escaped by an
/// odd number of backslashes, not the `'"'` character literal.
fn isQuote(line: []const u8, col: usize) bool {
    if (line[col] != '"') return false;
    var n: usize = 0;
    while (n < col and line[col - 1 - n] == '\\') n += 1;
    if (n % 2 == 1) return false;
    return !(col > 0 and col + 1 < line.len and line[col - 1] == '\'' and line[col + 1] == '\'');
}

fn quotesBefore(line: []const u8, col: usize) usize {
    var n: usize = 0;
    for (0..@min(col, line.len)) |i| n += @intFromBool(isQuote(line, i));
    return n;
}

/// The bracket closing the one at `at` (Vim's findmatch with 'cpoptions'
/// without `%`): on a line with an even number of double quotes, quoted
/// strings are skipped, and a bracket inside one only matches inside the
/// same string.
fn findClose(buf: *const Buffer, at: Pos, open: u8, close: u8) ?Pos {
    const first = buf.getLine(at.row);
    const in_str = quotesBefore(first, first.len) % 2 == 0 and quotesBefore(first, at.col) % 2 == 1;
    var depth: usize = 0;
    var row = at.row;
    var col = at.col + 1;
    while (row <= buf.lastRow()) : ({
        row += 1;
        col = 0;
    }) {
        const line = buf.getLine(row);
        const quotes = quotesBefore(line, line.len) % 2 == 0;
        var in_q = row == at.row and in_str;
        while (col < line.len) : (col += 1) {
            const c = line[col];
            if (quotes and isQuote(line, col)) {
                if (in_str) return null;
                in_q = !in_q;
            } else if (in_str or !in_q) {
                if (c == open) {
                    depth += 1;
                } else if (c == close) {
                    if (depth == 0) return .{ .row = row, .col = col };
                    depth -= 1;
                }
            }
        }
        if (in_str) return null;
    }
    return null;
}

/// The next unmatched `open` after `from`, any line (Vim's findmatchlimit
/// FM_FORWARD): a `close` on the way must be balanced by an `open` first.
fn findOpenForward(buf: *const Buffer, from: Pos, open: u8, close: u8) ?Pos {
    var w = Walker{ .buf = buf, .p = from };
    var depth: usize = 0;
    while (w.inc() != -1) {
        if (w.p.col >= buf.lineLen(w.p.row)) continue;
        const c = w.char();
        if (c == close) {
            depth += 1;
        } else if (c == open) {
            if (depth == 0) return w.p;
            depth -= 1;
        }
    }
    return null;
}

/// i( a( ib ab i[ a[ i{ a{ iB aB i< a< (nested, multi-line). When the
/// cursor is not inside a block, the count-th next one is used.
pub fn block(buf: *const Buffer, cur: Pos, count0: usize, include: bool, open: u8, close: u8) ?Obj {
    return blockSel(buf, cur, count0, include, open, close, null);
}

/// block() from a Visual selection `sel` (low, high end): the search starts
/// at its low end, and an inner block no bigger than the selection grows
/// to the enclosing one (Vim's current_block).
pub fn blockSel(buf: *const Buffer, cur: Pos, count0: usize, include: bool, open: u8, close: u8, sel: ?[2]Pos) ?Obj {
    var w = Walker{ .buf = buf, .p = cur };
    var old_start = cur;
    var old_end = cur;
    if (sel) |s| {
        w.p = s[0];
        old_start = s[0];
        old_end = s[1];
    } else {
        if (open == '{') {
            while (inIndent1(buf, w.p)) {
                if (w.inc() != 0) break;
            }
        }
        if (buf.charAt(w.p) == open) w.p.col += 1;
    }
    var start: ?Pos = null;
    var from = w.p;
    var count = @max(count0, 1);
    // The opening bracket is searched for without regard to quotes.
    if (motion.findUnmatched(buf, from, open, close, open) != null) {
        while (count > 0) : (count -= 1) {
            const p = motion.findUnmatched(buf, from, open, close, open) orelse return null;
            start = p;
            from = p;
        }
    } else {
        while (count > 0) : (count -= 1) {
            const p = findOpenForward(buf, from, open, close) orelse return null;
            start = p;
            from = p;
        }
    }
    var s0 = start.?;
    var end = findClose(buf, s0, open, close) orelse return null;
    if (include) return .{ .start = s0, .end = end, .kind = .inclusive };

    while (true) {
        var s = Walker{ .buf = buf, .p = s0 };
        _ = s.incl();
        var e = Walker{ .buf = buf, .p = end };
        var sol = e.p.col == 0;
        _ = e.decl();
        while (inIndent1(buf, e.p)) {
            sol = true;
            if (e.decl() != 0) break;
        }
        if (sel != null and !s.p.lessThan(old_start) and !old_end.lessThan(e.p) and !s.p.equals(e.p)) {
            var o = Walker{ .buf = buf, .p = old_start };
            _ = o.decl();
            s0 = motion.findUnmatched(buf, o.p, open, close, open) orelse return null;
            end = findClose(buf, s0, open, close) orelse return null;
            continue;
        }
        if (sol) {
            _ = e.incl();
            return .{ .start = s.p, .end = e.p, .kind = .exclusive };
        }
        if (!e.p.lessThan(s.p)) return .{ .start = s.p, .end = e.p, .kind = .inclusive };
        return .{ .start = s.p, .end = s.p, .kind = .exclusive };
    }
}

fn lineWhite(buf: *const Buffer, row: usize) bool {
    return buf.isBlankLine(row);
}

/// ip / ap (linewise).
pub fn paragraph(buf: *const Buffer, cur: Pos, count: usize, include: bool) ?Obj {
    const last = buf.lastRow();
    var start = cur.row;
    const white_in_front = lineWhite(buf, start);
    while (start > 0) {
        if (white_in_front) {
            if (!lineWhite(buf, start - 1)) break;
        } else if (lineWhite(buf, start - 1)) break;
        start -= 1;
    }
    // end is one less than the first row of the next run (may be start - 1).
    var end: isize = @intCast(start);
    while (end <= last and lineWhite(buf, @intCast(end))) end += 1;
    end -= 1;
    var i = @max(count, 1);
    if (!include and white_in_front) i -= 1;
    while (i > 0) {
        i -= 1;
        if (end == last) return null;
        const e1: usize = @intCast(end + 1);
        const do_white = if (!include) lineWhite(buf, e1) else false;
        if (include or !do_white) {
            end += 1;
            while (end < last and !lineWhite(buf, @intCast(end + 1))) end += 1;
        }
        if (i == 0 and white_in_front and include) break;
        if (include or do_white) {
            while (end < last and lineWhite(buf, @intCast(end + 1))) end += 1;
        }
    }
    const end_row: usize = @intCast(@max(end, @as(isize, @intCast(start))));
    if (!white_in_front and !lineWhite(buf, end_row) and include) {
        while (start > 0 and lineWhite(buf, start - 1)) start -= 1;
    }
    return .{ .start = .{ .row = start }, .end = .{ .row = end_row }, .kind = .linewise };
}

/// Visual `ip`/`ap` on a selection that already spans lines (or `Vip` on
/// a one-line paragraph): moves the cursor row `count` paragraph runs
/// further, away from the anchor (Vim's current_par "extend"). `ok` is
/// false when the buffer edge was hit first.
pub fn paragraphExtend(buf: *const Buffer, cur: usize, anchor: usize, count: usize, include: bool) struct { row: usize, ok: bool } {
    const back = cur < anchor;
    const edge: usize = if (back) 0 else buf.lastRow();
    var row = cur;
    var i = @max(count, 1);
    while (i > 0) : (i -= 1) {
        if (row == edge) return .{ .row = row, .ok = false };
        var prev_white: ?bool = null;
        var t: usize = 0;
        while (t < 2) : (t += 1) {
            row = if (back) row - 1 else row + 1;
            const white = lineWhite(buf, row);
            if (prev_white != null and prev_white.? == white) {
                row = if (back) row + 1 else row - 1;
                break;
            }
            while (row != edge) {
                const nxt = if (back) row - 1 else row + 1;
                if (white != lineWhite(buf, nxt)) break;
                row = nxt;
            }
            if (!include or row == edge) break;
            prev_white = white;
        }
    }
    return .{ .row = row, .ok = true };
}

const testing = std.testing;

test "quote pairing from the line start" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.setText("x = \"ab\" + \"cd\"");
    const o = quote(&b, .{ .col = 11 }, 1, false, '"').?;
    try testing.expectEqual(@as(usize, 12), o.start.col);
    try testing.expectEqual(@as(usize, 14), o.end.col);
}
