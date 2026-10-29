//! Marks `a`-`z`, the previous-context mark (`''`), the jump list
//! (`<C-o>`/`<C-i>`) and the change list (`g;`/`g,`), stored as tracked
//! positions in the buffer so they follow line inserts and deletes.
//! Marks on a deleted line are removed; jump and change list entries move
//! to the line after the deletion (Vim's mark_adjust).

const std = @import("std");
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;
const Pos = buffer_mod.Pos;
const Track = buffer_mod.Track;

/// Slots in `Buffer.tracked`.
pub const n_marks = 26;
/// Row of the line `U` restores (the text lives in the editor).
pub const uline_slot = 26;
/// `''` / ` `` `: where the cursor was before the latest jump.
pub const pcmark_slot = 27;
const jl_base = 28;
pub const jl_max = 100;
const cl_base = jl_base + jl_max;
pub const cl_max = 100;
/// `:g` marks its lines in slots from here on.
pub const fixed_slots = cl_base + cl_max;

pub const ChangeError = error{ ChangelistEmpty, AtStart, AtEnd };

pub const Lists = struct {
    jl_len: usize = 0,
    jl_idx: usize = 0,
    cl_len: usize = 0,
    cl_idx: usize = 0,

    /// Forgets every mark and both lists.
    pub fn clear(self: *Lists, buf: *Buffer) void {
        buf.tracked.clearRetainingCapacity();
        self.* = .{};
    }

    /// Allocates the fixed slots (before anything appends after them).
    pub fn ensure(buf: *Buffer) !void {
        const items = buf.tracked.items;
        if (items.len >= fixed_slots) return;
        const from = items.len;
        try buf.tracked.appendNTimes(buf.allocator, .{}, fixed_slots - from);
        for (buf.tracked.items[from..], from..) |*t, i| t.keep = i == pcmark_slot or i >= jl_base;
    }

    fn get(buf: *const Buffer, slot: usize) ?Pos {
        if (slot >= buf.tracked.items.len) return null;
        const t = buf.tracked.items[slot];
        return if (t.live) t.pos else null;
    }

    fn set(buf: *Buffer, slot: usize, pos: ?Pos) !void {
        try ensure(buf);
        const t = &buf.tracked.items[slot];
        t.live = pos != null;
        if (pos) |p| t.pos = p;
    }

    /// `m{a-z}`.
    pub fn setMark(buf: *Buffer, c: u8, pos: Pos) !void {
        try set(buf, c - 'a', pos);
    }

    pub fn mark(buf: *const Buffer, c: u8) ?Pos {
        return get(buf, c - 'a');
    }

    pub fn pcmark(buf: *const Buffer) ?Pos {
        return get(buf, pcmark_slot);
    }

    pub fn uline(buf: *const Buffer) ?usize {
        return if (get(buf, uline_slot)) |p| p.row else null;
    }

    pub fn setUline(buf: *Buffer, row: ?usize) !void {
        try set(buf, uline_slot, if (row) |r| Pos{ .row = r } else null);
    }

    fn jl(buf: *Buffer, i: usize) *Track {
        return &buf.tracked.items[jl_base + i];
    }

    /// Vim's setpcmark: `pos` becomes `''` and the newest jump list entry.
    pub fn pushJump(self: *Lists, buf: *Buffer, pos: Pos) !void {
        try set(buf, pcmark_slot, pos);
        if (self.jl_len == jl_max) {
            std.mem.copyForwards(Track, buf.tracked.items[jl_base..][0 .. jl_max - 1], buf.tracked.items[jl_base + 1 ..][0 .. jl_max - 1]);
            self.jl_len -= 1;
        }
        jl(buf, self.jl_len).* = .{ .pos = pos, .live = true, .keep = true };
        self.jl_len += 1;
        self.jl_idx = self.jl_len;
    }

    /// Vim's cleanup_jumplist: of entries on the same line only the newest
    /// stays.
    fn cleanup(self: *Lists, buf: *Buffer) void {
        var to: usize = 0;
        var from: usize = 0;
        while (from < self.jl_len) : (from += 1) {
            if (self.jl_idx == from) self.jl_idx = to;
            const row = jl(buf, from).pos.row;
            var dup = false;
            for (from + 1..self.jl_len) |i| {
                if (jl(buf, i).pos.row == row) dup = true;
            }
            if (!dup) {
                jl(buf, to).* = jl(buf, from).*;
                to += 1;
            }
        }
        if (self.jl_idx == self.jl_len) self.jl_idx = to;
        self.jl_len = to;
    }

    /// `<C-o>` (count < 0) / `<C-i>` (count > 0) from `cur`: the entry to go
    /// to, or null at either end. The first `<C-o>` after a jump records
    /// `cur` so `<C-i>` can come back.
    pub fn jump(self: *Lists, buf: *Buffer, cur: Pos, count: isize) !?Pos {
        try ensure(buf);
        self.cleanup(buf);
        if (@as(isize, @intCast(self.jl_idx)) + count < 0 or @as(isize, @intCast(self.jl_idx)) + count >= @as(isize, @intCast(self.jl_len))) return null;
        if (self.jl_idx == self.jl_len) {
            const keep_idx = self.jl_len;
            try self.pushJump(buf, cur);
            self.jl_idx = keep_idx;
            if (@as(isize, @intCast(self.jl_idx)) + count < 0) return null;
        }
        self.jl_idx = @intCast(@as(isize, @intCast(self.jl_idx)) + count);
        return jl(buf, self.jl_idx).pos;
    }

    fn cl(buf: *Buffer, i: usize) *Track {
        return &buf.tracked.items[cl_base + i];
    }

    /// Records a change at `pos`. A change on the line of the newest entry
    /// and within 79 columns of it moves that entry instead of adding one.
    pub fn noteChange(self: *Lists, buf: *Buffer, pos: Pos) !void {
        try ensure(buf);
        var add = self.cl_len == 0;
        if (!add) {
            const last = cl(buf, self.cl_len - 1).pos;
            add = last.row != pos.row or last.col + 79 < pos.col or pos.col + 79 < last.col;
        }
        if (add) {
            if (self.cl_len == cl_max) {
                std.mem.copyForwards(Track, buf.tracked.items[cl_base..][0 .. cl_max - 1], buf.tracked.items[cl_base + 1 ..][0 .. cl_max - 1]);
                self.cl_len -= 1;
            }
            self.cl_len += 1;
        }
        cl(buf, self.cl_len - 1).* = .{ .pos = pos, .live = true, .keep = true };
        self.cl_idx = self.cl_len;
    }

    /// The newest change (`'.`).
    pub fn lastChange(self: *const Lists, buf: *const Buffer) ?Pos {
        if (self.cl_len == 0) return null;
        return get(buf, cl_base + self.cl_len - 1);
    }

    /// `g;` (count < 0) / `g,` (count > 0).
    pub fn change(self: *Lists, buf: *Buffer, count: isize) ChangeError!Pos {
        if (self.cl_len == 0) return error.ChangelistEmpty;
        const n: isize = @intCast(self.cl_idx);
        const len: isize = @intCast(self.cl_len);
        var to = n + count;
        if (to < 0) {
            if (n == 0) return error.AtStart;
            to = 0;
        } else if (to >= len) {
            if (n == len - 1) return error.AtEnd;
            to = len - 1;
        }
        self.cl_idx = @intCast(to);
        return cl(buf, self.cl_idx).pos;
    }
};

