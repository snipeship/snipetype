//! Terminal capability detection (native only; neutral on wasm).
//!
//! `detect` sends one probe write and reads replies until the DA1 answer
//! (which every terminal sends, in order) or a timeout:
//!   kitty graphics query (`a=q`), kitty keyboard query (`CSI ? u`), cell and
//!   text-area pixel size (`CSI 16t` / `CSI 14t`), XTVERSION (`CSI > 0 q`),
//!   DECRQM for synchronized output (`CSI ? 2026 $ p`) and DA1 (`CSI c`).
//! When kitty graphics answered and we are not inside tmux, a second probe
//! checks the cheap local transfer media: shared memory (`t=s`, macOS/libc)
//! and temp files (`t=t`, any POSIX). Probe objects are removed afterwards.
//!
//! Keys typed while probing are re-queued on the `Input` (not lost).
//! Environment variables are passed in by the caller as `EnvHints` because
//! Zig 0.16 exposes the environment through `std.process.Init`.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("../core/constants.zig");
const keys = @import("keys.zig");
const Terminal = @import("terminal.zig").Terminal;
const Input = @import("input.zig").Input;
const time = @import("time.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;
const is_darwin = builtin.target.os.tag.isDarwin();
/// `t=s` needs shm_open, which we only use through libc on Darwin.
const have_shm = is_darwin and builtin.link_libc;

/// Kitty graphics transfer medium, best last.
pub const Media = enum { direct, temp_file, shm };

/// Graphics override from `--gfx` / `SNIPETYPE_GFX`.
pub const GfxOverride = enum {
    auto,
    kitty,
    cells,
    off,

    pub fn parse(s: []const u8) ?GfxOverride {
        if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(s, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(s, "cells") or std.ascii.eqlIgnoreCase(s, "halfblock")) return .cells;
        if (std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "none")) return .off;
        return null;
    }
};

/// Environment values relevant to detection (null = unset).
pub const EnvHints = struct {
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    tmux: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    snipetype_gfx: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,

    /// Fill from an environment map (e.g. `std.process.Init.environ_map`;
    /// anything with `get([]const u8) ?[]const u8`).
    pub fn fromMap(map: anytype) EnvHints {
        return .{
            .term = map.get("TERM"),
            .term_program = map.get("TERM_PROGRAM"),
            .tmux = map.get("TMUX"),
            .colorterm = map.get("COLORTERM"),
            .snipetype_gfx = map.get("SNIPETYPE_GFX"),
            .tmpdir = map.get("TMPDIR"),
        };
    }
};

pub const Options = struct {
    /// Upper bound per probe round (each ends early on DA1).
    timeout_ms: u32 = constants.CAPS_PROBE_TIMEOUT_MS,
    /// CLI `--gfx`; `.auto` defers to `SNIPETYPE_GFX`.
    gfx: GfxOverride = .auto,
    /// Probe `t=s` / `t=t` media after a successful graphics query.
    probe_media: bool = true,
};

