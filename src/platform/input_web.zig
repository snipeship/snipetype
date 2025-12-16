//! Browser input handling.
//! JavaScript pushes bytes into a ring buffer; Zig reads keys from it.

pub const Key = union(enum) {
    Byte: u8,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
};

pub const Input = struct {
    // Unread buffer for escape sequence parsing (same as native)
    queued: [8]u8 = undefined,
    queued_len: usize = 0,

    // Ring buffer for incoming bytes from JavaScript
    ring: [4096]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    pub fn init() Input {
        return .{};
    }

    /// Push a single byte into the ring buffer (called indirectly via staging buffer)
    pub fn pushByte(self: *Input, b: u8) void {
        const next_tail = (self.tail + 1) % self.ring.len;
        if (next_tail == self.head) {
            // Ring full: drop oldest byte
            self.head = (self.head + 1) % self.ring.len;
        }
        self.ring[self.tail] = b;
        self.tail = next_tail;
    }

    /// Push multiple bytes into the ring buffer
    pub fn pushBytes(self: *Input, bytes: []const u8) void {
        for (bytes) |b| self.pushByte(b);
    }

    /// Read and parse the next key (handles escape sequences)
    pub fn readKey(self: *Input) ?Key {
        const first = self.readByte() orelse return null;
        if (first != 0x1b) return .{ .Byte = first };

        // Possible escape sequence
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

        // Then check ring buffer
        if (self.head == self.tail) return null; // Empty
        const b = self.ring[self.head];
        self.head = (self.head + 1) % self.ring.len;
        return b;
    }

    fn unreadByte(self: *Input, b: u8) void {
        if (self.queued_len >= self.queued.len) return;

        if (self.queued_len > 0) {
            @memcpy(self.queued[1 .. self.queued_len + 1], self.queued[0..self.queued_len]);
        }
        self.queued[0] = b;
        self.queued_len += 1;
    }
};
