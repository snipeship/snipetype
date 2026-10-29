//! Registers: unnamed `"`, `"0` (last yank), `"1`-`"9` (deletes of a line
//! or more, shifted), `"-` (small deletes), `"a`-`"z` (`"A`-`"Z` append) and
//! the black hole `"_`. Each keeps whether its text is charwise, linewise
//! or a block (one '\n'-separated row per line of a Ctrl+V selection).

const std = @import("std");

pub const Kind = enum { char, line, block };

pub const Reg = struct {
    text: std.ArrayList(u8) = .empty,
    kind: Kind = .char,
    /// Block registers: the display width of the block (rows are padded to
    /// it when put before other text).
    width: usize = 0,

    pub fn slice(self: *const Reg) []const u8 {
        return self.text.items;
    }

    pub fn isLinewise(self: *const Reg) bool {
        return self.kind == .line;
    }
};

fn kindOf(linewise: bool) Kind {
    return if (linewise) .line else .char;
}

const slot_unnamed = 0;
const slot_small = 1;
const slot_num = 2; // "0..."9 → 2..11
const slot_named = 12; // "a..."z → 12..37
const n_slots = 38;

pub const Registers = struct {
    slots: [n_slots]Reg = @splat(.{}),
    /// A register has been written since init/clear (for the unnamed one).
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registers {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registers) void {
        for (&self.slots) |*r| r.text.deinit(self.allocator);
    }

    pub fn clear(self: *Registers) void {
        for (&self.slots) |*r| {
            r.text.clearRetainingCapacity();
            r.kind = .char;
            r.width = 0;
        }
    }

    pub fn isValidName(c: u8) bool {
        return slotOf(c) != null or c == '_';
    }

    fn slotOf(c: u8) ?usize {
        return switch (c) {
            '"' => slot_unnamed,
            '-' => slot_small,
            '0'...'9' => slot_num + (c - '0'),
            'a'...'z' => slot_named + (c - 'a'),
            'A'...'Z' => slot_named + (c - 'A'),
            else => null,
        };
    }

    /// Register to read for `name` (null = unnamed). Null for `"_` and
    /// unknown names.
    pub fn get(self: *const Registers, name: ?u8) ?*const Reg {
        const s = slotOf(name orelse '"') orelse return null;
        return &self.slots[s];
    }

    fn write(self: *Registers, slot: usize, text: []const u8, kind: Kind, width: usize, append: bool) !void {
        const r = &self.slots[slot];
        if (append and r.text.items.len > 0) {
            if (kind != .char or r.kind != .char) {
                try r.text.append(self.allocator, '\n');
                if (r.kind == .char) r.kind = kind;
                r.width = @max(r.width, width);
            }
            try r.text.appendSlice(self.allocator, text);
        } else {
            r.text.clearRetainingCapacity();
            try r.text.appendSlice(self.allocator, text);
            r.kind = kind;
            r.width = width;
        }
    }

    fn copySlot(self: *Registers, dst: usize, src: usize) !void {
        if (dst == src) return;
        const s = &self.slots[src];
        try self.write(dst, s.text.items, s.kind, s.width, false);
    }

    /// Writes a named register (if any) and makes the unnamed one follow it.
    /// Returns false when `name` is not a writable named register.
    fn writeNamed(self: *Registers, name: u8, text: []const u8, kind: Kind, width: usize) !bool {
        if (name < 'a' and !(name >= 'A' and name <= 'Z')) return false;
        if (name > 'z') return false;
        const slot = slotOf(name) orelse return false;
        if (slot < slot_named) return false;
        try self.write(slot, text, kind, width, name >= 'A' and name <= 'Z');
        try self.copySlot(slot_unnamed, slot);
        return true;
    }

    /// Store the text of a yank.
    pub fn yank(self: *Registers, name: ?u8, text: []const u8, linewise: bool) !void {
        return self.yankKind(name, text, kindOf(linewise), 0);
    }

    /// Store a yank of any kind (`width`: block registers).
    pub fn yankKind(self: *Registers, name: ?u8, text: []const u8, kind: Kind, width: usize) !void {
        if (name) |n| {
            if (n == '_') return;
            if (try self.writeNamed(n, text, kind, width)) return;
        }
        try self.write(slot_num, text, kind, width, false);
        try self.copySlot(slot_unnamed, slot_num);
    }

    /// Store the text of a delete or change. `force_ring` puts small
    /// deletes into "1 too (Vim does that for % ( ) / ? n N { }).
    pub fn delete(self: *Registers, name: ?u8, text: []const u8, linewise: bool, force_ring: bool) !void {
        return self.deleteKind(name, text, kindOf(linewise), 0, force_ring);
    }

    pub fn deleteKind(self: *Registers, name: ?u8, text: []const u8, kind: Kind, width: usize, force_ring: bool) !void {
        if (name == @as(?u8, '_')) return;
        const named = if (name) |n| try self.writeNamed(n, text, kind, width) else false;
        const big = kind == .line or std.mem.indexOfScalar(u8, text, '\n') != null or force_ring;
        if (big) {
            // Shift "1.."8 into "2.."9.
            var i: usize = 9;
            while (i > 1) : (i -= 1) {
                std.mem.swap(Reg, &self.slots[slot_num + i], &self.slots[slot_num + i - 1]);
            }
            try self.write(slot_num + 1, text, kind, width, false);
            if (!named) try self.copySlot(slot_unnamed, slot_num + 1);
        } else if (!named) {
            try self.write(slot_small, text, kind, width, false);
            try self.copySlot(slot_unnamed, slot_small);
        }
    }

    /// Set a register directly (macro recording).
    pub fn set(self: *Registers, name: u8, text: []const u8, linewise: bool) !void {
        const slot = slotOf(name) orelse return;
        try self.write(slot, text, kindOf(linewise), 0, name >= 'A' and name <= 'Z');
    }
};

const testing = std.testing;

test "registers: yank, delete ring, small delete, append, black hole" {
    var r = Registers.init(testing.allocator);
    defer r.deinit();
    try r.yank(null, "abc", false);
    try testing.expectEqualStrings("abc", r.get('0').?.slice());
    try r.delete(null, "line", true, false);
    try testing.expectEqualStrings("line", r.get('1').?.slice());
    try testing.expectEqualStrings("line", r.get(null).?.slice());
    try r.delete(null, "two", true, false);
    try testing.expectEqualStrings("line", r.get('2').?.slice());
    try r.delete(null, "x", false, false);
    try testing.expectEqualStrings("x", r.get('-').?.slice());
    try testing.expectEqualStrings("two", r.get('1').?.slice());
    try r.yank('a', "foo", false);
    try r.yank('A', "bar", false);
    try testing.expectEqualStrings("foobar", r.get('a').?.slice());
    try r.delete('_', "gone", true, false);
    try testing.expectEqualStrings("foobar", r.get(null).?.slice());
    try testing.expectEqualStrings("abc", r.get('0').?.slice());
}
