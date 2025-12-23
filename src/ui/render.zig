const one = @import("one");
const ansi = @import("ansi.zig");

const RESET = ansi.RESET;
const BOLD = ansi.BOLD;
const CLEAR_LINE = ansi.CLEAR_LINE;
const C_INDIGO = ansi.C_INDIGO;
const C_GREEN = ansi.C_GREEN;
const C_RED = ansi.C_RED;
const C_YELLOW = ansi.C_YELLOW;
const C_ORANGE = ansi.C_ORANGE;
const C_CYAN = ansi.C_CYAN;
const C_DIM = ansi.C_DIM;
const C_DIMMER = ansi.C_DIMMER;
const C_WHITE = ansi.C_WHITE;
const C_BG_INDIGO = ansi.C_BG_INDIGO;
const C_BG_GREEN = ansi.C_BG_GREEN;
const C_BG_RED = ansi.C_BG_RED;
const C_BG_VISUAL = ansi.C_BG_VISUAL;

// Render (words/sentences/code)

pub fn renderSimple(buf: *one.RenderBuffer, term: *one.Terminal, t: *one.TypingTest) void {
    const cx = term.width / 2;
    const cy = term.height / 2;

    buf.moveTo(cx -| 1, 1);
    buf.write(BOLD ++ C_INDIGO ++ "ONE" ++ RESET);

    buf.moveTo(cx -| 10, 2);
    buf.write(C_DIM);
    buf.write(t.config.mode.name());
    if (t.config.mode == .code) {
        buf.write(" · ");
        buf.write(t.config.lang.name());
    }
    if (t.config.time_limit > 0) {
        buf.print(" · {d}s", .{t.config.time_limit});
    }
    buf.write(RESET);

    // Divider
    buf.moveTo(cx -| 20, 4);
    buf.write(C_DIMMER);
    var i: usize = 0;
    while (i < 40) : (i += 1) buf.write("─");
    buf.write(RESET);

    // Stats line
    buf.moveTo(0, cy -| 2);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 15, cy -| 2);

    switch (t.state) {
        .waiting => {
            buf.write(C_DIM ++ "start typing..." ++ RESET);
        },
        .typing => {
            if (t.config.time_limit > 0) {
                const rem = t.getRemainingSeconds();
                if (rem <= 5) buf.write(C_RED ++ BOLD) else if (rem <= 10) buf.write(C_ORANGE) else buf.write(C_DIM);
                buf.print("{d:.1}s", .{rem});
            } else {
                buf.write(C_DIM);
                buf.print("{d:.1}s", .{t.getElapsedSeconds()});
            }
            buf.write(RESET);

            const wpm = t.getLiveWPM();
            if (wpm > 0) {
                buf.write("  " ++ C_INDIGO);
                buf.print("{d:.0}", .{wpm});
                buf.write(RESET ++ C_DIMMER ++ " wpm" ++ RESET);
            }

            if (t.target_text.len > 0) {
                const pct = @as(f64, @floatFromInt(t.typed.items.len)) / @as(f64, @floatFromInt(t.target_text.len)) * 100;
                buf.write("  " ++ C_DIMMER);
                buf.print("{d:.0}%", .{pct});
                buf.write(RESET);
            }
        },
        .finished => {
            buf.write(C_GREEN ++ BOLD ++ "complete!" ++ RESET);
        },
    }

    // Main text
    buf.moveTo(0, cy);
    buf.write(CLEAR_LINE);

    const target = t.target_text;
    const typed = t.typed.items;
    const max_w = term.width -| 4;
    const text_len = @max(target.len, typed.len);
    const start_x = if (text_len < max_w) (term.width -| text_len) / 2 else 2;

    buf.moveTo(start_x, cy);

    for (0..target.len) |idx| {
        if (idx < typed.len) {
            if (typed[idx] == target[idx]) {
                buf.write(C_GREEN);
            } else {
                buf.write(C_BG_RED ++ C_RED);
            }
            buf.writeByte(typed[idx]);
            buf.write(RESET);
        } else if (idx == typed.len) {
            buf.write(C_BG_INDIGO ++ C_WHITE);
            buf.writeByte(target[idx]);
            buf.write(RESET);
        } else {
            buf.write(C_DIM);
            buf.writeByte(target[idx]);
            buf.write(RESET);
        }
    }

    if (t.state == .finished) {
        renderResults(buf, term, t, cy);
    }

    renderFooter(buf, term, t);
}

