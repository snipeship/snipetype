//! Tag blocks `it` / `at`, ported from Vim's current_tagblock(). The
//! buffer is searched as one string (lines joined by '\n'; a '\n' offset
//! is the end-of-line position):
//!
//! - an opening tag is `<name` then `>`, attributes ending in a `>` not
//!   preceded by `/` (so `<br/>` is not one), or the end of the line;
//! - a closing tag is `</...>`;
//! - going back from the cursor, closing tags nest with any opening tag;
//!   going forward, only tags with the same name count (ignoring case).

const std = @import("std");
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;
const Pos = buffer_mod.Pos;
const textobj = @import("textobj.zig");

const Text = struct {
    s: []const u8,
    starts: []usize,

    fn pos(t: Text, o: usize) Pos {
        var row: usize = 0;
        while (row + 1 < t.starts.len and t.starts[row + 1] <= o) row += 1;
        return .{ .row = row, .col = o - t.starts[row] };
    }

    fn off(t: Text, p: Pos) usize {
        return @min(t.starts[p.row] + p.col, t.s.len);
    }

    /// Vim's inc(): next position, through line ends. False at the end.
    fn inc(t: Text, o: *usize) bool {
        if (o.* + 1 >= t.s.len) return false;
        o.* += 1;
        return true;
    }

    fn dec(t: Text, o: *usize) bool {
        _ = t;
        if (o.* == 0) return false;
        o.* -= 1;
        return true;
    }

    /// Vim's decl(): dec() that skips the end of a non-empty line.
    fn decl(t: Text, o: *usize) bool {
        if (!t.dec(o)) return false;
        if (t.s[o.*] == '\n' and o.* > 0 and t.s[o.* - 1] != '\n') return t.dec(o);
        return true;
    }

    fn at(t: Text, o: usize) u8 {
        return if (o < t.s.len) t.s[o] else 0;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

const Tag = struct {
    closing: bool,
    name: []const u8,
};

/// The tag starting at offset `i` (on its '<'), if any.
fn tagAt(s: []const u8, i: usize) ?Tag {
    if (i + 1 >= s.len or s[i] != '<') return null;
    if (s[i + 1] == '/') {
        var k = i + 2;
        while (k < s.len and s[k] != '>' and s[k] != '\n') k += 1;
        if (k >= s.len or s[k] != '>') return null;
        return .{ .closing = true, .name = s[i + 2 .. k] };
    }
    var j = i + 1;
    while (j < s.len and !isSpace(s[j]) and s[j] != '>' and s[j] != '/' and s[j] != '!') j += 1;
    if (j == i + 1) return null;
    const tag = Tag{ .closing = false, .name = s[i + 1 .. j] };
    if (j >= s.len or s[j] == '\n' or s[j] == '>') return tag;
    if (!isSpace(s[j])) return null;
    // Attributes: up to the first '>', which must not follow a '/'.
    var k = j + 1;
    while (k < s.len and s[k] != '>') k += 1;
    if (k < s.len and (s[k - 1] != '/' or k == j + 1)) return tag;
    return null;
}

/// Vim's searchpair() backward for an unclosed opening tag before `from`.
fn backStart(t: Text, from: usize) ?usize {
    var nest: usize = 0;
    var i = from;
    while (i > 0) {
        i -= 1;
        const tag = tagAt(t.s, i) orelse continue;
        if (tag.closing) {
            nest += 1;
        } else if (nest == 0) {
            return i;
        } else nest -= 1;
    }
    return null;
}

/// searchpair() forward for the `</name>` closing the tag at `from`.
fn forwardEnd(t: Text, from: usize, name: []const u8) ?usize {
    var nest: usize = 0;
    var i = from + 1;
    while (i < t.s.len) : (i += 1) {
        const tag = tagAt(t.s, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(tag.name, name)) continue;
        if (!tag.closing) {
            nest += 1;
        } else if (nest == 0) {
            return i;
        } else nest -= 1;
    }
    return null;
}

/// Vim's in_html_tag(): the cursor is inside an opening (or closing) tag
/// on its line.
fn inHtmlTag(buf: *const Buffer, p: Pos, closing: bool) bool {
    const line = buf.getLine(p.row);
    var i = @min(p.col, line.len);
    while (i > 0) {
        if (i < line.len and line[i] == '<') break;
        i -= 1;
        if (line[i] == '>') break;
    }
    if (i >= line.len or line[i] != '<') return false;
    if (closing) return i + 1 < line.len and line[i + 1] == '/';
    if (i + 1 < line.len and line[i + 1] == '/') return false;
    var lc: u8 = 0;
    var k = i + 1;
    while (k < line.len and line[k] != '>') : (k += 1) lc = line[k];
    return k < line.len and lc != '/';
}

pub const Result = struct {
    obj: textobj.Obj,
    /// Visual mode: the new anchor and cursor.
    anchor: Pos,
    cursor: Pos,
};

/// `it` / `at`. `anchor` is the Visual start (null outside Visual mode).
pub fn object(alloc: std.mem.Allocator, buf: *const Buffer, cursor: Pos, anchor: ?Pos, count0: usize, include0: bool) !?Result {
    const s = try buf.toText(alloc);
    defer alloc.free(s);
    const starts = try alloc.alloc(usize, buf.lineCount());
    defer alloc.free(starts);
    var acc: usize = 0;
    for (starts, 0..) |*st, row| {
        st.* = acc;
        acc += buf.lineLen(row) + 1;
    }
    const t = Text{ .s = s, .starts = starts };
    if (s.len == 0) return null;

    const visual = anchor != null;
    var cur = t.off(cursor);
    var old_start = cur;
    var old_end = cur;
    if (!visual) _ = t.decl(&old_end);
    if (!visual or anchor.?.equals(cursor)) {
        var p = cursor;
        while (p.col < buf.firstNonBlank(p.row)) p.col += 1;
        cur = t.off(p);
        if (inHtmlTag(buf, p, false)) {
            while (t.at(cur) != '>') {
                if (!t.inc(&cur)) break;
            }
        } else if (inHtmlTag(buf, p, true)) {
            while (t.at(cur) != '<') {
                if (!t.dec(&cur)) break;
            }
            _ = t.dec(&cur);
            old_end = cur;
        }
    } else if (anchor.?.lessThan(cursor)) {
        old_start = t.off(anchor.?);
        cur = old_start;
    } else old_end = t.off(anchor.?);

    const count1 = @max(count0, 1);
    var count = count1;
    var include = include0;
    while (true) {
        var start = cur;
        for (0..count) |_| start = backStart(t, start) orelse return null;
        const name = tagAt(t.s, start).?.name;
        if (name.len == 0) return null;
        const end_tag = forwardEnd(t, start, name);
        if (end_tag == null or end_tag.? < old_end) {
            // No end, or it is before the previous end: an unclosed tag
            // (like <p>); try the one around it.
            count = 1;
            cur = start;
            continue;
        }
        var e = end_tag.?;
        var inclusive = true;
        if (include) {
            while (t.at(e) != '>') {
                if (!t.inc(&e)) break;
            }
        } else if (!visual and t.pos(e).col == 0) {
            // A closing tag at the line start: exclusive, so the line
            // break before it is taken.
            inclusive = false;
        } else _ = t.dec(&e);
        if (!include) {
            var o = start;
            while (t.inc(&o)) {
                if (t.at(o) == '>') {
                    _ = t.inc(&o);
                    start = o;
                    break;
                }
            }
            if (visual and start == old_start and e == old_end) {
                // Same text as selected: select the tags too.
                include = true;
                cur = old_start;
                count = count1;
                continue;
            }
        }
        const sp = t.pos(start);
        const ep = t.pos(e);
        if (e < start) {
            return .{ .obj = .{ .start = sp, .end = sp, .kind = .exclusive }, .anchor = sp, .cursor = sp };
        }
        return .{
            .obj = .{ .start = sp, .end = ep, .kind = if (inclusive) .inclusive else .exclusive },
            .anchor = sp,
            .cursor = ep,
        };
    }
}
