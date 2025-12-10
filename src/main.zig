//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║  ONE - Lightning Fast Typing Speed Test                                   ║
//! ║                                                                           ║
//! ║  Test your typing speed with a beautiful, minimal TUI.                    ║
//! ║  Type 10 random words as fast as you can!                                 ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const one = @import("one");
const posix = std.posix;

// ANSI escape codes
const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const BOLD = ESC ++ "[1m";
const DIM = ESC ++ "[2m";
const HIDE_CURSOR = ESC ++ "[?25l";
const SHOW_CURSOR = ESC ++ "[?25h";
const CLEAR_SCREEN = ESC ++ "[2J";
const CLEAR_LINE = ESC ++ "[2K";
const HOME = ESC ++ "[H";

// Colors (RGB)
const COL_INDIGO = ESC ++ "[38;2;99;102;241m";
const COL_GREEN = ESC ++ "[38;2;34;197;94m";
const COL_RED = ESC ++ "[38;2;239;68;68m";
const COL_YELLOW = ESC ++ "[38;2;250;204;21m";
const COL_DIM = ESC ++ "[38;2;100;100;120m";
const COL_DIMMER = ESC ++ "[38;2;70;70;90m";
const COL_WHITE = ESC ++ "[38;2;255;255;255m";
const COL_BG_INDIGO = ESC ++ "[48;2;99;102;241m";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal
    var term = try one.Terminal.init();
    try term.enableRawMode();
    defer term.restore();

    // Initialize render buffer
    var buf = one.RenderBuffer.init(allocator);
    defer buf.deinit();

    // Initial setup: clear screen and hide cursor once
    buf.write(CLEAR_SCREEN ++ HIDE_CURSOR ++ HOME);
    buf.flush();

    // Get initial seed from time
    var seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));

    // Initialize typing test
    var test_state = try one.TypingTest.init(allocator, seed);
    defer test_state.deinit();

    // Frame timing
    var last_render: i64 = 0;
    const target_frame_time: i64 = 33; // ~30fps for smooth timer updates

    // Main loop - runs continuously for smooth animation
    var running = true;
    while (running) {
        const now = std.time.milliTimestamp();

        // Process all available input (non-blocking)
        while (one.readKey()) |key| {
            switch (key) {
                0x03 => running = false, // Ctrl+C
                0x1b => running = false, // Escape
                '\t' => {
                    // Tab to restart
                    seed = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
                    try test_state.reset(seed);
                },
                else => {
                    test_state.handleKey(key);
                },
            }
        }

        // Render at target framerate
        if (now - last_render >= target_frame_time) {
            last_render = now;
            try render(&buf, &term, &test_state);
        }

        // Small sleep to prevent CPU spinning
        std.Thread.sleep(1_000_000); // 1ms
    }

    // Cleanup: clear screen and show cursor
    buf.clear();
    buf.write(CLEAR_SCREEN ++ SHOW_CURSOR ++ HOME);
    buf.flush();
}