// Render (vim mode)

pub fn renderVim(buf: *one.RenderBuffer, term: *one.Terminal, t: *one.TypingTest) void {
    const cx = term.width / 2;
    const target_lines = t.target_lines.items;
    const vim = &t.vim;

    const total_lines = @max(target_lines.len, vim.buffer.lineCount());
    const start_y = (term.height -| total_lines -| 6) / 2 + 3;

    buf.moveTo(cx -| 1, 1);
    buf.write(BOLD ++ C_INDIGO ++ "ONE" ++ RESET);

    buf.moveTo(0, 2);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 15, 2);
    buf.write(C_DIM ++ "vim" ++ RESET);
    buf.write(" · ");
    buf.write(t.config.lang.name());
    buf.write(" · ");

    switch (vim.mode) {
        .normal => buf.write(C_YELLOW ++ BOLD ++ "NORMAL" ++ RESET),
        .insert => buf.write(C_GREEN ++ BOLD ++ "INSERT" ++ RESET),
        .visual => buf.write(C_CYAN ++ BOLD ++ "VISUAL" ++ RESET),
        .visual_line => buf.write(C_CYAN ++ BOLD ++ "V-LINE" ++ RESET),
    }

    if (t.config.time_limit > 0) {
        buf.write(C_DIM);
        buf.print(" · {d}s", .{t.config.time_limit});
        buf.write(RESET);
    }

    // Stats line
    buf.moveTo(0, 3);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 15, 3);
    switch (t.state) {
        .waiting => {
            buf.write(C_DIM ++ "press i to start typing..." ++ RESET);
        },
        .typing => {
            if (t.config.time_limit > 0) {
                const rem = t.getRemainingSeconds();
                if (rem <= 5) buf.write(C_RED ++ BOLD) else if (rem <= 10) buf.write(C_ORANGE) else buf.write(C_DIM);
                buf.print("{d:.1}s", .{rem});
            } else {
                buf.write(C_DIM);
                buf.print("{d:.1}s", .{t.getElapsedSeconds()});
            }
            buf.write(RESET);

            const wpm = t.getLiveWPM();
            if (wpm > 0) {
                buf.write("  " ++ C_INDIGO);
                buf.print("{d:.0}", .{wpm});
                buf.write(RESET ++ C_DIMMER ++ " wpm" ++ RESET);
            }

            // Cursor position
            buf.write("  " ++ C_DIMMER);
            buf.print("L{d}:C{d}", .{ vim.cursor.row + 1, vim.cursor.col + 1 });
            buf.write(RESET);
        },
        .finished => {
            buf.write(C_GREEN ++ BOLD ++ "complete!" ++ RESET);
        },
    }

    // Calculate max width for centering
    var max_line_len: usize = 0;
    for (target_lines) |line| {
        if (line.len > max_line_len) max_line_len = line.len;
    }
    for (0..vim.buffer.lineCount()) |row| {
        const line = vim.buffer.getLine(row);
        if (line.len > max_line_len) max_line_len = line.len;
    }

    const max_w = term.width -| 8;
    const display_width = @min(max_line_len + 4, max_w);
    const start_x = (term.width -| display_width) / 2;

    // Render lines
    const max_display_lines = @min(total_lines, term.height -| 10);

    for (0..max_display_lines) |row| {
        const y = start_y + row;
        buf.moveTo(0, y);
        buf.write(CLEAR_LINE);

        // Line number gutter
        buf.moveTo(start_x -| 4, y);
        buf.write(C_DIMMER);
        buf.print("{d:>3} ", .{row + 1});
        buf.write(RESET);

        buf.moveTo(start_x, y);

        const target_line = if (row < target_lines.len) target_lines[row] else "";
        const typed_line = vim.buffer.getLine(row);

        // Render character by character
        const line_len = @max(target_line.len, typed_line.len);
        for (0..line_len) |col| {
            const target_char: ?u8 = if (col < target_line.len) target_line[col] else null;
            const typed_char: ?u8 = if (col < typed_line.len) typed_line[col] else null;
            const is_cursor = vim.cursor.row == row and vim.cursor.col == col;
            const in_visual = vim.isInVisualRange(row, col);

            // Determine styling
            if (is_cursor) {
                if (vim.mode == .insert) {
                    buf.write(C_BG_GREEN ++ C_WHITE);
                } else {
                    buf.write(C_BG_INDIGO ++ C_WHITE);
                }
            } else if (in_visual) {
                buf.write(C_BG_VISUAL ++ C_WHITE);
            } else if (typed_char) |tc| {
                if (target_char) |tgt| {
                    if (tc == tgt) {
                        buf.write(C_GREEN);
                    } else {
                        buf.write(C_BG_RED ++ C_RED);
                    }
                } else {
                    buf.write(C_ORANGE); // Extra chars
                }
            } else {
                buf.write(C_DIM);
            }

            // Write character
            if (typed_char) |tc| {
                buf.writeByte(tc);
            } else if (target_char) |tgt| {
                buf.writeByte(tgt);
            } else {
                buf.write(" ");
            }
            buf.write(RESET);
        }

        // Cursor at end of line
        if (vim.cursor.row == row and vim.cursor.col >= line_len) {
            if (vim.mode == .insert) {
                buf.write(C_BG_GREEN ++ " " ++ RESET);
            } else {
                buf.write(C_BG_INDIGO ++ " " ++ RESET);
            }
        }
    }

    if (t.state == .finished) {
        renderResults(buf, term, t, start_y + max_display_lines + 1);
    }

    renderFooter(buf, term, t);
}

