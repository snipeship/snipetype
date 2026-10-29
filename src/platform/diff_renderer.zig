//! Diffing renderer for the classic modes (contract C7).
//!
//! Implements the `Renderer` vtable into a back grid of cells (the screen
//! as the app means it) and, on `flush`, emits only the cells that differ
//! from the front grid (the screen as the terminal shows it) through an
//! `AnsiRenderer`: changed runs per row, one cursor move per run, SGR only
//! where the pen changes. A typing frame that changes one letter costs a
//! few dozen bytes instead of a full repaint.
//!
//! - The back grid persists between frames like a terminal screen; only
//!   `clear` / `clearLine` erase it. `clear` also forces a full repaint
//!   (the app clears on resets, resizes, theme and overlay changes).
//! - Text is clipped at the right edge (never wraps); one codepoint is one
//!   column (the UI only draws single-width glyphs).
//! - `write` of bytes starting with ESC is forwarded verbatim at the start
//!   of the next flush (e.g. the arcade teardown queued in
//!   `App.pending_buf`); the terminal's SGR state is then unknown and is
//!   reset before the next cell.
//! - Every flush ends with a cursor move to the last `moveTo` position so
//!   the host's hardware cursor lands where it asked.
//! - `invalidate` forces a full repaint (resize, leaving arcade).
//!
//! Arcade frames never go through here: they keep the plain AnsiRenderer.

const std = @import("std");
const Color = @import("../ui/color.zig").Color;
const Renderer = @import("renderer.zig").Renderer;
const AnsiRenderer = @import("ansi_renderer.zig").AnsiRenderer;

/// One screen cell: a UTF-8 glyph (one column) and its style. `fg`/`bg`
/// are ignored when the matching `*_default` flag is set (the terminal's
/// own colors, `use_terminal_defaults`).
pub const Cell = struct {
    glyph: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u8 = 1,
    fg: Color = Color.WHITE,
    bg: Color = Color.BLACK,
    fg_default: bool = true,
    bg_default: bool = true,
    bold: bool = false,
    underline: bool = false,

    pub fn eql(a: Cell, b: Cell) bool {
        if (a.len != b.len or !std.mem.eql(u8, a.glyph[0..a.len], b.glyph[0..b.len])) return false;
        if (a.fg_default != b.fg_default or a.bg_default != b.bg_default) return false;
        if (a.bold != b.bold or a.underline != b.underline) return false;
        if (!a.fg_default and !colorEql(a.fg, b.fg)) return false;
        if (!a.bg_default and !colorEql(a.bg, b.bg)) return false;
        return true;
    }

    pub fn text(self: *const Cell) []const u8 {
        return self.glyph[0..self.len];
    }
};

