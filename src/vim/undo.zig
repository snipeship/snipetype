//! Undo tree of whole-buffer snapshots (buffers are small). Every state
//! is a node holding its text; a change group (a normal-mode command, a
//! whole insert session, a macro or a dot repeat) adds a child of the
//! current state. `u` goes to the parent, Ctrl-R to the child undone last
//! (else the newest), and g- / g+ walk the states in the order they were
//! made, across branches (Vim's undo_time with a step count).
//!
//! Each node also keeps the named marks from before its change (Vim's
//! uh_namedm): undo and redo swap them with the buffer's, so a mark on a
//! deleted line comes back with the line.

const std = @import("std");
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;
const Pos = buffer_mod.Pos;

/// States kept; past this the history restarts from the current state.
const max_nodes = 1000;
const n_marks = buffer_mod.n_named_marks;

pub const Marks = [n_marks]?Pos;

pub const Node = struct {
    /// The buffer text in this state.
    text: []u8,
    parent: usize = 0,
    /// Where the change that led here started (Vim's uh_cursor): the
    /// cursor goes back there after undo/redo.
    cursor: Pos = .{},
    /// The child Ctrl-R goes to: the one undone last, else the newest.
    redo_child: ?usize = null,
    marks: Marks = @splat(null),
};

/// Where an undo/redo step leaves the cursor, and how many steps ran.
pub const Moved = struct { cursor: Pos, steps: usize };

pub const History = struct {
    /// nodes[0] is the root (the text before the first change); node i was
    /// made i-th (its change number, Vim's seq).
    nodes: std.ArrayList(Node) = .empty,
    cur: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        self.clear();
        self.nodes.deinit(self.allocator);
    }

    pub fn clear(self: *History) void {
        for (self.nodes.items) |n| self.allocator.free(n.text);
        self.nodes.clearRetainingCapacity();
        self.cur = 0;
    }

    /// Records a change group: `before` is the text before it (ownership
    /// taken), `cursor` where it started, `marks` the named marks then. A
    /// snapshot equal to the current text is dropped (nothing changed).
    /// Returns true when a state was added.
    pub fn commitMarks(self: *History, buf: *const Buffer, before: []u8, cursor: Pos, marks: Marks) bool {
        if (buf.eqlText(before)) {
            self.allocator.free(before);
            return false;
        }
        const after = buf.toText(self.allocator) catch {
            self.allocator.free(before);
            return false;
        };
        if (self.nodes.items.len == 0 or self.nodes.items.len >= max_nodes) {
            self.clear();
            self.nodes.append(self.allocator, .{ .text = before }) catch {
                self.allocator.free(before);
                self.allocator.free(after);
                return false;
            };
        } else {
            // The text changed outside the history (should not happen):
            // the current state becomes what it was just before the change.
            const cur = &self.nodes.items[self.cur];
            if (!std.mem.eql(u8, cur.text, before)) {
                self.allocator.free(cur.text);
                cur.text = before;
            } else self.allocator.free(before);
        }
        self.nodes.append(self.allocator, .{ .text = after, .parent = self.cur, .cursor = cursor, .marks = marks }) catch {
            self.allocator.free(after);
            return false;
        };
        const id = self.nodes.items.len - 1;
        self.nodes.items[self.cur].redo_child = id;
        self.cur = id;
        return true;
    }

    /// commitMarks without marks.
    pub fn commit(self: *History, buf: *const Buffer, before: []u8, cursor: Pos) bool {
        return self.commitMarks(buf, before, cursor, @splat(null));
    }

    pub fn canUndo(self: *const History) bool {
        return self.cur != 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.nodes.items.len > 0 and self.nodes.items[self.cur].redo_child != null;
    }

    /// The change number of the current state (0: the original text).
    pub fn seq(self: *const History) usize {
        return self.cur;
    }

    /// The newest change number.
    pub fn seqLast(self: *const History) usize {
        return self.nodes.items.len -| 1;
    }

    /// Back to the parent state; returns where the cursor goes.
    pub fn undo(self: *History, buf: *Buffer) !?Pos {
        if (self.cur == 0) return null;
        const from = self.cur;
        self.stepUp(buf);
        try buf.setText(self.nodes.items[self.cur].text);
        return cursorAfter(buf, self.nodes.items[from].text, self.nodes.items[from].cursor);
    }

    /// Forward to the child undone last.
    pub fn redo(self: *History, buf: *Buffer) !?Pos {
        if (self.nodes.items.len == 0) return null;
        const child = self.nodes.items[self.cur].redo_child orelse return null;
        const parent = self.cur;
        self.stepDown(buf, child);
        try buf.setText(self.nodes.items[child].text);
        return cursorAfter(buf, self.nodes.items[parent].text, self.nodes.items[child].cursor);
    }

    /// g- (count < 0) / g+ (count > 0): to the state made `count` changes
    /// earlier/later, whatever branch it is on. Null when already there.
    pub fn travel(self: *History, buf: *Buffer, count: isize) !?Pos {
        if (self.nodes.items.len == 0) return null;
        const last: isize = @intCast(self.nodes.items.len - 1);
        const target: usize = @intCast(std.math.clamp(@as(isize, @intCast(self.cur)) + count, 0, last));
        if (target == self.cur) return null;
        // Up to the nearest common ancestor, then down to the target.
        var path: std.ArrayList(usize) = .empty;
        defer path.deinit(self.allocator);
        var n = target;
        while (!self.isAncestor(n, self.cur)) : (n = self.nodes.items[n].parent) try path.append(self.allocator, n);
        var last_from: usize = self.cur;
        var last_to: usize = self.cur;
        var down = false;
        while (self.cur != n) {
            last_from = self.cur;
            self.stepUp(buf);
            last_to = self.cur;
        }
        var i = path.items.len;
        while (i > 0) {
            i -= 1;
            last_from = self.cur;
            self.stepDown(buf, path.items[i]);
            last_to = self.cur;
            down = true;
        }
        try buf.setText(self.nodes.items[self.cur].text);
        // The cursor goes where the last step leaves it.
        const changed = if (down) last_to else last_from;
        return cursorAfter(buf, self.nodes.items[last_from].text, self.nodes.items[changed].cursor);
    }

    /// `a` is `b` or one of its ancestors.
    fn isAncestor(self: *const History, a: usize, b: usize) bool {
        var n = b;
        while (true) {
            if (n == a) return true;
            if (n == 0) return false;
            n = self.nodes.items[n].parent;
        }
    }

    fn stepUp(self: *History, buf: *Buffer) void {
        const node = &self.nodes.items[self.cur];
        swapMarks(buf, &node.marks);
        self.nodes.items[node.parent].redo_child = self.cur;
        self.cur = node.parent;
    }

    fn stepDown(self: *History, buf: *Buffer, child: usize) void {
        self.nodes.items[self.cur].redo_child = child;
        swapMarks(buf, &self.nodes.items[child].marks);
        self.cur = child;
    }
};

