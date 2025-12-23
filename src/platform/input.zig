//! Input handling for keyboard events.
//! Platform-specific byte source is selected at compile time.
//! - Native: reads from stdin
//! - WASM: JavaScript pushes bytes into a ring buffer

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("../core/constants.zig");

const is_wasm = builtin.cpu.arch == .wasm32;

/// Parse modified arrow key from escape sequence \x1b[1;{mod}{dir}
/// modifier: '2' = Shift, '5' = Ctrl
/// direction: 'A' = Up, 'B' = Down, 'C' = Right, 'D' = Left
fn parseModifiedArrow(modifier: u8, direction: u8) ?Key {
    return switch (modifier) {
        '2' => switch (direction) { // Shift
            'C' => .ShiftArrowRight,
            'D' => .ShiftArrowLeft,
            else => null,
        },
        '5' => switch (direction) { // Ctrl
            'A' => .CtrlArrowUp,
            'B' => .CtrlArrowDown,
            'C' => .CtrlArrowRight,
            'D' => .CtrlArrowLeft,
            else => null,
        },
        else => null,
    };
}

pub const Key = union(enum) {
    Byte: u8,
    // Plain arrows
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    // Shift+Arrow (word movement)
    ShiftArrowLeft,
    ShiftArrowRight,
    // Ctrl+Arrow (word movement)
    CtrlArrowLeft,
    CtrlArrowRight,
    // Ctrl+Up/Down (document navigation)
    CtrlArrowUp,
    CtrlArrowDown,
};

pub const Input = if (is_wasm) WasmInput else NativeInput;

/// WASM Input - reads from ring buffer fed by JavaScript
const WasmInput = struct {
    // Escape sequence queue for unread bytes
    queued: [constants.INPUT_QUEUE_SIZE]u8 = undefined,
    queued_len: usize = 0,

    // Ring buffer for incoming bytes from JavaScript
    ring: [constants.WEB_RING_BUFFER_SIZE]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    pub fn init() WasmInput {
        return .{};
    }

    /// Push a single byte into the ring buffer
    pub fn pushByte(self: *WasmInput, b: u8) void {
        const next_tail = (self.tail + 1) % constants.WEB_RING_BUFFER_SIZE;
        if (next_tail == self.head) {
            // Ring full: drop oldest byte
            self.head = (self.head + 1) % constants.WEB_RING_BUFFER_SIZE;
        }
        self.ring[self.tail] = b;
        self.tail = next_tail;
    }

    /// Push multiple bytes into the ring buffer
    pub fn pushBytes(self: *WasmInput, bytes: []const u8) void {
        for (bytes) |b| self.pushByte(b);
    }

    /// Read and parse the next key (handles escape sequences)
    pub fn readKey(self: *WasmInput) ?Key {
        const first = self.readByte() orelse return null;
        if (first != 0x1b) return .{ .Byte = first };

        const second = self.readByte() orelse return .{ .Byte = first };
        if (second != '[') {
            self.unreadByte(second);
            return .{ .Byte = first };
        }

        const third = self.readByte() orelse {
            self.unreadByte(second);
            return .{ .Byte = first };
        };

        // Check for modified arrow sequences: \x1b[1;{mod}{dir}
        if (third == '1') {
            const fourth = self.readByte() orelse {
                self.unreadByte(third);
                self.unreadByte(second);
                return .{ .Byte = first };
            };
            if (fourth == ';') {
                const modifier = self.readByte() orelse {
                    self.unreadByte(fourth);
                    self.unreadByte(third);
                    self.unreadByte(second);
                    return .{ .Byte = first };
                };
                const direction = self.readByte() orelse {
                    self.unreadByte(modifier);
                    self.unreadByte(fourth);
                    self.unreadByte(third);
                    self.unreadByte(second);
                    return .{ .Byte = first };
                };
                return parseModifiedArrow(modifier, direction);
            } else {
                self.unreadByte(fourth);
                self.unreadByte(third);
                self.unreadByte(second);
                return .{ .Byte = first };
            }
        }

        // Plain arrow keys
        return switch (third) {
            'A' => .ArrowUp,
            'B' => .ArrowDown,
            'C' => .ArrowRight,
            'D' => .ArrowLeft,
            else => blk: {
                self.unreadByte(third);
                self.unreadByte(second);
                break :blk .{ .Byte = first };
            },
        };
    }

    fn readByte(self: *WasmInput) ?u8 {
        // First check unread buffer
        if (self.queued_len > 0) {
            const b = self.queued[0];
            const remaining = self.queued_len - 1;
            if (remaining > 0) {
                @memcpy(self.queued[0..remaining], self.queued[1..self.queued_len]);
            }
            self.queued_len = remaining;
            return b;
        }

        // Read from ring buffer
        if (self.head == self.tail) return null; // Empty
        const b = self.ring[self.head];
        self.head = (self.head + 1) % constants.WEB_RING_BUFFER_SIZE;
        return b;
    }

    fn unreadByte(self: *WasmInput, b: u8) void {
        if (self.queued_len >= self.queued.len) return;
        if (self.queued_len > 0) {
            @memcpy(self.queued[1 .. self.queued_len + 1], self.queued[0..self.queued_len]);
        }
        self.queued[0] = b;
        self.queued_len += 1;
    }
};