fn colorEql(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// The current pen (style applied to written text).
const Pen = struct {
    fg: Color = Color.WHITE,
    bg: Color = Color.BLACK,
    fg_default: bool = true,
    bg_default: bool = true,
    bold: bool = false,
    underline: bool = false,
};

/// Unchanged cells shorter than this between two changed ones are
/// re-emitted instead of jumping over them (a cursor move costs ~8 bytes).
const GAP_MERGE: usize = 4;

pub const DiffRenderer = struct {
    allocator: std.mem.Allocator,
    out: *AnsiRenderer,
    w: usize = 0,
    h: usize = 0,
    back: []Cell = &.{},
    front: []Cell = &.{},
    /// Next flush repaints every cell.
    full: bool = true,
    /// Pen position (moveTo / write).
    cx: usize = 0,
    cy: usize = 0,
    pen: Pen = .{},
    default_fg: Color = Color.WHITE,
    default_bg: Color = Color.BLACK,
    use_terminal_defaults: bool = false,
    /// Raw escape sequences to forward at the start of the next flush.
    raw: std.ArrayList(u8) = .empty,
    /// What the terminal's SGR state is (valid when `sgr_known`).
    term_pen: Pen = .{},
    sgr_known: bool = false,
    /// Terminal cursor position while emitting (null: unknown).
    term_x: ?usize = null,
    term_y: usize = 0,

    pub fn init(allocator: std.mem.Allocator, out: *AnsiRenderer, width: usize, height: usize) !DiffRenderer {
        var d: DiffRenderer = .{ .allocator = allocator, .out = out };
        try d.setSize(width, height);
        return d;
    }

    pub fn deinit(self: *DiffRenderer) void {
        self.allocator.free(self.back);
        self.allocator.free(self.front);
        self.raw.deinit(self.allocator);
    }

    /// Resize both grids (contents are dropped) and force a full repaint.
    pub fn setSize(self: *DiffRenderer, width: usize, height: usize) !void {
        const n = width * height;
        if (n != self.back.len) {
            const back = try self.allocator.alloc(Cell, n);
            errdefer self.allocator.free(back);
            const front = try self.allocator.alloc(Cell, n);
            self.allocator.free(self.back);
            self.allocator.free(self.front);
            self.back = back;
            self.front = front;
        }
        self.w = width;
        self.h = height;
        self.out.setSize(width, height);
        @memset(self.back, self.blank());
        self.invalidate();
    }

    /// The next flush repaints everything (the terminal's screen is unknown).
    pub fn invalidate(self: *DiffRenderer) void {
        self.full = true;
        self.sgr_known = false;
        self.term_x = null;
    }

    pub fn renderer(self: *DiffRenderer) Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The cell at (x, y) of the back grid (tests).
    pub fn cellAt(self: *const DiffRenderer, x: usize, y: usize) Cell {
        return self.back[y * self.w + x];
    }

    const vtable = Renderer.VTable{
        .moveTo = moveTo,
        .setFg = setFg,
        .setBg = setBg,
        .setBold = setBold,
        .setUnderline = setUnderline,
        .resetStyle = resetStyle,
        .write = write,
        .writeByte = writeByte,
        .clear = clear,
        .clearLine = clearLine,
        .flush = flush,
        .getWidth = getWidth,
        .getHeight = getHeight,
        .setDefaultColors = setDefaultColors,
        .setUseTerminalDefaults = setUseTerminalDefaults,
    };

    fn cast(ptr: *anyopaque) *DiffRenderer {
        return @ptrCast(@alignCast(ptr));
    }

    /// The pen after a reset (SGR 0 plus the explicit default colors).
    fn resetPen(self: *const DiffRenderer) Pen {
        if (self.use_terminal_defaults) return .{};
        return .{ .fg = self.default_fg, .bg = self.default_bg, .fg_default = false, .bg_default = false };
    }

    /// An erased cell.
    fn blank(self: *const DiffRenderer) Cell {
        const p = self.resetPen();
        return .{ .fg = p.fg, .bg = p.bg, .fg_default = p.fg_default, .bg_default = p.bg_default };
    }

    fn moveTo(ptr: *anyopaque, x: usize, y: usize) void {
        const self = cast(ptr);
        self.cx = x;
        self.cy = y;
    }

    fn setFg(ptr: *anyopaque, c: Color) void {
        const self = cast(ptr);
        self.pen.fg = c;
        self.pen.fg_default = false;
    }

    fn setBg(ptr: *anyopaque, c: Color) void {
        const self = cast(ptr);
        self.pen.bg = c;
        self.pen.bg_default = false;
    }

    fn setBold(ptr: *anyopaque, b: bool) void {
        cast(ptr).pen.bold = b;
    }

    fn setUnderline(ptr: *anyopaque, on: bool) void {
        cast(ptr).pen.underline = on;
    }

    fn resetStyle(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.pen = self.resetPen();
    }

    fn write(ptr: *anyopaque, s: []const u8) void {
        const self = cast(ptr);
        if (s.len > 0 and s[0] == 0x1b) {
            self.raw.appendSlice(self.allocator, s) catch {};
            return;
        }
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(s.len, i + n);
            self.put(s[i..end]);
            i = end;
        }
    }

    fn writeByte(ptr: *anyopaque, b: u8) void {
        const self = cast(ptr);
        self.put(&.{b});
    }

    /// Draw one glyph at the pen position (clipped) and advance.
    fn put(self: *DiffRenderer, g: []const u8) void {
        // Control bytes draw nothing (the UI positions with moveTo).
        if (g.len == 1 and (g[0] < 0x20 or g[0] == 0x7f)) return;
        if (self.cx < self.w and self.cy < self.h) {
            var cell: Cell = .{
                .len = @intCast(@min(g.len, 4)),
                .fg = self.pen.fg,
                .bg = self.pen.bg,
                .fg_default = self.pen.fg_default,
                .bg_default = self.pen.bg_default,
                .bold = self.pen.bold,
                .underline = self.pen.underline,
            };
            @memcpy(cell.glyph[0..cell.len], g[0..cell.len]);
            self.back[self.cy * self.w + self.cx] = cell;
        }
        self.cx +|= 1;
    }

    fn clear(ptr: *anyopaque) void {
        const self = cast(ptr);
        @memset(self.back, self.blank());
        self.cx = 0;
        self.cy = 0;
        self.pen = self.resetPen();
        // Clears happen on resets, resizes and theme/overlay changes: repaint
        // everything so nothing stale survives on the terminal.
        self.invalidate();
    }

    fn clearLine(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.cy < self.h) @memset(self.back[self.cy * self.w ..][0..self.w], self.blank());
        self.cx = 0;
        if (!self.use_terminal_defaults) self.pen = self.resetPen();
    }

    fn getWidth(ptr: *anyopaque) usize {
        return cast(ptr).w;
    }

    fn getHeight(ptr: *anyopaque) usize {
        return cast(ptr).h;
    }

    fn setDefaultColors(ptr: *anyopaque, fg: Color, bg: Color) void {
        const self = cast(ptr);
        self.default_fg = fg;
        self.default_bg = bg;
        self.out.renderer().setDefaultColors(fg, bg);
    }

    fn setUseTerminalDefaults(ptr: *anyopaque, use_defaults: bool) void {
        const self = cast(ptr);
        self.use_terminal_defaults = use_defaults;
        self.out.renderer().setUseTerminalDefaults(use_defaults);
    }

    // ------------------------------------------------------------------
    // Emitting

    fn flush(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.emit();
        self.out.renderer().flush();
    }

    /// Diff back against front into `out` (without flushing it).
    pub fn emit(self: *DiffRenderer) void {
        const o = self.out.renderer();
        if (self.raw.items.len > 0) {
            o.write(self.raw.items);
            self.raw.clearRetainingCapacity();
            self.sgr_known = false;
            self.term_x = null;
        }
        for (0..self.h) |y| self.emitRow(y);
        @memcpy(self.front, self.back);
        self.full = false;
        // The hardware cursor goes where the app last moved the pen.
        if (self.w > 0 and self.h > 0) self.cup(@min(self.cx, self.w - 1), @min(self.cy, self.h - 1));
    }

    fn changed(self: *const DiffRenderer, i: usize) bool {
        return self.full or !self.back[i].eql(self.front[i]);
    }

    fn emitRow(self: *DiffRenderer, y: usize) void {
        const row = y * self.w;
        var x: usize = 0;
        while (x < self.w) {
            if (!self.changed(row + x)) {
                x += 1;
                continue;
            }
            // A run of changed cells, bridging short unchanged gaps.
            var end = x + 1;
            var gap: usize = 0;
            var i = end;
            while (i < self.w) : (i += 1) {
                if (self.changed(row + i)) {
                    end = i + 1;
                    gap = 0;
                } else {
                    gap += 1;
                    if (gap > GAP_MERGE) break;
                }
            }
            self.cup(x, y);
            for (x..end) |cx| self.emitCell(self.back[row + cx]);
            // Writing the last column leaves a pending wrap: position unknown.
            self.term_x = if (end >= self.w) null else end;
            x = end;
        }
    }

    fn cup(self: *DiffRenderer, x: usize, y: usize) void {
        if (self.term_x) |tx| {
            if (tx == x and self.term_y == y) return;
        }
        self.out.renderer().print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
        self.term_x = x;
        self.term_y = y;
    }

    fn emitCell(self: *DiffRenderer, c: Cell) void {
        const o = self.out.renderer();
        const t = &self.term_pen;
        if (!self.sgr_known) {
            o.write("\x1b[0m");
            t.* = .{};
            self.sgr_known = true;
        }
        if (t.bold != c.bold) {
            o.write(if (c.bold) "\x1b[1m" else "\x1b[22m");
            t.bold = c.bold;
        }
        if (t.underline != c.underline) {
            o.write(if (c.underline) "\x1b[4m" else "\x1b[24m");
            t.underline = c.underline;
        }
        if (c.fg_default) {
            if (!t.fg_default) o.write("\x1b[39m");
        } else if (t.fg_default or !colorEql(t.fg, c.fg)) {
            o.print("\x1b[38;2;{d};{d};{d}m", .{ c.fg.r, c.fg.g, c.fg.b });
        }
        t.fg_default = c.fg_default;
        t.fg = c.fg;
        if (c.bg_default) {
            if (!t.bg_default) o.write("\x1b[49m");
        } else if (t.bg_default or !colorEql(t.bg, c.bg)) {
            o.print("\x1b[48;2;{d};{d};{d}m", .{ c.bg.r, c.bg.g, c.bg.b });
        }
        t.bg_default = c.bg_default;
        t.bg = c.bg;
        o.write(c.text());
    }
};