/// Vim's mark restore in u_undoredo: marks saved with the change replace
/// the buffer's; the buffer's set marks are saved in their place.
fn swapMarks(buf: *Buffer, saved: *Marks) void {
    const now = buf.namedMarks();
    for (saved, 0..) |m, i| {
        if (m) |p| buf.setNamedMark(i, p);
    }
    saved.* = now;
}

/// Vim's cursor placement after undo/redo (u_undoredo): the saved cursor
/// when it lies within (or next to) the restored lines, else the first
/// changed line; the saved column on the saved line, else the first non-blank.
fn cursorAfter(buf: *const Buffer, replaced: []const u8, saved: Pos) Pos {
    const n_new = buf.lineCount();
    const n_old = std.mem.count(u8, replaced, "\n") + 1;
    var top: usize = 0;
    var fwd = std.mem.splitScalar(u8, replaced, '\n');
    while (top < n_new) : (top += 1) {
        const l = fwd.next() orelse break;
        if (!std.mem.eql(u8, l, buf.getLine(top))) break;
    }
    var suffix: usize = 0;
    var bwd = std.mem.splitBackwardsScalar(u8, replaced, '\n');
    while (suffix < n_new - top and suffix < n_old -| top) : (suffix += 1) {
        const l = bwd.next() orelse break;
        if (!std.mem.eql(u8, l, buf.getLine(n_new - 1 - suffix))) break;
    }
    const newsize = n_new - top - suffix;
    var p: Pos = saved;
    if (!(saved.row + 1 >= top and saved.row <= top + newsize)) {
        p = .{ .row = top };
        if (saved.row + 1 == p.row and p.row > 0) p.row -= 1;
    }
    if (p.row >= n_new) return .{ .row = n_new - 1 };
    p.col = if (p.row == saved.row) saved.col else buf.firstNonBlank(p.row);
    return p;
}

const t = std.testing;

fn change(h: *History, b: *Buffer, text: []const u8) !void {
    try b.setLine(0, text);
    try t.expect(h.commit(b, b.takeSnapshot().?, .{}));
}

test "undo/redo round trip" {
    var b = Buffer.init(t.allocator);
    defer b.deinit();
    var h = History.init(t.allocator);
    defer h.deinit();
    try b.setText("abc\ndef");
    try b.deleteRange(.{ .row = 1, .col = 1 }, .{ .row = 1, .col = 2 });
    try t.expect(h.commit(&b, b.takeSnapshot().?, .{ .row = 1, .col = 1 }));
    try t.expect(b.eqlText("abc\ndf"));
    const p = (try h.undo(&b)).?;
    try t.expect(b.eqlText("abc\ndef"));
    try t.expectEqual(Pos{ .row = 1, .col = 1 }, p);
    _ = try h.redo(&b);
    try t.expect(b.eqlText("abc\ndf"));
    try t.expect((try h.redo(&b)) == null);
}

test "undo tree: a change after undo branches; g- g+ visit every state in order" {
    var b = Buffer.init(t.allocator);
    defer b.deinit();
    var h = History.init(t.allocator);
    defer h.deinit();
    try b.setText("one");
    try change(&h, &b, "two");
    try change(&h, &b, "three");
    _ = try h.undo(&b);
    try change(&h, &b, "four"); // branch: one -> two -> {three, four}
    try t.expect(b.eqlText("four"));
    _ = try h.undo(&b);
    _ = try h.redo(&b); // back to the branch undone last
    try t.expect(b.eqlText("four"));
    _ = try h.travel(&b, -1); // change 2: "three", on the other branch
    try t.expect(b.eqlText("three"));
    _ = try h.travel(&b, -1);
    try t.expect(b.eqlText("two"));
    _ = try h.travel(&b, -5);
    try t.expect(b.eqlText("one"));
    try t.expect((try h.travel(&b, -1)) == null);
    _ = try h.travel(&b, 2);
    try t.expect(b.eqlText("three"));
    _ = try h.redo(&b);
    try t.expect(b.eqlText("three")); // nothing to redo past "three"
    _ = try h.travel(&b, 9);
    try t.expect(b.eqlText("four"));
    try t.expect((try h.travel(&b, 1)) == null);
}
