//! UI rendering functions using the abstract Renderer interface.
//! Works with both AnsiRenderer (native) and CellRenderer (web).

const theme_mod = @import("theme.zig");
const Color = @import("color.zig").Color;
const Renderer = @import("../platform/renderer.zig").Renderer;
const TypingTest = @import("../core/typing_test.zig").TypingTest;

// ============================================================================
// Common UI Elements
// ============================================================================

/// Render the "ONE" header at top center
fn renderHeader(r: Renderer, cx: usize, theme: *const theme_mod.Theme) void {
    r.moveTo(cx -| 1, 1);
    r.setBold(true);
    r.setFg(theme.accent);
    r.write("ONE");
    r.resetStyle();
}

/// Render a horizontal divider line
fn renderDivider(r: Renderer, cx: usize, y: usize, theme: *const theme_mod.Theme) void {
    const w = r.width();
    const div_width = @min(40, w -| 4); // Leave 2 char margin on each side
    const start_x = cx -| (div_width / 2);

    r.moveTo(start_x, y);
    r.setFg(theme.dimmer);
    var i: usize = 0;
    while (i < div_width) : (i += 1) r.write("-");
    r.resetStyle();
}

/// Render timer display (handles both countdown and elapsed time)
fn renderTimer(r: Renderer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    if (t.config.time_limit > 0) {
        const rem = t.getRemainingSeconds();
        if (rem <= 5) {
            r.setFg(theme.danger);
            r.setBold(true);
        } else if (rem <= 10) {
            r.setFg(theme.extra);
        } else {
            r.setFg(theme.dim);
        }
        r.print("{d:.1}s", .{rem});
    } else {
        r.setFg(theme.dim);
        r.print("{d:.1}s", .{t.getElapsedSeconds()});
    }
    r.resetStyle();
}

/// Render live WPM display
fn renderWPM(r: Renderer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const wpm = t.getLiveWPM();
    if (wpm > 0) {
        r.write("  ");
        r.setFg(theme.accent);
        r.print("{d:.0}", .{wpm});
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" wpm");
        r.resetStyle();
    }
}

// ============================================================================
// Main Render Functions
// ============================================================================

/// Render simple mode (words/sentences/code)
pub fn renderSimple(r: Renderer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const cx = r.width() / 2;
    const cy = r.height() / 2;

    // Clear header and mode lines to avoid stale content
    r.moveTo(0, 1);
    r.clearLine();
    r.moveTo(0, 2);
    r.clearLine();

    renderHeader(r, cx, theme);

    r.moveTo(cx -| 10, 2);
    r.setFg(theme.dim);
    r.write(t.config.mode.name());
    if (t.config.mode == .code) {
        r.write(" . ");
        r.write(t.config.lang.name());
    }
    if (t.config.time_limit > 0) {
        r.print(" . {d}s", .{t.config.time_limit});
    }
    r.resetStyle();

    renderDivider(r, cx, 4, theme);

    r.moveTo(0, cy -| 2);
    r.clearLine();
    r.moveTo(cx -| 15, cy -| 2);

    switch (t.state) {
        .waiting => {
            r.setFg(theme.dim);
            r.write("start typing...");
            r.resetStyle();
        },
        .typing => {
            renderTimer(r, t, theme);
            renderWPM(r, t, theme);

            if (t.target_text.len > 0) {
                const pct = @as(f64, @floatFromInt(t.typed.items.len)) / @as(f64, @floatFromInt(t.target_text.len)) * 100;
                r.write("  ");
                r.setFg(theme.dimmer);
                r.print("{d:.0}%", .{pct});
                r.resetStyle();
            }
        },
        .finished => {
            r.setFg(theme.success);
            r.setBold(true);
            r.write("complete!");
            r.resetStyle();
        },
    }

    r.moveTo(0, cy);
    r.clearLine();

    const target = t.target_text;
    const typed = t.typed.items;
    const max_w = r.width() -| 4;
    const text_len = @max(target.len, typed.len);
    const start_x = if (text_len < max_w) (r.width() -| text_len) / 2 else 2;

    r.moveTo(start_x, cy);

    for (0..target.len) |idx| {
        if (idx < typed.len) {
            if (typed[idx] == target[idx]) {
                r.setFg(theme.success);
            } else {
                r.setBg(theme.error_bg);
                r.setFg(theme.danger);
            }
            r.writeByte(typed[idx]);
            r.resetStyle();
        } else if (idx == typed.len) {
            r.setBg(theme.cursor_bg);
            r.setFg(theme.cursor_fg);
            r.writeByte(target[idx]);
            r.resetStyle();
        } else {
            r.setFg(theme.dim);
            r.writeByte(target[idx]);
            r.resetStyle();
        }
    }

    if (t.state == .finished) {
        renderResults(r, t, theme, cy);
    }

    renderFooter(r, t, theme);
}

