//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║  ONE - Lightning Fast Typing Speed Test                                   ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const one = @import("one");
const posix = std.posix;

// ANSI
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const UNDERLINE = "\x1b[4m";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";
const CLEAR = "\x1b[2J\x1b[H";
const CLEAR_LINE = "\x1b[2K";
const SYNC_BEGIN = "\x1b[?2026h";
const SYNC_END = "\x1b[?2026l";

// Colors
const C_INDIGO = "\x1b[38;2;99;102;241m";
const C_GREEN = "\x1b[38;2;34;197;94m";
const C_RED = "\x1b[38;2;239;68;68m";
const C_YELLOW = "\x1b[38;2;250;204;21m";
const C_ORANGE = "\x1b[38;2;251;146;60m";
const C_CYAN = "\x1b[38;2;34;211;238m";
const C_DIM = "\x1b[38;2;100;100;120m";
const C_DIMMER = "\x1b[38;2;60;60;80m";
const C_WHITE = "\x1b[38;2;255;255;255m";
const C_BG_INDIGO = "\x1b[48;2;99;102;241m";
const C_BG_GREEN = "\x1b[48;2;34;197;94m";
const C_BG_RED = "\x1b[48;2;50;20;20m";
const C_BG_YELLOW = "\x1b[48;2;80;70;20m";
const C_BG_VISUAL = "\x1b[48;2;60;60;100m";

const HELP =
    \\ONE - Typing Speed Test with Vim Editor
    \\
    \\USAGE: one [OPTIONS]
    \\
    \\OPTIONS:
    \\  -m, --mode <MODE>   words | sentences | code | vim
    \\  -w, --words <N>     Number of words/items (default: 10)
    \\  -t, --time <SEC>    Time limit in seconds
    \\  -l, --lang <LANG>   zig | rust | go | ts | python | c | mixed
    \\  -h, --help          Show help
    \\
    \\VIM MODE KEYS:
    \\  Motion:     h j k l w b e 0 $ ^ gg G
    \\  Insert:     i I a A o O s S
    \\  Visual:     v V (then d/c/y to operate)
    \\  Operators:  d dd D c cc C y yy x X
    \\  Other:      p P J r
    \\
    \\EXAMPLES:
    \\  one                      10 random words
    \\  one -m sentences         Coherent sentences
    \\  one -m code -l rust      Rust code snippets
    \\  one -m vim               Multi-line vim editing
    \\  one -m vim -l zig        Zig code in vim mode
    \\  one -t 60                60 second challenge
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |e| {
        if (e == error.HelpRequested) {
            std.debug.print("{s}", .{HELP});
            return;
        }
        std.debug.print("Invalid arguments. Use --help\n", .{});
        return;
    };

    var term = try one.Terminal.init();
    try term.enableRawMode();
    defer term.restore();

    var buf = one.RenderBuffer.init(allocator);
    defer buf.deinit();

    buf.write(CLEAR ++ HIDE_CURSOR);
    buf.flush();

    var seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var test_state = try one.TypingTest.init(allocator, seed, config);
    defer test_state.deinit();

    var dirty: bool = true;
    var needs_full_clear: bool = true;
    var last_state: one.TestState = test_state.state;
    var last_render: i64 = 0;

    while (true) {
        const prev_w = term.width;
        const prev_h = term.height;
        term.updateSize();
        if (term.width != prev_w or term.height != prev_h) {
            dirty = true;
            needs_full_clear = true;
        }

        const now = std.time.milliTimestamp();

        // Input
        while (one.readKey()) |key| {
            switch (key) {
                0x03 => { // Ctrl+C always quits
                    buf.clear();
                    buf.write(CLEAR ++ SHOW_CURSOR);
                    buf.flush();
                    return;
                },
                0x1b => { // Escape
                    if (test_state.config.mode == .vim) {
                        test_state.handleKey(27);
                        dirty = true;
                    } else {
                        buf.clear();
                        buf.write(CLEAR ++ SHOW_CURSOR);
                        buf.flush();
                        return;
                    }
                },
                '\t' => {
                    if (test_state.config.mode == .vim and test_state.vim.mode == .insert and test_state.state != .finished) {
                        test_state.handleKey('\t');
                        dirty = true;
                    } else {
                        seed = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
                        try test_state.reset(seed);
                        dirty = true;
                        needs_full_clear = true;
                        last_state = test_state.state;
                    }
                },
                else => {
                    test_state.handleKey(key);
                    dirty = true;
                },
            }
        }

        test_state.checkTimeLimit();
        if (test_state.state != last_state) {
            last_state = test_state.state;
            dirty = true;
        }

        // Render on change, plus a small timer refresh while typing.
        const timer_refresh_ms: i64 = 100;
        if (dirty or (test_state.state == .typing and now - last_render >= timer_refresh_ms)) {
            last_render = now;
            dirty = false;

            buf.clear();
            buf.write(SYNC_BEGIN);
            if (needs_full_clear) {
                buf.write(CLEAR);
                needs_full_clear = false;
            }
            if (test_state.config.mode == .vim) {
                renderVim(&buf, &term, &test_state);
            } else {
                renderSimple(&buf, &term, &test_state);
            }
            buf.write(SYNC_END);
            buf.flush();
        }

        const poll_wait_ms: i64 = blk: {
            if (dirty) break :blk 0;
            if (test_state.state == .typing) {
                const elapsed = now - last_render;
                break :blk @max(0, timer_refresh_ms - elapsed);
            }
            break :blk 250;
        };

        var fds = [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&fds, @intCast(poll_wait_ms)) catch {};
    }
}

