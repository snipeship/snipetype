const std = @import("std");
const posix = std.posix;

pub const RenderBuffer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderBuffer {
        return .{ .data = std.ArrayList(u8){}, .allocator = allocator };
    }

    pub fn deinit(self: *RenderBuffer) void {
        self.data.deinit(self.allocator);
    }

    pub fn clear(self: *RenderBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn write(self: *RenderBuffer, s: []const u8) void {
        self.data.appendSlice(self.allocator, s) catch {};
    }

    pub fn writeByte(self: *RenderBuffer, b: u8) void {
        self.data.append(self.allocator, b) catch {};
    }

    pub fn print(self: *RenderBuffer, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.data.writer(self.allocator), fmt, args) catch {};
    }

    pub fn moveTo(self: *RenderBuffer, x: usize, y: usize) void {
        self.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    pub fn flush(self: *RenderBuffer) void {
        var remaining = self.data.items;
        while (remaining.len > 0) {
            const n = posix.write(posix.STDOUT_FILENO, remaining) catch return;
            if (n == 0) return;
            remaining = remaining[n..];
        }
    }
};
