const std = @import("std");
const posix = std.posix;

pub const Key = union(enum) {
    Byte: u8,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
};

pub const Input = struct {
    queued: [8]u8 = undefined,
    queued_len: usize = 0,

    pub fn init() Input {
        return .{};
    }

    pub fn readKey(self: *Input) ?Key {
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

    fn readByte(self: *Input) ?u8 {
        if (self.queued_len > 0) {
            const b = self.queued[0];
            const remaining = self.queued_len - 1;
            if (remaining > 0) {
                @memcpy(self.queued[0..remaining], self.queued[1..self.queued_len]);
            }
            self.queued_len = remaining;
            return b;
        }

        var buf: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &buf) catch return null;
        if (n == 0) return null;
        return buf[0];
    }

    fn unreadByte(self: *Input, b: u8) void {
        if (self.queued_len >= self.queued.len) return;

        if (self.queued_len > 0) {
            @memcpy(
                self.queued[1 .. self.queued_len + 1],
                self.queued[0..self.queued_len],
            );
        }
        self.queued[0] = b;
        self.queued_len += 1;
    }
};
