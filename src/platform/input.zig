//! Keyboard input: one escape-sequence parser shared by native and web.
//!
//! `Parser` is pure (no I/O, wasm-safe). It turns raw terminal bytes into
//! `keys.Event`s: UTF-8 text, C0 controls (Ctrl+letter), ESC-prefixed Alt,
//! CSI/SS3 functional keys with modifiers, xterm modifyOtherKeys
//! (`CSI 27;m;c~`), the kitty keyboard protocol (`CSI code:sh:base;m:ev;text u`)
//! and replies to capability probes (APC kitty graphics, DA1, size reports,
//! DECRQM, XTVERSION). Unknown sequences are consumed and dropped, never
//! turned into typed text. Sequences split across reads are kept pending.
//!
//! Byte sources:
//! - Native: reads all available stdin bytes in bulk into the parser buffer.
//!   A trailing partial sequence (e.g. a lone ESC) waits up to
//!   `ESC_TIMEOUT_MS` for its continuation before being resolved.
//! - WASM: JavaScript pushes whole key sequences; they are parsed at push
//!   time, so an ESC at the end of a push is the Escape key.
//!
//! `readEvent()` is the rich API; `readKey()` is the legacy wrapper mapping
//! through `KeyEvent.toLegacy()` (replies, releases and unmappable keys are
//! skipped).

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("../core/constants.zig");
const keys = @import("keys.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const Key = keys.Key;
pub const Event = keys.Event;
pub const KeyEvent = keys.KeyEvent;
const code = keys.code;
const Mods = keys.Mods;

pub const Input = if (is_wasm) WasmInput else NativeInput;

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

// ============================================================================
// Parser
// ============================================================================

/// Result of trying to parse one sequence at the start of the buffer.
const Step = union(enum) {
    /// The sequence is not complete yet.
    need_more,
    /// Consumed `len` bytes; `ev` is null when the sequence is dropped.
    done: struct { len: usize, ev: ?Event },
    /// Over-long string sequence: consume `len` bytes, then skip until ST.
    skip_string: usize,
    /// Over-long CSI/SS3: consume `len` bytes, then skip its remaining
    /// parameter/intermediate bytes and final byte.
    skip_csi: usize,
};

fn done(len: usize, ev: ?Event) Step {
    return .{ .done = .{ .len = len, .ev = ev } };
}

fn keyEvent(k: KeyEvent) Event {
    return .{ .key = k };
}

/// Numeric CSI parameters: up to 8 `;`-separated fields of up to 4
/// `:`-separated sub-values each. Missing values are null.
const Params = struct {
    const max_fields = 8;
    const max_sub = 4;

    vals: [max_fields][max_sub]?u32 = @splat(@splat(null)),
    n: usize = 0,

    fn parse(s: []const u8) Params {
        var p: Params = .{};
        if (s.len == 0) return p;
        p.n = 1;
        var field: usize = 0;
        var sub: usize = 0;
        var cur: ?u32 = null;
        for (s) |ch| {
            switch (ch) {
                '0'...'9' => cur = ((cur orelse 0) *| 10) +| (ch - '0'),
                ';' => {
                    p.store(field, sub, cur);
                    field += 1;
                    sub = 0;
                    cur = null;
                    p.n = field + 1;
                },
                ':' => {
                    p.store(field, sub, cur);
                    sub += 1;
                    cur = null;
                },
                else => {},
            }
        }
        p.store(field, sub, cur);
        return p;
    }

    fn store(self: *Params, field: usize, sub: usize, v: ?u32) void {
        if (field < max_fields and sub < max_sub) self.vals[field][sub] = v;
    }

    fn get(self: *const Params, field: usize, sub: usize) ?u32 {
        if (field >= max_fields or sub >= max_sub) return null;
        return self.vals[field][sub];
    }

    fn getOr(self: *const Params, field: usize, sub: usize, default: u32) u32 {
        return self.get(field, sub) orelse default;
    }
};

fn kindFromWire(v: u32) keys.Kind {
    return switch (v) {
        2 => .repeat,
        3 => .release,
        else => .press,
    };
}

fn sat16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn isPrintableCp(v: u32) bool {
    return v >= 0x20 and v != 0x7f and v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF) and
        !(v >= 0x80 and v < 0xA0);
}

