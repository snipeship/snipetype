//! Low-level ANSI output helpers shared by the presenters.
//!
//! `Buf` is a growable byte buffer with fast integer/UTF-8 appends, `Pen`
//! tracks the terminal's current SGR state so only changed attributes are
//! emitted, and `Cursor` tracks the cursor position so CUP is skipped when
//! the next changed cell is directly to the right of the previous one.
//! Everything here is pure computation (wasm-safe).

const std = @import("std");
const Color = @import("../ui/color.zig").Color;

pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";
pub const sgr_reset = "\x1b[0m";

/// Pack a color as 0xRRGGBB.
pub inline fn pack(c: Color) u24 {
    return (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | c.b;
}

pub inline fn unpack(v: u24) Color {
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

/// Growable output buffer. Bytes stay valid until the next `clear`.
pub const Buf = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Buf {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Buf) void {
        self.list.deinit(self.gpa);
    }

    pub fn clear(self: *Buf) void {
        self.list.clearRetainingCapacity();
    }

    pub fn bytes(self: *const Buf) []const u8 {
        return self.list.items;
    }

    pub fn len(self: *const Buf) usize {
        return self.list.items.len;
    }

    pub fn str(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.gpa, s);
    }

    pub fn byte(self: *Buf, b: u8) !void {
        try self.list.append(self.gpa, b);
    }

    /// Decimal unsigned integer.
    pub fn uint(self: *Buf, v: u64) !void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var x = v;
        while (true) {
            i -= 1;
            tmp[i] = @intCast('0' + x % 10);
            x /= 10;
            if (x == 0) break;
        }
        try self.str(tmp[i..]);
    }

    /// Decimal signed integer.
    pub fn int(self: *Buf, v: i64) !void {
        if (v < 0) {
            try self.byte('-');
            try self.uint(@abs(v));
        } else try self.uint(@intCast(v));
    }

    /// Lowercase hex, no prefix.
    pub fn hex(self: *Buf, v: u32) !void {
        var tmp: [8]u8 = undefined;
        var i: usize = tmp.len;
        var x = v;
        while (true) {
            i -= 1;
            tmp[i] = "0123456789abcdef"[x & 15];
            x >>= 4;
            if (x == 0) break;
        }
        try self.str(tmp[i..]);
    }

    /// UTF-8 encode `cp`; invalid scalars become U+FFFD.
    pub fn utf8(self: *Buf, cp: u21) !void {
        if (cp < 0x80) return self.byte(@intCast(cp));
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try self.str(tmp[0..n]);
    }

    /// Append the standard (padded) base64 of `src`.
    pub fn base64(self: *Buf, src: []const u8) !void {
        const enc = std.base64.standard.Encoder;
        const n = enc.calcSize(src.len);
        try self.list.ensureUnusedCapacity(self.gpa, n);
        const dst = self.list.unusedCapacitySlice()[0..n];
        _ = enc.encode(dst, src);
        self.list.items.len += n;
    }
};

/// Tracked SGR state. `fg`/`bg` null = terminal default color.
pub const Pen = struct {
    valid: bool = false,
    fg: ?u24 = null,
    bg: ?u24 = null,
    bold: bool = false,

    /// What a cell needs. `fg == .any` / `bold == null` mean "don't care"
    /// (e.g. a space only needs its background).
    pub const Want = struct {
        fg: Fg = .any,
        bg: ?u24 = null,
        bold: ?bool = null,
    };

    pub const Fg = union(enum) { any, default, rgb: u24 };

    /// Forget the terminal state; the next `apply` starts with SGR 0.
    pub fn invalidate(self: *Pen) void {
        self.valid = false;
    }

    /// Emit the minimal SGR sequence to reach `want`.
    pub fn apply(self: *Pen, buf: *Buf, want: Want) !void {
        var params: [48]u8 = undefined;
        var w: std.Io.Writer = .fixed(&params);
        var first = true;
        if (!self.valid) {
            w.writeAll("0") catch unreachable;
            first = false;
            self.* = .{ .valid = true };
        }
        if (want.bold) |b| if (b != self.bold) {
            sep(&w, &first);
            w.writeAll(if (b) "1" else "22") catch unreachable;
            self.bold = b;
        };
        switch (want.fg) {
            .any => {},
            .default => if (self.fg != null) {
                sep(&w, &first);
                w.writeAll("39") catch unreachable;
                self.fg = null;
            },
            .rgb => |c| if (self.fg == null or self.fg.? != c) {
                sep(&w, &first);
                rgbParam(&w, "38", c);
                self.fg = c;
            },
        }
        if (want.bg) |c| {
            if (self.bg == null or self.bg.? != c) {
                sep(&w, &first);
                rgbParam(&w, "48", c);
                self.bg = c;
            }
        } else if (self.bg != null) {
            sep(&w, &first);
            w.writeAll("49") catch unreachable;
            self.bg = null;
        }
        if (first) return; // nothing changed
        try buf.str("\x1b[");
        try buf.str(w.buffered());
        try buf.byte('m');
    }

    fn sep(w: *std.Io.Writer, first: *bool) void {
        if (!first.*) w.writeByte(';') catch unreachable;
        first.* = false;
    }

    fn rgbParam(w: *std.Io.Writer, lead: []const u8, c: u24) void {
        w.print("{s};2;{d};{d};{d}", .{ lead, @as(u8, @truncate(c >> 16)), @as(u8, @truncate(c >> 8)), @as(u8, @truncate(c)) }) catch unreachable;
    }
};