// ----------------------------------------------------------------------------
// Tests

const testing = std.testing;

const red: Color = .{ .r = 200, .g = 10, .b = 10 };
const blue: Color = .{ .r = 10, .g = 10, .b = 200 };

const Harness = struct {
    ansi: AnsiRenderer,
    diff: DiffRenderer,

    fn init(self: *Harness, w: usize, h: usize) !void {
        self.ansi = AnsiRenderer.init(testing.allocator, w, h);
        self.diff = try DiffRenderer.init(testing.allocator, &self.ansi, w, h);
        // Terminal-default colors, blank screen.
        const r = self.diff.renderer();
        r.setUseTerminalDefaults(true);
        r.resetStyle();
        r.clear();
    }

    fn deinit(self: *Harness) void {
        self.diff.deinit();
        self.ansi.deinit();
    }

    /// Emit the pending diff and take the bytes.
    fn frame(self: *Harness, buf: []u8) []const u8 {
        self.diff.emit();
        const out = self.ansi.output();
        const n = @min(out.len, buf.len);
        @memcpy(buf[0..n], out[0..n]);
        self.ansi.clearBuffer();
        return buf[0..n];
    }
};

test "identical frame emits only the cursor" {
    var hs: Harness = undefined;
    try hs.init(10, 3);
    defer hs.deinit();
    const r = hs.diff.renderer();
    r.setUseTerminalDefaults(true);
    r.moveTo(1, 1);
    r.write("hello");
    var buf: [4096]u8 = undefined;
    _ = hs.frame(&buf);
    r.moveTo(1, 1);
    r.write("hello");
    r.moveTo(3, 2);
    try testing.expectEqualStrings("\x1b[3;4H", hs.frame(&buf));
}

