//! Half-block presenter: two pixels per cell using U+2580 (upper half block).
//!
//! Every cell shows a top and a bottom pixel: `▀` with fg = top, bg = bottom
//! (or `▄` with the roles swapped when that reuses the current pen), or a
//! plain space on bg when both halves match. Text cells print their glyph
//! with fg = text color and bg = TextCell.bg orelse the blend of the two
//! pixels underneath. Output is diffed against the previously emitted frame
//! and is run-length friendly: SGR only when the pen changes, CUP only when
//! the next changed cell is not adjacent. Pure computation (wasm-safe).

const std = @import("std");
const ansi = @import("ansi.zig");
const surface_mod = @import("../fx/surface.zig");
const Surface = surface_mod.Surface;
const Px = surface_mod.Px;

pub const upper_half: u21 = 0x2580;
pub const lower_half: u21 = 0x2584;

/// A cell as last emitted. `cp == 0`: pixel cell with `a` = top, `b` = bottom.
/// Otherwise a text glyph with `a` = fg, `b` = bg.
pub const Shown = struct {
    cp: u21 = 0,
    a: u24 = 0,
    b: u24 = 0,
    bold: bool = false,

    pub fn eql(x: Shown, y: Shown) bool {
        return x.cp == y.cp and x.a == y.a and x.b == y.b and x.bold == y.bold;
    }
};

/// Quantize one channel by dropping `bits` low bits (re-centred so the
/// result stays close to the input).
pub inline fn quantChannel(v: u8, bits: u3) u8 {
    if (bits == 0) return v;
    const mask: u8 = @as(u8, 0xff) << bits;
    const half: u8 = @as(u8, 1) << (bits - 1);
    return (v & mask) | half;
}

pub inline fn quantPx(p: Px, bits: u3) u24 {
    return (@as(u24, quantChannel(p.r, bits)) << 16) |
        (@as(u24, quantChannel(p.g, bits)) << 8) |
        quantChannel(p.b, bits);
}

/// Blend two packed colors in (approximately) linear light: per channel
/// sqrt((a² + b²) / 2).
pub fn blend(x: u24, y: u24) u24 {
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const a: u32 = @as(u8, @truncate(x >> sh));
        const b: u32 = @as(u8, @truncate(y >> sh));
        const m: u24 = std.math.sqrt((a * a + b * b + 1) / 2);
        out |= @as(u24, @min(m, 255)) << sh;
    }
    return out;
}