pub const Caps = struct {
    /// Terminal answered the kitty graphics query (or `--gfx kitty`).
    kitty_graphics: bool = false,
    /// Best medium that answered OK (`direct` is always usable).
    kitty_media: Media = .direct,
    /// Terminal answered the kitty keyboard query.
    kitty_keyboard: bool = false,
    /// Synchronized output (mode 2026) supported.
    sync: bool = false,
    /// Cell size in pixels (0 = unknown).
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    truecolor: bool = false,
    in_tmux: bool = false,
    /// Effective graphics override (CLI beats env).
    gfx: GfxOverride = .auto,
    /// Terminal name: XTVERSION reply, else TERM_PROGRAM, else TERM.
    term: [32]u8 = @splat(0),
    term_len: u8 = 0,

    /// Neutral capabilities for no tty / unknown terminals.
    pub fn fallback() Caps {
        return .{};
    }

    /// Capabilities derivable from the environment alone (no probe).
    pub fn fromEnv(env: EnvHints, opts: Options) Caps {
        var c: Caps = .{};
        c.in_tmux = nonEmpty(env.tmux);
        c.gfx = if (opts.gfx != .auto) opts.gfx else if (env.snipetype_gfx) |s| (GfxOverride.parse(s) orelse .auto) else .auto;
        if (env.colorterm) |ct| {
            if (std.ascii.eqlIgnoreCase(ct, "truecolor") or std.ascii.eqlIgnoreCase(ct, "24bit")) c.truecolor = true;
        }
        if (env.term_program) |tp| {
            if (knownTruecolor(tp)) c.truecolor = true;
            c.setTerm(tp);
        } else if (env.term) |t| {
            c.setTerm(t);
        }
        if (env.term) |t| {
            if (std.mem.indexOf(u8, t, "kitty") != null or std.mem.indexOf(u8, t, "ghostty") != null or
                std.mem.endsWith(u8, t, "direct")) c.truecolor = true;
        }
        if (c.gfx == .kitty) c.kitty_graphics = true;
        return c;
    }

    pub fn termName(self: *const Caps) []const u8 {
        return self.term[0..self.term_len];
    }

    /// True when the kitty graphics presenter should be used.
    pub fn useKittyGraphics(self: *const Caps) bool {
        if (self.gfx == .cells or self.gfx == .off) return false;
        if (self.gfx == .kitty) return true;
        return self.kitty_graphics and !self.in_tmux;
    }

    fn setTerm(self: *Caps, name: []const u8) void {
        const n = @min(name.len, self.term.len);
        @memcpy(self.term[0..n], name[0..n]);
        self.term_len = @intCast(n);
    }
};

fn nonEmpty(s: ?[]const u8) bool {
    return if (s) |v| v.len > 0 else false;
}

fn knownTruecolor(name: []const u8) bool {
    const names = [_][]const u8{ "ghostty", "kitty", "wezterm", "iterm", "vscode", "foot", "konsole", "contour", "alacritty", "rio", "tabby", "hyper" };
    for (names) |n| {
        if (std.ascii.findIgnoreCase(name, n) != null) return true;
    }
    return false;
}

/// Replies collected during one probe round.
const ProbeState = struct {
    gfx_reply: bool = false,
    shm_ok: bool = false,
    temp_ok: bool = false,
    kitty_keyboard: bool = false,
    sync: bool = false,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    text_w: u16 = 0,
    text_h: u16 = 0,
    xt: [32]u8 = undefined,
    xt_len: usize = 0,
    got_da1: bool = false,

    fn apply(self: *ProbeState, r: keys.Reply) void {
        switch (r) {
            .kitty_graphics => |g| switch (g.id) {
                gfx_query_id => self.gfx_reply = true,
                shm_query_id => self.shm_ok = g.ok,
                temp_query_id => self.temp_ok = g.ok,
                else => {},
            },
            .kitty_keyboard => self.kitty_keyboard = true,
            .da1 => self.got_da1 = true,
            .cell_size => |s| {
                self.cell_w = s.w;
                self.cell_h = s.h;
            },
            .text_area => |s| {
                self.text_w = s.w;
                self.text_h = s.h;
            },
            .decrqm => |d| {
                if (d.mode == 2026 and d.value >= 1 and d.value <= 3) self.sync = true;
            },
            .xtversion => |name| {
                const n = @min(name.len, self.xt.len);
                @memcpy(self.xt[0..n], name[0..n]);
                self.xt_len = n;
            },
        }
    }
};

const gfx_query_id = 31;
const shm_query_id = 32;
const temp_query_id = 33;

/// The single startup probe write (see module docs).
pub const probe_sequence = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++
    "\x1b[?u" ++
    "\x1b[16t" ++
    "\x1b[14t" ++
    "\x1b[>0q" ++
    "\x1b[?2026$p" ++
    "\x1b[c";

