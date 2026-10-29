//! Terminal raw mode, screen modes and size helpers.
//! Platform-specific behavior is selected at compile time.
//! - Native: termios raw mode (cfmakeraw-style, OPOST kept), TIOCGWINSZ size
//!   incl. pixel size, alt screen / cursor / kitty keyboard helpers, and a
//!   process-wide restore that also runs on SIGINT/SIGTERM/SIGHUP/SIGQUIT and
//!   (via `emergencyRestore`) from a panic handler.
//! - WASM: size and cell pixel size are controlled by JavaScript; the screen
//!   helpers are no-ops.
//!
//! Restore strategy: every mode change is recorded in a process-global
//! `saved` record (there is only one controlling tty). `restore()` and the
//! signal handler undo exactly what was enabled, in reverse order (pop kitty
//! keyboard flags while still on the alt screen, then leave it), and are
//! idempotent. Signal handlers re-raise the signal with the default action
//! after restoring, so exit status semantics are preserved.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("../core/constants.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const Terminal = if (is_wasm) WasmTerminal else NativeTerminal;

/// Cell size in pixels.
pub const CellPx = struct { w: u16, h: u16 };

/// Hardware cursor shape (DECSCUSR, steady variants). `default` restores
/// the user's configured shape.
pub const CursorShape = enum { default, block, underline, bar };

/// Kitty keyboard protocol flag bits and the presets used by the app.
pub const keyboard_flags = struct {
    pub const disambiguate: u8 = 1;
    pub const event_types: u8 = 2;
    pub const alternate_keys: u8 = 4;
    pub const all_as_escapes: u8 = 8;
    pub const associated_text: u8 = 16;
    /// Typing / vim / settings modes.
    pub const typing: u8 = disambiguate;
    /// Arcade: presses+releases, every key as an escape, with text (27).
    pub const arcade: u8 = disambiguate | event_types | all_as_escapes | associated_text;
};

/// WASM Terminal - minimal implementation
const WasmTerminal = struct {
    width: usize = constants.DEFAULT_TERM_WIDTH,
    height: usize = constants.DEFAULT_TERM_HEIGHT,
    cell_px: ?CellPx = null,

    pub fn init() !WasmTerminal {
        return WasmTerminal{};
    }

    pub fn updateSize(self: *WasmTerminal) void {
        _ = self;
        // Web: JS calls setSize() directly
    }

    pub fn setSize(self: *WasmTerminal, w: usize, h: usize) void {
        self.width = w;
        self.height = h;
    }

    /// Cell pixel size reported by the host (ghostty-web renderer metrics).
    pub fn setCellPixelSize(self: *WasmTerminal, w: u16, h: u16) void {
        self.cell_px = if (w > 0 and h > 0) .{ .w = w, .h = h } else null;
    }

    pub fn cellPixelSize(self: *const WasmTerminal) ?CellPx {
        return self.cell_px;
    }

    pub fn enableRawMode(self: *WasmTerminal) !void {
        _ = self;
    }

    pub fn eraseIsCtrlH(self: *const WasmTerminal) bool {
        _ = self;
        return false;
    }

    pub fn isRaw(self: *const WasmTerminal) bool {
        _ = self;
        return false;
    }

    pub fn enterAltScreen(self: *WasmTerminal) void {
        _ = self;
    }
    pub fn leaveAltScreen(self: *WasmTerminal) void {
        _ = self;
    }
    pub fn hideCursor(self: *WasmTerminal) void {
        _ = self;
    }
    pub fn showCursor(self: *WasmTerminal) void {
        _ = self;
    }
    pub fn setCursorShape(self: *WasmTerminal, shape: CursorShape) void {
        _ = self;
        _ = shape;
    }
    pub fn pushKeyboardFlags(self: *WasmTerminal, flags: u8) void {
        _ = self;
        _ = flags;
    }
    pub fn popKeyboardFlags(self: *WasmTerminal) void {
        _ = self;
    }
    pub fn setKeyboardFlags(self: *WasmTerminal, flags: u8) void {
        _ = self;
        _ = flags;
    }
    pub fn setInBandResize(self: *WasmTerminal, on: bool) void {
        _ = self;
        _ = on;
    }
    pub fn setBracketedPaste(self: *WasmTerminal, on: bool) void {
        _ = self;
        _ = on;
    }
    pub fn write(self: *WasmTerminal, bytes: []const u8) void {
        _ = self;
        _ = bytes;
    }

    pub fn restore(self: *WasmTerminal) void {
        _ = self;
    }

    pub fn emergencyRestore() void {}
};

