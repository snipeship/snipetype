const std = @import("std");

const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;

const MAX_UNDO_ENTRIES = 100;

/// A snapshot of buffer state for undo
pub const UndoEntry = struct {
    lines: [][]u8,
    cursor: Cursor,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UndoEntry) void {
        for (self.lines) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.lines);
    }
};

/// Stack of undo entries (uses Zig 0.15 unmanaged ArrayList)
pub const UndoStack = struct {
    entries: std.ArrayList(UndoEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UndoStack {
        return .{
            .entries = std.ArrayList(UndoEntry){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit(self.allocator);
    }

    pub fn clear(self: *UndoStack) void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.clearRetainingCapacity();
    }

    /// Save current buffer state to undo stack
    pub fn push(self: *UndoStack, buffer: *const Buffer, cursor: Cursor) !void {
        // Limit stack size
        if (self.entries.items.len >= MAX_UNDO_ENTRIES) {
            var oldest = self.entries.orderedRemove(0);
            oldest.deinit();
        }

        // Snapshot all lines
        const lines = try self.allocator.alloc([]u8, buffer.lines.items.len);
        errdefer self.allocator.free(lines);

        var copied: usize = 0;
        errdefer {
            for (lines[0..copied]) |line| {
                self.allocator.free(line);
            }
        }

        for (buffer.lines.items, 0..) |line, i| {
            lines[i] = try self.allocator.dupe(u8, line.items);
            copied += 1;
        }

        try self.entries.append(self.allocator, .{
            .lines = lines,
            .cursor = cursor,
            .allocator = self.allocator,
        });
    }

    /// Pop and restore buffer state, returns new cursor position
    pub fn pop(self: *UndoStack, buffer: *Buffer) ?Cursor {
        if (self.entries.items.len == 0) return null;

        var entry = self.entries.pop() orelse return null;

        // Clear current buffer
        for (buffer.lines.items) |*line| {
            line.deinit(buffer.allocator);
        }
        buffer.lines.clearRetainingCapacity();

        // Restore lines from snapshot
        for (entry.lines) |line_content| {
            var new_line = std.ArrayList(u8){};
            new_line.appendSlice(buffer.allocator, line_content) catch {
                // On failure, ensure at least one empty line
                if (buffer.lines.items.len == 0) {
                    buffer.lines.append(buffer.allocator, std.ArrayList(u8){}) catch {};
                }
                entry.deinit();
                return null;
            };
            buffer.lines.append(buffer.allocator, new_line) catch {
                new_line.deinit(buffer.allocator);
                if (buffer.lines.items.len == 0) {
                    buffer.lines.append(buffer.allocator, std.ArrayList(u8){}) catch {};
                }
                entry.deinit();
                return null;
            };
        }

        // Ensure at least one line
        if (buffer.lines.items.len == 0) {
            buffer.lines.append(buffer.allocator, std.ArrayList(u8){}) catch {};
        }

        const cursor = entry.cursor;
        entry.deinit();
        return cursor;
    }

    pub fn isEmpty(self: *const UndoStack) bool {
        return self.entries.items.len == 0;
    }

    pub fn len(self: *const UndoStack) usize {
        return self.entries.items.len;
    }
};