/// Probe the terminal. Requires raw mode (otherwise returns env-only caps).
/// Key events typed during the probe are re-queued on `input`.
pub fn detect(term: *Terminal, input: *Input, env: EnvHints, opts: Options) Caps {
    var caps = Caps.fromEnv(env, opts);
    if (comptime is_wasm) return caps;

    if (term.cellPixelSize()) |c| {
        caps.cell_w = c.w;
        caps.cell_h = c.h;
    }
    if (!term.isRaw()) return caps;

    term.write(probe_sequence);
    var st: ProbeState = .{};
    collect(input, &st, opts.timeout_ms);

    if (st.gfx_reply) {
        caps.kitty_graphics = true;
        caps.truecolor = true;
    }
    caps.kitty_keyboard = st.kitty_keyboard;
    caps.sync = st.sync;
    if (st.xt_len > 0) {
        caps.setTerm(st.xt[0..st.xt_len]);
        if (knownTruecolor(st.xt[0..st.xt_len])) caps.truecolor = true;
    }

    // Cell size: exact report > text area / grid > winsize (already set).
    if (st.cell_w > 0 and st.cell_h > 0) {
        caps.cell_w = st.cell_w;
        caps.cell_h = st.cell_h;
    } else if (st.text_w > 0 and st.text_h > 0 and term.width > 0 and term.height > 0) {
        const w = st.text_w / term.width;
        const h = st.text_h / term.height;
        if (w > 0 and h > 0) {
            caps.cell_w = @intCast(w);
            caps.cell_h = @intCast(h);
        }
    }
    if (caps.cell_w > 0 and caps.cell_h > 0) term.setCellPixelSize(caps.cell_w, caps.cell_h);

    if (st.gfx_reply and !caps.in_tmux and opts.probe_media and caps.gfx != .cells and caps.gfx != .off) {
        caps.kitty_media = probeMedia(term, input, env, opts.timeout_ms);
    }
    return caps;
}

/// Read events until DA1 or timeout; replies go to `st`, keys back to input.
fn collect(input: *Input, st: *ProbeState, timeout_ms: u32) void {
    const deadline = time.milliTimestamp() + @as(i64, timeout_ms);
    while (!st.got_da1) {
        const now = time.milliTimestamp();
        if (now >= deadline) break;
        const left: i32 = @intCast(@min(deadline - now, std.math.maxInt(i32)));
        const ev = input.readEventWait(left) orelse break;
        switch (ev) {
            .key => input.queueEvent(ev),
            .reply => |r| st.apply(r),
        }
    }
}

// ============================================================================
// Media probe (t=s / t=t)
// ============================================================================

fn probeMedia(term: *Terminal, input: *Input, env: EnvHints, timeout_ms: u32) Media {
    const pid: u32 = @intCast(std.posix.system.getpid());

    var shm_buf: [32]u8 = undefined;
    const shm_name: ?[:0]const u8 = if (have_shm) blk: {
        const name = std.mem.printSentinel(&shm_buf, "/snt{d}q", .{pid}, 0) catch break :blk null;
        break :blk if (createShm(name)) name else null;
    } else null;
    defer if (shm_name) |n| removeShm(n);

    var path_buf: [1024]u8 = undefined;
    const temp_path: ?[:0]const u8 = blk: {
        var dir = env.tmpdir orelse "/tmp";
        if (dir.len == 0) dir = "/tmp";
        while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
        const p = std.mem.printSentinel(&path_buf, "{s}/snipetype-tty-graphics-protocol-{d}.rgb", .{ dir, pid }, 0) catch break :blk null;
        break :blk if (createTempFile(p)) p else null;
    };
    defer if (temp_path) |p| removeFile(p);

    if (shm_name == null and temp_path == null) return .direct;

    var out: [3 * 1024]u8 = undefined;
    var len: usize = 0;
    if (shm_name) |n| len += queryCmd(out[len..], shm_query_id, 's', n);
    if (temp_path) |p| len += queryCmd(out[len..], temp_query_id, 't', p);
    const da1 = "\x1b[c";
    @memcpy(out[len..][0..da1.len], da1);
    len += da1.len;
    term.write(out[0..len]);

    var st: ProbeState = .{};
    collect(input, &st, timeout_ms);
    if (st.shm_ok) return .shm;
    if (st.temp_ok) return .temp_file;
    return .direct;
}