/// Tracked cursor position (0-based).
pub const Cursor = struct {
    known: bool = false,
    row: u32 = 0,
    col: u32 = 0,

    pub fn invalidate(self: *Cursor) void {
        self.known = false;
    }

    /// Move to (row, col) with CUP unless already there.
    pub fn moveTo(self: *Cursor, buf: *Buf, row: u32, col: u32) !void {
        if (self.known and self.row == row and self.col == col) return;
        try buf.str("\x1b[");
        try buf.uint(row + 1);
        try buf.byte(';');
        try buf.uint(col + 1);
        try buf.byte('H');
        self.* = .{ .known = true, .row = row, .col = col };
    }

    /// Account for one printed single-width glyph. At the right edge the
    /// terminal enters the pending-wrap state, so the position is forgotten.
    pub fn advance(self: *Cursor, cols: u32) void {
        self.col += 1;
        if (self.col >= cols) self.known = false;
    }
};

/// Map a text-layer codepoint to something safe to print: control
/// characters and invalid scalars become a space.
pub fn printable(cp: u21) u21 {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return ' ';
    if (cp >= 0xd800 and cp <= 0xdfff) return ' ';
    if (cp > 0x10ffff) return ' ';
    return cp;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Buf numbers and utf8" {
    var b = Buf.init(testing.allocator);
    defer b.deinit();
    try b.uint(0);
    try b.byte(' ');
    try b.uint(4294967295);
    try b.byte(' ');
    try b.int(-12);
    try b.byte(' ');
    try b.hex(0x5E000001);
    try b.byte(' ');
    try b.utf8(0x2580);
    try b.utf8('A');
    try testing.expectEqualStrings("0 4294967295 -12 5e000001 \u{2580}A", b.bytes());
}

test "Pen emits minimal SGR" {
    var b = Buf.init(testing.allocator);
    defer b.deinit();
    var pen: Pen = .{};
    try pen.apply(&b, .{ .fg = .{ .rgb = 0xff0000 }, .bg = null, .bold = false });
    try testing.expectEqualStrings("\x1b[0;38;2;255;0;0m", b.bytes());
    b.clear();
    // same state: nothing
    try pen.apply(&b, .{ .fg = .{ .rgb = 0xff0000 }, .bg = null, .bold = false });
    try testing.expectEqualStrings("", b.bytes());
    // only bg changes
    try pen.apply(&b, .{ .fg = .any, .bg = 0x0a0b0c });
    try testing.expectEqualStrings("\x1b[48;2;10;11;12m", b.bytes());
    b.clear();
    // bold on + back to default bg
    try pen.apply(&b, .{ .fg = .{ .rgb = 0xff0000 }, .bg = null, .bold = true });
    try testing.expectEqualStrings("\x1b[1;49m", b.bytes());
    b.clear();
    try pen.apply(&b, .{ .fg = .default, .bold = false });
    try testing.expectEqualStrings("\x1b[22;39m", b.bytes());
}

test "Cursor skips adjacent CUP and forgets at right edge" {
    var b = Buf.init(testing.allocator);
    defer b.deinit();
    var cur: Cursor = .{};
    try cur.moveTo(&b, 0, 0);
    try testing.expectEqualStrings("\x1b[1;1H", b.bytes());
    cur.advance(3);
    b.clear();
    try cur.moveTo(&b, 0, 1);
    try testing.expectEqualStrings("", b.bytes());
    cur.advance(3);
    cur.advance(3); // col 3 == cols: pending wrap
    try cur.moveTo(&b, 1, 0);
    try testing.expectEqualStrings("\x1b[2;1H", b.bytes());
}

test "printable" {
    try testing.expectEqual(@as(u21, ' '), printable(0x1b));
    try testing.expectEqual(@as(u21, ' '), printable(0x9b));
    try testing.expectEqual(@as(u21, 'x'), printable('x'));
    try testing.expectEqual(@as(u21, 0x2580), printable(0x2580));
}