/// Build a key event from a kitty/modifyOtherKeys key code, normalizing
/// uppercase ASCII (→ lowercase + shift) and keypad keys (→ main keys).
fn keyFromCode(cp: u32, mods_in: Mods, kind: keys.Kind, text_in: u21) ?KeyEvent {
    if (cp == 0 or cp > 0x10FFFF) return null;
    var c: u21 = @intCast(cp);
    var mods = mods_in;
    var text = text_in;
    if (c >= 'A' and c <= 'Z') {
        if (text == 0) text = c;
        c += 32;
        mods.shift = true;
    }
    c = switch (c) {
        57399...57408 => '0' + (c - 57399),
        57409 => '.',
        57410 => '/',
        57411 => '*',
        57412 => '-',
        57413 => '+',
        57414 => code.enter,
        57415 => '=',
        57416 => ',',
        57417 => code.left,
        57418 => code.right,
        57419 => code.up,
        57420 => code.down,
        57421 => code.page_up,
        57422 => code.page_down,
        57423 => code.home,
        57424 => code.end,
        57425 => code.insert,
        57426 => code.delete,
        // Some terminals report Ctrl+Backspace / legacy BS as 8.
        8 => code.backspace,
        else => c,
    };
    return .{ .code = c, .mods = mods, .kind = kind, .text = text };
}

/// Final byte of `CSI 1;mods X` / `SS3 X` → key code.
fn letterCode(final: u8) ?u21 {
    return switch (final) {
        'A' => code.up,
        'B' => code.down,
        'C' => code.right,
        'D' => code.left,
        'E' => code.kp_begin,
        'F' => code.end,
        'H' => code.home,
        'P' => code.f(1),
        'Q' => code.f(2),
        'R' => code.f(3),
        'S' => code.f(4),
        else => null,
    };
}

/// `CSI n ~` number → key code.
fn tildeCode(n: u32) ?u21 {
    return switch (n) {
        1, 7 => code.home,
        2 => code.insert,
        3 => code.delete,
        4, 8 => code.end,
        5 => code.page_up,
        6 => code.page_down,
        11...15 => code.f(@intCast(n - 10)),
        17...21 => code.f(@intCast(n - 11)),
        23...26 => code.f(@intCast(n - 12)),
        28, 29 => code.f(@intCast(n - 13)),
        31...34 => code.f(@intCast(n - 14)),
        200 => code.paste_start,
        201 => code.paste_end,
        else => null,
    };
}