/// `ESC _G i=<id>,s=1,v=1,a=q,t=<medium>,f=24,S=3 ; base64(payload) ESC \`.
/// Returns bytes written into `buf` (0 if it does not fit).
fn queryCmd(buf: []u8, id: u32, medium: u8, payload: []const u8) usize {
    const enc = std.base64.standard.Encoder;
    var head: [64]u8 = undefined;
    const h = std.mem.print(&head, "\x1b_Gi={d},s=1,v=1,a=q,t={c},f=24,S=3;", .{ id, medium }) catch return 0;
    const b64_len = enc.calcSize(payload.len);
    const total = h.len + b64_len + 2;
    if (total > buf.len) return 0;
    @memcpy(buf[0..h.len], h);
    _ = enc.encode(buf[h.len..][0..b64_len], payload);
    buf[h.len + b64_len] = 0x1b;
    buf[h.len + b64_len + 1] = '\\';
    return total;
}

const probe_pixel = [3]u8{ 0, 0, 0 };

fn createTempFile(path: [:0]const u8) bool {
    const posix = std.posix;
    // Exclusive + no-follow: the name is predictable and $TMPDIR may be a
    // shared /tmp, so never write through a planted file or symlink.
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true };
    const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, flags, 0o600) catch |err| blk: {
        if (err != error.PathAlreadyExists) return false;
        // Stale file from an earlier run with the same pid.
        removeFile(path);
        break :blk posix.openatZ(posix.AT.FDCWD, path.ptr, flags, 0o600) catch return false;
    };
    defer _ = posix.system.close(fd);
    var off: usize = 0;
    while (off < probe_pixel.len) {
        const rc = posix.system.write(fd, probe_pixel[off..].ptr, probe_pixel.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) break;
                off += n;
            },
            .INTR => continue,
            else => break,
        }
    }
    if (off != probe_pixel.len) {
        removeFile(path);
        return false;
    }
    return true;
}

fn removeFile(path: [:0]const u8) void {
    _ = std.posix.system.unlink(path.ptr); // ENOENT (terminal already deleted it) is fine
}

fn createShm(name: [:0]const u8) bool {
    if (comptime !have_shm) return false;
    const c = std.c;
    const flags: c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
    var fd = c.shm_open(name.ptr, @bitCast(flags), @as(c_uint, 0o600));
    if (fd < 0) {
        // Stale object from an earlier run with the same pid.
        _ = c.shm_unlink(name.ptr);
        fd = c.shm_open(name.ptr, @bitCast(flags), @as(c_uint, 0o600));
        if (fd < 0) return false;
    }
    defer _ = std.posix.system.close(fd);
    if (c.ftruncate(fd, probe_pixel.len) != 0) {
        _ = c.shm_unlink(name.ptr);
        return false;
    }
    const p = c.mmap(null, probe_pixel.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (p == c.MAP_FAILED) {
        _ = c.shm_unlink(name.ptr);
        return false;
    }
    const bytes: [*]u8 = @ptrCast(p);
    @memcpy(bytes[0..probe_pixel.len], &probe_pixel);
    _ = c.munmap(@alignCast(p), probe_pixel.len);
    return true;
}

fn removeShm(name: [:0]const u8) void {
    if (comptime !have_shm) return;
    _ = std.c.shm_unlink(name.ptr); // ENOENT (terminal already unlinked it) is fine
}