test "one changed letter emits one short sequence" {
    var hs: Harness = undefined;
    try hs.init(20, 3);
    defer hs.deinit();
    const r = hs.diff.renderer();
    r.setUseTerminalDefaults(true);
    r.moveTo(0, 0);
    r.write("the quick fox");
    var buf: [4096]u8 = undefined;
    _ = hs.frame(&buf);
    r.moveTo(4, 0);
    r.write("Q");
    r.moveTo(5, 0);
    // Only the changed cell: CUP, the letter, then the cursor (already there).
    try testing.expectEqualStrings("\x1b[1;5HQ", hs.frame(&buf));
}

test "colors, bold and underline transitions" {
    var hs: Harness = undefined;
    try hs.init(10, 1);
    defer hs.deinit();
    const r = hs.diff.renderer();
    r.setUseTerminalDefaults(true);
    var buf: [4096]u8 = undefined;
    _ = hs.frame(&buf);
    r.moveTo(0, 0);
    r.setFg(red);
    r.setBold(true);
    r.write("a");
    r.setBold(false);
    r.setUnderline(true);
    r.setBg(blue);
    r.write("b");
    r.resetStyle();
    r.write("c");
    r.moveTo(3, 0);
    try testing.expectEqualStrings(
        "\x1b[1m\x1b[38;2;200;10;10ma\x1b[22m\x1b[4m\x1b[48;2;10;10;200mb\x1b[24m\x1b[39m\x1b[49mc",
        hs.frame(&buf),
    );
    // Themed defaults: a reset pen paints explicit colors.
    r.setUseTerminalDefaults(false);
    r.setDefaultColors(red, blue);
    r.resetStyle();
    r.moveTo(0, 0);
    r.write("x");
    r.moveTo(1, 0);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[38;2;200;10;10m\x1b[48;2;10;10;200mx", hs.frame(&buf));
}

test "utf-8 glyphs and clipping at the right edge" {
    var hs: Harness = undefined;
    try hs.init(4, 2);
    defer hs.deinit();
    const r = hs.diff.renderer();
    r.setUseTerminalDefaults(true);
    r.moveTo(1, 0);
    r.write("╭─é·xyz");
    try testing.expectEqualStrings("╭", hs.diff.cellAt(1, 0).text());
    try testing.expectEqualStrings("é", hs.diff.cellAt(3, 0).text());
    // Clipped: nothing reached the next row.
    try testing.expectEqualStrings(" ", hs.diff.cellAt(0, 1).text());
    r.moveTo(9, 9);
    r.write("out of bounds");
    var buf: [4096]u8 = undefined;
    const out = hs.frame(&buf);
    try testing.expect(std.mem.indexOf(u8, out, "╭─é") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x") == null);
}

test "raw escapes pass through and reset the known SGR state" {
    var hs: Harness = undefined;
    try hs.init(4, 1);
    defer hs.deinit();
    const r = hs.diff.renderer();
    r.setUseTerminalDefaults(true);
    var buf: [4096]u8 = undefined;
    _ = hs.frame(&buf);
    r.write("\x1b_Ga=d\x1b\\\x1b[0m");
    r.moveTo(0, 0);
    r.write("a");
    r.moveTo(1, 0);
    try testing.expectEqualStrings("\x1b_Ga=d\x1b\\\x1b[0m\x1b[1;1H\x1b[0ma", hs.frame(&buf));
}

test "invalidate and clear repaint everything" {
    var hs: Harness = undefined;
    try hs.init(3, 2);
    defer hs.deinit();
    const r = hs.diff.renderer();
    r.setUseTerminalDefaults(true);
    r.moveTo(0, 0);
    r.write("ab");
    var buf: [4096]u8 = undefined;
    _ = hs.frame(&buf);
    hs.diff.invalidate();
    const full = hs.frame(&buf);
    // 6 cells: "ab" plus four blanks.
    try testing.expect(std.mem.indexOf(u8, full, "ab ") != null);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, full, " "));
    r.clear();
    try testing.expectEqualStrings(" ", hs.diff.cellAt(0, 0).text());
    try testing.expect(std.mem.count(u8, hs.frame(&buf), " ") == 6);
}

/// A tiny VT interpreter for the replay test: CUP, CHA, ED 2, EL 2, the SGR
/// codes the renderers use, text (clipped at the right edge).
const Screen = struct {
    const W = 24;
    const H = 6;
    cells: [H][W]Cell = @splat(@splat(.{})),
    x: usize = 0,
    y: usize = 0,
    pen: Pen = .{},

    fn feed(self: *Screen, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
                var j = i + 2;
                while (j < bytes.len and (bytes[j] < 0x40 or bytes[j] > 0x7e)) j += 1;
                if (j >= bytes.len) return;
                self.csi(bytes[i + 2 .. j], bytes[j]);
                i = j + 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            const g = bytes[i..@min(bytes.len, i + n)];
            if (self.x < W and self.y < H) {
                var c: Cell = .{ .len = @intCast(g.len), .fg = self.pen.fg, .bg = self.pen.bg, .fg_default = self.pen.fg_default, .bg_default = self.pen.bg_default, .bold = self.pen.bold, .underline = self.pen.underline };
                @memcpy(c.glyph[0..g.len], g);
                self.cells[self.y][self.x] = c;
            }
            self.x += 1;
            i += g.len;
        }
    }

    fn erased(self: *const Screen) Cell {
        return .{ .bg = self.pen.bg, .bg_default = self.pen.bg_default, .fg = self.pen.fg, .fg_default = self.pen.fg_default };
    }

    fn csi(self: *Screen, params: []const u8, final: u8) void {
        var nums: [8]u32 = @splat(0);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |p| : (n += 1) {
            if (n < nums.len) nums[n] = std.fmt.parseInt(u32, p, 10) catch 0;
        }
        switch (final) {
            'H' => {
                self.y = @max(nums[0], 1) - 1;
                self.x = @max(nums[1], 1) - 1;
            },
            'G' => self.x = @max(nums[0], 1) - 1,
            'J' => for (&self.cells) |*row| {
                @memset(row, self.erased());
            },
            'K' => if (self.y < H) @memset(&self.cells[self.y], self.erased()),
            'm' => {
                var k: usize = 0;
                if (n == 0) n = 1;
                while (k < n) : (k += 1) {
                    switch (nums[k]) {
                        0 => self.pen = .{},
                        1 => self.pen.bold = true,
                        22 => self.pen.bold = false,
                        4 => self.pen.underline = true,
                        24 => self.pen.underline = false,
                        39 => self.pen.fg_default = true,
                        49 => self.pen.bg_default = true,
                        38, 48 => {
                            const c: Color = .{ .r = @intCast(nums[k + 2]), .g = @intCast(nums[k + 3]), .b = @intCast(nums[k + 4]) };
                            if (nums[k] == 38) {
                                self.pen.fg = c;
                                self.pen.fg_default = false;
                            } else {
                                self.pen.bg = c;
                                self.pen.bg_default = false;
                            }
                            k += 4;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn eql(a: *const Screen, b: *const Screen) bool {
        for (0..H) |y| {
            for (0..W) |x| {
                if (!a.cells[y][x].eql(b.cells[y][x])) return false;
            }
        }
        return true;
    }
};

/// A small frame using every renderer call.
fn drawFrame(r: Renderer, step: usize) void {
    r.setUseTerminalDefaults(step % 2 == 0);
    r.setDefaultColors(.{ .r = 1, .g = 2, .b = 3 }, .{ .r = 4, .g = 5, .b = 6 });
    r.resetStyle();
    if (step == 0) r.clear();
    r.moveTo(0, 1);
    r.clearLine();
    r.moveTo(2, 1);
    r.setFg(red);
    r.write(if (step == 1) "typed text" else "typed tExt");
    r.setBold(true);
    r.setBg(blue);
    r.write("│é");
    r.resetStyle();
    r.moveTo(20, 3);
    r.setUnderline(true);
    r.write("clipped here");
    r.resetStyle();
    r.moveTo(0, 5);
    r.print("{d} wpm", .{40 + step});
}

test "diffed frames replay to the same screen as plain frames" {
    var plain = AnsiRenderer.init(testing.allocator, Screen.W, Screen.H);
    defer plain.deinit();
    var hs: Harness = undefined;
    try hs.init(Screen.W, Screen.H);
    defer hs.deinit();
    var want: Screen = .{};
    var got: Screen = .{};
    var buf: [16384]u8 = undefined;
    for (0..4) |step| {
        // The plain renderer would wrap past the right edge; the screen
        // model clips, as the diff renderer does.
        drawFrame(plain.renderer(), step);
        want.feed(plain.output());
        plain.clearBuffer();
        drawFrame(hs.diff.renderer(), step);
        got.feed(hs.frame(&buf));
        try testing.expect(want.eql(&got));
    }
}
