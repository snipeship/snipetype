//! snipetype - Terminal Typing Test (Native CLI Entry Point)
//!
//! Startup: raw mode → alt screen → capability probe (kitty graphics /
//! keyboard, cell size; ≤300 ms, usually one round trip) → kitty keyboard
//! flags for the current mode. The loop drains input events, ticks the app,
//! renders when due and polls stdin until the next frame is due (60 fps in
//! arcade). The hardware cursor follows `App.cursorStyle` (hidden in arcade,
//! over settings and on results; bar while typing, block in vim normal).
//! Exit (and panics/signals) restore the terminal, cursor shape included.
//! Settings and history are read at startup and written as they change
//! (platform/store_native.zig; `--no-save` skips writes). History is
//! streamed in chunks and compacted when it grows past 16 MB. I/O errors
//! show one toast and never stop the app.
//!
//! Classic modes draw through a `DiffRenderer` (only changed cells reach
//! the terminal); arcade frames keep the plain `AnsiRenderer` path.
//! `snipetype stats` prints the history and exits before any terminal
//! setup. Custom text comes from `--text`, `--file`, piped stdin (the
//! terminal is then reopened from /dev/tty) or the saved `custom.txt`.

const std = @import("std");
const snipetype = @import("snipetype");
const posix = std.posix;
const builtin = @import("builtin");
const cli = @import("cli.zig");

const caps = snipetype.caps;
const gfx = snipetype.gfx;

/// Restore the terminal (raw mode, alt screen, keyboard flags, cursor)
/// before printing the panic message.
pub const panic = std.debug.FullPanic(panicRestore);

