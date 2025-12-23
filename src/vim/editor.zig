const std = @import("std");

const constants = @import("../core/constants.zig");
const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const VimMode = @import("mode.zig").VimMode;
const Operator = @import("operator.zig").Operator;
const Register = @import("register.zig").Register;
const UndoStack = @import("undo.zig").UndoStack;
const motions = @import("motions.zig");
const operators = @import("operators.zig");

pub const VimEditor = struct {
    buffer: Buffer,
    cursor: Cursor,
    mode: VimMode,
    visual_start: Cursor,
    pending_op: Operator,
    pending_g: bool,
    pending_replace: bool,
    op_start: Cursor,
    register: Register,
    undo_stack: UndoStack,
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
            .pending_replace = false,
            .op_start = .{},
            .register = Register.init(allocator),
            .undo_stack = UndoStack.init(allocator),
            .status_msg = "",
            .allocator = allocator,
            .count = 0,
        };
    }

    pub fn deinit(self: *VimEditor) void {
        self.buffer.deinit();
        self.register.deinit();
        self.undo_stack.deinit();
    }

    pub fn reset(self: *VimEditor) void {
        self.buffer.clear();
        self.cursor = .{};
        self.mode = .normal;
        self.visual_start = .{};
        self.pending_op = .none;
        self.pending_g = false;
        self.pending_replace = false;
        self.op_start = .{};
        self.register.clear();
        self.undo_stack.clear();
        self.status_msg = "";
        self.count = 0;
    }

    /// Save current state to undo stack before making changes
    fn saveUndoState(self: *VimEditor) void {
        self.undo_stack.push(&self.buffer, self.cursor) catch {
            self.status_msg = "undo: out of memory";
        };
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
        // Handle pending replace - next printable char replaces char under cursor
        if (self.pending_replace) {
            self.pending_replace = false;
            if (key >= 32 and key < 127) {
                const line_len = self.buffer.lineLen(self.cursor.row);
                if (self.cursor.col < line_len) {
                    self.saveUndoState();
                    self.buffer.deleteChar(self.cursor);
                    self.buffer.insertChar(self.cursor, key);
                }
            }
            return;
        }

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
            if (self.count > constants.MAX_VIM_COUNT) self.count = constants.MAX_VIM_COUNT;
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
            'h' => motions.moveLeft(&self.cursor, count),
            'j' => motions.moveDown(&self.buffer, &self.cursor, self.mode, count),
            'k' => motions.moveUp(&self.buffer, &self.cursor, self.mode, count),
            'l' => motions.moveRight(&self.buffer, &self.cursor, self.mode, count),
            'w' => motions.moveWordForward(&self.buffer, &self.cursor, self.mode, count),
            'W' => motions.moveWordForward(&self.buffer, &self.cursor, self.mode, count), // Same as w for now
            'b' => motions.moveWordBackward(&self.buffer, &self.cursor, self.mode, count),
            'B' => motions.moveWordBackward(&self.buffer, &self.cursor, self.mode, count),
            'e' => motions.moveWordEnd(&self.buffer, &self.cursor, self.mode, count),
            'E' => motions.moveWordEnd(&self.buffer, &self.cursor, self.mode, count),
            '0' => self.cursor.col = 0,
            '^' => motions.moveToFirstNonBlank(&self.buffer, &self.cursor),
            '$' => motions.moveToEndOfLine(&self.buffer, &self.cursor),
            'g' => {
                self.pending_g = true;
                return;
            },
            'G' => motions.moveToLastLine(&self.buffer, &self.cursor, self.mode),

            // Insert mode
            'i' => self.mode = .insert,
            'I' => {
                motions.moveToFirstNonBlank(&self.buffer, &self.cursor);
                self.mode = .insert;
            },
            'a' => {
                motions.moveRight(&self.buffer, &self.cursor, self.mode, 1);
                self.mode = .insert;
            },
            'A' => {
                motions.moveToEndOfLine(&self.buffer, &self.cursor);
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
                motions.clampCursor(&self.buffer, &self.cursor, self.mode);
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
                self.register.set(content, false) catch {
                    self.status_msg = "out of memory";
                    return;
                };
                motions.clampCursor(&self.buffer, &self.cursor, self.mode);
            },
            'C' => {
                const content = self.buffer.deleteToEndOfLine(self.cursor) catch {
                    self.status_msg = "out of memory";
                    return;
                };
                defer self.allocator.free(content);
                self.register.set(content, false) catch {
                    self.status_msg = "out of memory";
                    return;
                };
                self.mode = .insert;
            },
            'J' => {
                self.saveUndoState();
                self.buffer.joinLines(self.cursor.row);
            },

            // Paste
            'p' => {
                self.saveUndoState();
                self.pasteAfter();
            },
            'P' => {
                self.saveUndoState();
                self.pasteBefore();
            },

            // Replace single char
            'r' => {
                self.pending_replace = true;
                self.status_msg = "r";
            },

            // Undo
            'u' => {
                if (self.undo_stack.pop(&self.buffer)) |new_cursor| {
                    self.cursor = new_cursor;
                    motions.clampCursor(&self.buffer, &self.cursor, self.mode);
                } else {
                    self.status_msg = "Already at oldest change";
                }
            },

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
            'w' => motions.moveWordForward(&self.buffer, &self.cursor, self.mode, count),
            'b' => motions.moveWordBackward(&self.buffer, &self.cursor, self.mode, count),
            'e' => motions.moveWordEnd(&self.buffer, &self.cursor, self.mode, count),
            'j' => motions.moveDown(&self.buffer, &self.cursor, self.mode, count),
            'k' => motions.moveUp(&self.buffer, &self.cursor, self.mode, count),
            'h' => motions.moveLeft(&self.cursor, count),
            'l' => motions.moveRight(&self.buffer, &self.cursor, self.mode, count),
            '$' => motions.moveToEndOfLine(&self.buffer, &self.cursor),
            '0' => self.cursor.col = 0,
            '^' => motions.moveToFirstNonBlank(&self.buffer, &self.cursor),
            'G' => motions.moveToLastLine(&self.buffer, &self.cursor, self.mode),
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

    fn makeOpContext(self: *VimEditor) operators.Context {
        return .{
            .allocator = self.allocator,
            .buffer = &self.buffer,
            .cursor = &self.cursor,
            .mode = &self.mode,
            .visual_start = &self.visual_start,
            .register = &self.register,
            .status_msg = &self.status_msg,
        };
    }

    fn opLineRange(self: *VimEditor, op: Operator, from_row: usize, to_row: usize) void {
        var ctx = self.makeOpContext();
        operators.opLineRange(&ctx, op, from_row, to_row);
    }

    fn opCharRange(self: *VimEditor, op: Operator, start: Cursor, end: Cursor) void {
        var ctx = self.makeOpContext();
        operators.opCharRange(&ctx, op, start, end);
    }

    fn handleInsert(self: *VimEditor, key: u8) void {
        switch (key) {
            27 => { // Escape
                self.mode = .normal;
                if (self.cursor.col > 0) self.cursor.col -= 1;
                motions.clampCursor(&self.buffer, &self.cursor, self.mode);
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
            'h' => motions.moveLeft(&self.cursor, 1),
            'j' => motions.moveDown(&self.buffer, &self.cursor, self.mode, 1),
            'k' => motions.moveUp(&self.buffer, &self.cursor, self.mode, 1),
            'l' => motions.moveRight(&self.buffer, &self.cursor, self.mode, 1),
            'w' => motions.moveWordForward(&self.buffer, &self.cursor, self.mode, 1),
            'b' => motions.moveWordBackward(&self.buffer, &self.cursor, self.mode, 1),
            'e' => motions.moveWordEnd(&self.buffer, &self.cursor, self.mode, 1),
            '0' => self.cursor.col = 0,
            '$' => motions.moveToEndOfLine(&self.buffer, &self.cursor),
            'G' => motions.moveToLastLine(&self.buffer, &self.cursor, self.mode),
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
        var ctx = self.makeOpContext();
        operators.deleteVisualSelection(&ctx);
    }

    fn yankVisualSelection(self: *VimEditor) void {
        var ctx = self.makeOpContext();
        operators.yankVisualSelection(&ctx);
    }

    fn pasteAfter(self: *VimEditor) void {
        self.register.pasteAfter(&self.buffer, &self.cursor);
        motions.clampCursor(&self.buffer, &self.cursor, self.mode);
    }

    fn pasteBefore(self: *VimEditor) void {
        self.register.pasteBefore(&self.buffer, &self.cursor);
        motions.clampCursor(&self.buffer, &self.cursor, self.mode);
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
