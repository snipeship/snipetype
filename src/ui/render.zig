const ansi = @import("ansi.zig");
const theme_mod = @import("theme.zig");

// Import platform types from consolidated modules
const RenderBuffer = @import("../platform/render_buffer.zig").RenderBuffer;
const Terminal = @import("../platform/terminal.zig").Terminal;
const TypingTest = @import("../core/typing_test.zig").TypingTest;

const BOLD = ansi.BOLD;
const CLEAR_LINE = ansi.CLEAR_LINE;

// ============================================================================
// Common UI Elements
// ============================================================================

/// Render the "ONE" header at top center
fn renderHeader(buf: *RenderBuffer, cx: usize, theme: *const theme_mod.Theme) void {
    buf.moveTo(cx -| 1, 1);
    buf.write(BOLD);
    buf.write(theme.accent);
    buf.write("ONE");
    buf.write(theme.base);
}

/// Render a horizontal divider line
fn renderDivider(buf: *RenderBuffer, cx: usize, y: usize, theme: *const theme_mod.Theme) void {
    buf.moveTo(cx -| 20, y);
    buf.write(theme.dimmer);
    var i: usize = 0;
    while (i < 40) : (i += 1) buf.write("─");
    buf.write(theme.base);
}

/// Render timer display (handles both countdown and elapsed time)
fn renderTimer(buf: *RenderBuffer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    if (t.config.time_limit > 0) {
        const rem = t.getRemainingSeconds();
        if (rem <= 5) {
            buf.write(theme.danger);
            buf.write(BOLD);
        } else if (rem <= 10) {
            buf.write(theme.extra);
        } else {
            buf.write(theme.dim);
        }
        buf.print("{d:.1}s", .{rem});
    } else {
        buf.write(theme.dim);
        buf.print("{d:.1}s", .{t.getElapsedSeconds()});
    }
    buf.write(theme.base);
}

/// Render live WPM display
fn renderWPM(buf: *RenderBuffer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const wpm = t.getLiveWPM();
    if (wpm > 0) {
        buf.write("  ");
        buf.write(theme.accent);
        buf.print("{d:.0}", .{wpm});
        buf.write(theme.base);
        buf.write(theme.dimmer);
        buf.write(" wpm");
        buf.write(theme.base);
    }
}

// ============================================================================
// Main Render Functions
// ============================================================================

// Render (words/sentences/code)

pub fn renderSimple(buf: *RenderBuffer, term: *Terminal, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const cx = term.width / 2;
    const cy = term.height / 2;
    const base = theme.base;

    renderHeader(buf, cx, theme);

    buf.moveTo(cx -| 10, 2);
    buf.write(theme.dim);
    buf.write(t.config.mode.name());
    if (t.config.mode == .code) {
        buf.write(" · ");
        buf.write(t.config.lang.name());
    }
    if (t.config.time_limit > 0) {
        buf.print(" · {d}s", .{t.config.time_limit});
    }
    buf.write(base);

    renderDivider(buf, cx, 4, theme);

    buf.moveTo(0, cy -| 2);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 15, cy -| 2);

    switch (t.state) {
        .waiting => {
            buf.write(theme.dim);
            buf.write("start typing...");
            buf.write(base);
        },
        .typing => {
            renderTimer(buf, t, theme);
            renderWPM(buf, t, theme);

            if (t.target_text.len > 0) {
                const pct = @as(f64, @floatFromInt(t.typed.items.len)) / @as(f64, @floatFromInt(t.target_text.len)) * 100;
                buf.write("  ");
                buf.write(theme.dimmer);
                buf.print("{d:.0}%", .{pct});
                buf.write(base);
            }
        },
        .finished => {
            buf.write(theme.success);
            buf.write(BOLD);
            buf.write("complete!");
            buf.write(base);
        },
    }

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
                buf.write(theme.success);
            } else {
                buf.write(theme.error_bg);
                buf.write(theme.danger);
            }
            buf.writeByte(typed[idx]);
            buf.write(base);
        } else if (idx == typed.len) {
            buf.write(theme.cursor_bg);
            buf.write(theme.cursor_fg);
            buf.writeByte(target[idx]);
            buf.write(base);
        } else {
            buf.write(theme.dim);
            buf.writeByte(target[idx]);
            buf.write(base);
        }
    }

    if (t.state == .finished) {
        renderResults(buf, term, t, theme, cy);
    }

    renderFooter(buf, term, t, theme);
}