const testing = std.testing;

test "jump list: Vim's <C-o> records the cursor once; duplicates collapse" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.setText("0\n1\n2\n3\n4");
    var l = Lists{};
    try l.pushJump(&b, .{ .row = 0 });
    try l.pushJump(&b, .{ .row = 4 });
    try testing.expectEqual(Pos{ .row = 4 }, (try l.jump(&b, .{ .row = 2 }, -1)).?);
    try testing.expectEqual(Pos{ .row = 0 }, (try l.jump(&b, .{ .row = 4 }, -1)).?);
    try testing.expect((try l.jump(&b, .{}, -1)) == null);
    try testing.expectEqual(Pos{ .row = 4 }, (try l.jump(&b, .{}, 1)).?);
    try testing.expectEqual(Pos{ .row = 2 }, (try l.jump(&b, .{ .row = 4 }, 1)).?);
    try testing.expect((try l.jump(&b, .{ .row = 2 }, 1)) == null);
    try l.pushJump(&b, .{ .row = 0, .col = 1 });
    _ = try l.jump(&b, .{ .row = 3 }, -1);
    // The old row-0 entry was dropped in favour of the newer one.
    try testing.expectEqual(@as(usize, 4), l.jl_len);
}

test "change list: near changes merge, g; g, stop at the ends" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.setText("a\nb\nc");
    var l = Lists{};
    try testing.expectError(error.ChangelistEmpty, l.change(&b, -1));
    try l.noteChange(&b, .{ .row = 0, .col = 0 });
    try l.noteChange(&b, .{ .row = 0, .col = 3 });
    try l.noteChange(&b, .{ .row = 2, .col = 0 });
    try testing.expectEqual(@as(usize, 2), l.cl_len);
    try testing.expectEqual(Pos{ .row = 2 }, try l.change(&b, -1));
    try testing.expectEqual(Pos{ .row = 0, .col = 3 }, try l.change(&b, -1));
    try testing.expectError(error.AtStart, l.change(&b, -1));
    try testing.expectEqual(Pos{ .row = 2 }, try l.change(&b, 1));
    try testing.expectError(error.AtEnd, l.change(&b, 1));
    try b.deleteLines(0, 0);
    try testing.expectEqual(Pos{ .row = 1 }, l.lastChange(&b).?);
}
