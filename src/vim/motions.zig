const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const VimMode = @import("mode.zig").VimMode;

pub fn moveLeft(cursor: *Cursor, count: usize) void {
    cursor.col -|= count;
}

pub fn moveRight(buffer: *const Buffer, cursor: *Cursor, mode: VimMode, count: usize) void {
    const max_col = buffer.lineLen(cursor.row);
    const target = if (mode == .insert) max_col else max_col -| 1;
    cursor.col = @min(cursor.col + count, target);
}

pub fn moveUp(buffer: *const Buffer, cursor: *Cursor, mode: VimMode, count: usize) void {
    cursor.row -|= count;
    clampCursor(buffer, cursor, mode);
}

pub fn moveDown(buffer: *const Buffer, cursor: *Cursor, mode: VimMode, count: usize) void {
    cursor.row = @min(cursor.row + count, buffer.lineCount() -| 1);
    clampCursor(buffer, cursor, mode);
}

pub fn moveWordForward(buffer: *const Buffer, cursor: *Cursor, mode: VimMode, count: usize) void {
    for (0..count) |_| {
        const line = buffer.getLine(cursor.row);
        var col = cursor.col;

        // Skip current word
        while (col < line.len and !isWordBoundary(line[col])) col += 1;
        // Skip whitespace
        while (col < line.len and line[col] == ' ') col += 1;

        if (col >= line.len and cursor.row + 1 < buffer.lineCount()) {
            cursor.row += 1;
            cursor.col = 0;
            // Skip leading whitespace on new line
            const new_line = buffer.getLine(cursor.row);
            while (cursor.col < new_line.len and new_line[cursor.col] == ' ') {
                cursor.col += 1;
            }
        } else {
            cursor.col = col;
        }
    }

    clampCursor(buffer, cursor, mode);
}

pub fn moveWordBackward(buffer: *const Buffer, cursor: *Cursor, mode: VimMode, count: usize) void {
    for (0..count) |_| {
        if (cursor.col == 0) {
            if (cursor.row > 0) {
                cursor.row -= 1;
                cursor.col = buffer.lineLen(cursor.row);
            }
            continue;
        }

        const line = buffer.getLine(cursor.row);
        var col = cursor.col -| 1;

        // Skip whitespace
        while (col > 0 and line[col] == ' ') col -= 1;
        // Skip word
        while (col > 0 and !isWordBoundary(line[col - 1])) col -= 1;

        cursor.col = col;
    }

    clampCursor(buffer, cursor, mode);
}

pub fn moveWordEnd(buffer: *const Buffer, cursor: *Cursor, mode: VimMode, count: usize) void {
    for (0..count) |_| {
        const line = buffer.getLine(cursor.row);
        var col = cursor.col + 1;

        // Skip whitespace
        while (col < line.len and line[col] == ' ') col += 1;
        // Skip to end of word
        while (col < line.len and !isWordBoundary(line[col])) col += 1;

        if (col > 0) col -= 1;
        cursor.col = col;
    }

    clampCursor(buffer, cursor, mode);
}

pub fn moveToFirstNonBlank(buffer: *const Buffer, cursor: *Cursor) void {
    const line = buffer.getLine(cursor.row);
    cursor.col = 0;
    while (cursor.col < line.len and line[cursor.col] == ' ') {
        cursor.col += 1;
    }
}

pub fn moveToEndOfLine(buffer: *const Buffer, cursor: *Cursor) void {
    cursor.col = buffer.lineLen(cursor.row) -| 1;
}

pub fn moveToLastLine(buffer: *const Buffer, cursor: *Cursor, mode: VimMode) void {
    cursor.row = buffer.lineCount() -| 1;
    clampCursor(buffer, cursor, mode);
}

pub fn clampCursor(buffer: *const Buffer, cursor: *Cursor, mode: VimMode) void {
    if (cursor.row >= buffer.lineCount()) {
        cursor.row = buffer.lineCount() -| 1;
    }
    const max_col = buffer.lineLen(cursor.row);
    if (mode == .insert) {
        if (cursor.col > max_col) cursor.col = max_col;
    } else {
        if (cursor.col >= max_col and max_col > 0) {
            cursor.col = max_col - 1;
        } else if (max_col == 0) {
            cursor.col = 0;
        }
    }
}

fn isWordBoundary(c: u8) bool {
    return c == ' ' or c == '.' or c == ',' or c == ';' or c == ':' or
        c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}' or
        c == '<' or c == '>' or c == '"' or c == '\'' or c == '=' or c == '+' or
        c == '-' or c == '*' or c == '/' or c == '\\' or c == '|' or c == '&';
}