fn render(buf: *one.RenderBuffer, term: *one.Terminal, test_state: *one.TypingTest) !void {
    buf.clear();

    const cx = term.width / 2;
    const cy = term.height / 2;

    // ─────────────────────────────────────────────────────────────────────────
    // HEADER
    // ─────────────────────────────────────────────────────────────────────────

    // Title
    buf.moveTo(cx - 1, 2);
    buf.write(BOLD ++ COL_INDIGO ++ "ONE" ++ RESET);

    // Subtitle
    const subtitle = "typing speed test";
    buf.moveTo(cx - subtitle.len / 2, 3);
    buf.write(DIM ++ COL_DIM ++ subtitle ++ RESET);

    // Top decorative line
    buf.moveTo(cx - 20, 5);
    buf.write(COL_DIMMER);
    for (0..40) |_| buf.write("─");
    buf.write(RESET);

    // ─────────────────────────────────────────────────────────────────────────
    // LIVE STATS (during typing)
    // ─────────────────────────────────────────────────────────────────────────

    buf.moveTo(cx - 20, cy - 3);
    buf.write(CLEAR_LINE);
    buf.moveTo(cx - 20, cy - 3);

    switch (test_state.state) {
        .waiting => {
            buf.write(COL_DIM ++ "start typing..." ++ RESET);
        },
        .typing => {
            const elapsed = test_state.getElapsedSeconds();
            const live_wpm = test_state.getLiveWPM();

            buf.write(COL_DIM);
            buf.print("{d:.1}s", .{elapsed});
            buf.write(RESET);

            if (live_wpm > 0) {
                buf.write("  " ++ COL_INDIGO);
                buf.print("{d:.0}", .{live_wpm});
                buf.write(RESET ++ COL_DIMMER ++ " wpm" ++ RESET);
            }
        },
        .finished => {
            buf.write(COL_GREEN ++ BOLD ++ "complete!" ++ RESET);
        },
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TYPING AREA
    // ─────────────────────────────────────────────────────────────────────────

    const target = test_state.target;
    const typed = test_state.typed.items;

    // Center the text
    const text_x = if (cx > target.len / 2) cx - target.len / 2 else 2;

    buf.moveTo(text_x, cy);

    // Render each character with appropriate styling
    for (target, 0..) |char, i| {
        if (i < typed.len) {
            if (typed[i] == char) {
                // Correct - green
                buf.write(COL_GREEN);
                buf.writeByte(char);
            } else {
                // Wrong - red
                buf.write(COL_RED);
                buf.writeByte(typed[i]);
            }
        } else if (i == typed.len) {
            // Cursor position - inverted
            buf.write(COL_BG_INDIGO ++ COL_WHITE);
            buf.writeByte(char);
            buf.write(RESET);
        } else {
            // Not yet typed - dim
            buf.write(COL_DIM);
            buf.writeByte(char);
        }
    }

    // Extra typed characters (overflow) in red
    if (typed.len > target.len) {
        buf.write(COL_RED);
        buf.write(typed[target.len..]);
    }

    buf.write(RESET);

    // ─────────────────────────────────────────────────────────────────────────
    // RESULTS (after completion)
    // ─────────────────────────────────────────────────────────────────────────

    // Clear the results area first to prevent ghosting
    for (0..6) |i| {
        buf.moveTo(0, cy + 3 + i);
        buf.write(CLEAR_LINE);
    }

    if (test_state.state == .finished) {
        const wpm = test_state.getWPM();
        const accuracy = test_state.getAccuracy();
        const elapsed = test_state.getElapsedSeconds();

        // WPM - big display
        buf.moveTo(cx - 10, cy + 3);
        buf.write(BOLD ++ COL_INDIGO);
        buf.print("{d:.0}", .{wpm});
        buf.write(RESET ++ COL_DIM ++ " wpm" ++ RESET);

        // Accuracy
        buf.write("    ");
        if (accuracy >= 95) {
            buf.write(COL_GREEN);
        } else if (accuracy >= 80) {
            buf.write(COL_YELLOW);
        } else {
            buf.write(COL_RED);
        }
        buf.print("{d:.1}%", .{accuracy});
        buf.write(RESET ++ COL_DIM ++ " accuracy" ++ RESET);

        // Details row
        buf.moveTo(cx - 12, cy + 5);
        buf.write(COL_DIMMER);
        buf.print("time: {d:.2}s  ", .{elapsed});
        buf.print("chars: {d}/{d}  ", .{ test_state.correct_chars, target.len });
        if (test_state.errors > 0) {
            buf.write(RESET ++ COL_RED);
            buf.print("errors: {d}", .{test_state.errors});
        }
        buf.write(RESET);

        // Restart hint
        buf.moveTo(cx - 7, cy + 7);
        buf.write(COL_INDIGO ++ "tab" ++ RESET);
        buf.write(COL_DIMMER ++ " to restart" ++ RESET);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FOOTER
    // ─────────────────────────────────────────────────────────────────────────

    // Bottom decorative line
    buf.moveTo(cx - 20, term.height - 4);
    buf.write(COL_DIMMER);
    for (0..40) |_| buf.write("─");
    buf.write(RESET);

    // Controls
    buf.moveTo(cx - 12, term.height - 2);
    buf.write(COL_DIM ++ "tab" ++ RESET ++ COL_DIMMER ++ " restart  " ++ RESET);
    buf.write(COL_DIM ++ "esc" ++ RESET ++ COL_DIMMER ++ " quit" ++ RESET);

    // Flush everything to screen in one write
    buf.flush();
}
