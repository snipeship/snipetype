//! snipetype - Terminal Typing Test (Native CLI Entry Point)

const std = @import("std");
const snipetype = @import("snipetype");
const posix = std.posix;
const cli = @import("cli.zig");

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

    var term = try snipetype.Terminal.init();
    try term.enableRawMode();
    defer term.restore();

    var ansi_renderer = snipetype.AnsiRenderer.init(allocator, term.width, term.height);
    defer ansi_renderer.deinit();

    // Initial setup: clear screen and hide cursor
    ansi_renderer.hideCursor();
    var r = ansi_renderer.renderer();
    r.clear();
    r.flush();

    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var app = try snipetype.App.init(allocator, seed, config);
    defer app.deinit();

    var input = snipetype.Input.init();

    while (true) {
        // Check for terminal resize
        const prev_w = term.width;
        const prev_h = term.height;
        term.updateSize();
        if (term.width != prev_w or term.height != prev_h) {
            ansi_renderer.setSize(term.width, term.height);
            app.onResize();
        }

        const now = std.time.milliTimestamp();

        // Process input
        while (input.readKey()) |key| {
            // Handle Ctrl+C specially - always quits in native
            if (key == .Byte and key.Byte == 0x03) {
                ansi_renderer.clearBuffer();
                r.clear();
                ansi_renderer.showCursor();
                r.flush();
                return;
            }

            const result = app.handleKey(key, false);
            if (result == .quit) {
                ansi_renderer.clearBuffer();
                r.clear();
                ansi_renderer.showCursor();
                r.flush();
                return;
            }
        }

        // Update state
        _ = app.update();

        // Render if needed
        if (app.shouldRender(now)) {
            ansi_renderer.beginSync();
            app.render(r);
            ansi_renderer.endSync();
            r.flush();
        }

        // Poll for input with appropriate timeout
        const poll_wait_ms = app.getPollWaitMs(now);
        var fds = [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&fds, @intCast(poll_wait_ms)) catch {};
    }
}