/// Render vim mode
pub fn renderVim(r: Renderer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const cx = r.width() / 2;
    const target_lines = t.target_lines.items;
    const vim = &t.vim;

    const total_lines = @max(target_lines.len, vim.buffer.lineCount());
    const start_y = (r.height() -| total_lines -| 6) / 2 + 3;

    // Clear content area to avoid stale text
    const content_start_y: usize = 4;
    const content_end_y: usize = r.height() -| 3;
    if (content_end_y >= content_start_y) {
        var y: usize = content_start_y;
        while (y <= content_end_y) : (y += 1) {
            r.moveTo(0, y);
            r.clearLine();
        }
    }

    // Clear header and status lines to avoid stale content
    r.moveTo(0, 1);
    r.clearLine();
    r.moveTo(0, 2);
    r.clearLine();
    r.moveTo(0, 3);
    r.clearLine();

    renderHeader(r, cx, theme);

    r.moveTo(cx -| 15, 2);
    r.setFg(theme.dim);
    r.write("vim");
    r.resetStyle();
    r.write(" . ");
    r.write(t.config.lang.name());
    r.write(" . ");

    switch (vim.mode) {
        .normal => {
            r.setFg(theme.warning);
            r.setBold(true);
            r.write("NORMAL");
            r.resetStyle();
        },
        .insert => {
            r.setFg(theme.success);
            r.setBold(true);
            r.write("INSERT");
            r.resetStyle();
        },
        .visual => {
            r.setFg(theme.info);
            r.setBold(true);
            r.write("VISUAL");
            r.resetStyle();
        },
        .visual_line => {
            r.setFg(theme.info);
            r.setBold(true);
            r.write("V-LINE");
            r.resetStyle();
        },
    }

    if (t.config.time_limit > 0) {
        r.setFg(theme.dim);
        r.print(" . {d}s", .{t.config.time_limit});
        r.resetStyle();
    }

    r.moveTo(0, 3);
    r.clearLine();
    r.moveTo(cx -| 15, 3);
    switch (t.state) {
        .waiting => {
            r.setFg(theme.dim);
            r.write("press i to start typing...");
            r.resetStyle();
        },
        .typing => {
            renderTimer(r, t, theme);
            renderWPM(r, t, theme);

            r.write("  ");
            r.setFg(theme.dimmer);
            r.print("L{d}:C{d}", .{ vim.cursor.row + 1, vim.cursor.col + 1 });
            r.resetStyle();
        },
        .finished => {
            r.setFg(theme.success);
            r.setBold(true);
            r.write("complete!");
            r.resetStyle();
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

    const max_w = r.width() -| 8;
    const display_width = @min(max_line_len + 4, max_w);
    const start_x = (r.width() -| display_width) / 2;

    const max_display_lines = @min(total_lines, r.height() -| 10);

    for (0..max_display_lines) |row| {
        const y = start_y + row;
        r.moveTo(0, y);
        r.clearLine();

        r.moveTo(start_x -| 4, y);
        r.setFg(theme.dimmer);
        r.print("{d:>3} ", .{row + 1});
        r.resetStyle();

        r.moveTo(start_x, y);

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
                    r.setBg(theme.cursor_insert_bg);
                    r.setFg(theme.cursor_fg);
                } else {
                    r.setBg(theme.cursor_bg);
                    r.setFg(theme.cursor_fg);
                }
            } else if (in_visual) {
                r.setBg(theme.visual_bg);
                r.setFg(theme.visual_fg);
            } else if (typed_char) |tc| {
                if (target_char) |tgt| {
                    if (tc == tgt) {
                        r.setFg(theme.success);
                    } else {
                        r.setBg(theme.error_bg);
                        r.setFg(theme.danger);
                    }
                } else {
                    r.setFg(theme.extra);
                }
            } else {
                r.setFg(theme.dim);
            }

            if (typed_char) |tc| {
                r.writeByte(tc);
            } else if (target_char) |tgt| {
                r.writeByte(tgt);
            } else {
                r.write(" ");
            }
            r.resetStyle();
        }

        if (vim.cursor.row == row and vim.cursor.col >= line_len) {
            if (vim.mode == .insert) {
                r.setBg(theme.cursor_insert_bg);
                r.write(" ");
                r.resetStyle();
            } else {
                r.setBg(theme.cursor_bg);
                r.write(" ");
                r.resetStyle();
            }
        }
    }

    if (t.state == .finished) {
        renderResults(r, t, theme, start_y + max_display_lines + 1);
    }

    renderFooter(r, t, theme);
}