/// Native Terminal - full implementation with raw mode support
const NativeTerminal = struct {
    const posix = std.posix;
    const stdout = @import("stdout.zig");

    width: usize = constants.DEFAULT_TERM_WIDTH,
    height: usize = constants.DEFAULT_TERM_HEIGHT,
    /// Text area size in pixels from TIOCGWINSZ (0 = unknown).
    xpixel: u16 = 0,
    ypixel: u16 = 0,
    /// Exact cell size reported by the terminal (CSI 16t), overrides winsize.
    cell_px: ?CellPx = null,
    original: posix.termios = undefined,

    pub fn init() !NativeTerminal {
        var t = NativeTerminal{};
        t.original = try posix.tcgetattr(posix.STDIN_FILENO);
        if (!saved.have_original) {
            saved.original = t.original;
            saved.have_original = true;
        }
        t.updateSize();
        return t;
    }

    pub fn updateSize(self: *NativeTerminal) void {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (ws.col > 0) self.width = @intCast(ws.col);
        if (ws.row > 0) self.height = @intCast(ws.row);
        self.xpixel = ws.xpixel;
        self.ypixel = ws.ypixel;
    }

    pub fn setSize(self: *NativeTerminal, w: usize, h: usize) void {
        self.width = w;
        self.height = h;
    }

    /// Record the exact cell size (e.g. from a `CSI 6;h;w t` reply).
    pub fn setCellPixelSize(self: *NativeTerminal, w: u16, h: u16) void {
        self.cell_px = if (w > 0 and h > 0) .{ .w = w, .h = h } else null;
    }

    /// Cell size in pixels: the reported size if known, else derived from
    /// the winsize pixel fields; null when the terminal reports neither.
    pub fn cellPixelSize(self: *const NativeTerminal) ?CellPx {
        if (self.cell_px) |c| return c;
        if (self.xpixel == 0 or self.ypixel == 0 or self.width == 0 or self.height == 0) return null;
        const w = self.xpixel / self.width;
        const h = self.ypixel / self.height;
        if (w == 0 or h == 0) return null;
        return .{ .w = @intCast(w), .h = @intCast(h) };
    }

    /// cfmakeraw-style raw mode (keeps OPOST so '\n' still implies CR):
    /// no echo, no canonical mode, no signals from keys (Ctrl+C/Z arrive as
    /// bytes), no XON/XOFF (Ctrl+S/Q), no CR→NL (Enter = '\r'), no IEXTEN
    /// (Ctrl+V/O on macOS), 8-bit chars, non-blocking reads (VMIN=VTIME=0).
    /// Also installs the restoring signal handlers.
    pub fn enableRawMode(self: *NativeTerminal) !void {
        var raw = self.original;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@backingInt(posix.V.MIN)] = 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        saved.raw = true;
        installSignalHandlers();
    }

    /// The tty's erase character is ^H (`stty erase ^H`): its Backspace key
    /// sends 0x08, which the input parser reads as Ctrl+H.
    pub fn eraseIsCtrlH(self: *const NativeTerminal) bool {
        return self.original.cc[@backingInt(posix.V.ERASE)] == 0x08;
    }

    pub fn isRaw(self: *const NativeTerminal) bool {
        _ = self;
        return saved.raw;
    }

    /// Write bytes straight to stdout (unbuffered).
    pub fn write(self: *NativeTerminal, bytes: []const u8) void {
        _ = self;
        stdout.writeAll(bytes);
    }

    pub fn enterAltScreen(self: *NativeTerminal) void {
        if (saved.alt) return;
        self.write("\x1b[?1049h");
        saved.alt = true;
    }

    /// Leave the alt screen. Kitty keyboard flags are per screen, so any
    /// flags pushed on the alt screen are popped first.
    pub fn leaveAltScreen(self: *NativeTerminal) void {
        if (!saved.alt) return;
        while (saved.kbd_depth > 0) self.popKeyboardFlags();
        self.write("\x1b[?1049l");
        saved.alt = false;
    }

    pub fn hideCursor(self: *NativeTerminal) void {
        self.write("\x1b[?25l");
        saved.cursor_hidden = true;
    }

    pub fn showCursor(self: *NativeTerminal) void {
        self.write("\x1b[?25h");
        saved.cursor_hidden = false;
    }

    /// Set the cursor shape (`CSI n SP q`); `restore` resets it to the
    /// terminal default when it was changed.
    pub fn setCursorShape(self: *NativeTerminal, shape: CursorShape) void {
        self.write(switch (shape) {
            .default => "\x1b[0 q",
            .block => "\x1b[2 q",
            .underline => "\x1b[4 q",
            .bar => "\x1b[6 q",
        });
        saved.cursor_shaped = shape != .default;
    }

    /// Push kitty keyboard flags (`CSI > flags u`). Terminals without the
    /// protocol ignore it.
    pub fn pushKeyboardFlags(self: *NativeTerminal, flags: u8) void {
        var buf: [16]u8 = undefined;
        const s = std.mem.print(&buf, "\x1b[>{d}u", .{flags}) catch return;
        self.write(s);
        saved.kbd_depth +|= 1;
    }

    /// Pop one level pushed by `pushKeyboardFlags` (no-op if none).
    pub fn popKeyboardFlags(self: *NativeTerminal) void {
        if (saved.kbd_depth == 0) return;
        self.write("\x1b[<u");
        saved.kbd_depth -= 1;
    }

    /// Replace the flags of our current stack entry (`CSI = flags ; 1 u`);
    /// pushes one first if we have none. Use when switching app modes.
    pub fn setKeyboardFlags(self: *NativeTerminal, flags: u8) void {
        if (saved.kbd_depth == 0) return self.pushKeyboardFlags(flags);
        var buf: [16]u8 = undefined;
        const s = std.mem.print(&buf, "\x1b[={d};1u", .{flags}) catch return;
        self.write(s);
    }

    /// Toggle in-band resize reports (mode 2048: `CSI 48;rows;cols;hpx;wpx t`).
    pub fn setInBandResize(self: *NativeTerminal, on: bool) void {
        self.write(if (on) "\x1b[?2048h" else "\x1b[?2048l");
        saved.in_band_resize = on;
    }

    /// Toggle bracketed paste (mode 2004): pasted text arrives between
    /// `CSI 200~` and `CSI 201~` (`code.paste_start` / `code.paste_end`).
    pub fn setBracketedPaste(self: *NativeTerminal, on: bool) void {
        self.write(if (on) "\x1b[?2004h" else "\x1b[?2004l");
        saved.bracketed_paste = on;
    }

    /// Undo everything enabled through this module (idempotent).
    pub fn restore(self: *NativeTerminal) void {
        _ = self;
        restoreSaved();
    }

    /// Best-effort restore usable without a `Terminal` (panic handlers).
    pub fn emergencyRestore() void {
        restoreSaved();
    }
};

