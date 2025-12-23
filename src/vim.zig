const std = @import("std");

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,

    pub fn lessThan(a: Cursor, b: Cursor) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }

    pub fn equals(a: Cursor, b: Cursor) bool {
        return a.row == b.row and a.col == b.col;
    }
};

test "buffer basic" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    buf.insertChar(.{ .row = 0, .col = 0 }, 'a');
    try std.testing.expectEqualStrings("a", buf.getLine(0));
}

test "vim editor" {
    const allocator = std.testing.allocator;
    var vim = VimEditor.init(allocator);
    defer vim.deinit();

    vim.handleKey('i'); // Enter insert
    vim.handleKey('h');
    vim.handleKey('e');
    vim.handleKey('l');
    vim.handleKey('l');
    vim.handleKey('o');
    try std.testing.expectEqualStrings("hello", vim.buffer.getLine(0));
}

pub const VimMode = enum {
    normal,
    insert,
    visual,
    visual_line,

    pub fn name(self: VimMode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
        };
    }
};

pub const Operator = enum {
    none,
    delete, // d
    change, // c
    yank, // y
};

const Line = std.ArrayList(u8);

pub const Buffer = struct {
    lines: std.ArrayList(Line),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        var lines = std.ArrayList(Line){};
        // Start with one empty line
        var first_line = Line{};
        lines.append(allocator, first_line) catch {};
        _ = &first_line;
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
        var first_line = Line{};
        self.lines.append(self.allocator, first_line) catch {};
        _ = &first_line;
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
        const line = self.getLineMut(cursor.row);
        const col = @min(cursor.col, line.items.len);

        // Create new line with content after cursor
        var new_line = Line{};
        if (col < line.items.len) {
            new_line.appendSlice(self.allocator, line.items[col..]) catch {};
            line.shrinkRetainingCapacity(col);
        }
        self.lines.insert(self.allocator, cursor.row + 1, new_line) catch {};
    }

    pub fn joinLines(self: *Buffer, row: usize) void {
        if (row + 1 >= self.lines.items.len) return;
        const next_line = self.lines.items[row + 1].items;
        self.lines.items[row].appendSlice(self.allocator, next_line) catch {};
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
        new_line.appendSlice(self.allocator, content) catch {};
        const insert_row = @min(row, self.lines.items.len);
        self.lines.insert(self.allocator, insert_row, new_line) catch {};
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
};

// Vim editor