// Helpers

fn renderResults(buf: *one.RenderBuffer, term: *one.Terminal, t: *one.TypingTest, y: usize) void {
    const cx = term.width / 2;
    const wpm = t.getWPM();
    const acc = t.getAccuracy();

    buf.moveTo(cx -| 10, y + 1);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 10, y + 1);
    buf.write(BOLD ++ C_INDIGO);
    buf.print("{d:.0}", .{wpm});
    buf.write(RESET ++ C_DIM ++ " wpm  " ++ RESET);

    if (acc >= 97) buf.write(C_GREEN) else if (acc >= 90) buf.write(C_YELLOW) else buf.write(C_RED);
    buf.print("{d:.1}%", .{acc});
    buf.write(RESET ++ C_DIM ++ " acc" ++ RESET);

    buf.moveTo(cx -| 12, y + 3);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 12, y + 3);
    buf.write(C_DIMMER);
    buf.print("{d:.2}s · {d}/{d} chars", .{ t.getElapsedSeconds(), t.correct_chars, t.target_text.len });
    if (t.errors > 0) {
        buf.write(RESET ++ " · " ++ C_RED);
        buf.print("{d} errors", .{t.errors});
    }
    buf.write(RESET);

    buf.moveTo(cx -| 7, y + 5);
    buf.write(C_INDIGO ++ "tab" ++ RESET ++ C_DIMMER ++ " restart" ++ RESET);
}

fn renderFooter(buf: *one.RenderBuffer, term: *one.Terminal, t: *one.TypingTest) void {
    const cx = term.width / 2;

    // Bottom divider
    buf.moveTo(cx -| 20, term.height -| 2);
    buf.write(C_DIMMER);
    var i: usize = 0;
    while (i < 40) : (i += 1) buf.write("─");
    buf.write(RESET);

    // Help line
    buf.moveTo(cx -| 18, term.height);
    if (t.config.mode == .vim) {
        if (t.vim.mode == .insert and t.state != .finished) {
            buf.write(C_DIM ++ "tab" ++ RESET ++ C_DIMMER ++ " indent  " ++ RESET);
        } else {
            buf.write(C_DIM ++ "tab" ++ RESET ++ C_DIMMER ++ " new  " ++ RESET);
        }
        buf.write(C_DIM ++ "esc" ++ RESET ++ C_DIMMER ++ " normal  " ++ RESET);
        buf.write(C_DIM ++ "v/V" ++ RESET ++ C_DIMMER ++ " visual  " ++ RESET);
    } else {
        buf.write(C_DIM ++ "tab" ++ RESET ++ C_DIMMER ++ " new  " ++ RESET);
    }
    buf.write(C_DIM ++ "ctrl+c" ++ RESET ++ C_DIMMER ++ " quit" ++ RESET);
}