fn panicRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    snipetype.Terminal.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    // start.zig provides a leak-checked allocator (SafeAllocator in Debug/
    // ReleaseSafe since Zig 0.17) as `init.gpa`, plus the process `Io`
    // implementation and argv/environ.
    const allocator = init.gpa;
    snipetype.time.setIo(init.io);

    const args_parsed = cli.parseArgs(init.arena.allocator(), init.minimal.args) catch |e| {
        if (e == error.HelpRequested) {
            std.debug.print("{s}", .{cli.HELP});
            return;
        }
        std.debug.print("Invalid arguments. Use --help\n", .{});
        std.process.exit(2);
    };
    var args = args_parsed;

    // Saved settings and history (read before the terminal switches modes).
    var store: ?snipetype.store_native.Store = null;
    var paths: snipetype.store_native.Paths = undefined;
    if (snipetype.store_native.resolve(init.environ_map, &paths) != null) {
        store = .{ .io = init.io, .paths = paths, .read_only = args.no_save };
    }

    if (args.stats) |opts| {
        runStats(allocator, init.io, &store, opts);
        return;
    }

    // Custom text: --text, --file, else piped stdin. Whenever stdin is not
    // a terminal the keys come from the controlling terminal instead (also
    // with --text / --file, whose text beats the pipe, left unread).
    var custom_owned: ?[]u8 = null;
    defer if (custom_owned) |b| allocator.free(b);
    if (args.text_file) |path| {
        custom_owned = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(stdin_cap)) catch |e| switch (e) {
            // Like a pipe: a file over the cap gives its first stdin_cap bytes.
            error.StreamTooLong => readFileHead(allocator, path),
            else => null,
        } orelse {
            std.debug.print("snipetype: cannot read {s}\n", .{path});
            std.process.exit(2);
        };
        args.overrides.custom_text = custom_owned.?;
    }
    if (!isTty(posix.STDIN_FILENO)) {
        if (cli.wantsStdinText(&args)) {
            custom_owned = readStdin(allocator);
            if (custom_owned) |text| cli.useStdinText(&args, text);
        }
        if (!reopenTty()) {
            std.debug.print("snipetype: stdin is not a terminal and /dev/tty cannot be opened.\n", .{});
            std.process.exit(1);
        }
    }
    // The last custom text (when none was given now).
    var saved_custom: ?[]u8 = null;
    defer if (saved_custom) |b| allocator.free(b);
    if (args.overrides.custom_text == null) {
        if (store) |*st| saved_custom = st.readCustom(allocator);
    }
    const config = args.config;

    const saved_cfg: ?[]u8 = if (store) |*st| st.readConfig(allocator) else null;
    defer if (saved_cfg) |b| allocator.free(b);

    var term = snipetype.Terminal.init() catch {
        std.debug.print("snipetype needs an interactive terminal (stdin is not a tty).\n", .{});
        std.process.exit(1);
    };
    term.enableRawMode() catch {
        std.debug.print("snipetype could not switch the terminal to raw mode.\n", .{});
        std.process.exit(1);
    };
    defer term.restore();
    term.enterAltScreen();

    var input = snipetype.Input.init();

    // Capabilities (kitty graphics/keyboard, cell pixel size). Keys typed
    // during the probe are re-queued on `input`.
    const env = caps.EnvHints.fromMap(init.environ_map);
    const gfx_override: caps.GfxOverride = switch (config.gfx) {
        .auto => .auto,
        .kitty => .kitty,
        .cells => .cells,
    };
    const tc = caps.detect(&term, &input, env, .{ .gfx = gfx_override });

    var ansi_renderer = snipetype.AnsiRenderer.init(allocator, term.width, term.height);
    defer ansi_renderer.deinit();
    // Classic modes: only changed cells are written.
    var diff = try snipetype.DiffRenderer.init(allocator, &ansi_renderer, term.width, term.height);
    defer diff.deinit();
    var was_arcade = false;

    // Initial setup: clear screen
    var r = ansi_renderer.renderer();
    r.clear();
    r.flush();

    const seed: u64 = @truncate(@as(u128, @bitCast(snipetype.time.nanoTimestamp())));
    var app = try snipetype.App.init(allocator, seed, config);
    defer app.deinit();
    // History first (personal bests pick the first unstarred drill).
    if (store) |*st| {
        _ = st.streamHistory(allocator, HistorySink{ .app = &app });
        if (st.needsCompaction()) {
            if (app.pbLines(allocator)) |pbs| {
                defer allocator.free(pbs);
                _ = st.compactHistory(allocator, pbs);
            }
        }
    }
    if (saved_custom) |text| app.loadCustomText(text);
    app.loadSaved(saved_cfg, null, args.overrides);
    var save_failed = false;

    app.setGfx(gfxSetup(&tc, env));
    if (term.cellPixelSize()) |cp| app.setCellPx(cp.w, cp.h);

    // `stty erase ^H`: that terminal's Backspace key sends 0x08 (parsed as
    // Ctrl+H, which deletes a word): read it as Backspace in the typing
    // modes, unless the kitty keyboard protocol tells the two apart.
    const erase_is_ctrl_h = term.eraseIsCtrlH() and !tc.kitty_keyboard;

    var kbd_flags = app.keyboardFlags();
    term.pushKeyboardFlags(kbd_flags);
    // Pasted text arrives framed (CSI 200~ / 201~) and is not typed.
    term.setBracketedPaste(true);
    // Cursor as last sent (null: the terminal's own, visible).
    var cursor_style: ?snipetype.App.CursorStyle = null;
    var cursor_visible = true;

    while (true) {
        // Check for terminal resize
        const prev_w = term.width;
        const prev_h = term.height;
        term.updateSize();
        if (term.width != prev_w or term.height != prev_h) {
            ansi_renderer.setSize(term.width, term.height);
            diff.setSize(term.width, term.height) catch {};
            app.onResize();
            if (term.cellPixelSize()) |cp| app.setCellPx(cp.w, cp.h);
        }

        // Process all pending input
        while (input.readEvent()) |raw_ev| {
            const ev = if (erase_is_ctrl_h and !app.isArcade()) ctrlHAsBackspace(raw_ev) else raw_ev;
            if (app.handleEvent(ev, false) == .quit) {
                // A run or setting finished in this same batch is still saved.
                persist(&store, &app, &save_failed);
                ansi_renderer.clearBuffer();
                term.write(app.teardownBytes());
                return;
            }
        }

        // Mode-dependent terminal state (kitty keyboard flags, cursor)
        const want_flags = app.keyboardFlags();
        if (want_flags != kbd_flags) {
            term.setKeyboardFlags(want_flags);
            kbd_flags = want_flags;
        }
        // Hidden in arcade, over settings and on results; a bar while
        // typing, a block in vim normal/visual (reset on exit by restore).
        var want_style = app.cursorStyle();
        if (want_style != .hidden and !app.getCursorPos(term.width, term.height).visible) want_style = .hidden;
        if (want_style != cursor_style) {
            const want_visible = want_style != .hidden;
            if (want_visible != cursor_visible) {
                if (want_visible) term.showCursor() else term.hideCursor();
                cursor_visible = want_visible;
            }
            switch (want_style) {
                .hidden => {},
                .block => term.setCursorShape(.block),
                .bar => term.setCursorShape(.bar),
                .underline => term.setCursorShape(.underline),
            }
            cursor_style = want_style;
        }

        // Update state
        _ = app.update();

        persist(&store, &app, &save_failed);

        // Render if needed
        const now = snipetype.time.milliTimestamp();
        if (app.shouldRender(now)) {
            if (app.isArcade()) {
                // The presenter emits its own synchronized frame.
                app.render(r);
                was_arcade = true;
            } else {
                // Coming back from arcade: the screen holds pixels.
                if (was_arcade) diff.invalidate();
                was_arcade = false;
                const dr = diff.renderer();
                ansi_renderer.beginSync();
                app.render(dr);

                // Position terminal cursor at typing position
                const cursor_pos = app.getCursorPos(term.width, term.height);
                dr.moveTo(cursor_pos.x, cursor_pos.y);
                diff.emit();

                ansi_renderer.endSync();
                r.flush();
            }
        }

        // Poll for input until the next frame is due
        const poll_wait_ms = app.getPollWaitMs(snipetype.time.milliTimestamp());
        var fds = [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&fds, @intCast(std.math.clamp(poll_wait_ms, 0, 1000))) catch {};
    }
}

