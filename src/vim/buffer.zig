//! Text buffer: a list of lines (no trailing '\n' stored).
//!
//! Character ranges are half-open (`end` exclusive) and may span rows; a
//! range that ends at `{ .row = r + 1, .col = 0 }` includes the line break
//! after row r. Every mutation bumps `version` and, while `track` is set,
//! lazily snapshots the text before the first change of an undo group
//! (`takeSnapshot` hands it to the undo history).
//!
//! `tracked` positions (marks, the jump and change lists, `:g` lines)
//! follow line inserts and deletes, as Vim's mark_adjust does.

const std = @import("std");

const Cursor = @import("cursor.zig").Cursor;
pub const Pos = Cursor;

const Line = std.ArrayList(u8);

/// A position that follows line inserts and deletes.
pub const Track = struct {
    pos: Pos = .{},
    live: bool = false,
    /// On a deleted line: move to the first line after the deletion (Vim's
    /// jump and change lists) instead of dying (marks, `:g` lines).
    keep: bool = false,
};

/// `tracked` slots 0..25 are the marks a-z (see jumps.zig); undo saves and
/// restores them.
pub const n_named_marks = 26;

pub const Buffer = struct {
    lines: std.ArrayList(Line),
    allocator: std.mem.Allocator,
    /// Incremented by every mutation.
    version: u64 = 0,
    /// Text before the first mutation since the last `takeSnapshot`.
    snapshot: ?[]u8 = null,
    track: bool = true,
    /// Positions adjusted by every line insert/delete (owned by the editor's
    /// layout; see jumps.zig).
    tracked: std.ArrayList(Track) = .empty,
    /// Where the latest mutation started (Vim's b_last_change).
    last_change: Pos = .{},
    /// Counts mutations (not `setText`), for the change list.
    edits: u64 = 0,
    /// The marks a-z when `snapshot` was taken (for the undo history).
    snapshot_marks: [n_named_marks]?Pos = @splat(null),

    /// Vim's "U" line: the row the latest single-line changes were made
    /// on, its text before them and the cursor column then. Not moved by
    /// line inserts (as in Vim); forgotten by line deletes and splits.
    u_row: ?usize = null,
    u_text: Line = .empty,
    u_col: usize = 0,
    /// The cursor when the current command started (set by the editor).
    u_cursor: Pos = .{},
    /// Set during changes to several lines (J, d2j, >ip): they do not
    /// save a "U" line (Vim saves one only for a one-line change).
    u_hold: bool = false,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        var lines = std.ArrayList(Line).empty;
        lines.append(allocator, Line.empty) catch {};
        return .{ .lines = lines, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.tracked.deinit(self.allocator);
        self.u_text.deinit(self.allocator);
        self.dropSnapshot();
    }

    pub fn clear(self: *Buffer) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
        self.lines.append(self.allocator, Line.empty) catch {};
        self.version +%= 1;
        self.dropSnapshot();
        self.u_row = null;
    }

    /// Replaces the whole text (does not snapshot).
    pub fn setText(self: *Buffer, text: []const u8) !void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |piece| {
            var l = Line.empty;
            errdefer l.deinit(self.allocator);
            try l.appendSlice(self.allocator, piece);
            try self.lines.append(self.allocator, l);
        }
        self.version +%= 1;
    }

    fn touch(self: *Buffer, at: Pos) !void {
        self.version +%= 1;
        self.edits +%= 1;
        self.last_change = at;
        if (self.track and self.snapshot == null) {
            self.snapshot = try self.toText(self.allocator);
            self.snapshot_marks = self.namedMarks();
        }
    }

    pub fn namedMarks(self: *const Buffer) [n_named_marks]?Pos {
        var out: [n_named_marks]?Pos = @splat(null);
        const n = @min(self.tracked.items.len, n_named_marks);
        for (self.tracked.items[0..n], 0..) |t, i| out[i] = if (t.live) t.pos else null;
        return out;
    }

    /// Sets mark `i` (0 = 'a') when the mark slots exist (not clamped: undo
    /// restores marks before the text).
    pub fn setNamedMark(self: *Buffer, i: usize, p: Pos) void {
        if (i >= self.tracked.items.len) return;
        self.tracked.items[i].pos = p;
        self.tracked.items[i].live = true;
    }

    /// Vim's u_saveline(): before the first change on a line that is not
    /// the "U" line yet, remember its text.
    fn saveLine(self: *Buffer, row: usize) !void {
        if (!self.track or self.u_hold or self.u_row == row) return;
        self.u_text.clearRetainingCapacity();
        try self.u_text.appendSlice(self.allocator, self.getLine(row));
        self.u_row = row;
        self.u_col = if (self.u_cursor.row == row) self.u_cursor.col else 0;
    }

    /// Vim's u_clearline(): `U` has nothing to restore.
    pub fn clearLine(self: *Buffer) void {
        self.u_row = null;
    }

    /// Tracked rows >= `row` move down by `n` (lines inserted before `row`).
    fn shiftDown(self: *Buffer, row: usize, n: usize) void {
        for (self.tracked.items) |*t| {
            if (t.live and t.pos.row >= row) t.pos.row += n;
        }
    }

    /// Rows a..b were deleted.
    fn dropRows(self: *Buffer, a: usize, b: usize) void {
        const n = b - a + 1;
        for (self.tracked.items) |*t| {
            if (!t.live) continue;
            if (t.pos.row > b) {
                t.pos.row -= n;
            } else if (t.pos.row >= a) {
                if (t.keep) t.pos = .{ .row = a } else t.live = false;
            }
        }
    }

    /// [start, end) was deleted across rows: the tail of `end.row` joins
    /// `start.row`; rows in between are gone.
    fn joinRows(self: *Buffer, start: Pos, end: Pos) void {
        const n = end.row - start.row;
        for (self.tracked.items) |*t| {
            if (!t.live or t.pos.row <= start.row) continue;
            if (t.pos.row > end.row) {
                t.pos.row -= n;
            } else if (t.pos.row == end.row) {
                t.pos = .{ .row = start.row, .col = start.col + (t.pos.col -| end.col) };
            } else if (t.keep) {
                t.pos = start;
            } else t.live = false;
        }
    }

    pub fn dropSnapshot(self: *Buffer) void {
        if (self.snapshot) |s| self.allocator.free(s);
        self.snapshot = null;
    }

    /// Returns (and forgets) the pre-change snapshot, if any.
    pub fn takeSnapshot(self: *Buffer) ?[]u8 {
        const s = self.snapshot;
        self.snapshot = null;
        return s;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn lastRow(self: *const Buffer) usize {
        return self.lines.items.len - 1;
    }

    pub fn getLine(self: *const Buffer, row: usize) []const u8 {
        if (row >= self.lines.items.len) return "";
        return self.lines.items[row].items;
    }

    pub fn lineLen(self: *const Buffer, row: usize) usize {
        return self.getLine(row).len;
    }

    /// Char at pos, or 0 at/after the end of the line (Vim's NUL).
    pub fn charAt(self: *const Buffer, p: Pos) u8 {
        const l = self.getLine(p.row);
        return if (p.col < l.len) l[p.col] else 0;
    }

    /// Column of the first non-blank (line length when all blank).
    pub fn firstNonBlank(self: *const Buffer, row: usize) usize {
        const l = self.getLine(row);
        var i: usize = 0;
        while (i < l.len and (l[i] == ' ' or l[i] == '\t')) i += 1;
        return i;
    }

    /// Leading whitespace of a row.
    pub fn indent(self: *const Buffer, row: usize) []const u8 {
        return self.getLine(row)[0..self.firstNonBlank(row)];
    }

    pub fn isBlankLine(self: *const Buffer, row: usize) bool {
        return self.firstNonBlank(row) == self.lineLen(row);
    }

    /// Clamps a position into the buffer (col may equal the line length).
    pub fn clampPos(self: *const Buffer, p: Pos) Pos {
        const row = @min(p.row, self.lastRow());
        return .{ .row = row, .col = @min(p.col, self.lineLen(row)) };
    }

    // -- mutations ---------------------------------------------------------

    /// Inserts `text` (may contain '\n') at `p`; returns the position just
    /// after the inserted text.
    pub fn insertText(self: *Buffer, p0: Pos, text: []const u8) !Pos {
        const p = self.clampPos(p0);
        if (text.len == 0) return p;
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse {
            try self.saveLine(p.row);
            try self.touch(p);
            try self.lines.items[p.row].insertSlice(self.allocator, p.col, text);
            return .{ .row = p.row, .col = p.col + text.len };
        };
        try self.touch(p);
        self.clearLine();
        self.shiftDown(p.row + 1, std.mem.count(u8, text, "\n"));
        // Split the line: head + first piece | middle pieces | last piece + tail.
        const tail = try self.allocator.dupe(u8, self.lines.items[p.row].items[p.col..]);
        defer self.allocator.free(tail);
        self.lines.items[p.row].shrinkRetainingCapacity(p.col);
        try self.lines.items[p.row].appendSlice(self.allocator, text[0..nl]);
        var row = p.row;
        var rest = text[nl + 1 ..];
        while (true) {
            row += 1;
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            var l = Line.empty;
            errdefer l.deinit(self.allocator);
            try l.appendSlice(self.allocator, rest[0..end]);
            const col = l.items.len;
            if (end == rest.len) try l.appendSlice(self.allocator, tail);
            try self.lines.insert(self.allocator, row, l);
            if (end == rest.len) return .{ .row = row, .col = col };
            rest = rest[end + 1 ..];
        }
    }

    pub fn insertChar(self: *Buffer, p: Pos, c: u8) void {
        _ = self.insertText(p, &.{c}) catch {};
    }

    /// Deletes the half-open range [start, end) (may span rows).
    pub fn deleteRange(self: *Buffer, start0: Pos, end0: Pos) !void {
        const start = self.clampPos(start0);
        const end = self.clampEnd(end0);
        if (!start.lessThan(end)) return;
        if (start.row == end.row) try self.saveLine(start.row);
        try self.touch(start);
        if (start.row == end.row) {
            const l = &self.lines.items[start.row];
            const n = end.col - start.col;
            std.mem.copyForwards(u8, l.items[start.col..], l.items[end.col..]);
            l.shrinkRetainingCapacity(l.items.len - n);
            return;
        }
        self.joinRows(start, end);
        const tail_line = self.lines.items[end.row].items[end.col..];
        const first = &self.lines.items[start.row];
        first.shrinkRetainingCapacity(start.col);
        try first.appendSlice(self.allocator, tail_line);
        var r = end.row;
        while (r > start.row) : (r -= 1) {
            var l = self.lines.orderedRemove(r);
            l.deinit(self.allocator);
        }
    }

    /// Copy of [start, end) with '\n' between rows.
    pub fn copyRange(self: *const Buffer, allocator: std.mem.Allocator, start0: Pos, end0: Pos) ![]u8 {
        const start = self.clampPos(start0);
        const end = self.clampEnd(end0);
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        if (!start.lessThan(end)) return out.toOwnedSlice(allocator);
        var row = start.row;
        while (row <= end.row) : (row += 1) {
            const l = self.getLine(row);
            const a = if (row == start.row) start.col else 0;
            const b = if (row == end.row) end.col else l.len;
            try out.appendSlice(allocator, l[a..b]);
            if (row != end.row) try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }

    /// An exclusive end may sit at (lastRow + 1, 0): clamp to buffer end.
    fn clampEnd(self: *const Buffer, p: Pos) Pos {
        if (p.row > self.lastRow()) return .{ .row = self.lastRow(), .col = self.lineLen(self.lastRow()) };
        return self.clampPos(p);
    }

    /// Rows a..b joined with '\n' (no trailing newline).
    pub fn copyLines(self: *const Buffer, allocator: std.mem.Allocator, a: usize, b: usize) ![]u8 {
        return self.copyRange(allocator, .{ .row = a, .col = 0 }, .{ .row = b, .col = self.lineLen(b) });
    }

    /// Inserts `text` as whole lines before `row` (row may equal lineCount).
    pub fn insertLines(self: *Buffer, row: usize, text: []const u8) !void {
        const at = @min(row, self.lineCount());
        try self.touch(.{ .row = at });
        self.shiftDown(at, std.mem.count(u8, text, "\n") + 1);
        var it = std.mem.splitScalar(u8, text, '\n');
        var r = at;
        while (it.next()) |piece| : (r += 1) {
            var l = Line.empty;
            errdefer l.deinit(self.allocator);
            try l.appendSlice(self.allocator, piece);
            try self.lines.insert(self.allocator, r, l);
        }
    }

    /// Removes rows a..b; the buffer always keeps at least one (empty) line.
    pub fn deleteLines(self: *Buffer, a: usize, b0: usize) !void {
        if (a > self.lastRow()) return;
        const b = @min(b0, self.lastRow());
        try self.touch(.{ .row = a });
        self.clearLine();
        self.dropRows(a, b);
        var r = b + 1;
        while (r > a) {
            r -= 1;
            var l = self.lines.orderedRemove(r);
            l.deinit(self.allocator);
        }
        if (self.lines.items.len == 0) try self.lines.append(self.allocator, Line.empty);
    }

    /// Replaces the text of one row.
    pub fn setLine(self: *Buffer, row: usize, text: []const u8) !void {
        if (row > self.lastRow()) return;
        if (std.mem.eql(u8, self.getLine(row), text)) return;
        try self.saveLine(row);
        try self.touch(.{ .row = row });
        const l = &self.lines.items[row];
        l.clearRetainingCapacity();
        try l.appendSlice(self.allocator, text);
    }

    /// Replaces cols [a, b) of a row with `text`.
    pub fn replaceInLine(self: *Buffer, row: usize, a: usize, b: usize, text: []const u8) !void {
        try self.saveLine(row);
        try self.touch(.{ .row = row, .col = a });
        try self.lines.items[row].replaceRange(self.allocator, a, b - a, text);
    }

    // -- legacy helpers kept for callers ----------------------------------

    pub fn deleteChar(self: *Buffer, p: Pos) void {
        self.deleteRange(p, .{ .row = p.row, .col = p.col + 1 }) catch {};
    }

    pub fn insertNewline(self: *Buffer, p: Pos) void {
        _ = self.insertText(p, "\n") catch {};
    }

    pub fn joinLines(self: *Buffer, row: usize) void {
        if (row + 1 >= self.lineCount()) return;
        self.deleteRange(.{ .row = row, .col = self.lineLen(row) }, .{ .row = row + 1, .col = 0 }) catch {};
    }

    pub fn deleteLine(self: *Buffer, row: usize) void {
        self.deleteLines(row, row) catch {};
    }

    pub fn insertLine(self: *Buffer, row: usize, content: []const u8) void {
        self.insertLines(row, content) catch {};
    }

    // -- queries -----------------------------------------------------------

    pub fn toText(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, self.totalChars());
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(buf[pos..][0..line.items.len], line.items);
            pos += line.items.len;
            if (i < self.lines.items.len - 1) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
        return buf;
    }

    /// True when the text equals `text` exactly.
    pub fn eqlText(self: *const Buffer, text: []const u8) bool {
        if (self.totalChars() != text.len) return false;
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            if (!std.mem.eql(u8, line.items, text[pos..][0..line.items.len])) return false;
            pos += line.items.len;
            if (i < self.lines.items.len - 1) {
                if (text[pos] != '\n') return false;
                pos += 1;
            }
        }
        return true;
    }

    /// Count characters matching target lines without allocation.
    /// Returns struct with correct char count and total typed chars.
    pub fn countMatchingChars(self: *const Buffer, target_lines: []const []const u8) struct { correct: usize, total: usize, errors: usize } {
        var correct: usize = 0;
        var total: usize = 0;
        var errors: usize = 0;

        const max_rows = @max(self.lines.items.len, target_lines.len);

        for (0..max_rows) |row| {
            const typed_line = if (row < self.lines.items.len) self.lines.items[row].items else "";
            const target_line = if (row < target_lines.len) target_lines[row] else "";

            const len = @min(typed_line.len, target_line.len);
            for (0..len) |col| {
                if (typed_line[col] == target_line[col]) correct += 1 else errors += 1;
            }
            // Extra or missing characters are errors.
            if (typed_line.len > target_line.len) {
                errors += typed_line.len - target_line.len;
            } else if (typed_line.len < target_line.len) {
                errors += target_line.len - typed_line.len;
            }
            total += typed_line.len;

            // Line breaks (all but the last line).
            if (row < self.lines.items.len - 1) {
                total += 1;
                if (target_lines.len > 0 and row < target_lines.len - 1) correct += 1 else errors += 1;
            } else if (target_lines.len > 0 and row < target_lines.len - 1) {
                errors += 1;
            }
        }

        return .{ .correct = correct, .total = total, .errors = errors };
    }

    /// Total character count including line breaks.
    pub fn totalChars(self: *const Buffer) usize {
        var total: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total += line.items.len;
            if (i < self.lines.items.len - 1) total += 1;
        }
        return total;
    }

    /// Check if buffer content exactly matches target text (allocation-free)
    pub fn matchesTarget(self: *const Buffer, target_lines: []const []const u8, target_len: usize) bool {
        if (self.totalChars() != target_len) return false;
        if (self.lines.items.len != target_lines.len) return false;
        for (self.lines.items, 0..) |line, row| {
            if (!std.mem.eql(u8, line.items, target_lines[row])) return false;
        }
        return true;
    }
};