pub const VimEditor = struct {
    buffer: Buffer,
    cursor: Cursor,
    mode: VimMode,
    visual_start: Cursor,
    pending_op: Operator,
    pending_g: bool,
    op_start: Cursor,
    yank_register: std.ArrayList(u8),
    yank_is_line: bool,
    status_msg: []const u8,
    allocator: std.mem.Allocator,
    count: usize, // For number prefixes like 3j, 5w

    pub fn init(allocator: std.mem.Allocator) VimEditor {
        return .{
            .buffer = Buffer.init(allocator),
            .cursor = .{},
            .mode = .normal,
            .visual_start = .{},
            .pending_op = .none,
            .pending_g = false,
            .op_start = .{},
            .yank_register = std.ArrayList(u8){},
            .yank_is_line = false,
            .status_msg = "",
            .allocator = allocator,
            .count = 0,
        };
    }

    pub fn deinit(self: *VimEditor) void {
        self.buffer.deinit();
        self.yank_register.deinit(self.allocator);
    }

    pub fn reset(self: *VimEditor) void {
        self.buffer.clear();
        self.cursor = .{};
        self.mode = .normal;
        self.visual_start = .{};
        self.pending_op = .none;
        self.pending_g = false;
        self.op_start = .{};
        self.yank_register.clearRetainingCapacity();
        self.yank_is_line = false;
        self.status_msg = "";
        self.count = 0;
    }

    pub fn handleKey(self: *VimEditor, key: u8) void {
        self.status_msg = "";

        switch (self.mode) {
            .normal => self.handleNormal(key),
            .insert => self.handleInsert(key),
            .visual, .visual_line => self.handleVisual(key),
        }
    }

    fn handleNormal(self: *VimEditor, key: u8) void {
        if (self.pending_g) {
            self.pending_g = false;
            if (key == 'g') {
                self.cursor.row = 0;
                self.cursor.col = 0;
                return;
            }
        }

        // Handle count prefix
        if (key >= '1' and key <= '9' and self.count == 0) {
            self.count = key - '0';
            return;
        }
        if (key >= '0' and key <= '9' and self.count > 0) {
            self.count = self.count * 10 + (key - '0');
            if (self.count > 999) self.count = 999;
            return;
        }

        const count = if (self.count == 0) 1 else self.count;
        self.count = 0;

        // Handle pending operator
        if (self.pending_op != .none) {
            self.handleOperatorMotion(key, count);
            return;
        }

        switch (key) {
            // Motion
            'h' => self.moveLeft(count),
            'j' => self.moveDown(count),
            'k' => self.moveUp(count),
            'l' => self.moveRight(count),
            'w' => self.moveWordForward(count),
            'W' => self.moveWordForward(count), // Same as w for now
            'b' => self.moveWordBackward(count),
            'B' => self.moveWordBackward(count),
            'e' => self.moveWordEnd(count),
            'E' => self.moveWordEnd(count),
            '0' => self.cursor.col = 0,
            '^' => self.moveToFirstNonBlank(),
            '$' => self.moveToEndOfLine(),
            'g' => {
                self.pending_g = true;
                return;
            },
            'G' => self.moveToLastLine(),

            // Insert mode
            'i' => self.mode = .insert,
            'I' => {
                self.moveToFirstNonBlank();
                self.mode = .insert;
            },
            'a' => {
                self.moveRight(1);
                self.mode = .insert;
            },
            'A' => {
                self.moveToEndOfLine();
                self.cursor.col = self.buffer.lineLen(self.cursor.row);
                self.mode = .insert;
            },
            'o' => {
                self.buffer.insertLine(self.cursor.row + 1, "");
                self.cursor.row += 1;
                self.cursor.col = 0;
                self.mode = .insert;
            },
            'O' => {
                self.buffer.insertLine(self.cursor.row, "");
                self.cursor.col = 0;
                self.mode = .insert;
            },
            's' => {
                self.buffer.deleteChar(self.cursor);
                self.mode = .insert;
            },
            'S' => {
                self.buffer.deleteLine(self.cursor.row);
                self.buffer.insertLine(self.cursor.row, "");
                self.cursor.col = 0;
                self.mode = .insert;
            },

            // Visual mode
            'v' => {
                self.mode = .visual;
                self.visual_start = self.cursor;
            },
            'V' => {
                self.mode = .visual_line;
                self.visual_start = self.cursor;
            },

            // Operators
            'd' => self.pending_op = .delete,
            'c' => self.pending_op = .change,
            'y' => self.pending_op = .yank,

            // Single-key actions
            'x' => {
                for (0..count) |_| {
                    if (self.cursor.col < self.buffer.lineLen(self.cursor.row)) {
                        self.buffer.deleteChar(self.cursor);
                    }
                }
                self.clampCursor();
            },
            'X' => {
                for (0..count) |_| {
                    if (self.cursor.col > 0) {
                        self.cursor.col -= 1;
                        self.buffer.deleteChar(self.cursor);
                    }
                }
            },
            'D' => {
                const content = self.buffer.deleteToEndOfLine(self.cursor) catch {
                    self.status_msg = "out of memory";
                    return;
                };
                defer self.allocator.free(content);
                self.setYank(content, false);
                self.clampCursor();
            },
            'C' => {
                const content = self.buffer.deleteToEndOfLine(self.cursor) catch {
                    self.status_msg = "out of memory";
                    return;
                };
                defer self.allocator.free(content);
                self.setYank(content, false);
                self.mode = .insert;
            },
            'J' => {
                self.buffer.joinLines(self.cursor.row);
            },

            // Paste
            'p' => self.pasteAfter(),
            'P' => self.pasteBefore(),

            // Replace single char
            'r' => self.status_msg = "r",

            // Undo placeholder
            'u' => self.status_msg = "undo (not implemented)",

            else => {},
        }
    }

    fn handleOperatorMotion(self: *VimEditor, key: u8, count: usize) void {
        const op = self.pending_op;

        if (self.pending_g) {
            self.pending_g = false;
            if (key == 'g') {
                const start = self.op_start;
                self.cursor.row = 0;
                self.cursor.col = 0;
                self.opLineRange(op, @min(start.row, self.cursor.row), @max(start.row, self.cursor.row));
                self.pending_op = .none;
                return;
            }
        }

        // Double key (dd, cc, yy)
        switch (key) {
            'd' => if (op == .delete) {
                self.opLineRange(op, self.cursor.row, self.cursor.row + count - 1);
                self.pending_op = .none;
                return;
            },
            'c' => if (op == .change) {
                self.opLineRange(op, self.cursor.row, self.cursor.row + count - 1);
                self.pending_op = .none;
                return;
            },
            'y' => if (op == .yank) {
                self.opLineRange(op, self.cursor.row, self.cursor.row + count - 1);
                self.pending_op = .none;
                return;
            },
            else => {},
        }

        if (key == 'g') {
            self.pending_g = true;
            self.op_start = self.cursor;
            return;
        }

        // Motion
        const start = self.cursor;
        switch (key) {
            'w' => self.moveWordForward(count),
            'b' => self.moveWordBackward(count),
            'e' => self.moveWordEnd(count),
            'j' => self.moveDown(count),
            'k' => self.moveUp(count),
            'h' => self.moveLeft(count),
            'l' => self.moveRight(count),
            '$' => self.moveToEndOfLine(),
            '0' => self.cursor.col = 0,
            '^' => self.moveToFirstNonBlank(),
            'G' => self.moveToLastLine(),
            else => {
                self.pending_op = .none;
                return;
            },
        }

        // Apply operator to range
        if (key == 'j' or key == 'k' or key == 'G') {
            // Line-wise
            const from = @min(start.row, self.cursor.row);
            const to = @max(start.row, self.cursor.row);
            self.opLineRange(op, from, to);
        } else {
            // Character-wise
            self.opCharRange(op, start, self.cursor);
        }
        self.pending_op = .none;
    }

    fn opLineRange(self: *VimEditor, op: Operator, from_row: usize, to_row: usize) void {
        const from = @min(from_row, self.buffer.lineCount() -| 1);
        const to = @min(to_row, self.buffer.lineCount() -| 1);

        // Collect content
        var content = std.ArrayList(u8){};
        for (from..to + 1) |row| {
            const line = self.buffer.getLine(row);
            content.appendSlice(self.allocator, line) catch {};
            if (row < to) content.append(self.allocator, '\n') catch {};
        }
        self.yank_register.clearRetainingCapacity();
        self.yank_register.appendSlice(self.allocator, content.items) catch {};
        self.yank_is_line = true;
        content.deinit(self.allocator);

        if (op == .delete or op == .change) {
            // Delete lines from bottom up
            var row = to;
            while (row >= from) : (row -|= 1) {
                self.buffer.deleteLine(row);
                if (row == 0) break;
            }
            self.cursor.row = from;
            self.cursor.col = 0;
            self.clampCursor();
            if (op == .change) {
                if (self.buffer.lineCount() == 0 or (self.cursor.row == 0 and self.buffer.lineLen(0) == 0)) {
                    // Line was cleared
                } else {
                    self.buffer.insertLine(self.cursor.row, "");
                }
                self.mode = .insert;
            }
        }
    }

    fn opCharRange(self: *VimEditor, op: Operator, start: Cursor, end: Cursor) void {
        var from = start;
        var to = end;
        if (!Cursor.lessThan(from, to)) {
            const tmp = from;
            from = to;
            to = tmp;
        }

        // Single line for now
        if (from.row == to.row) {
            const content = switch (op) {
                .delete, .change => self.buffer.deleteRange(from, .{ .row = to.row, .col = to.col + 1 }),
                .yank => self.buffer.copyRange(from, .{ .row = to.row, .col = to.col + 1 }),
                .none => return,
            } catch {
                self.status_msg = "out of memory";
                return;
            };
            defer self.allocator.free(content);
            self.setYank(content, false);
            self.cursor = from;
            self.clampCursor();
            if (op == .change) self.mode = .insert;
        }
    }

    fn handleInsert(self: *VimEditor, key: u8) void {
        switch (key) {
            27 => { // Escape
                self.mode = .normal;
                if (self.cursor.col > 0) self.cursor.col -= 1;
                self.clampCursor();
            },
            127, 8 => { // Backspace
                if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                    self.buffer.deleteChar(self.cursor);
                } else if (self.cursor.row > 0) {
                    // Join with previous line
                    const prev_len = self.buffer.lineLen(self.cursor.row - 1);
                    self.buffer.joinLines(self.cursor.row - 1);
                    self.cursor.row -= 1;
                    self.cursor.col = prev_len;
                }
            },
            '\r', '\n' => {
                self.buffer.insertNewline(self.cursor);
                self.cursor.row += 1;
                self.cursor.col = 0;
            },
            '\t' => {
                // Insert 4 spaces
                for (0..4) |_| {
                    self.buffer.insertChar(self.cursor, ' ');
                    self.cursor.col += 1;
                }
            },
            else => {
                if (key >= 32 and key < 127) {
                    self.buffer.insertChar(self.cursor, key);
                    self.cursor.col += 1;
                }
            },
        }
    }

    fn handleVisual(self: *VimEditor, key: u8) void {
        switch (key) {
            27, 'v', 'V' => { // Escape or toggle
                self.mode = .normal;
            },
            'h' => self.moveLeft(1),
            'j' => self.moveDown(1),
            'k' => self.moveUp(1),
            'l' => self.moveRight(1),
            'w' => self.moveWordForward(1),
            'b' => self.moveWordBackward(1),
            'e' => self.moveWordEnd(1),
            '0' => self.cursor.col = 0,
            '$' => self.moveToEndOfLine(),
            'G' => self.moveToLastLine(),
            'g' => {
                self.cursor.row = 0;
                self.cursor.col = 0;
            },
            'd', 'x' => {
                self.deleteVisualSelection();
                self.mode = .normal;
            },
            'c' => {
                self.deleteVisualSelection();
                self.mode = .insert;
            },
            'y' => {
                self.yankVisualSelection();
                self.mode = .normal;
            },
            else => {},
        }
    }

    fn deleteVisualSelection(self: *VimEditor) void {
        if (self.mode == .visual_line) {
            const from = @min(self.visual_start.row, self.cursor.row);
            const to = @max(self.visual_start.row, self.cursor.row);
            self.opLineRange(.delete, from, to);
        } else {
            var from = self.visual_start;
            var to = self.cursor;
            if (!Cursor.lessThan(from, to)) {
                const tmp = from;
                from = to;
                to = tmp;
            }
            if (from.row == to.row) {
                const content = self.buffer.deleteRange(from, .{ .row = to.row, .col = to.col + 1 }) catch {
                    self.status_msg = "out of memory";
                    return;
                };
                defer self.allocator.free(content);
                self.setYank(content, false);
            }
            self.cursor = from;
            self.clampCursor();
        }
    }

    fn yankVisualSelection(self: *VimEditor) void {
        if (self.mode == .visual_line) {
            const from = @min(self.visual_start.row, self.cursor.row);
            const to = @max(self.visual_start.row, self.cursor.row);
            var content = std.ArrayList(u8){};
            for (from..to + 1) |row| {
                const line = self.buffer.getLine(row);
                content.appendSlice(self.allocator, line) catch {};
                if (row < to) content.append(self.allocator, '\n') catch {};
            }
            self.yank_register.clearRetainingCapacity();
            self.yank_register.appendSlice(self.allocator, content.items) catch {};
            self.yank_is_line = true;
            content.deinit(self.allocator);
        } else {
            var from = self.visual_start;
            var to = self.cursor;
            if (!Cursor.lessThan(from, to)) {
                const tmp = from;
                from = to;
                to = tmp;
            }
            if (from.row == to.row) {
                const line = self.buffer.getLine(from.row);
                const start = @min(from.col, line.len);
                const end = @min(to.col + 1, line.len);
                self.yank_register.clearRetainingCapacity();
                self.yank_register.appendSlice(self.allocator, line[start..end]) catch {};
                self.yank_is_line = false;
            }
        }
        self.cursor = self.visual_start;
        if (Cursor.lessThan(self.cursor, self.visual_start)) {} else {
            self.cursor = self.visual_start;
        }
    }

    fn setYank(self: *VimEditor, content: []const u8, is_line: bool) void {
        self.yank_register.clearRetainingCapacity();
        self.yank_register.appendSlice(self.allocator, content) catch {};
        self.yank_is_line = is_line;
    }

    fn pasteAfter(self: *VimEditor) void {
        if (self.yank_register.items.len == 0) return;
        if (self.yank_is_line) {
            var insert_row = self.cursor.row + 1;
            var it = std.mem.splitScalar(u8, self.yank_register.items, '\n');
            while (it.next()) |line| {
                self.buffer.insertLine(insert_row, line);
                insert_row += 1;
            }
            self.cursor.row += 1;
            self.cursor.col = 0;
        } else {
            const line_len = self.buffer.lineLen(self.cursor.row);
            const insert_col = @min(self.cursor.col + 1, line_len);
            for (self.yank_register.items, 0..) |char, i| {
                self.buffer.insertChar(.{ .row = self.cursor.row, .col = insert_col + i }, char);
            }
            if (self.yank_register.items.len > 0) {
                self.cursor.col = insert_col + self.yank_register.items.len - 1;
            }
            self.clampCursor();
        }
    }

    fn pasteBefore(self: *VimEditor) void {
        if (self.yank_register.items.len == 0) return;
        if (self.yank_is_line) {
            var insert_row = self.cursor.row;
            var it = std.mem.splitScalar(u8, self.yank_register.items, '\n');
            while (it.next()) |line| {
                self.buffer.insertLine(insert_row, line);
                insert_row += 1;
            }
            self.cursor.col = 0;
        } else {
            const start_col = self.cursor.col;
            for (self.yank_register.items, 0..) |char, i| {
                self.buffer.insertChar(.{ .row = self.cursor.row, .col = start_col + i }, char);
            }
            if (self.yank_register.items.len > 0) {
                self.cursor.col = start_col + self.yank_register.items.len - 1;
            }
            self.clampCursor();
        }
    }

    fn moveLeft(self: *VimEditor, count: usize) void {
        self.cursor.col -|= count;
    }

    fn moveRight(self: *VimEditor, count: usize) void {
        const max_col = self.buffer.lineLen(self.cursor.row);
        const target = if (self.mode == .insert) max_col else max_col -| 1;
        self.cursor.col = @min(self.cursor.col + count, target);
    }

    fn moveUp(self: *VimEditor, count: usize) void {
        self.cursor.row -|= count;
        self.clampCursor();
    }

    fn moveDown(self: *VimEditor, count: usize) void {
        self.cursor.row = @min(self.cursor.row + count, self.buffer.lineCount() -| 1);
        self.clampCursor();
    }

    fn moveWordForward(self: *VimEditor, count: usize) void {
        for (0..count) |_| {
            const line = self.buffer.getLine(self.cursor.row);
            var col = self.cursor.col;

            // Skip current word
            while (col < line.len and !isWordBoundary(line[col])) col += 1;
            // Skip whitespace
            while (col < line.len and line[col] == ' ') col += 1;

            if (col >= line.len and self.cursor.row + 1 < self.buffer.lineCount()) {
                self.cursor.row += 1;
                self.cursor.col = 0;
                // Skip leading whitespace on new line
                const new_line = self.buffer.getLine(self.cursor.row);
                while (self.cursor.col < new_line.len and new_line[self.cursor.col] == ' ') {
                    self.cursor.col += 1;
                }
            } else {
                self.cursor.col = col;
            }
        }
    }

    fn moveWordBackward(self: *VimEditor, count: usize) void {
        for (0..count) |_| {
            if (self.cursor.col == 0) {
                if (self.cursor.row > 0) {
                    self.cursor.row -= 1;
                    self.cursor.col = self.buffer.lineLen(self.cursor.row);
                }
                continue;
            }

            const line = self.buffer.getLine(self.cursor.row);
            var col = self.cursor.col -| 1;

            // Skip whitespace
            while (col > 0 and line[col] == ' ') col -= 1;
            // Skip word
            while (col > 0 and !isWordBoundary(line[col - 1])) col -= 1;

            self.cursor.col = col;
        }
    }

    fn moveWordEnd(self: *VimEditor, count: usize) void {
        for (0..count) |_| {
            const line = self.buffer.getLine(self.cursor.row);
            var col = self.cursor.col + 1;

            // Skip whitespace
            while (col < line.len and line[col] == ' ') col += 1;
            // Skip to end of word
            while (col < line.len and !isWordBoundary(line[col])) col += 1;

            if (col > 0) col -= 1;
            self.cursor.col = col;
        }
    }

    fn moveToFirstNonBlank(self: *VimEditor) void {
        const line = self.buffer.getLine(self.cursor.row);
        self.cursor.col = 0;
        while (self.cursor.col < line.len and line[self.cursor.col] == ' ') {
            self.cursor.col += 1;
        }
    }

    fn moveToEndOfLine(self: *VimEditor) void {
        self.cursor.col = self.buffer.lineLen(self.cursor.row) -| 1;
    }

    fn moveToLastLine(self: *VimEditor) void {
        self.cursor.row = self.buffer.lineCount() -| 1;
        self.clampCursor();
    }

    fn clampCursor(self: *VimEditor) void {
        if (self.cursor.row >= self.buffer.lineCount()) {
            self.cursor.row = self.buffer.lineCount() -| 1;
        }
        const max_col = self.buffer.lineLen(self.cursor.row);
        if (self.mode == .insert) {
            if (self.cursor.col > max_col) self.cursor.col = max_col;
        } else {
            if (self.cursor.col >= max_col and max_col > 0) {
                self.cursor.col = max_col - 1;
            } else if (max_col == 0) {
                self.cursor.col = 0;
            }
        }
    }

    fn isWordBoundary(c: u8) bool {
        return c == ' ' or c == '.' or c == ',' or c == ';' or c == ':' or
            c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}' or
            c == '<' or c == '>' or c == '"' or c == '\'' or c == '=' or c == '+' or
            c == '-' or c == '*' or c == '/' or c == '\\' or c == '|' or c == '&';
    }

    pub fn isInVisualRange(self: *const VimEditor, row: usize, col: usize) bool {
        if (self.mode != .visual and self.mode != .visual_line) return false;

        if (self.mode == .visual_line) {
            const from = @min(self.visual_start.row, self.cursor.row);
            const to = @max(self.visual_start.row, self.cursor.row);
            return row >= from and row <= to;
        }

        // Character visual
        var from = self.visual_start;
        var to = self.cursor;
        if (!Cursor.lessThan(from, to)) {
            const tmp = from;
            from = to;
            to = tmp;
        }

        if (row < from.row or row > to.row) return false;
        if (from.row == to.row) {
            return col >= from.col and col <= to.col;
        }
        if (row == from.row) return col >= from.col;
        if (row == to.row) return col <= to.col;
        return true;
    }
};