/// Piped custom text is read up to this size (TypingTest keeps 64 KiB).
const stdin_cap: usize = 1 << 20;

/// History chunks → App (personal bests and the run log).
const HistorySink = struct {
    app: *snipetype.App,
    pub fn chunk(self: HistorySink, bytes: []const u8) void {
        self.app.loadHistoryChunk(bytes);
    }
};

fn isTty(fd: posix.fd_t) bool {
    _ = posix.tcgetattr(fd) catch return false;
    return true;
}

/// Read stdin to EOF or `stdin_cap` bytes, whichever comes first (an
/// endless pipe such as `yes | snipetype` must not hang the start).
fn readStdin(allocator: std.mem.Allocator) ?[]u8 {
    return readCapped(allocator, posix.STDIN_FILENO);
}

/// The first `stdin_cap` bytes of a file too big to read whole.
fn readFileHead(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(z);
    const fd = posix.openatZ(posix.AT.FDCWD, z, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = posix.system.close(fd);
    return readCapped(allocator, fd);
}

fn readCapped(allocator: std.mem.Allocator, fd: posix.fd_t) ?[]u8 {
    var list: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (list.items.len < stdin_cap) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..@min(n, stdin_cap - list.items.len)]) catch break;
    }
    return list.toOwnedSlice(allocator) catch {
        list.deinit(allocator);
        return null;
    };
}

/// Put the controlling terminal on fd 0 so the terminal and input code
/// keep reading STDIN after a pipe was consumed.
///
/// macOS `poll()` reports POLLNVAL for a descriptor opened on `/dev/tty`,
/// so there a read-write stdout or stderr (the real `/dev/ttysNNN` the
/// shell opened) is duplicated instead; `/dev/tty` is the fallback.
fn reopenTty() bool {
    if (comptime builtin.os.tag.isDarwin()) {
        for ([_]posix.fd_t{ posix.STDOUT_FILENO, posix.STDERR_FILENO }) |src| {
            if (!isTty(src)) continue;
            const flags = std.c.fcntl(src, posix.F.GETFL);
            if (flags < 0) continue;
            const mode: u32 = @bitCast(flags & 3);
            if (mode != 2) continue; // O_RDWR
            if (posix.system.dup2(src, posix.STDIN_FILENO) < 0) continue;
            if (isTty(posix.STDIN_FILENO)) return true;
        }
    }
    const fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return false;
    _ = posix.system.dup2(fd, posix.STDIN_FILENO);
    if (fd != posix.STDIN_FILENO) _ = posix.system.close(fd);
    return isTty(posix.STDIN_FILENO);
}

/// History chunks → a Log and PbTable (stats), or CSV rows on the fly.
const StatsSink = struct {
    log: *snipetype.history.Log,
    pbs: *snipetype.history.PbTable,
    csv: ?*std.Io.Writer = null,
    pub fn chunk(self: StatsSink, bytes: []const u8) void {
        if (self.csv) |w| {
            var it = std.mem.splitScalar(u8, bytes, '\n');
            while (it.next()) |line| {
                if (line.len > 0) _ = snipetype.history.writeCsvLine(w, line) catch false;
            }
            return;
        }
        self.log.loadJsonl(bytes);
        self.pbs.loadJsonl(bytes);
    }
};