const testing = std.testing;

fn expectText(b: *const Buffer, want: []const u8) !void {
    const t = try b.toText(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings(want, t);
}

test "buffer: insert and delete across rows" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.setText("hello world\nfoo");
    const end = try b.insertText(.{ .row = 0, .col = 5 }, ",\nnew\nmid");
    try testing.expectEqual(Pos{ .row = 2, .col = 3 }, end);
    try expectText(&b, "hello,\nnew\nmid world\nfoo");
    const c = try b.copyRange(testing.allocator, .{ .row = 0, .col = 3 }, .{ .row = 2, .col = 1 });
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("lo,\nnew\nm", c);
    try b.deleteRange(.{ .row = 0, .col = 3 }, .{ .row = 2, .col = 1 });
    try expectText(&b, "helid world\nfoo");
    try b.deleteRange(.{ .row = 0, .col = 11 }, .{ .row = 1, .col = 0 });
    try expectText(&b, "helid worldfoo");
    try b.deleteLines(0, 0);
    try expectText(&b, "");
    try testing.expectEqual(@as(usize, 1), b.lineCount());
    if (b.takeSnapshot()) |s| testing.allocator.free(s);
}

test "buffer: tracked positions follow line inserts and deletes" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.setText("a\nb\nc\nd\ne");
    try b.tracked.appendSlice(testing.allocator, &.{
        .{ .pos = .{ .row = 3, .col = 0 }, .live = true },
        .{ .pos = .{ .row = 1 }, .live = true },
        .{ .pos = .{ .row = 1 }, .live = true, .keep = true },
        .{ .pos = .{ .row = 4 }, .live = true },
    });
    try b.insertLines(0, "x\ny");
    try testing.expectEqual(@as(usize, 5), b.tracked.items[0].pos.row);
    try b.deleteLines(3, 3); // "b"
    try testing.expect(!b.tracked.items[1].live);
    try testing.expectEqual(@as(usize, 3), b.tracked.items[2].pos.row);
    try testing.expectEqual(@as(usize, 4), b.tracked.items[0].pos.row);
    _ = try b.insertText(.{ .row = 0, .col = 1 }, "\n");
    try testing.expectEqual(@as(usize, 5), b.tracked.items[0].pos.row);
    // Joining "d" onto "c": the mark on "d" moves to the joined line.
    try b.deleteRange(.{ .row = 4, .col = 1 }, .{ .row = 5 });
    try testing.expectEqual(Pos{ .row = 4, .col = 1 }, b.tracked.items[0].pos);
    try testing.expectEqual(@as(usize, 5), b.tracked.items[3].pos.row);
    if (b.takeSnapshot()) |s| testing.allocator.free(s);
}

test "buffer: snapshot is taken once per group" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.setText("abc");
    b.insertChar(.{ .col = 3 }, 'd');
    b.insertChar(.{ .col = 4 }, 'e');
    const s = b.takeSnapshot().?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("abc", s);
    try testing.expect(b.eqlText("abcde"));
}