pub const Parser = struct {
    buf: [constants.INPUT_BUFFER_SIZE]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Discarding an over-long APC/DCS/OSC string until its terminator.
    skipping: bool = false,
    /// A string was abandoned on flush right after an ESC: swallow a
    /// following `\` (the rest of ST), keep anything else.
    skip_esc: bool = false,
    /// Discarding the tail of an over-long CSI/SS3 sequence.
    skipping_csi: bool = false,
    /// Storage for the last XTVERSION reply (`Reply.xtversion` points here).
    xt_buf: [64]u8 = undefined,

    /// Number of buffered, not yet parsed bytes.
    pub fn pending(self: *const Parser) usize {
        return self.end - self.start;
    }

    /// True when nothing is buffered and no string is being skipped.
    pub fn isIdle(self: *const Parser) bool {
        return self.start == self.end and !self.skipping and !self.skipping_csi and !self.skip_esc;
    }

    fn compact(self: *Parser) void {
        if (self.start == 0) return;
        const n = self.end - self.start;
        if (n > 0) @memmove(self.buf[0..n], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = n;
    }

    /// Free space to read into directly (call `commit(n)` afterwards).
    pub fn writable(self: *Parser) []u8 {
        self.compact();
        return self.buf[self.end..];
    }

    /// Mark `n` bytes written into `writable()` as buffered.
    pub fn commit(self: *Parser, n: usize) void {
        std.debug.assert(self.end + n <= self.buf.len);
        self.end += n;
    }

    /// Copy as many of `bytes` as fit; returns how many were accepted.
    pub fn feed(self: *Parser, bytes: []const u8) usize {
        const w = self.writable();
        const n = @min(w.len, bytes.len);
        @memcpy(w[0..n], bytes[0..n]);
        self.end += n;
        return n;
    }

    /// Parse the next complete event. With `flush == false` a trailing
    /// partial sequence stays buffered (returns null). With `flush == true`
    /// it is resolved: lone ESC → Escape, `ESC x` intro → Alt+x, anything
    /// longer is dropped.
    pub fn next(self: *Parser, flush: bool) ?Event {
        while (true) {
            if (self.skip_esc) {
                if (self.start == self.end) return null;
                if (self.buf[self.start] == '\\') self.start += 1;
                self.skip_esc = false;
            }
            if (self.skipping) {
                self.skipString();
                if (self.skipping) {
                    if (!flush) return null;
                    // Stale after a flush: stop skipping so the next chunk is
                    // parsed intact. A trailing ESC (the only byte that can be
                    // left) is taken as the start of ST.
                    self.skipping = false;
                    if (self.start < self.end) {
                        self.start = self.end;
                        self.skip_esc = true;
                    }
                    return null;
                }
            }
            if (self.skipping_csi) {
                self.skipCsiTail();
                if (self.skipping_csi) {
                    // Stale after a flush: do not eat the next chunk's bytes.
                    if (flush) self.skipping_csi = false;
                    return null;
                }
            }
            if (self.start == self.end) return null;
            const data = self.buf[self.start..self.end];
            switch (self.parseOne(data)) {
                .done => |d| {
                    self.start += d.len;
                    if (d.ev) |ev| return ev;
                },
                .skip_string => |n| {
                    self.start += n;
                    self.skipping = true;
                },
                .skip_csi => |n| {
                    self.start += n;
                    self.skipping_csi = true;
                },
                .need_more => {
                    if (!flush) return null;
                    const r = resolvePartial(data);
                    self.start += r.len;
                    if (r.ev) |ev| return ev;
                },
            }
        }
    }

    /// Discard string bytes up to its terminator. `ESC \` (ST) is consumed;
    /// ESC followed by anything else starts a new sequence and is kept. A
    /// trailing ESC stays buffered until its next byte arrives.
    fn skipString(self: *Parser) void {
        while (self.start < self.end) {
            const b = self.buf[self.start];
            if (b == ESC) {
                if (self.start + 1 == self.end) return;
                self.skipping = false;
                if (self.buf[self.start + 1] == '\\') self.start += 2;
                return;
            }
            self.start += 1;
            if (b == BEL or b == 0x18 or b == 0x1a) {
                self.skipping = false;
                return;
            }
        }
    }

    /// Skip CSI parameter/intermediate bytes, then the final byte. A byte
    /// that cannot belong to a CSI (e.g. ESC) ends skipping unconsumed.
    fn skipCsiTail(self: *Parser) void {
        while (self.start < self.end) {
            const b = self.buf[self.start];
            if (b >= 0x20 and b <= 0x3f) {
                self.start += 1;
                continue;
            }
            if (b >= 0x40 and b <= 0x7e) self.start += 1;
            self.skipping_csi = false;
            return;
        }
    }

    fn parseOne(self: *Parser, data: []const u8) Step {
        if (data[0] != ESC) return parsePlain(data, false);
        if (data.len < 2) return .need_more;
        return switch (data[1]) {
            '[' => self.parseCsi(data),
            'O' => parseSs3(data),
            'P', '_', ']', 'X', '^' => self.parseString(data),
            // ESC ESC: the first one is a plain Escape press.
            ESC => done(1, keyEvent(.{ .code = code.escape })),
            else => switch (parsePlain(data[1..], true)) {
                .done => |d| done(d.len + 1, d.ev),
                else => |s| s,
            },
        };
    }

    // ---- CSI ---------------------------------------------------------------

    fn parseCsi(self: *Parser, data: []const u8) Step {
        var j: usize = 2;
        var prefix: u8 = 0;
        if (j < data.len and data[j] >= 0x3c and data[j] <= 0x3f) {
            prefix = data[j];
            j += 1;
        }
        const p_start = j;
        while (j < data.len and data[j] >= 0x30 and data[j] <= 0x3f) j += 1;
        const p_end = j;
        while (j < data.len and data[j] >= 0x20 and data[j] <= 0x2f) j += 1;
        const i_end = j;
        if (j >= data.len) {
            return if (j >= constants.INPUT_MAX_CSI_LEN) .{ .skip_csi = j } else .need_more;
        }
        const final = data[j];
        // Malformed (control byte inside): drop what we have, reparse the byte.
        if (final < 0x40 or final > 0x7e) return done(j, null);
        const ev = self.csiEvent(prefix, data[p_start..p_end], data[p_end..i_end], final);
        return done(j + 1, ev);
    }

    fn csiEvent(self: *Parser, prefix: u8, params: []const u8, inter: []const u8, final: u8) ?Event {
        _ = self;
        const p = Params.parse(params);
        if (prefix == '?') {
            return switch (final) {
                'u' => .{ .reply = .{ .kitty_keyboard = p.getOr(0, 0, 0) } },
                'c' => .{ .reply = .da1 },
                'y' => if (std.mem.eql(u8, inter, "$")) decrqm(&p) else null,
                else => null,
            };
        }
        if (prefix != 0) return null;
        if (inter.len != 0) {
            if (final == 'y' and std.mem.eql(u8, inter, "$")) return decrqm(&p);
            return null;
        }
        switch (final) {
            'u' => return kittyKey(&p),
            '~' => return tildeKey(&p),
            'Z' => return keyEvent(.{ .code = code.tab, .mods = .{ .shift = true } }),
            't' => return windowReport(&p),
            'R' => {
                // F3 (`CSI 1;m R`); anything else is a cursor position report.
                if (p.getOr(0, 0, 1) != 1) return null;
                return letterKey(final, &p);
            },
            'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'S' => return letterKey(final, &p),
            else => return null,
        }
    }

    // ---- strings (APC / DCS / OSC / SOS / PM) -------------------------------

    fn parseString(self: *Parser, data: []const u8) Step {
        const intro = data[1];
        var j: usize = 2;
        while (j < data.len) : (j += 1) {
            const b = data[j];
            if (b == BEL) return done(j + 1, self.stringEvent(intro, data[2..j]));
            if (b == 0x18 or b == 0x1a) return done(j + 1, null); // CAN / SUB abort
            if (b == ESC) {
                if (j + 1 >= data.len) break;
                if (data[j + 1] == '\\') return done(j + 2, self.stringEvent(intro, data[2..j]));
                // Interrupted by another sequence: drop the string.
                return done(j, null);
            }
        }
        // `j` stops before a trailing ESC so skipString can check for ST.
        if (data.len >= constants.INPUT_MAX_STRING_LEN) return .{ .skip_string = j };
        return .need_more;
    }

    fn stringEvent(self: *Parser, intro: u8, content: []const u8) ?Event {
        switch (intro) {
            '_' => {
                if (content.len == 0 or content[0] != 'G') return null;
                return kittyGraphicsReply(content[1..]);
            },
            'P' => {
                if (!std.mem.startsWith(u8, content, ">|")) return null;
                const name = content[2..];
                const n = @min(name.len, self.xt_buf.len);
                @memcpy(self.xt_buf[0..n], name[0..n]);
                return .{ .reply = .{ .xtversion = self.xt_buf[0..n] } };
            },
            else => return null,
        }
    }
};

/// Resolve a partial sequence at the end of input (`flush`).
fn resolvePartial(data: []const u8) struct { len: usize, ev: ?Event } {
    if (data[0] == ESC) {
        if (data.len == 1) return .{ .len = 1, .ev = keyEvent(.{ .code = code.escape }) };
        if (data.len == 2) switch (data[1]) {
            '[', 'O', 'P', '_', ']', 'X', '^' => {
                switch (parsePlain(data[1..], true)) {
                    .done => |d| return .{ .len = 2, .ev = d.ev },
                    else => {},
                }
            },
            else => {},
        };
    }
    return .{ .len = data.len, .ev = null };
}

/// A single plain byte / UTF-8 character (optionally Alt-prefixed).
fn parsePlain(data: []const u8, alt: bool) Step {
    const b = data[0];
    var k: KeyEvent = switch (b) {
        0x00 => .{ .code = ' ', .mods = .{ .ctrl = true } },
        0x09 => .{ .code = code.tab },
        0x0d => .{ .code = code.enter },
        0x01...0x08, 0x0a...0x0c, 0x0e...0x1a => .{ .code = @as(u21, b) + 0x60, .mods = .{ .ctrl = true } },
        0x1b => .{ .code = code.escape },
        0x1c...0x1f => .{ .code = @as(u21, b) + 0x40, .mods = .{ .ctrl = true } },
        0x7f => .{ .code = code.backspace },
        'A'...'Z' => .{ .code = @as(u21, b) + 32, .mods = .{ .shift = true }, .text = b },
        0x20...0x40, 0x5b...0x7e => .{ .code = b, .text = b },
        0x80...0xff => {
            const n = std.unicode.utf8ByteSequenceLength(b) catch return done(1, null);
            if (data.len < n) return .need_more;
            const cp = std.unicode.utf8Decode(data[0..n]) catch return done(1, null);
            const ev: KeyEvent = .{ .code = cp, .text = cp };
            if (alt) {
                var e = ev;
                e.mods.alt = true;
                return done(n, keyEvent(e));
            }
            return done(n, keyEvent(ev));
        },
    };
    if (alt) k.mods.alt = true;
    return done(1, keyEvent(k));
}

fn parseSs3(data: []const u8) Step {
    var j: usize = 2;
    while (j < data.len and ((data[j] >= '0' and data[j] <= '9') or data[j] == ';')) j += 1;
    if (j >= data.len) {
        return if (j >= constants.INPUT_MAX_CSI_LEN) .{ .skip_csi = j } else .need_more;
    }
    const final = data[j];
    if (final < 0x20 or final > 0x7e) return done(j, null);
    const p = Params.parse(data[2..j]);
    const mods_wire = if (p.n >= 2) p.getOr(1, 0, 1) else p.getOr(0, 0, 1);
    const c: ?u21 = letterCode(final) orelse switch (final) {
        'M' => code.enter,
        'X' => '=',
        'j' => '*',
        'k' => '+',
        'l' => ',',
        'm' => '-',
        'n' => '.',
        'o' => '/',
        'p'...'y' => '0' + @as(u21, final - 'p'),
        else => null,
    };
    const k = c orelse return done(j + 1, null);
    return done(j + 1, keyEvent(.{ .code = k, .mods = Mods.fromWire(mods_wire) }));
}

fn letterKey(final: u8, p: *const Params) ?Event {
    const c = letterCode(final) orelse return null;
    return keyEvent(.{
        .code = c,
        .mods = Mods.fromWire(p.getOr(1, 0, 1)),
        .kind = kindFromWire(p.getOr(1, 1, 1)),
    });
}

fn tildeKey(p: *const Params) ?Event {
    const n = p.get(0, 0) orelse return null;
    if (n == 27) {
        // xterm modifyOtherKeys: CSI 27 ; mods ; code ~
        const cp = p.get(2, 0) orelse return null;
        const mods = Mods.fromWire(p.getOr(1, 0, 1));
        const k = keyFromCode(cp, mods, .press, 0) orelse return null;
        return keyEvent(k);
    }
    const c = tildeCode(n) orelse return null; // incl. bracketed paste 200/201
    return keyEvent(.{
        .code = c,
        .mods = Mods.fromWire(p.getOr(1, 0, 1)),
        .kind = kindFromWire(p.getOr(1, 1, 1)),
    });
}

/// kitty: CSI code[:shifted[:base]] ; mods[:event] ; text[:text...] u
fn kittyKey(p: *const Params) ?Event {
    const cp = p.get(0, 0) orelse return null;
    const mods = Mods.fromWire(p.getOr(1, 0, 1));
    const kind = kindFromWire(p.getOr(1, 1, 1));
    var text: u21 = 0;
    if (p.get(2, 0)) |t| {
        if (isPrintableCp(t)) text = @intCast(t);
    } else if (p.get(0, 1)) |shifted| {
        if (mods.shift and isPrintableCp(shifted)) text = @intCast(shifted);
    }
    const k = keyFromCode(cp, mods, kind, text) orelse return null;
    return keyEvent(k);
}

fn windowReport(p: *const Params) ?Event {
    const what = p.get(0, 0) orelse return null;
    return switch (what) {
        6 => .{ .reply = .{ .cell_size = .{ .w = sat16(p.getOr(2, 0, 0)), .h = sat16(p.getOr(1, 0, 0)) } } },
        4 => .{ .reply = .{ .text_area = .{ .w = sat16(p.getOr(2, 0, 0)), .h = sat16(p.getOr(1, 0, 0)) } } },
        48 => .{ .reply = .{ .text_area = .{ .w = sat16(p.getOr(4, 0, 0)), .h = sat16(p.getOr(3, 0, 0)) } } },
        else => null,
    };
}

fn decrqm(p: *const Params) ?Event {
    const mode = p.get(0, 0) orelse return null;
    return .{ .reply = .{ .decrqm = .{
        .mode = sat16(mode),
        .value = @intCast(@min(p.getOr(1, 0, 0), 255)),
    } } };
}

/// Body of `ESC _ G <keys> ; <message> ESC \` after the 'G'.
fn kittyGraphicsReply(body: []const u8) ?Event {
    const semi = std.mem.indexOfScalar(u8, body, ';');
    const ctrl = if (semi) |s| body[0..s] else body;
    const msg = if (semi) |s| body[s + 1 ..] else "";
    var id: u32 = 0;
    var it = std.mem.splitScalar(u8, ctrl, ',');
    while (it.next()) |kv| {
        if (kv.len > 2 and kv[0] == 'i' and kv[1] == '=') {
            id = std.fmt.parseInt(u32, kv[2..], 10) catch 0;
        }
    }
    return .{ .reply = .{ .kitty_graphics = .{ .id = id, .ok = std.mem.eql(u8, msg, "OK") } } };
}

// ============================================================================
// Event queue
// ============================================================================

/// Fixed-capacity FIFO of events; drops the oldest when full.
pub fn EventQueue(comptime cap: usize) type {
    return struct {
        const Self = @This();

        items: [cap]Event = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, ev: Event) void {
            if (self.len == cap) {
                self.head = (self.head + 1) % cap;
                self.len -= 1;
            }
            self.items[(self.head + self.len) % cap] = ev;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?Event {
            if (self.len == 0) return null;
            const ev = self.items[self.head];
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            return ev;
        }
    };
}

fn legacyFrom(ev: Event) ?Key {
    return switch (ev) {
        .key => |k| k.toLegacy(),
        .reply => null,
    };
}

// ============================================================================
// WASM byte source
// ============================================================================

/// Web input: JavaScript pushes bytes (whole key sequences); they are parsed
/// immediately into an event queue.
pub const WasmInput = struct {
    parser: Parser = .{},
    queue: EventQueue(constants.WEB_EVENT_QUEUE_SIZE) = .{},

    pub fn init() WasmInput {
        return .{};
    }

    /// Push a single byte (treated as a complete chunk).
    pub fn pushByte(self: *WasmInput, b: u8) void {
        self.pushBytes(&[_]u8{b});
    }

    /// Push a chunk of bytes. A partial sequence at the end of the chunk is
    /// resolved right away (lone ESC = Escape) since JS sends whole sequences.
    pub fn pushBytes(self: *WasmInput, bytes: []const u8) void {
        var rest = bytes;
        while (true) {
            const n = self.parser.feed(rest);
            rest = rest[n..];
            const last = rest.len == 0;
            while (self.parser.next(last)) |ev| self.queue.push(ev);
            if (last) break;
            if (n == 0) {
                // Parser full of an unterminated sequence: drop it.
                while (self.parser.next(true)) |ev| self.queue.push(ev);
            }
        }
    }

    /// Re-queue an event (FIFO, after already queued events).
    pub fn queueEvent(self: *WasmInput, ev: Event) void {
        self.queue.push(ev);
    }

    /// Next parsed event, or null when none is pending.
    pub fn readEvent(self: *WasmInput) ?Event {
        return self.queue.pop();
    }

    /// Legacy wrapper: next key that maps to the old `Key` union.
    pub fn readKey(self: *WasmInput) ?Key {
        while (self.readEvent()) |ev| {
            if (legacyFrom(ev)) |k| return k;
        }
        return null;
    }
};

// ============================================================================
// Native byte source
// ============================================================================

/// Native input: reads stdin (non-blocking in raw mode, VMIN=0/VTIME=0).
pub const NativeInput = struct {
    const posix = std.posix;

    parser: Parser = .{},
    /// Events pushed back by `queueEvent` (returned before fresh input).
    backlog: EventQueue(constants.INPUT_EVENT_QUEUE_SIZE) = .{},
    fd: posix.fd_t = posix.STDIN_FILENO,

    pub fn init() NativeInput {
        return .{};
    }

    /// Inject a byte as if read from the terminal (tests / tooling).
    pub fn pushByte(self: *NativeInput, b: u8) void {
        self.pushBytes(&[_]u8{b});
    }

    /// Inject bytes as if read from the terminal; excess beyond the parser
    /// buffer is dropped.
    pub fn pushBytes(self: *NativeInput, bytes: []const u8) void {
        _ = self.parser.feed(bytes);
    }

    /// Re-queue an event (e.g. a key typed during the capability probe).
    pub fn queueEvent(self: *NativeInput, ev: Event) void {
        self.backlog.push(ev);
    }

    /// Non-blocking: next event from queued events or available input.
    /// Only waits (≤ ESC_TIMEOUT_MS) when the buffer ends in a partial
    /// sequence such as a lone ESC.
    pub fn readEvent(self: *NativeInput) ?Event {
        if (self.backlog.pop()) |ev| return ev;
        var waited = false;
        while (true) {
            if (self.parser.next(false)) |ev| return ev;
            if (self.fill(0)) continue;
            if (self.parser.pending() == 0) return null;
            if (!waited) {
                waited = true;
                if (self.fill(constants.ESC_TIMEOUT_MS)) continue;
            }
            return self.parser.next(true);
        }
    }

    /// Wait up to `timeout_ms` for the next event from fresh input (ignores
    /// the backlog, never resolves partial sequences). Used by the probe.
    pub fn readEventWait(self: *NativeInput, timeout_ms: i32) ?Event {
        while (true) {
            if (self.parser.next(false)) |ev| return ev;
            if (!self.fill(timeout_ms)) return null;
        }
    }

    /// Legacy wrapper: next key that maps to the old `Key` union.
    pub fn readKey(self: *NativeInput) ?Key {
        while (self.readEvent()) |ev| {
            if (legacyFrom(ev)) |k| return k;
        }
        return null;
    }

    /// Read whatever is available (after waiting up to `timeout_ms` for
    /// readability). Returns true if any bytes were added.
    fn fill(self: *NativeInput, timeout_ms: i32) bool {
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return false;
        if (ready == 0 or (fds[0].revents & posix.POLL.IN) == 0) return false;
        const w = self.parser.writable();
        if (w.len == 0) return false;
        const n = posix.read(self.fd, w) catch return false;
        if (n == 0) return false;
        self.parser.commit(n);
        return true;
    }
};
