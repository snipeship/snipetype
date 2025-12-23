const std = @import("std");

const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;

pub const Register = struct {
    buf: std.ArrayList(u8),
    is_line: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Register {
        return .{
            .buf = std.ArrayList(u8){},
            .is_line = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Register) void {
        self.buf.deinit(self.allocator);
    }

    pub fn clear(self: *Register) void {
        self.buf.clearRetainingCapacity();
        self.is_line = false;
    }

    pub fn isEmpty(self: *const Register) bool {
        return self.buf.items.len == 0;
    }

    pub fn set(self: *Register, content: []const u8, is_line: bool) !void {
        var next = std.ArrayList(u8){};
        try next.appendSlice(self.allocator, content);

        self.buf.deinit(self.allocator);
        self.buf = next;
        self.is_line = is_line;
    }

    pub fn pasteAfter(self: *const Register, buffer: *Buffer, cursor: *Cursor) void {
        if (self.buf.items.len == 0) return;
        if (self.is_line) {
            var insert_row = cursor.row + 1;
            var it = std.mem.splitScalar(u8, self.buf.items, '\n');
            while (it.next()) |line| {
                buffer.insertLine(insert_row, line);
                insert_row += 1;
            }
            cursor.row += 1;
            cursor.col = 0;
        } else {
            const line_len = buffer.lineLen(cursor.row);
            const insert_col = @min(cursor.col + 1, line_len);
            for (self.buf.items, 0..) |char, i| {
                buffer.insertChar(.{ .row = cursor.row, .col = insert_col + i }, char);
            }
            if (self.buf.items.len > 0) {
                cursor.col = insert_col + self.buf.items.len - 1;
            }
        }
    }

    pub fn pasteBefore(self: *const Register, buffer: *Buffer, cursor: *Cursor) void {
        if (self.buf.items.len == 0) return;
        if (self.is_line) {
            var insert_row = cursor.row;
            var it = std.mem.splitScalar(u8, self.buf.items, '\n');
            while (it.next()) |line| {
                buffer.insertLine(insert_row, line);
                insert_row += 1;
            }
            cursor.col = 0;
        } else {
            const start_col = cursor.col;
            for (self.buf.items, 0..) |char, i| {
                buffer.insertChar(.{ .row = cursor.row, .col = start_col + i }, char);
            }
            if (self.buf.items.len > 0) {
                cursor.col = start_col + self.buf.items.len - 1;
            }
        }
    }
};