// Render (vim mode)

pub fn renderVim(buf: *RenderBuffer, term: *Terminal, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const cx = term.width / 2;
    const target_lines = t.target_lines.items;
    const vim = &t.vim;
    const base = theme.base;

    const total_lines = @max(target_lines.len, vim.buffer.lineCount());
    const start_y = (term.height -| total_lines -| 6) / 2 + 3;

    // When the vim buffer shrinks (e.g. deleting many newlines), the content area can move
    // and we must clear lines that are no longer drawn to avoid leaving stale text behind.
    const content_start_y: usize = 4;
    const content_end_y: usize = term.height -| 3;
    if (content_end_y >= content_start_y) {
        var y: usize = content_start_y;
        while (y <= content_end_y) : (y += 1) {
            buf.moveTo(0, y);
            buf.write(CLEAR_LINE);
        }
    }

    renderHeader(buf, cx, theme);

    buf.moveTo(0, 2);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 15, 2);
    buf.write(theme.dim);
    buf.write("vim");
    buf.write(base);
    buf.write(" · ");
    buf.write(t.config.lang.name());
    buf.write(" · ");

    switch (vim.mode) {
        .normal => {
            buf.write(theme.warning);
            buf.write(BOLD);
            buf.write("NORMAL");
            buf.write(base);
        },
        .insert => {
            buf.write(theme.success);
            buf.write(BOLD);
            buf.write("INSERT");
            buf.write(base);
        },
        .visual => {
            buf.write(theme.info);
            buf.write(BOLD);
            buf.write("VISUAL");
            buf.write(base);
        },
        .visual_line => {
            buf.write(theme.info);
            buf.write(BOLD);
            buf.write("V-LINE");
            buf.write(base);
        },
    }

    if (t.config.time_limit > 0) {
        buf.write(theme.dim);
        buf.print(" · {d}s", .{t.config.time_limit});
        buf.write(base);
    }

    buf.moveTo(0, 3);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 15, 3);
    switch (t.state) {
        .waiting => {
            buf.write(theme.dim);
            buf.write("press i to start typing...");
            buf.write(base);
        },
        .typing => {
            renderTimer(buf, t, theme);
            renderWPM(buf, t, theme);

            // Cursor position
            buf.write("  ");
            buf.write(theme.dimmer);
            buf.print("L{d}:C{d}", .{ vim.cursor.row + 1, vim.cursor.col + 1 });
            buf.write(base);
        },
        .finished => {
            buf.write(theme.success);
            buf.write(BOLD);
            buf.write("complete!");
            buf.write(base);
        },
    }

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

    const max_display_lines = @min(total_lines, term.height -| 10);

    for (0..max_display_lines) |row| {
        const y = start_y + row;
        buf.moveTo(0, y);
        buf.write(CLEAR_LINE);

        buf.moveTo(start_x -| 4, y);
        buf.write(theme.dimmer);
        buf.print("{d:>3} ", .{row + 1});
        buf.write(base);

        buf.moveTo(start_x, y);

        const target_line = if (row < target_lines.len) target_lines[row] else "";
        const typed_line = vim.buffer.getLine(row);

        const line_len = @max(target_line.len, typed_line.len);
        for (0..line_len) |col| {
            const target_char: ?u8 = if (col < target_line.len) target_line[col] else null;
            const typed_char: ?u8 = if (col < typed_line.len) typed_line[col] else null;
            const is_cursor = vim.cursor.row == row and vim.cursor.col == col;
            const in_visual = vim.isInVisualRange(row, col);

            if (is_cursor) {
                if (vim.mode == .insert) {
                    buf.write(theme.cursor_insert_bg);
                    buf.write(theme.cursor_fg);
                } else {
                    buf.write(theme.cursor_bg);
                    buf.write(theme.cursor_fg);
                }
            } else if (in_visual) {
                buf.write(theme.visual_bg);
                buf.write(theme.visual_fg);
            } else if (typed_char) |tc| {
                if (target_char) |tgt| {
                    if (tc == tgt) {
                        buf.write(theme.success);
                    } else {
                        buf.write(theme.error_bg);
                        buf.write(theme.danger);
                    }
                } else {
                    buf.write(theme.extra); // Extra chars
                }
            } else {
                buf.write(theme.dim);
            }

            if (typed_char) |tc| {
                buf.writeByte(tc);
            } else if (target_char) |tgt| {
                buf.writeByte(tgt);
            } else {
                buf.write(" ");
            }
            buf.write(base);
        }

        if (vim.cursor.row == row and vim.cursor.col >= line_len) {
            if (vim.mode == .insert) {
                buf.write(theme.cursor_insert_bg);
                buf.write(" ");
                buf.write(base);
            } else {
                buf.write(theme.cursor_bg);
                buf.write(" ");
                buf.write(base);
            }
        }
    }

    if (t.state == .finished) {
        renderResults(buf, term, t, theme, start_y + max_display_lines + 1);
    }

    renderFooter(buf, term, t, theme);
}

