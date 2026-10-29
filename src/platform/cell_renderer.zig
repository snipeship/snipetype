//! Cell grid renderer for WASM/Web.
//! Writes to a cell buffer that JavaScript reads directly from WASM memory.

const std = @import("std");
const Color = @import("../ui/color.zig").Color;
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const Cell = renderer_mod.Cell;
const CellFlags = renderer_mod.CellFlags;

pub const CellRenderer = struct {
    cells: []Cell,
    width: usize,
    height: usize,
    cursor_x: usize,
    cursor_y: usize,
    current_fg: Color,
    current_bg: Color,
    default_fg: Color,
    default_bg: Color,
    is_bold: bool,
    is_underline: bool = false,
    dirty: bool,
    dirty_min_x: usize,
    dirty_min_y: usize,
    dirty_max_x: usize,
    dirty_max_y: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !CellRenderer {
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, Cell.EMPTY);
        return .{
            .cells = cells,
            .width = width,
            .height = height,
            .cursor_x = 0,
            .cursor_y = 0,
            .current_fg = Color.WHITE,
            .current_bg = Color.BLACK,
            .default_fg = Color.WHITE,
            .default_bg = Color.BLACK,
            .is_bold = false,
            .dirty = true,
            .dirty_min_x = 0,
            .dirty_min_y = 0,
            .dirty_max_x = width,
            .dirty_max_y = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CellRenderer) void {
        self.allocator.free(self.cells);
    }

    pub fn resize(self: *CellRenderer, new_width: usize, new_height: usize) !void {
        if (new_width == self.width and new_height == self.height) return;

        const new_cells = try self.allocator.alloc(Cell, new_width * new_height);
        @memset(new_cells, Cell.EMPTY);

        // Copy existing content
        const copy_w = @min(self.width, new_width);
        const copy_h = @min(self.height, new_height);
        for (0..copy_h) |y| {
            const src_start = y * self.width;
            const dst_start = y * new_width;
            @memcpy(new_cells[dst_start .. dst_start + copy_w], self.cells[src_start .. src_start + copy_w]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;
        self.markFullDirty();
    }

    /// Get pointer to cell grid (for JavaScript to read directly)
    pub fn getCellsPtr(self: *const CellRenderer) [*]const Cell {
        return self.cells.ptr;
    }

    /// Get size of cell grid in bytes
    pub fn getCellsSize(self: *const CellRenderer) usize {
        return self.cells.len * @sizeOf(Cell);
    }

    /// Check if grid needs redraw
    pub fn isDirty(self: *const CellRenderer) bool {
        return self.dirty;
    }

    /// Get dirty region for incremental updates
    pub const DirtyRegion = struct {
        x: usize,
        y: usize,
        w: usize,
        h: usize,
    };

    pub fn getDirtyRegion(self: *const CellRenderer) DirtyRegion {
        if (!self.dirty) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{
            .x = self.dirty_min_x,
            .y = self.dirty_min_y,
            .w = self.dirty_max_x -| self.dirty_min_x,
            .h = self.dirty_max_y -| self.dirty_min_y,
        };
    }

    /// Clear dirty flag after rendering
    pub fn clearDirty(self: *CellRenderer) void {
        self.dirty = false;
        self.dirty_min_x = self.width;
        self.dirty_min_y = self.height;
        self.dirty_max_x = 0;
        self.dirty_max_y = 0;
    }

    /// Get the abstract Renderer interface
    pub fn renderer(self: *CellRenderer) Renderer {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ========================================================================
    // VTable implementation
    // ========================================================================

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

    fn moveTo(ptr: *anyopaque, x: usize, y: usize) void {
        const self = cast(ptr);
        self.cursor_x = x;
        self.cursor_y = y;
    }

    fn setFg(ptr: *anyopaque, c: Color) void {
        const self = cast(ptr);
        self.current_fg = c;
    }

    fn setBg(ptr: *anyopaque, c: Color) void {
        const self = cast(ptr);
        self.current_bg = c;
    }

    fn setBold(ptr: *anyopaque, b: bool) void {
        const self = cast(ptr);
        self.is_bold = b;
    }

    fn setUnderline(ptr: *anyopaque, on: bool) void {
        const self = cast(ptr);
        self.is_underline = on;
    }

    fn resetStyle(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.current_fg = self.default_fg;
        self.current_bg = self.default_bg;
        self.is_bold = false;
        self.is_underline = false;
    }

    fn write(ptr: *anyopaque, s: []const u8) void {
        const self = cast(ptr);
        for (s) |char| {
            self.setCell(self.cursor_x, self.cursor_y, char);
            self.cursor_x += 1;
        }
    }

    fn writeByte(ptr: *anyopaque, b: u8) void {
        const self = cast(ptr);
        self.setCell(self.cursor_x, self.cursor_y, b);
        self.cursor_x += 1;
    }

    fn clear(ptr: *anyopaque) void {
        const self = cast(ptr);
        const empty_cell = Cell{
            .char = ' ',
            .flags = 0,
            .fg_r = self.default_fg.r,
            .fg_g = self.default_fg.g,
            .fg_b = self.default_fg.b,
            .bg_r = self.default_bg.r,
            .bg_g = self.default_bg.g,
            .bg_b = self.default_bg.b,
        };
        @memset(self.cells, empty_cell);
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.markFullDirty();
    }

    fn clearLine(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.cursor_y >= self.height) return;

        const empty_cell = Cell{
            .char = ' ',
            .flags = 0,
            .fg_r = self.default_fg.r,
            .fg_g = self.default_fg.g,
            .fg_b = self.default_fg.b,
            .bg_r = self.default_bg.r,
            .bg_g = self.default_bg.g,
            .bg_b = self.default_bg.b,
        };

        const start = self.cursor_y * self.width;
        const end = start + self.width;
        @memset(self.cells[start..end], empty_cell);
        self.markDirtyRow(self.cursor_y);
    }

    fn flush(ptr: *anyopaque) void {
        // No-op for cell renderer - JS reads cells directly
        _ = ptr;
    }

    fn getWidth(ptr: *anyopaque) usize {
        const self = cast(ptr);
        return self.width;
    }

    fn getHeight(ptr: *anyopaque) usize {
        const self = cast(ptr);
        return self.height;
    }

    fn setDefaultColors(ptr: *anyopaque, fg: Color, bg: Color) void {
        const self = cast(ptr);
        self.default_fg = fg;
        self.default_bg = bg;
        self.current_fg = fg;
        self.current_bg = bg;
    }

    fn setUseTerminalDefaults(ptr: *anyopaque, use_defaults: bool) void {
        // No-op for cell renderer - web always needs explicit colors
        _ = ptr;
        _ = use_defaults;
    }

    // ========================================================================
    // Helper methods
    // ========================================================================

    fn cast(ptr: *anyopaque) *CellRenderer {
        return @ptrCast(@alignCast(ptr));
    }

    fn setCell(self: *CellRenderer, x: usize, y: usize, char: u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = y * self.width + x;
        self.cells[idx] = .{
            .char = char,
            .flags = @bitCast(CellFlags{ .bold = self.is_bold, .underline = self.is_underline }),
            .fg_r = self.current_fg.r,
            .fg_g = self.current_fg.g,
            .fg_b = self.current_fg.b,
            .bg_r = self.current_bg.r,
            .bg_g = self.current_bg.g,
            .bg_b = self.current_bg.b,
        };
        self.markDirty(x, y);
    }

    fn markDirty(self: *CellRenderer, x: usize, y: usize) void {
        self.dirty = true;
        self.dirty_min_x = @min(self.dirty_min_x, x);
        self.dirty_min_y = @min(self.dirty_min_y, y);
        self.dirty_max_x = @max(self.dirty_max_x, x + 1);
        self.dirty_max_y = @max(self.dirty_max_y, y + 1);
    }

    fn markDirtyRow(self: *CellRenderer, y: usize) void {
        self.dirty = true;
        self.dirty_min_x = 0;
        self.dirty_min_y = @min(self.dirty_min_y, y);
        self.dirty_max_x = self.width;
        self.dirty_max_y = @max(self.dirty_max_y, y + 1);
    }

    fn markFullDirty(self: *CellRenderer) void {
        self.dirty = true;
        self.dirty_min_x = 0;
        self.dirty_min_y = 0;
        self.dirty_max_x = self.width;
        self.dirty_max_y = self.height;
    }
};
