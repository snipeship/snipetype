const std = @import("std");

const Cursor = @import("cursor.zig").Cursor;

const Line = std.ArrayList(u8);

pub const Buffer = struct {
    lines: std.ArrayList(Line),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        var lines = std.ArrayList(Line){};
        // Start with one empty line
        const first_line = Line{};
        lines.append(allocator, first_line) catch {};
        return .{ .lines = lines, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn clear(self: *Buffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.clearRetainingCapacity();
        const first_line = Line{};
        self.lines.append(self.allocator, first_line) catch {};
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn getLine(self: *const Buffer, row: usize) []const u8 {
        if (row >= self.lines.items.len) return "";
        return self.lines.items[row].items;
    }

    pub fn getLineMut(self: *Buffer, row: usize) *Line {
        return &self.lines.items[row];
    }

    pub fn lineLen(self: *const Buffer, row: usize) usize {
        if (row >= self.lines.items.len) return 0;
        return self.lines.items[row].items.len;
    }

    pub fn insertChar(self: *Buffer, cursor: Cursor, char: u8) void {
        if (cursor.row >= self.lines.items.len) return;
        const line = self.getLineMut(cursor.row);
        const col = @min(cursor.col, line.items.len);
        line.insert(self.allocator, col, char) catch {};
    }

    pub fn deleteChar(self: *Buffer, cursor: Cursor) void {
        if (cursor.row >= self.lines.items.len) return;
        const line = self.getLineMut(cursor.row);
        if (cursor.col < line.items.len) {
            _ = line.orderedRemove(cursor.col);
        }
    }

    pub fn insertNewline(self: *Buffer, cursor: Cursor) void {
        if (cursor.row >= self.lines.items.len) return;
        const line = self.getLine(cursor.row);
        const col = @min(cursor.col, line.len);

        var new_line = Line{};
        if (col < line.len) {
            new_line.appendSlice(self.allocator, line[col..]) catch return;
        }
        self.lines.insert(self.allocator, cursor.row + 1, new_line) catch {
            new_line.deinit(self.allocator);
            return;
        };

        self.lines.items[cursor.row].shrinkRetainingCapacity(col);
    }

    pub fn joinLines(self: *Buffer, row: usize) void {
        if (row + 1 >= self.lines.items.len) return;
        const next_line = self.lines.items[row + 1].items;
        self.lines.items[row].appendSlice(self.allocator, next_line) catch return;
        self.lines.items[row + 1].deinit(self.allocator);
        _ = self.lines.orderedRemove(row + 1);
    }

    pub fn deleteLine(self: *Buffer, row: usize) void {
        if (row >= self.lines.items.len) return;
        if (self.lines.items.len == 1) {
            // Can't delete last line, just clear it
            self.lines.items[0].clearRetainingCapacity();
            return;
        }
        var line = self.lines.orderedRemove(row);
        line.deinit(self.allocator);
    }

    pub fn insertLine(self: *Buffer, row: usize, content: []const u8) void {
        var new_line = Line{};
        new_line.appendSlice(self.allocator, content) catch return;
        const insert_row = @min(row, self.lines.items.len);
        self.lines.insert(self.allocator, insert_row, new_line) catch {
            new_line.deinit(self.allocator);
            return;
        };
    }

    pub fn copyRange(self: *const Buffer, start: Cursor, end: Cursor) ![]u8 {
        // For simplicity, only handle single-line range for now
        if (start.row != end.row) return try self.allocator.alloc(u8, 0);
        if (start.row >= self.lines.items.len) return try self.allocator.alloc(u8, 0);

        const line = self.getLine(start.row);
        const from = @min(start.col, line.len);
        const to = @min(end.col, line.len);
        if (from >= to) return try self.allocator.alloc(u8, 0);

        return try self.allocator.dupe(u8, line[from..to]);
    }

    pub fn deleteRange(self: *Buffer, start: Cursor, end: Cursor) ![]u8 {
        // For simplicity, only handle single-line range for now
        if (start.row != end.row) return try self.allocator.alloc(u8, 0);
        if (start.row >= self.lines.items.len) return try self.allocator.alloc(u8, 0);

        const line = self.getLineMut(start.row);
        const from = @min(start.col, line.items.len);
        const to = @min(end.col, line.items.len);
        if (from >= to) return try self.allocator.alloc(u8, 0);

        const content = try self.allocator.dupe(u8, line.items[from..to]);
        // Remove chars from 'to' down to 'from'
        var i: usize = to;
        while (i > from) {
            i -= 1;
            _ = line.orderedRemove(i);
        }
        return content;
    }

    pub fn deleteToEndOfLine(self: *Buffer, cursor: Cursor) ![]u8 {
        if (cursor.row >= self.lines.items.len) return try self.allocator.alloc(u8, 0);
        const line = self.getLineMut(cursor.row);
        const col = @min(cursor.col, line.items.len);
        const content = try self.allocator.dupe(u8, line.items[col..]);
        line.shrinkRetainingCapacity(col);
        return content;
    }

    pub fn toText(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total += line.items.len;
            if (i < self.lines.items.len - 1) total += 1; // newline
        }
        const buf = try allocator.alloc(u8, total);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(buf[pos..][0..line.items.len], line.items);
            pos += line.items.len;
            if (i < self.lines.items.len - 1) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
        return buf;
    }

    /// Count characters matching target lines without allocation.
    /// Returns struct with correct char count and total typed chars.
    pub fn countMatchingChars(self: *const Buffer, target_lines: []const []const u8) struct { correct: usize, total: usize, errors: usize } {
        var correct: usize = 0;
        var total: usize = 0;
        var errors: usize = 0;

        const max_rows = @max(self.lines.items.len, target_lines.len);

        for (0..max_rows) |row| {
            const typed_line = if (row < self.lines.items.len) self.lines.items[row].items else "";
            const target_line = if (row < target_lines.len) target_lines[row] else "";

            const len = @min(typed_line.len, target_line.len);

            // Compare characters in common range
            for (0..len) |col| {
                if (typed_line[col] == target_line[col]) {
                    correct += 1;
                } else {
                    errors += 1;
                }
            }

            // Count extra or missing characters as errors
            if (typed_line.len > target_line.len) {
                errors += typed_line.len - target_line.len;
            } else if (typed_line.len < target_line.len) {
                errors += target_line.len - typed_line.len;
            }

            total += typed_line.len;

            // Count newline matching (except for last line)
            if (row < self.lines.items.len - 1) {
                total += 1; // We have a newline
                if (row < target_lines.len - 1) {
                    correct += 1; // Target also has newline here
                } else {
                    errors += 1; // Extra newline
                }
            } else if (row < target_lines.len - 1) {
                // We don't have a newline but target does
                errors += 1;
            }
        }

        return .{ .correct = correct, .total = total, .errors = errors };
    }

    /// Calculate total character count (for quick length comparison)
    pub fn totalChars(self: *const Buffer) usize {
        var total: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total += line.items.len;
            if (i < self.lines.items.len - 1) total += 1; // newline
        }
        return total;
    }

    /// Check if buffer content exactly matches target text (allocation-free)
    pub fn matchesTarget(self: *const Buffer, target_lines: []const []const u8, target_len: usize) bool {
        // Quick length check first
        if (self.totalChars() != target_len) return false;

        // Line count must match
        if (self.lines.items.len != target_lines.len) return false;

        // Compare line by line
        for (self.lines.items, 0..) |line, row| {
            if (row >= target_lines.len) return false;
            if (!std.mem.eql(u8, line.items, target_lines[row])) return false;
        }

        return true;
    }
};