// Helpers

fn renderResults(buf: *RenderBuffer, term: *Terminal, t: *TypingTest, theme: *const theme_mod.Theme, y: usize) void {
    const cx = term.width / 2;
    const wpm = t.getWPM();
    const acc = t.getAccuracy();
    const base = theme.base;

    buf.moveTo(cx -| 10, y + 1);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 10, y + 1);
    buf.write(BOLD);
    buf.write(theme.accent);
    buf.print("{d:.0}", .{wpm});
    buf.write(base);
    buf.write(theme.dim);
    buf.write(" wpm  ");
    buf.write(base);

    if (acc >= 97) buf.write(theme.success) else if (acc >= 90) buf.write(theme.warning) else buf.write(theme.danger);
    buf.print("{d:.1}%", .{acc});
    buf.write(base);
    buf.write(theme.dim);
    buf.write(" acc");
    buf.write(base);

    buf.moveTo(cx -| 12, y + 3);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx -| 12, y + 3);
    buf.write(theme.dimmer);
    buf.print("{d:.2}s · {d}/{d} chars", .{ t.getElapsedSeconds(), t.correct_chars, t.target_text.len });
    if (t.errors > 0) {
        buf.write(base);
        buf.write(" · ");
        buf.write(theme.danger);
        buf.print("{d} errors", .{t.errors});
    }
    buf.write(base);

    buf.moveTo(cx -| 7, y + 5);
    buf.write(theme.accent);
    buf.write("tab");
    buf.write(base);
    buf.write(theme.dimmer);
    buf.write(" restart");
    buf.write(base);
}

fn renderFooter(buf: *RenderBuffer, term: *Terminal, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const cx = term.width / 2;
    const base = theme.base;

    renderDivider(buf, cx, term.height -| 2, theme);

    buf.moveTo(cx -| 18, term.height);
    if (t.config.mode == .vim) {
        if (t.vim.mode == .insert and t.state != .finished) {
            buf.write(theme.dim);
            buf.write("tab");
            buf.write(base);
            buf.write(theme.dimmer);
            buf.write(" indent  ");
            buf.write(base);
        } else {
            buf.write(theme.dim);
            buf.write("tab");
            buf.write(base);
            buf.write(theme.dimmer);
            buf.write(" new  ");
            buf.write(base);
        }
        buf.write(theme.dim);
        buf.write("esc");
        buf.write(base);
        buf.write(theme.dimmer);
        buf.write(" normal  ");
        buf.write(base);
        buf.write(theme.dim);
        buf.write("v/V");
        buf.write(base);
        buf.write(theme.dimmer);
        buf.write(" visual  ");
        buf.write(base);
    } else {
        buf.write(theme.dim);
        buf.write("tab");
        buf.write(base);
        buf.write(theme.dimmer);
        buf.write(" new  ");
        buf.write(base);
    }
    buf.write(theme.dim);
    buf.write("ctrl+p");
    buf.write(base);
    buf.write(theme.dimmer);
    buf.write(" settings  ");
    buf.write(base);
    buf.write(theme.dim);
    buf.write("ctrl+c");
    buf.write(base);
    buf.write(theme.dimmer);
    buf.write(" quit");
    buf.write(base);
}