// ============================================================================
// Process-global restore state (native)
// ============================================================================

const Saved = struct {
    original: if (is_wasm) void else std.posix.termios = undefined,
    have_original: bool = false,
    raw: bool = false,
    alt: bool = false,
    cursor_hidden: bool = false,
    /// A cursor shape other than the default was set.
    cursor_shaped: bool = false,
    kbd_depth: u8 = 0,
    in_band_resize: bool = false,
    bracketed_paste: bool = false,
    handlers_installed: bool = false,
};

var saved: Saved = .{};

/// Append `s` to `buf` at `len.*` if it fits.
fn put(buf: []u8, len: *usize, s: []const u8) void {
    if (len.* + s.len > buf.len) return;
    @memcpy(buf[len.*..][0..s.len], s);
    len.* += s.len;
}

/// Async-signal-safe restore: one write(2) of the undo sequence, then
/// tcsetattr. Clears the record so repeated calls do nothing.
fn restoreSaved() void {
    if (comptime is_wasm) return;
    const posix = std.posix;
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var depth = saved.kbd_depth;
    while (depth > 0) : (depth -= 1) put(&buf, &len, "\x1b[<u");
    if (saved.in_band_resize) put(&buf, &len, "\x1b[?2048l");
    if (saved.bracketed_paste) put(&buf, &len, "\x1b[?2004l");
    if (saved.raw or saved.alt or saved.cursor_hidden) {
        // End any open synchronized update and reset colors.
        put(&buf, &len, "\x1b[?2026l\x1b[0m");
    }
    if (saved.cursor_shaped) put(&buf, &len, "\x1b[0 q");
    if (saved.cursor_hidden) put(&buf, &len, "\x1b[?25h");
    if (saved.alt) put(&buf, &len, "\x1b[?1049l");
    saved.kbd_depth = 0;
    saved.in_band_resize = false;
    saved.bracketed_paste = false;
    saved.cursor_hidden = false;
    saved.cursor_shaped = false;
    saved.alt = false;
    if (len > 0) @import("stdout.zig").writeAll(buf[0..len]);
    if (saved.raw and saved.have_original) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved.original) catch {};
    }
    saved.raw = false;
}

const handled_signals = if (is_wasm) [_]u8{} else [_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT };

fn installSignalHandlers() void {
    if (comptime is_wasm) return;
    if (saved.handlers_installed) return;
    saved.handlers_installed = true;
    const posix = std.posix;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (handled_signals) |sig| posix.sigaction(sig, &act, null);
}

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    const posix = std.posix;
    restoreSaved();
    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &dfl, null);
    posix.raise(sig) catch {};
}