pub const HalfBlock = struct {
    gpa: std.mem.Allocator,
    cols: u16 = 0,
    rows: u16 = 0,
    prev: []Shown = &.{},
    valid: bool = false,
    /// Low bits dropped from every pixel channel before diffing (0..4).
    quant_bits: u3 = 0,
    /// Cells written by the last `emit`.
    last_cells: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, quant_bits: u3) HalfBlock {
        return .{ .gpa = gpa, .quant_bits = quant_bits };
    }

    pub fn deinit(self: *HalfBlock) void {
        self.gpa.free(self.prev);
        self.prev = &.{};
    }

    pub fn invalidate(self: *HalfBlock) void {
        self.valid = false;
    }

    fn ensureSize(self: *HalfBlock, cols: u16, rows: u16) !void {
        const n = @as(usize, cols) * rows;
        if (cols == self.cols and rows == self.rows and self.prev.len == n) return;
        const fresh = try self.gpa.alloc(Shown, n);
        self.gpa.free(self.prev);
        self.prev = fresh;
        self.cols = cols;
        self.rows = rows;
        self.valid = false;
    }

    /// Top/bottom pixel for cell (c, r). Exact when the surface is
    /// cols × rows*2, nearest-sample otherwise.
    inline fn sample(s: *const Surface, c: usize, r: usize, exact: bool) [2]Px {
        if (exact) {
            const w: usize = s.w;
            return .{ s.pixels[(2 * r) * w + c], s.pixels[(2 * r + 1) * w + c] };
        }
        if (s.w == 0 or s.h == 0) return .{ Px.black, Px.black };
        const cols: usize = @max(s.cols, 1);
        const rows4: usize = @as(usize, @max(s.rows, 1)) * 4;
        const x = @min(((2 * c + 1) * s.w) / (2 * cols), s.w - 1);
        const yt = @min(((4 * r + 1) * s.h) / rows4, s.h - 1);
        const yb = @min(((4 * r + 3) * s.h) / rows4, s.h - 1);
        return .{ s.pixels[yt * s.w + x], s.pixels[yb * s.w + x] };
    }

    /// Append the diff between the last emitted frame and `s` to `buf`.
    pub fn emit(self: *HalfBlock, buf: *ansi.Buf, pen: *ansi.Pen, cur: *ansi.Cursor, s: *const Surface) !void {
        try self.ensureSize(s.cols, s.rows);
        const full = !self.valid;
        const exact = s.w == s.cols and s.h == @as(u32, s.rows) * 2;
        const cols: u32 = s.cols;
        const q = self.quant_bits;
        var cells: u32 = 0;
        for (0..s.rows) |r| {
            const row_off = r * cols;
            for (0..cols) |c| {
                const px = sample(s, c, r, exact);
                const top = quantPx(px[0], q);
                const bot = quantPx(px[1], q);
                const tc = s.text[row_off + c];
                var now: Shown = .{ .a = top, .b = bot };
                if (tc.cp != 0) {
                    const bg = if (tc.bg) |b| ansi.pack(b) else blend(top, bot);
                    const cp = ansi.printable(tc.cp);
                    now = if (cp == ' ')
                        .{ .a = bg, .b = bg } // blank text cell = solid bg
                    else
                        .{ .cp = cp, .a = ansi.pack(tc.fg), .b = bg, .bold = tc.bold };
                }
                const old = &self.prev[row_off + c];
                if (!full and old.eql(now)) continue;
                try cur.moveTo(buf, @intCast(r), @intCast(c));
                try writeCell(buf, pen, now);
                if (now.cp == 0 or now.cp < 0x80) cur.advance(cols) else cur.invalidate();
                old.* = now;
                cells += 1;
            }
        }
        self.valid = true;
        self.last_cells = cells;
    }

    fn writeCell(buf: *ansi.Buf, pen: *ansi.Pen, cell: Shown) !void {
        if (cell.cp != 0) {
            try pen.apply(buf, .{ .fg = .{ .rgb = cell.a }, .bg = cell.b, .bold = cell.bold });
            return buf.utf8(cell.cp);
        }
        const top = cell.a;
        const bot = cell.b;
        if (top == bot) {
            try pen.apply(buf, .{ .fg = .any, .bg = top, .bold = null });
            return buf.byte(' ');
        }
        // Pick the orientation that reuses more of the current pen.
        var use_lower = false;
        if (pen.valid) {
            const up: u2 = @as(u2, @intFromBool(pen.fg == top)) + @intFromBool(pen.bg == bot);
            const lo: u2 = @as(u2, @intFromBool(pen.fg == bot)) + @intFromBool(pen.bg == top);
            use_lower = lo > up;
        }
        if (use_lower) {
            try pen.apply(buf, .{ .fg = .{ .rgb = bot }, .bg = top, .bold = null });
            try buf.utf8(lower_half);
        } else {
            try pen.apply(buf, .{ .fg = .{ .rgb = top }, .bg = bot, .bold = null });
            try buf.utf8(upper_half);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Color = @import("../ui/color.zig").Color;

fn emitOnce(hb: *HalfBlock, buf: *ansi.Buf, s: *const Surface) !void {
    buf.clear();
    var pen: ansi.Pen = .{};
    var cur: ansi.Cursor = .{};
    try hb.emit(buf, &pen, &cur, s);
}

test "quantize and blend" {
    try testing.expectEqual(@as(u8, 0xab), quantChannel(0xab, 0));
    try testing.expectEqual(@as(u8, 0xaa), quantChannel(0xab, 2));
    try testing.expectEqual(@as(u8, 0xfe), quantChannel(0xff, 2));
    try testing.expectEqual(@as(u24, 0x808080), blend(0x808080, 0x808080));
    // linear-ish: blend of black and white is brighter than 127
    const g = blend(0x000000, 0xffffff);
    try testing.expectEqual(@as(u24, 180), g & 0xff);
    try testing.expectEqual(g >> 16, g & 0xff);
}

test "pixel cell maps top to fg and bottom to bg" {
    var s = try Surface.init(testing.allocator, 2, 1, 2, 2);
    defer s.deinit();
    s.pixels[0] = .{ .r = 255, .g = 0, .b = 0 }; // (0,0) top
    s.pixels[2] = .{ .r = 0, .g = 0, .b = 255 }; // (0,1) bottom
    s.pixels[1] = .{ .r = 9, .g = 9, .b = 9 }; // col 1 uniform
    s.pixels[3] = .{ .r = 9, .g = 9, .b = 9 };
    var hb = HalfBlock.init(testing.allocator, 0);
    defer hb.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&hb, &buf, &s);
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[0;38;2;255;0;0;48;2;0;0;255m\u{2580}" ++
            "\x1b[48;2;9;9;9m ",
        buf.bytes(),
    );
    // unchanged: nothing
    try emitOnce(&hb, &buf, &s);
    try testing.expectEqualStrings("", buf.bytes());
    // change only the right cell's bottom: one CUP + one cell
    s.pixels[3] = .{ .r = 0, .g = 255, .b = 0 };
    try emitOnce(&hb, &buf, &s);
    try testing.expectEqualStrings("\x1b[1;2H\x1b[0;38;2;9;9;9;48;2;0;255;0m\u{2580}", buf.bytes());
}

test "text cell uses text fg and blended or explicit bg" {
    var s = try Surface.init(testing.allocator, 2, 1, 2, 2);
    defer s.deinit();
    @memset(s.pixels, .{ .r = 100, .g = 100, .b = 100 });
    s.text[0] = .{ .cp = 'A', .fg = Color.rgb(1, 2, 3), .bold = true };
    s.text[1] = .{ .cp = 'B', .fg = Color.rgb(1, 2, 3), .bg = Color.rgb(7, 8, 9) };
    var hb = HalfBlock.init(testing.allocator, 0);
    defer hb.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&hb, &buf, &s);
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[0;1;38;2;1;2;3;48;2;100;100;100mA" ++
            "\x1b[22;48;2;7;8;9mB",
        buf.bytes(),
    );
}