// ============================================================================
// Helpers
// ============================================================================

fn renderResults(r: Renderer, t: *TypingTest, theme: *const theme_mod.Theme, y: usize) void {
    const cx = r.width() / 2;
    const wpm = t.getWPM();
    const acc = t.getAccuracy();

    r.moveTo(cx -| 10, y + 1);
    r.clearLine();
    r.moveTo(cx -| 10, y + 1);
    r.setBold(true);
    r.setFg(theme.accent);
    r.print("{d:.0}", .{wpm});
    r.resetStyle();
    r.setFg(theme.dim);
    r.write(" wpm  ");
    r.resetStyle();

    if (acc >= 97) {
        r.setFg(theme.success);
    } else if (acc >= 90) {
        r.setFg(theme.warning);
    } else {
        r.setFg(theme.danger);
    }
    r.print("{d:.1}%", .{acc});
    r.resetStyle();
    r.setFg(theme.dim);
    r.write(" acc");
    r.resetStyle();

    r.moveTo(cx -| 12, y + 3);
    r.clearLine();
    r.moveTo(cx -| 12, y + 3);
    r.setFg(theme.dimmer);
    r.print("{d:.2}s . {d}/{d} chars", .{ t.getElapsedSeconds(), t.correct_chars, t.target_text.len });
    if (t.errors > 0) {
        r.resetStyle();
        r.write(" . ");
        r.setFg(theme.danger);
        r.print("{d} errors", .{t.errors});
    }
    r.resetStyle();

    r.moveTo(cx -| 7, y + 5);
    r.setFg(theme.accent);
    r.write("tab");
    r.resetStyle();
    r.setFg(theme.dimmer);
    r.write(" restart");
    r.resetStyle();
}

fn renderFooter(r: Renderer, t: *TypingTest, theme: *const theme_mod.Theme) void {
    const w = r.width();
    const cx = w / 2;

    renderDivider(r, cx, r.height() -| 2, theme);

    // Clear footer line
    r.moveTo(0, r.height());
    r.clearLine();

    // Adaptive footer based on screen width
    const is_vim = t.config.mode == .vim;
    const is_vim_insert = is_vim and t.vim.mode == .insert and t.state != .finished;

    // Calculate content and center it
    // Minimal: "tab  ctrl+c" (11 chars)
    // Small: "tab new  ctrl+c quit" (20 chars)
    // Medium: add "ctrl+p settings" (36 chars)
    // Full vim: add "esc normal  v/V visual" (58 chars)

    if (w < 30) {
        // Minimal - just essential keys
        r.moveTo(cx -| 5, r.height());
        r.setFg(theme.dim);
        r.write("tab");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write("  ");
        r.setFg(theme.dim);
        r.write("ctrl+c");
        r.resetStyle();
    } else if (w < 50) {
        // Small screen
        r.moveTo(cx -| 10, r.height());
        r.setFg(theme.dim);
        r.write("tab");
        r.resetStyle();
        r.setFg(theme.dimmer);
        if (is_vim_insert) r.write(" indent  ") else r.write(" new  ");
        r.setFg(theme.dim);
        r.write("ctrl+c");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" quit");
        r.resetStyle();
    } else if (w < 70 or !is_vim) {
        // Medium screen or non-vim mode
        r.moveTo(cx -| 18, r.height());
        r.setFg(theme.dim);
        r.write("tab");
        r.resetStyle();
        r.setFg(theme.dimmer);
        if (is_vim_insert) r.write(" indent  ") else r.write(" new  ");
        r.setFg(theme.dim);
        r.write("ctrl+p");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" settings  ");
        r.setFg(theme.dim);
        r.write("ctrl+c");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" quit");
        r.resetStyle();
    } else {
        // Full vim footer
        r.moveTo(cx -| 29, r.height());
        r.setFg(theme.dim);
        r.write("tab");
        r.resetStyle();
        r.setFg(theme.dimmer);
        if (is_vim_insert) r.write(" indent  ") else r.write(" new  ");
        r.setFg(theme.dim);
        r.write("esc");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" normal  ");
        r.setFg(theme.dim);
        r.write("v/V");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" visual  ");
        r.setFg(theme.dim);
        r.write("ctrl+p");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" settings  ");
        r.setFg(theme.dim);
        r.write("ctrl+c");
        r.resetStyle();
        r.setFg(theme.dimmer);
        r.write(" quit");
        r.resetStyle();
    }
}
