//! Sentences, ported from Vim's findsent() and current_sent(). A sentence
//! ends at '.', '!' or '?' followed by any of `)]"'` and then a space, a
//! tab or the end of the line. An empty line (a paragraph boundary) is a
//! sentence of its own.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Pos = @import("buffer.zig").Pos;
const motion = @import("motion.zig");
const textobj = @import("textobj.zig");
const Walker = motion.Walker;

fn isWhite(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn in(set: []const u8, c: u8) bool {
    return c != 0 and std.mem.indexOfScalar(u8, set, c) != null;
}

/// Vim's startPS() for a paragraph: an empty line.
fn startPS(buf: *const Buffer, row: usize) bool {
    return buf.lineLen(row) == 0;
}

fn step(w: *Walker, forward: bool) i8 {
    return if (forward) w.incl() else w.decl();
}

/// `(` / `)`: the start of the `count`-th sentence back or forward. Null
/// when the buffer edge is hit with count left.
pub fn find(buf: *const Buffer, from: Pos, count0: usize, forward: bool) ?Pos {
    var w = Walker{ .buf = buf, .p = from };
    var count = @max(count0, 1);
    while (count > 0) {
        count -= 1;
        var noskip = false;
        found: {
            if (w.char() == 0) {
                // On an empty line: skip to a non-empty one.
                while (true) {
                    if (step(&w, forward) == -1) break;
                    if (w.char() != 0) break;
                }
                if (forward) break :found;
            } else if (forward and w.p.col == 0 and startPS(buf, w.p.row)) {
                if (w.p.row == buf.lastRow()) return null;
                w.p = .{ .row = w.p.row + 1 };
                break :found;
            } else if (!forward) _ = w.decl();

            // Back to the previous non-white, non-punctuation char.
            var found_dot = false;
            while (true) {
                const c = w.char();
                if (!(isWhite(c) or in(".!?)]\"'", c))) break;
                var t = w;
                if (t.decl() == -1 or (buf.lineLen(t.p.row) == 0 and forward)) break;
                if (found_dot) break;
                if (in(".!?", c)) found_dot = true;
                if (in(")]\"'", c) and !in(".!?)]\"'", t.char())) break;
                _ = w.decl();
            }

            // Find the end of the sentence.
            const start_row = w.p.row;
            while (true) {
                const c = w.char();
                if (c == 0 or (w.p.col == 0 and startPS(buf, w.p.row))) {
                    if (!forward and w.p.row != start_row) w.p = .{ .row = w.p.row + 1 };
                    break;
                }
                if (c == '.' or c == '!' or c == '?') {
                    var t = w;
                    var after: i16 = 0;
                    while (true) {
                        if (t.inc() == -1) {
                            after = -1;
                            break;
                        }
                        after = t.char();
                        if (!in(")]\"'", t.char())) break;
                    }
                    if (after == -1 or after == ' ' or after == '\t' or after == 0) {
                        w = t;
                        if (w.char() == 0) _ = w.inc();
                        break;
                    }
                }
                if (step(&w, forward) == -1) {
                    if (count > 0) return null;
                    noskip = true;
                    break;
                }
            }
        }
        // Skip white space.
        while (!noskip and isWhite(w.char())) {
            if (w.incl() == -1) break;
        }
    }
    return w.p;
}

/// Back to the first of the blanks before `p`.
fn firstBlank(w: *Walker) void {
    while (w.decl() != -1) {
        if (!isWhite(w.char())) {
            _ = w.incl();
            break;
        }
    }
}

fn forwardN(buf: *const Buffer, cur: *Walker, count0: usize, at_start0: bool) void {
    var count = count0;
    var at_start = at_start0;
    while (count > 0) {
        count -= 1;
        cur.p = find(buf, cur.p, 1, true) orelse cur.p;
        if (at_start) firstBlank(cur);
        if (count == 0 or at_start) _ = cur.decl();
        at_start = !at_start;
    }
}

/// `is` / `as` on a Visual area of more than one char: grow it by
/// `count` sentences (or the white space between them) from the cursor's
/// end (Vim's current_sent `extend:`). Returns the new cursor.
pub fn extend(buf: *const Buffer, anchor: Pos, cur: Pos, count0: usize, include: bool) Pos {
    const n = @max(count0, 1) * @as(usize, if (include) 2 else 1);
    const next = find(buf, cur, 1, true) orelse cur;
    var w = Walker{ .buf = buf, .p = next };
    var pos = Walker{ .buf = buf, .p = cur };
    var at_start: bool = undefined;
    if (cur.lessThan(anchor)) {
        // Cursor at the start of the area: in the white space before a
        // sentence, in a sentence or just after one, or at a start.
        at_start = true;
        while (pos.p.lessThan(w.p)) {
            if (!isWhite(pos.char())) {
                at_start = false;
                break;
            }
            _ = pos.incl();
        }
        if (!at_start) {
            w.p = find(buf, w.p, 1, false) orelse w.p;
            if (w.p.equals(cur)) {
                at_start = true;
            } else w.p = find(buf, w.p, 1, true) orelse w.p;
        }
        var k = n;
        while (k > 0) : (k -= 1) {
            if (at_start) firstBlank(&w);
            if (!at_start or (!include and !isWhite(w.char()))) w.p = find(buf, w.p, 1, false) orelse w.p;
            at_start = !at_start;
        }
        return w.p;
    }
    // Cursor at the end: just before a sentence, in or before the white
    // space before one, or in a sentence.
    _ = pos.incl();
    at_start = true;
    if (!pos.p.equals(w.p)) {
        at_start = false;
        while (pos.p.lessThan(w.p)) {
            if (!isWhite(pos.char())) {
                at_start = true;
                break;
            }
            _ = pos.incl();
        }
        if (at_start) {
            w.p = find(buf, w.p, 1, false) orelse w.p;
        } else w.p = cur;
    }
    forwardN(buf, &w, n, at_start);
    return w.p;
}

pub const SentObj = struct {
    obj: textobj.Obj,
    /// Last char of the sentence (the Visual-mode cursor).
    last: Pos,
};

/// `is` / `as` (Vim's current_sent, without extending a selection).
pub fn object(buf: *const Buffer, cur: Pos, count0: usize, include: bool) SentObj {
    const count = @max(count0, 1);
    var start = Walker{ .buf = buf, .p = cur };
    var pos = start;
    var c = Walker{ .buf = buf, .p = find(buf, cur, 1, true) orelse cur };
    // Started on a blank just before the next sentence?
    while (isWhite(pos.char())) _ = pos.incl();
    var start_blank = false;
    if (pos.p.equals(c.p)) {
        start_blank = true;
        firstBlank(&start);
    } else {
        c.p = find(buf, c.p, 1, false) orelse c.p;
        start.p = c.p;
    }
    const ncount: usize = if (include) count * 2 else count - @intFromBool(start_blank);
    if (ncount > 0) forwardN(buf, &c, ncount, true) else _ = c.decl();
    if (include) {
        // Blanks in front are taken: leave the trailing ones out; else
        // take the leading blanks when there are no trailing ones.
        if (start_blank) {
            firstBlank(&c);
            if (isWhite(c.char())) _ = c.decl();
        } else if (!isWhite(c.char())) firstBlank(&start);
    }
    const last = c.p;
    // Include the line break after the sentence, if there is one.
    const inclusive = c.incl() == -1;
    return .{
        .obj = .{ .start = start.p, .end = if (inclusive) last else c.p, .kind = if (inclusive) .inclusive else .exclusive },
        .last = last,
    };
}
