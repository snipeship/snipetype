//! ANSI escape sequence renderer.
//! Buffers output; on native targets `flush` writes it to stdout, on wasm
//! the bytes are kept for the JS host to drain (see `output`/`clearBuffer`)
//! and hand to the browser terminal emulator (ghostty-web).

const std = @import("std");
const builtin = @import("builtin");

/// On wasm there is no stdout: frames accumulate until the host drains them.
const is_wasm = builtin.target.cpu.arch.isWasm();
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
            .data = std.ArrayList(u8).empty,
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

    fn setUnderline(ptr: *anyopaque, on: bool) void {
        const self = cast(ptr);
        self.appendSlice(if (on) "\x1b[4m" else "\x1b[24m");
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
        if (!self.use_terminal_defaults) {
            // Fill entire screen with spaces to ensure background is applied
            // (ANSI erase codes don't reliably use the current bg color)
            self.appendFmt("\x1b[48;2;{d};{d};{d}m", .{ self.default_bg.r, self.default_bg.g, self.default_bg.b });
            self.appendFmt("\x1b[38;2;{d};{d};{d}m", .{ self.default_fg.r, self.default_fg.g, self.default_fg.b });
            for (0..self.term_height) |_| {
                for (0..self.term_width) |_| {
                    self.data.append(self.allocator, ' ') catch {};
                }
            }
            self.appendSlice("\x1b[H"); // Return home
        }
    }

    fn clearLine(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (!self.use_terminal_defaults) {
            // Move to column 1, set bg, fill with spaces, stay at end
            self.appendSlice("\x1b[1G"); // Move to column 1
            self.appendFmt("\x1b[48;2;{d};{d};{d}m", .{ self.default_bg.r, self.default_bg.g, self.default_bg.b });
            self.appendFmt("\x1b[38;2;{d};{d};{d}m", .{ self.default_fg.r, self.default_fg.g, self.default_fg.b });
            for (0..self.term_width) |_| {
                self.data.append(self.allocator, ' ') catch {};
            }
            self.appendSlice("\x1b[1G"); // Move back to column 1
        } else {
            self.appendSlice("\x1b[2K");
        }
    }

    fn flush(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.data.items.len == 0) return;
        // wasm: keep the bytes; the host reads `output()` after the tick.
        if (comptime is_wasm) return;

        @import("stdout.zig").writeAll(self.data.items);
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
        self.data.print(self.allocator, fmt, args) catch {};
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

    /// Bytes buffered since the last flush (native) or drain (wasm).
    /// Valid until the next renderer call.
    pub fn output(self: *const AnsiRenderer) []const u8 {
        return self.data.items;
    }

    /// Set the cursor shape with DECSCUSR (steady block or steady bar).
    pub fn setCursorShape(self: *AnsiRenderer, shape: CursorShape) void {
        self.appendSlice(switch (shape) {
            .block => "\x1b[2 q",
            .underline => "\x1b[4 q",
            .bar => "\x1b[6 q",
        });
    }
};

pub const CursorShape = enum { block, underline, bar };

test "buffers escape sequences until drained" {
    var ar = AnsiRenderer.init(std.testing.allocator, 10, 3);
    defer ar.deinit();
    ar.renderer().setUseTerminalDefaults(true);
    const r = ar.renderer();
    ar.beginSync();
    r.moveTo(2, 1);
    r.setFg(.{ .r = 1, .g = 2, .b = 3 });
    r.write("hi");
    ar.endSync();
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[2;3H\x1b[38;2;1;2;3mhi\x1b[?2026l", ar.output());
    ar.clearBuffer();
    try std.testing.expectEqual(@as(usize, 0), ar.output().len);
}

test "terminal-default clear emits erase only" {
    var ar = AnsiRenderer.init(std.testing.allocator, 4, 2);
    defer ar.deinit();
    ar.renderer().setUseTerminalDefaults(true);
    ar.renderer().clear();
    try std.testing.expectEqualStrings("\x1b[2J\x1b[H", ar.output());
}

test "themed clear paints every cell" {
    var ar = AnsiRenderer.init(std.testing.allocator, 4, 2);
    defer ar.deinit();
    ar.renderer().clear();
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, ar.output(), " "));
}

test "underline emits SGR 4/24 and reset clears it" {
    var ar = AnsiRenderer.init(std.testing.allocator, 4, 2);
    defer ar.deinit();
    ar.renderer().setUseTerminalDefaults(true);
    const r = ar.renderer();
    r.setUnderline(true);
    r.write("a");
    r.setUnderline(false);
    r.resetStyle();
    try std.testing.expectEqualStrings("\x1b[4ma\x1b[24m\x1b[0m", ar.output());
}

test "cursor shape" {
    var ar = AnsiRenderer.init(std.testing.allocator, 4, 2);
    defer ar.deinit();
    ar.setCursorShape(.bar);
    ar.setCursorShape(.block);
    try std.testing.expectEqualStrings("\x1b[6 q\x1b[2 q", ar.output());
}
