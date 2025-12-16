//! Browser terminal shim.
//! Size is controlled by JavaScript; raw mode is not applicable.

pub const Terminal = struct {
    width: usize = 80,
    height: usize = 24,

    pub fn init() !Terminal {
        return .{};
    }

    pub fn updateSize(self: *Terminal) void {
        // In browser, JS calls setSize() instead
        _ = self;
    }

    pub fn setSize(self: *Terminal, w: usize, h: usize) void {
        self.width = w;
        self.height = h;
    }

    pub fn enableRawMode(self: *Terminal) !void {
        // No-op in browser (terminal emulator handles this)
        _ = self;
    }

    pub fn restore(self: *Terminal) void {
        // No-op in browser
        _ = self;
    }
};
