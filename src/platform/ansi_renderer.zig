//! ANSI escape sequence renderer for native terminals.
//! Buffers output and flushes to stdout.

const std = @import("std");
const Color = @import("../ui/color.zig").Color;
const Renderer = @import("renderer.zig").Renderer;

pub const AnsiRenderer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    term_width: usize,
    term_height: usize,
    default_fg: Color,
    default_bg: Color,
    use_terminal_defaults: bool,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) AnsiRenderer {
        return .{
            .data = std.ArrayList(u8){},
            .allocator = allocator,
            .term_width = width,
            .term_height = height,
            .default_fg = Color.WHITE,
            .default_bg = Color.BLACK,
            .use_terminal_defaults = false,
        };
    }

    pub fn deinit(self: *AnsiRenderer) void {
        self.data.deinit(self.allocator);
    }

    pub fn setSize(self: *AnsiRenderer, width: usize, height: usize) void {
        self.term_width = width;
        self.term_height = height;
    }

    pub fn renderer(self: *AnsiRenderer) Renderer {
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
        self.appendFmt("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    fn setFg(ptr: *anyopaque, c: Color) void {
        const self = cast(ptr);
        self.appendFmt("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    }

    fn setBg(ptr: *anyopaque, c: Color) void {
        const self = cast(ptr);
        self.appendFmt("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    }

    fn setBold(ptr: *anyopaque, b: bool) void {
        const self = cast(ptr);
        if (b) {
            self.appendSlice("\x1b[1m");
        } else {
            self.appendSlice("\x1b[22m");
        }
    }

    fn resetStyle(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.appendSlice("\x1b[0m");
        // Only re-apply colors if not using terminal defaults
        if (!self.use_terminal_defaults) {
            self.appendFmt("\x1b[38;2;{d};{d};{d}m", .{ self.default_fg.r, self.default_fg.g, self.default_fg.b });
            self.appendFmt("\x1b[48;2;{d};{d};{d}m", .{ self.default_bg.r, self.default_bg.g, self.default_bg.b });
        }
    }

    fn write(ptr: *anyopaque, s: []const u8) void {
        const self = cast(ptr);
        self.appendSlice(s);
    }

    fn writeByte(ptr: *anyopaque, b: u8) void {
        const self = cast(ptr);
        self.data.append(self.allocator, b) catch {};
    }

    fn clear(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.appendSlice("\x1b[2J\x1b[H");
    }

    fn clearLine(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.appendSlice("\x1b[2K");
    }

    fn flush(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.data.items.len == 0) return;

        const posix = std.posix;
        var remaining = self.data.items;
        while (remaining.len > 0) {
            const n = posix.write(posix.STDOUT_FILENO, remaining) catch return;
            if (n == 0) return;
            remaining = remaining[n..];
        }
        self.data.clearRetainingCapacity();
    }

    fn getWidth(ptr: *anyopaque) usize {
        const self = cast(ptr);
        return self.term_width;
    }

    fn getHeight(ptr: *anyopaque) usize {
        const self = cast(ptr);
        return self.term_height;
    }

    fn setDefaultColors(ptr: *anyopaque, fg: Color, bg: Color) void {
        const self = cast(ptr);
        self.default_fg = fg;
        self.default_bg = bg;
    }

    fn setUseTerminalDefaults(ptr: *anyopaque, use_defaults: bool) void {
        const self = cast(ptr);
        self.use_terminal_defaults = use_defaults;
    }

    // ========================================================================
    // Helper methods
    // ========================================================================

    fn cast(ptr: *anyopaque) *AnsiRenderer {
        return @ptrCast(@alignCast(ptr));
    }

    fn appendSlice(self: *AnsiRenderer, s: []const u8) void {
        self.data.appendSlice(self.allocator, s) catch {};
    }

    fn appendFmt(self: *AnsiRenderer, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.data.writer(self.allocator), fmt, args) catch {};
    }

    // ========================================================================
    // Additional ANSI helpers for sync mode
    // ========================================================================

    pub fn beginSync(self: *AnsiRenderer) void {
        self.appendSlice("\x1b[?2026h");
    }

    pub fn endSync(self: *AnsiRenderer) void {
        self.appendSlice("\x1b[?2026l");
    }

    pub fn hideCursor(self: *AnsiRenderer) void {
        self.appendSlice("\x1b[?25l");
    }

    pub fn showCursor(self: *AnsiRenderer) void {
        self.appendSlice("\x1b[?25h");
    }

    pub fn clearBuffer(self: *AnsiRenderer) void {
        self.data.clearRetainingCapacity();
    }
};