/// `snipetype stats [--csv]`: the history as text or CSV on stdout.
fn runStats(allocator: std.mem.Allocator, io: std.Io, store: *?snipetype.store_native.Store, opts: cli.Stats) void {
    var out_buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;
    defer w.flush() catch {};
    var log = snipetype.history.Log.init(allocator);
    defer log.deinit();
    var pbs = snipetype.history.PbTable.init(allocator);
    defer pbs.deinit();
    const st = &(store.* orelse {
        w.writeAll("no history yet (HOME is not set)\n") catch {};
        return;
    });
    if (opts.csv) {
        snipetype.history.writeCsvHeader(w) catch return;
        _ = st.streamHistory(allocator, StatsSink{ .log = &log, .pbs = &pbs, .csv = w });
        return;
    }
    if (!st.streamHistory(allocator, StatsSink{ .log = &log, .pbs = &pbs }) or log.count() == 0) {
        w.print("no history yet: finish a test first ({s})\n", .{st.paths.historyPath()}) catch {};
        return;
    }
    snipetype.history.writeStatsText(w, &log, &pbs, opts.limit) catch {};
}

/// Plain Ctrl+H → Backspace (see `erase_is_ctrl_h`).
fn ctrlHAsBackspace(ev: snipetype.keys.Event) snipetype.keys.Event {
    var k = switch (ev) {
        .key => |k| k,
        .reply => return ev,
    };
    if (k.code != 'h' or !snipetype.keys.Mods.eql(k.mods, .{ .ctrl = true })) return ev;
    k.code = snipetype.keys.code.backspace;
    k.mods.ctrl = false;
    return .{ .key = k };
}

/// Write a finished run and changed settings (one toast on the first
/// failure; the app carries on).
fn persist(store: *?snipetype.store_native.Store, app: *snipetype.App, save_failed: *bool) void {
    const st = &(store.* orelse return);
    var ok = true;
    if (app.takeRecordLine()) |line| ok = st.appendHistory(line) and ok;
    if (app.takeConfigJson()) |json| ok = st.writeConfig(json) and ok;
    if (app.takeCustomText()) |text| ok = st.writeCustom(text) and ok;
    if (!ok and !save_failed.*) {
        save_failed.* = true;
        app.showToast("could not save settings/history (see --help)");
    }
}

/// Arcade output from the probed capabilities: kitty graphics when
/// supported (and not in tmux / overridden), else half-block cells.
fn gfxSetup(tc: *const caps.Caps, env: caps.EnvHints) snipetype.GfxSetup {
    const backend: gfx.Backend = if (tc.useKittyGraphics()) .kitty else .halfblock;
    const media: gfx.KittyMedia = switch (tc.kitty_media) {
        .direct => .direct,
        .temp_file => .temp_file,
        .shm => .shm,
    };
    const pid = posix.system.getpid();
    return .{
        .backend = backend,
        .opts = .{
            .kitty_media = media,
            .kitty_png = decodesPng(tc.termName()),
            .tmpdir = env.tmpdir,
            .unique = @intCast(@max(pid, 0)),
        },
        // Modifier chords (Ctrl+Shift+Z, Alt+arrows) need the kitty
        // keyboard protocol to be told apart.
        .chords = tc.kitty_keyboard,
    };
}

/// Terminals known to decode PNG payloads (`f=100`) for the direct medium.
/// Others (e.g. libghostty-vt embedders) get zlib'd raw pixels.
fn decodesPng(term_name: []const u8) bool {
    const known = [_][]const u8{ "kitty", "wezterm", "konsole" };
    for (known) |k| {
        if (std.ascii.findIgnoreCase(term_name, k) != null) return true;
    }
    return false;
}

test {
    _ = cli;
}

test "stty erase ^H: ctrl+h reads as backspace" {
    const keys = snipetype.keys;
    const bs = ctrlHAsBackspace(.{ .key = .{ .code = 'h', .mods = .{ .ctrl = true } } });
    try std.testing.expectEqual(keys.code.backspace, bs.key.code);
    try std.testing.expect(!bs.key.mods.ctrl);
    // Other chords stay.
    try std.testing.expectEqual(@as(u21, 'h'), ctrlHAsBackspace(.{ .key = .{ .code = 'h', .mods = .{ .ctrl = true, .alt = true } } }).key.code);
    try std.testing.expectEqual(@as(u21, 'w'), ctrlHAsBackspace(.{ .key = .{ .code = 'w', .mods = .{ .ctrl = true } } }).key.code);
}

test "png decoders by terminal name" {
    try std.testing.expect(decodesPng("kitty(0.39.1)"));
    try std.testing.expect(decodesPng("WezTerm 20240203"));
    try std.testing.expect(!decodesPng("ghostty 1.2.0"));
    try std.testing.expect(!decodesPng(""));
}
