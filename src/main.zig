//! ONE - Typing Speed Test

const std = @import("std");
const one = @import("one");
const posix = std.posix;
const cli = @import("cli.zig");

// Import UI modules through the one library
const ansi = one.ansi;
const render = one.render;
const theme = one.theme;
const settings = one.settings;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = cli.parseArgs(allocator) catch |e| {
        if (e == error.HelpRequested) {
            std.debug.print("{s}", .{cli.HELP});
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

    buf.write(ansi.CLEAR ++ ansi.HIDE_CURSOR);
    buf.flush();

    var seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var test_state = try one.TypingTest.init(allocator, seed, config);
    defer test_state.deinit();

    var dirty: bool = true;
    var needs_full_clear: bool = true;
    var last_state: one.TestState = test_state.state;
    var last_render: i64 = 0;

    var input = one.Input.init();
    var theme_id: theme.ThemeId = .system;
    var settings_ui = settings.Settings{};

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
        while (input.readKey()) |key| {
            switch (key) {
                .Byte => |b| {
                    if (b == 0x03) { // Ctrl+C always quits
                        buf.clear();
                        buf.write(ansi.RESET ++ ansi.CLEAR ++ ansi.SHOW_CURSOR);
                        buf.flush();
                        return;
                    }
                },
                else => {},
            }

            if (settings_ui.is_open) {
                const action = settings_ui.handleKey(key);
                switch (action) {
                    .none => {},
                    .preview_theme => |id| {
                        theme_id = id;
                        needs_full_clear = true;
                    },
                    .apply_mode => |mode| {
                        test_state.config.mode = mode;
                        seed = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
                        try test_state.reset(seed);
                        needs_full_clear = true;
                        last_state = test_state.state;
                    },
                    .close => needs_full_clear = true,
                    .cancel => |id| {
                        theme_id = id;
                        needs_full_clear = true;
                    },
                }
                dirty = true;
                continue;
            }

            switch (key) {
                .Byte => |b| switch (b) {
                    0x10 => { // Ctrl+P
                        settings_ui.open(theme_id, test_state.config.mode);
                        dirty = true;
                    },
                    0x1b => { // Escape
                        if (test_state.config.mode == .vim) {
                            test_state.handleKey(27);
                            dirty = true;
                        } else {
                            buf.clear();
                            buf.write(ansi.RESET ++ ansi.CLEAR ++ ansi.SHOW_CURSOR);
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
                        test_state.handleKey(b);
                        dirty = true;
                    },
                },
                .ArrowUp, .ArrowDown, .ArrowLeft, .ArrowRight => {},
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
            buf.write(ansi.SYNC_BEGIN);
            const palette = theme.resolve(theme_id);
            buf.write(palette.base);
            if (needs_full_clear) {
                buf.write(ansi.CLEAR);
                needs_full_clear = false;
            }
            if (test_state.config.mode == .vim) {
                render.renderVim(&buf, &term, &test_state, palette);
            } else {
                render.renderSimple(&buf, &term, &test_state, palette);
            }
            settings_ui.renderOverlay(&buf, &term, palette, theme_id, test_state.config.mode);
            buf.write(ansi.SYNC_END);
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