fn parseArgs(allocator: std.mem.Allocator) !one.Config {
    var cfg = one.Config{};
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return error.HelpRequested;
        } else if ((std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--mode")) and i + 1 < args.len) {
            i += 1;
            cfg.mode = one.Mode.fromString(args[i]) orelse return error.InvalidArg;
        } else if ((std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--words")) and i + 1 < args.len) {
            i += 1;
            cfg.word_count = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
            cfg.word_count = @max(1, @min(100, cfg.word_count));
        } else if ((std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--time")) and i + 1 < args.len) {
            i += 1;
            cfg.time_limit = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
        } else if ((std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--lang")) and i + 1 < args.len) {
            i += 1;
            cfg.lang = one.Lang.fromString(args[i]) orelse return error.InvalidArg;
        }
    }
    return cfg;
}

// ═══════════════════════════════════════════════════════════════════════════════
// SIMPLE MODE RENDERER (words, sentences, code)
// ═══════════════════════════════════════════════════════════════════════════════

fn renderSimple(buf: *one.RenderBuffer, term: *one.Terminal, t: *one.TypingTest) void {
    const cx = term.width / 2;
    const cy = term.height / 2;

    // Header
    buf.moveTo(cx -| 1, 1);
    buf.write(BOLD ++ C_INDIGO ++ "ONE" ++ RESET);

    // Mode line
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

    // Results
    if (t.state == .finished) {
        renderResults(buf, term, t, cy);
    }

    // Footer
    renderFooter(buf, term, t);
}

// ═══════════════════════════════════════════════════════════════════════════════
// VIM MODE RENDERER (multi-line with visual mode support)
// ═══════════════════════════════════════════════════════════════════════════════

fn renderVim(buf: *one.RenderBuffer, term: *one.Terminal, t: *one.TypingTest) void {
    const cx = term.width / 2;
    const target_lines = t.target_lines.items;
    const vim = &t.vim;

    // Calculate vertical centering
    const total_lines = @max(target_lines.len, vim.buffer.lineCount());
    const start_y = (term.height -| total_lines -| 6) / 2 + 3;

    // Header
    buf.moveTo(cx -| 1, 1);
    buf.write(BOLD ++ C_INDIGO ++ "ONE" ++ RESET);

    // Mode line with vim mode indicator
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

    // Results
    if (t.state == .finished) {
        renderResults(buf, term, t, start_y + max_display_lines + 1);
    }

    // Footer
    renderFooter(buf, term, t);
}

// ═══════════════════════════════════════════════════════════════════════════════
// SHARED RENDER HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

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
