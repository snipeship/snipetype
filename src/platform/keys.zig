//! Rich key events shared by native and web input.
//!
//! Input parsers (input.zig) turn raw terminal bytes — legacy escape
//! sequences, xterm modifyOtherKeys and the kitty keyboard protocol
//! (`CSI code;mods:event u`) — into `Event`s. Terminal replies to startup
//! probes (kitty graphics, DA1, size reports, ...) are surfaced as
//! `Event.reply` so they never leak into the app as keystrokes.

const std = @import("std");

/// Modifier bitset (kitty encoding: wire value = 1 + bits).
pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub const none: Mods = .{};

    /// Modifiers that matter for matching chords (ignores lock keys).
    pub fn chord(self: Mods) Mods {
        return .{ .shift = self.shift, .alt = self.alt, .ctrl = self.ctrl, .super = self.super };
    }

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a.chord())) == @as(u8, @bitCast(b.chord()));
    }

    pub fn fromWire(v: u32) Mods {
        const bits: u8 = @truncate(if (v == 0) 0 else v - 1);
        return @bitCast(bits);
    }
};

pub const Kind = enum(u2) { press = 1, repeat = 2, release = 3 };

/// Functional key codes. Values follow the kitty keyboard protocol where it
/// defines them (Private Use Area 57344+); ASCII control keys keep their
/// ASCII value.
pub const code = struct {
    pub const escape: u21 = 27;
    pub const enter: u21 = 13;
    pub const tab: u21 = 9;
    pub const backspace: u21 = 127;
    pub const space: u21 = ' ';
    pub const insert: u21 = 57348;
    pub const delete: u21 = 57349;
    pub const left: u21 = 57350;
    pub const right: u21 = 57351;
    pub const up: u21 = 57352;
    pub const down: u21 = 57353;
    pub const page_up: u21 = 57354;
    pub const page_down: u21 = 57355;
    pub const home: u21 = 57356;
    pub const end: u21 = 57357;
    pub const caps_lock: u21 = 57358;
    pub const f1: u21 = 57364; // f1..f12 = f1 + n - 1
    pub const left_shift: u21 = 57441;
    pub const left_control: u21 = 57442;
    pub const left_alt: u21 = 57443;
    pub const left_super: u21 = 57444;
    pub const right_shift: u21 = 57447;
    pub const right_control: u21 = 57448;
    pub const right_alt: u21 = 57449;
    pub const right_super: u21 = 57450;
    /// Keypad "begin" (5 on the keypad without NumLock): `CSI E` / `CSI 57427 u`.
    pub const kp_begin: u21 = 57427;
    /// Bracketed paste markers (`CSI 200~` / `CSI 201~`; private codes,
    /// outside kitty's range). Keys between them are pasted text.
    pub const paste_start: u21 = 0x10FF00;
    pub const paste_end: u21 = 0x10FF01;

    /// Function key F`n` (1-based; F1..F35 per kitty).
    pub fn f(n: u8) u21 {
        return f1 + @as(u21, n) - 1;
    }

    pub fn isModifier(c: u21) bool {
        return (c >= left_shift and c <= 57452) or c == caps_lock;
    }

    pub fn isArrow(c: u21) bool {
        return c >= left and c <= down;
    }
};