/// Native Input - reads from stdin
const NativeInput = struct {
    const posix = std.posix;

    // Escape sequence queue for unread bytes
    queued: [constants.INPUT_QUEUE_SIZE]u8 = undefined,
    queued_len: usize = 0,

    pub fn init() NativeInput {
        return .{};
    }

    /// No-op for native (only used by web)
    pub fn pushByte(self: *NativeInput, b: u8) void {
        _ = self;
        _ = b;
    }

    /// No-op for native (only used by web)
    pub fn pushBytes(self: *NativeInput, bytes: []const u8) void {
        _ = self;
        _ = bytes;
    }

    /// Read and parse the next key (handles escape sequences)
    pub fn readKey(self: *NativeInput) ?Key {
        const first = self.readByte() orelse return null;
        if (first != 0x1b) return .{ .Byte = first };

        const second = self.readByte() orelse return .{ .Byte = first };
        if (second != '[') {
            self.unreadByte(second);
            return .{ .Byte = first };
        }

        const third = self.readByte() orelse {
            self.unreadByte(second);
            return .{ .Byte = first };
        };

        // Check for modified arrow sequences: \x1b[1;{mod}{dir}
        if (third == '1') {
            const fourth = self.readByte() orelse {
                self.unreadByte(third);
                self.unreadByte(second);
                return .{ .Byte = first };
            };
            if (fourth == ';') {
                const modifier = self.readByte() orelse {
                    self.unreadByte(fourth);
                    self.unreadByte(third);
                    self.unreadByte(second);
                    return .{ .Byte = first };
                };
                const direction = self.readByte() orelse {
                    self.unreadByte(modifier);
                    self.unreadByte(fourth);
                    self.unreadByte(third);
                    self.unreadByte(second);
                    return .{ .Byte = first };
                };
                return parseModifiedArrow(modifier, direction);
            } else {
                self.unreadByte(fourth);
                self.unreadByte(third);
                self.unreadByte(second);
                return .{ .Byte = first };
            }
        }

        // Plain arrow keys
        return switch (third) {
            'A' => .ArrowUp,
            'B' => .ArrowDown,
            'C' => .ArrowRight,
            'D' => .ArrowLeft,
            else => blk: {
                self.unreadByte(third);
                self.unreadByte(second);
                break :blk .{ .Byte = first };
            },
        };
    }

    fn readByte(self: *NativeInput) ?u8 {
        // First check unread buffer
        if (self.queued_len > 0) {
            const b = self.queued[0];
            const remaining = self.queued_len - 1;
            if (remaining > 0) {
                @memcpy(self.queued[0..remaining], self.queued[1..self.queued_len]);
            }
            self.queued_len = remaining;
            return b;
        }

        // Read from stdin
        var buf: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &buf) catch return null;
        if (n == 0) return null;
        return buf[0];
    }

    fn unreadByte(self: *NativeInput, b: u8) void {
        if (self.queued_len >= self.queued.len) return;
        if (self.queued_len > 0) {
            @memcpy(self.queued[1 .. self.queued_len + 1], self.queued[0..self.queued_len]);
        }
        self.queued[0] = b;
        self.queued_len += 1;
    }
};