test "lower half chosen when it reuses the pen; adjacent cells skip CUP" {
    var s = try Surface.init(testing.allocator, 3, 1, 3, 2);
    defer s.deinit();
    const red: Px = .{ .r = 255, .g = 0, .b = 0 };
    const blue: Px = .{ .r = 0, .g = 0, .b = 255 };
    // cell0: red/blue, cell1: blue/red (swap) -> ▄ reuses the pen fully
    s.pixels[0] = red;
    s.pixels[3] = blue;
    s.pixels[1] = blue;
    s.pixels[4] = red;
    s.pixels[2] = red;
    s.pixels[5] = blue;
    var hb = HalfBlock.init(testing.allocator, 0);
    defer hb.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&hb, &buf, &s);
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[0;38;2;255;0;0;48;2;0;0;255m\u{2580}\u{2584}\u{2580}",
        buf.bytes(),
    );
}

test "non-exact surface size is nearest-sampled" {
    var s = try Surface.init(testing.allocator, 1, 1, 4, 4);
    defer s.deinit();
    for (0..4) |y| for (0..4) |x| {
        s.pixels[y * 4 + x] = if (y < 2) .{ .r = 10, .g = 0, .b = 0 } else .{ .r = 0, .g = 20, .b = 0 };
    };
    var hb = HalfBlock.init(testing.allocator, 0);
    defer hb.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&hb, &buf, &s);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[0;38;2;10;0;0;48;2;0;20;0m\u{2580}", buf.bytes());
}
