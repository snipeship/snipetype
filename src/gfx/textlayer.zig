//! Diffed text-layer emission for the kitty and external presenters.
//!
//! Each frame the Surface's text layer is normalised into `Shown` cells and
//! compared with what was emitted last frame; only changed cells are written
//! (CUP + minimal SGR + glyph). Cells without text are written as a space on
//! the terminal's DEFAULT background so whatever is under the text grid (a
//! kitty image at z=-1, or the web canvas) shows through.

const std = @import("std");
const ansi = @import("ansi.zig");
const surface_mod = @import("../fx/surface.zig");
const Surface = surface_mod.Surface;
const TextCell = surface_mod.TextCell;

/// A cell as it appears on the terminal. `bg == null` = default background.
pub const Shown = struct {
    cp: u21 = ' ',
    fg: u24 = 0,
    bg: ?u24 = null,
    bold: bool = false,

    /// Normalise a text cell: non-text and blank cells only depend on bg.
    pub fn of(cell: TextCell) Shown {
        const cp = if (cell.cp == 0) ' ' else ansi.printable(cell.cp);
        const bg: ?u24 = if (cell.bg) |c| ansi.pack(c) else null;
        if (cp == ' ') return .{ .bg = bg };
        return .{ .cp = cp, .fg = ansi.pack(cell.fg), .bg = bg, .bold = cell.bold };
    }

    pub fn eql(a: Shown, b: Shown) bool {
        return a.cp == b.cp and a.fg == b.fg and a.bold == b.bold and
            std.meta.eql(a.bg, b.bg);
    }
};

pub const TextLayer = struct {
    gpa: std.mem.Allocator,
    cols: u16 = 0,
    rows: u16 = 0,
    prev: []Shown = &.{},
    /// false = next emit repaints every cell.
    valid: bool = false,
    /// Cells written by the last `emit`.
    last_cells: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) TextLayer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TextLayer) void {
        self.gpa.free(self.prev);
        self.prev = &.{};
    }

    pub fn invalidate(self: *TextLayer) void {
        self.valid = false;
    }

    fn ensureSize(self: *TextLayer, cols: u16, rows: u16) !void {
        if (cols == self.cols and rows == self.rows and self.prev.len == @as(usize, cols) * rows) return;
        const n = @as(usize, cols) * rows;
        const fresh = try self.gpa.alloc(Shown, n);
        self.gpa.free(self.prev);
        self.prev = fresh;
        self.cols = cols;
        self.rows = rows;
        self.valid = false;
    }

    /// Append the diff between the last emitted frame and `s.text` to `buf`.
    pub fn emit(self: *TextLayer, buf: *ansi.Buf, pen: *ansi.Pen, cur: *ansi.Cursor, s: *const Surface) !void {
        try self.ensureSize(s.cols, s.rows);
        const full = !self.valid;
        var cells: u32 = 0;
        const cols: u32 = s.cols;
        for (0..s.rows) |r| {
            const row_off = r * cols;
            for (0..cols) |c| {
                const now = Shown.of(s.text[row_off + c]);
                const old = &self.prev[row_off + c];
                if (!full and old.eql(now)) continue;
                try cur.moveTo(buf, @intCast(r), @intCast(c));
                if (now.cp == ' ') {
                    try pen.apply(buf, .{ .fg = .any, .bg = now.bg, .bold = null });
                } else {
                    try pen.apply(buf, .{ .fg = .{ .rgb = now.fg }, .bg = now.bg, .bold = now.bold });
                }
                try buf.utf8(now.cp);
                if (now.cp < 0x80) cur.advance(cols) else cur.invalidate(); // width unknown
                old.* = now;
                cells += 1;
            }
        }
        self.valid = true;
        self.last_cells = cells;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Color = @import("../ui/color.zig").Color;

fn emitOnce(tl: *TextLayer, buf: *ansi.Buf, s: *const Surface) !void {
    buf.clear();
    var pen: ansi.Pen = .{};
    var cur: ansi.Cursor = .{};
    try tl.emit(buf, &pen, &cur, s);
}

test "first emit repaints every cell with default bg spaces" {
    var s = try Surface.init(testing.allocator, 3, 2, 3, 2);
    defer s.deinit();
    var tl = TextLayer.init(testing.allocator);
    defer tl.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&tl, &buf, &s);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[0m   \x1b[2;1H   ", buf.bytes());
    try testing.expectEqual(@as(u32, 6), tl.last_cells);
    // unchanged frame: no output at all
    try emitOnce(&tl, &buf, &s);
    try testing.expectEqualStrings("", buf.bytes());
}

test "diff emits only changed cells with CUP and minimal SGR" {
    var s = try Surface.init(testing.allocator, 10, 3, 10, 3);
    defer s.deinit();
    var tl = TextLayer.init(testing.allocator);
    defer tl.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&tl, &buf, &s);

    s.putText(2, 1, "hi", Color.rgb(255, 107, 74), null, true);
    s.putText(7, 1, "X", Color.rgb(255, 107, 74), Color.rgb(19, 20, 50), false);
    try emitOnce(&tl, &buf, &s);
    try testing.expectEqualStrings(
        "\x1b[2;3H\x1b[0;1;38;2;255;107;74mhi" ++
            "\x1b[2;8H\x1b[22;48;2;19;20;50mX",
        buf.bytes(),
    );

    // remove "h": becomes a default-bg space; fg untouched
    s.text[1 * 10 + 2] = .{};
    try emitOnce(&tl, &buf, &s);
    try testing.expectEqualStrings("\x1b[2;3H\x1b[0m ", buf.bytes());

    // invalidate forces a full repaint
    tl.invalidate();
    try emitOnce(&tl, &buf, &s);
    try testing.expectEqual(@as(u32, 30), tl.last_cells);
}

test "non-ascii glyph forces CUP for the next cell; controls are sanitised" {
    var s = try Surface.init(testing.allocator, 4, 1, 4, 1);
    defer s.deinit();
    var tl = TextLayer.init(testing.allocator);
    defer tl.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&tl, &buf, &s);
    s.text[0] = .{ .cp = 0x00d7, .fg = Color.WHITE }; // ×
    s.text[1] = .{ .cp = 'a', .fg = Color.WHITE };
    s.text[2] = .{ .cp = 0x1b, .fg = Color.WHITE }; // ESC must never be printed
    try emitOnce(&tl, &buf, &s);
    // the ESC cell normalises to a blank, which is unchanged: not emitted
    try testing.expectEqualStrings("\x1b[1;1H\x1b[0;38;2;255;255;255m\u{d7}\x1b[1;2Ha", buf.bytes());
}

test "resize reallocates and repaints" {
    var s = try Surface.init(testing.allocator, 2, 1, 2, 1);
    defer s.deinit();
    var tl = TextLayer.init(testing.allocator);
    defer tl.deinit();
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try emitOnce(&tl, &buf, &s);
    try s.resize(5, 2, 5, 2);
    try emitOnce(&tl, &buf, &s);
    try testing.expectEqual(@as(u32, 10), tl.last_cells);
}