pub const KeyEvent = struct {
    /// Unshifted key code: lowercase ASCII letter for letters, the
    /// character itself for printable keys, or a `code.*` constant.
    code: u21,
    mods: Mods = .{},
    kind: Kind = .press,
    /// Shifted/produced text codepoint if known (e.g. 'V' for shift+v,
    /// '$' for shift+4). 0 when unknown or not a text-producing key.
    text: u21 = 0,

    /// The character this event types, if any (respects shift via `text`).
    pub fn char(self: KeyEvent) ?u21 {
        if (self.mods.ctrl or self.mods.alt or self.mods.super) return null;
        if (self.text != 0) return self.text;
        if (self.code >= 32 and self.code < 127) {
            if (self.mods.shift and self.code >= 'a' and self.code <= 'z') return self.code - 32;
            return self.code;
        }
        return null;
    }

    /// Map to the legacy `Key` union used by the typing/vim/settings paths.
    /// Reproduces the bytes a plain xterm-style terminal would have sent
    /// (Ctrl+letter → letter & 0x1f, Enter → '\r', Backspace → 0x7f, ...).
    /// Returns null for releases, modifier-only keys, Super chords, non-ASCII
    /// text and keys the legacy union cannot express (Home/End, F-keys, ...).
    pub fn toLegacy(self: KeyEvent) ?Key {
        if (self.kind == .release) return null;
        if (code.isModifier(self.code)) return null;
        const m = self.mods;
        if (m.super or m.hyper or m.meta) return null;

        switch (self.code) {
            code.enter => return if (m.alt) null else .{ .Byte = '\r' },
            code.tab => return if (m.alt or m.ctrl) null else .{ .Byte = '\t' },
            code.escape => return .{ .Byte = 0x1b },
            code.backspace => {
                if (m.alt) return .AltBackspace;
                return .{ .Byte = if (m.ctrl) 0x08 else 0x7f };
            },
            code.delete => {
                if (m.ctrl or m.shift) return null;
                return if (m.alt) .AltDelete else .Delete;
            },
            code.left, code.right, code.up, code.down => return legacyArrow(self.code, m),
            else => {},
        }

        const c = self.code;
        if (c >= 0x80) {
            // Non-ASCII text (or a functional key without a legacy form).
            return null;
        }

        if (m.ctrl and m.alt) {
            // ESC 0x08: legacy terminals send Ctrl+H for (Alt+)Backspace.
            return if (c == 'h') .AltBackspace else null;
        }
        if (m.ctrl) {
            // C0 control bytes: Ctrl+Space/@ → 0x00, Ctrl+letter, Ctrl+[\]^_.
            if (c == ' ' or c == '@') return .{ .Byte = 0x00 };
            if (c >= 'a' and c <= 'z') return .{ .Byte = @intCast(c & 0x1f) };
            if (c >= 'A' and c <= '_') return .{ .Byte = @intCast(c & 0x1f) };
            return null;
        }
        if (m.alt) {
            // ESC-prefixed word motions understood by the legacy parser.
            return switch (c) {
                'b', 'B' => .AltArrowLeft,
                'f', 'F' => .AltArrowRight,
                'd', 'D' => .AltDelete,
                else => null,
            };
        }
        const ch = self.char() orelse return null;
        if (ch < 0x20 or ch >= 0x7f) return null;
        return .{ .Byte = @intCast(ch) };
    }
};

/// Replies to terminal capability probes (see caps.zig).
pub const Reply = union(enum) {
    /// `ESC _G i=<id>;OK ESC \` or an error message.
    kitty_graphics: struct { id: u32, ok: bool },
    /// `CSI ? flags u`
    kitty_keyboard: u32,
    /// `CSI ? ... c` (primary device attributes, used as probe terminator)
    da1,
    /// `CSI 6 ; h ; w t`
    cell_size: struct { w: u16, h: u16 },
    /// `CSI 4 ; h ; w t` or in-band resize `CSI 48 ; rows ; cols ; hpx ; wpx t`
    text_area: struct { w: u16, h: u16 },
    /// `CSI ? mode ; value $ y`
    decrqm: struct { mode: u16, value: u8 },
    /// `DCS > | name ST`; slice valid until the next read.
    xtversion: []const u8,
};

pub const Event = union(enum) {
    key: KeyEvent,
    reply: Reply,
};

/// Legacy key union consumed by the typing, vim and settings code paths.
/// Produced from rich events via `KeyEvent.toLegacy()`.
pub const Key = union(enum) {
    Byte: u8,
    // Plain arrows
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    // Shift+Arrow (word movement)
    ShiftArrowLeft,
    ShiftArrowRight,
    // Alt+Arrow (word movement)
    AltArrowLeft,
    AltArrowRight,
    // Ctrl+Arrow (word movement)
    CtrlArrowLeft,
    CtrlArrowRight,
    // Ctrl+Up/Down (document navigation)
    CtrlArrowUp,
    CtrlArrowDown,
    // Delete keys
    Delete,
    AltDelete,
    AltBackspace,
};

fn legacyArrow(c: u21, m: Mods) ?Key {
    const shift = m.shift;
    const alt = m.alt;
    const ctrl = m.ctrl;
    if (!shift and !alt and !ctrl) return switch (c) {
        code.up => .ArrowUp,
        code.down => .ArrowDown,
        code.left => .ArrowLeft,
        code.right => .ArrowRight,
        else => null,
    };
    if (shift and !alt and !ctrl) return switch (c) {
        code.left => .ShiftArrowLeft,
        code.right => .ShiftArrowRight,
        else => null,
    };
    if (alt and !shift and !ctrl) return switch (c) {
        code.left => .AltArrowLeft,
        code.right => .AltArrowRight,
        else => null,
    };
    if (ctrl and !shift and !alt) return switch (c) {
        code.up => .CtrlArrowUp,
        code.down => .CtrlArrowDown,
        code.left => .CtrlArrowLeft,
        code.right => .CtrlArrowRight,
        else => null,
    };
    return null;
}

test "mods wire decoding" {
    const m = Mods.fromWire(6); // ctrl+shift
    try std.testing.expect(m.ctrl and m.shift and !m.alt);
    try std.testing.expect(Mods.eql(m, .{ .ctrl = true, .shift = true }));
}
