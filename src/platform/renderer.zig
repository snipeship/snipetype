//! Abstract renderer interface.
//! Implementations: AnsiRenderer (native), CellRenderer (web)

const std = @import("std");
const Color = @import("../ui/color.zig").Color;

/// Cell flags for text attributes
pub const CellFlags = packed struct {
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _padding: u5 = 0,
};

/// A single cell in the grid (8 bytes, extern for WASM memory layout)
pub const Cell = extern struct {
    char: u8,
    flags: u8, // CellFlags packed as u8
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,

    pub const EMPTY: Cell = .{
        .char = ' ',
        .flags = 0,
        .fg_r = 255,
        .fg_g = 255,
        .fg_b = 255,
        .bg_r = 0,
        .bg_g = 0,
        .bg_b = 0,
    };

    pub fn withColors(char: u8, fg: Color, bg: Color, bold: bool) Cell {
        return .{
            .char = char,
            .flags = if (bold) 1 else 0,
            .fg_r = fg.r,
            .fg_g = fg.g,
            .fg_b = fg.b,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
        };
    }
};

/// Abstract renderer interface using vtable pattern
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        moveTo: *const fn (*anyopaque, usize, usize) void,
        setFg: *const fn (*anyopaque, Color) void,
        setBg: *const fn (*anyopaque, Color) void,
        setBold: *const fn (*anyopaque, bool) void,
        resetStyle: *const fn (*anyopaque) void,
        write: *const fn (*anyopaque, []const u8) void,
        writeByte: *const fn (*anyopaque, u8) void,
        clear: *const fn (*anyopaque) void,
        clearLine: *const fn (*anyopaque) void,
        flush: *const fn (*anyopaque) void,
        getWidth: *const fn (*anyopaque) usize,
        getHeight: *const fn (*anyopaque) usize,
        setDefaultColors: *const fn (*anyopaque, Color, Color) void,
    };

    // Forwarding methods
    pub inline fn moveTo(self: Renderer, x: usize, y: usize) void {
        self.vtable.moveTo(self.ptr, x, y);
    }

    pub inline fn setFg(self: Renderer, c: Color) void {
        self.vtable.setFg(self.ptr, c);
    }

    pub inline fn setBg(self: Renderer, c: Color) void {
        self.vtable.setBg(self.ptr, c);
    }

    pub inline fn setBold(self: Renderer, b: bool) void {
        self.vtable.setBold(self.ptr, b);
    }

    pub inline fn resetStyle(self: Renderer) void {
        self.vtable.resetStyle(self.ptr);
    }

    pub inline fn write(self: Renderer, s: []const u8) void {
        self.vtable.write(self.ptr, s);
    }

    pub inline fn writeByte(self: Renderer, b: u8) void {
        self.vtable.writeByte(self.ptr, b);
    }

    pub inline fn clear(self: Renderer) void {
        self.vtable.clear(self.ptr);
    }

    pub inline fn clearLine(self: Renderer) void {
        self.vtable.clearLine(self.ptr);
    }

    pub inline fn flush(self: Renderer) void {
        self.vtable.flush(self.ptr);
    }

    pub inline fn width(self: Renderer) usize {
        return self.vtable.getWidth(self.ptr);
    }

    pub inline fn height(self: Renderer) usize {
        return self.vtable.getHeight(self.ptr);
    }

    pub inline fn setDefaultColors(self: Renderer, fg: Color, bg: Color) void {
        self.vtable.setDefaultColors(self.ptr, fg, bg);
    }

    /// Print formatted text
    pub fn print(self: Renderer, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(slice);
    }
};
