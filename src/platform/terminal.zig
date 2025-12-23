//! Terminal raw mode and size helpers.
//! Platform-specific behavior is selected at compile time.
//! - Native: uses termios for raw mode, ioctl for size
//! - WASM: size controlled by JavaScript, raw mode not applicable

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("../core/constants.zig");

const is_wasm = builtin.cpu.arch == .wasm32;

pub const Terminal = if (is_wasm) WasmTerminal else NativeTerminal;

/// WASM Terminal - minimal implementation
const WasmTerminal = struct {
    width: usize = constants.DEFAULT_TERM_WIDTH,
    height: usize = constants.DEFAULT_TERM_HEIGHT,

    pub fn init() !WasmTerminal {
        return WasmTerminal{};
    }

    pub fn updateSize(self: *WasmTerminal) void {
        _ = self;
        // Web: JS calls setSize() directly
    }

    pub fn setSize(self: *WasmTerminal, w: usize, h: usize) void {
        self.width = w;
        self.height = h;
    }

    pub fn enableRawMode(self: *WasmTerminal) !void {
        _ = self;
        // No-op in browser
    }

    pub fn restore(self: *WasmTerminal) void {
        _ = self;
        // No-op in browser
    }
};

/// Native Terminal - full implementation with raw mode support
const NativeTerminal = struct {
    const posix = std.posix;

    width: usize = constants.DEFAULT_TERM_WIDTH,
    height: usize = constants.DEFAULT_TERM_HEIGHT,
    original: posix.termios = undefined,

    pub fn init() !NativeTerminal {
        var t = NativeTerminal{};
        t.original = try posix.tcgetattr(posix.STDIN_FILENO);
        t.updateSize();
        return t;
    }

    pub fn updateSize(self: *NativeTerminal) void {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (ws.col > 0) self.width = @intCast(ws.col);
        if (ws.row > 0) self.height = @intCast(ws.row);
    }

    pub fn setSize(self: *NativeTerminal, w: usize, h: usize) void {
        self.width = w;
        self.height = h;
    }

    pub fn enableRawMode(self: *NativeTerminal) !void {
        var raw = self.original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    }

    pub fn restore(self: *NativeTerminal) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};
