//! The frame a graphical scene renders into.
//!
//! A `Surface` covers the whole terminal grid (`cols` x `rows` cells) with
//! two layers:
//!   - `pixels`: an opaque RGBA8 framebuffer of `w` x `h` pixels stretched
//!     over the grid. Its resolution depends on the presenter backend
//!     (half-block: cols x rows*2; kitty / web: several pixels per cell).
//!   - `text`: one optional glyph per cell drawn on top of the pixels with
//!     the terminal's own font (crisp legends, HUD labels).
//!
//! Presenters (src/gfx/) turn a Surface into terminal output; the web host
//! blits `pixels` to a canvas under the terminal instead.

const std = @import("std");
const Color = @import("../ui/color.zig").Color;

/// One pixel, laid out as R,G,B,A bytes (matches ImageData and kitty f=32).
pub const Px = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const black: Px = .{ .r = 0, .g = 0, .b = 0 };

    pub fn fromColor(c: Color) Px {
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }

    pub fn toColor(self: Px) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }
};

pub const TextCell = struct {
    /// Codepoint to draw; 0 = no text (pixels show through).
    cp: u21 = 0,
    fg: Color = Color.WHITE,
    /// Opaque cell background; null = let the pixel layer show through.
    bg: ?Color = null,
    bold: bool = false,
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    w: u32,
    h: u32,
    pixels: []Px,
    text: []TextCell,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, w: u32, h: u32) !Surface {
        const pixels = try allocator.alloc(Px, @as(usize, w) * h);
        errdefer allocator.free(pixels);
        const text = try allocator.alloc(TextCell, @as(usize, cols) * rows);
        @memset(pixels, Px.black);
        @memset(text, .{});
        return .{ .allocator = allocator, .cols = cols, .rows = rows, .w = w, .h = h, .pixels = pixels, .text = text };
    }

    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.text);
    }

    /// Reallocate if the grid or pixel size changed. Contents are cleared.
    pub fn resize(self: *Surface, cols: u16, rows: u16, w: u32, h: u32) !void {
        if (cols == self.cols and rows == self.rows and w == self.w and h == self.h) return;
        const allocator = self.allocator;
        self.deinit();
        self.* = try Surface.init(allocator, cols, rows, w, h);
    }

    /// Horizontal pixels per cell.
    pub fn pxPerCol(self: *const Surface) f32 {
        return @as(f32, @floatFromInt(self.w)) / @as(f32, @floatFromInt(@max(self.cols, 1)));
    }

    /// Vertical pixels per cell.
    pub fn pxPerRow(self: *const Surface) f32 {
        return @as(f32, @floatFromInt(self.h)) / @as(f32, @floatFromInt(@max(self.rows, 1)));
    }

    pub fn clearText(self: *Surface) void {
        @memset(self.text, .{});
    }

    pub fn textAt(self: *Surface, col: usize, row: usize) ?*TextCell {
        if (col >= self.cols or row >= self.rows) return null;
        return &self.text[row * self.cols + col];
    }

    /// Write UTF-8 `s` into the text layer starting at (col, row). Clips.
    pub fn putText(self: *Surface, col: i32, row: i32, s: []const u8, fg: Color, bg: ?Color, bold: bool) void {
        if (row < 0 or row >= self.rows) return;
        var x = col;
        var it = (std.unicode.Utf8View.init(s) catch return).iterator();
        while (it.nextCodepoint()) |cp| : (x += 1) {
            if (x < 0) continue;
            const cell = self.textAt(@intCast(x), @intCast(row)) orelse return;
            cell.* = .{ .cp = cp, .fg = fg, .bg = bg, .bold = bold };
        }
    }
};
