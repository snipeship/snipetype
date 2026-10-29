//! Keys as the vim engine sees them.
//!
//! `VimKey` is the single input type of `VimEditor.feed`. Native and web
//! input arrive as `keys.KeyEvent` and are converted by `fromKeyEvent`;
//! tests, macros and drill solutions are written in Vim's key notation
//! (`ci(x<Esc>`) and parsed by `Notation`.

const std = @import("std");
const keys = @import("../platform/keys.zig");

pub const VimKey = union(enum) {
    /// Printable ASCII 0x20..0x7e.
    char: u8,
    /// 'a'..'z', '[', ']', '\\', '^', '_' (Ctrl+C = .{ .ctrl = 'c' }).
    ctrl: u8,
    esc,
    enter,
    backspace,
    delete,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    /// Ctrl/Shift/Alt + Left/Right.
    word_left,
    word_right,
    /// Ctrl+Up / Ctrl+Down.
    doc_top,
    doc_bottom,
    /// F1..F12.
    f: u8,

    pub fn eql(a: VimKey, b: VimKey) bool {
        return std.meta.eql(a, b);
    }

    /// True for `.ctrl = c` or the equivalent named key (Ctrl+[ is Esc).
    pub fn isCtrl(self: VimKey, c: u8) bool {
        return switch (self) {
            .ctrl => |x| x == c,
            else => false,
        };
    }

    /// Vim notation of the key: "x" "<C-w>" "<Esc>" "<CR>" "<BS>" "<lt>" ...
    /// Every name fits in 8 bytes (Ctrl/Shift+Left/Right are "<WLeft>" and
    /// "<WRight>", Page Down is "<PageDn>").
    pub fn format(self: VimKey, buf: *[8]u8) []const u8 {
        const name: []const u8 = switch (self) {
            .char => |c| {
                if (c == '<') return "<lt>";
                buf[0] = c;
                return buf[0..1];
            },
            .ctrl => |c| {
                buf[0..3].* = "<C-".*;
                buf[3] = c;
                buf[4] = '>';
                return buf[0..5];
            },
            .f => |n| return std.fmt.bufPrint(buf, "<F{d}>", .{n}) catch "<F?>",
            .esc => "<Esc>",
            .enter => "<CR>",
            .backspace => "<BS>",
            .delete => "<Del>",
            .tab => "<Tab>",
            .up => "<Up>",
            .down => "<Down>",
            .left => "<Left>",
            .right => "<Right>",
            .home => "<Home>",
            .end => "<End>",
            .page_up => "<PageUp>",
            .page_down => "<PageDn>",
            .word_left => "<WLeft>",
            .word_right => "<WRight>",
            .doc_top => "<C-Home>",
            .doc_bottom => "<C-End>",
        };
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }

    /// Key for a legacy terminal byte (27 Esc, 13 Enter, 127/8 Backspace,
    /// 9 Tab, 0x01..0x1a Ctrl+letter, printable ASCII). Null for others.
    pub fn fromByte(b: u8) ?VimKey {
        return switch (b) {
            0x1b => .esc,
            '\r', '\n' => .enter,
            0x7f => .backspace,
            '\t' => .tab,
            0x01...0x08, 0x0b, 0x0c, 0x0e...0x1a => .{ .ctrl = b + 'a' - 1 },
            0x1c => .{ .ctrl = '\\' },
            0x1d => .{ .ctrl = ']' },
            0x1e => .{ .ctrl = '^' },
            0x1f => .{ .ctrl = '_' },
            0x20...0x7e => .{ .char = b },
            else => null,
        };
    }
};

/// keys.KeyEvent → 0, 1 or 2 VimKeys. Releases, modifier-only keys and
/// Super chords → empty. Alt+printable → {esc, char} (vim terminal
/// convention; fixes a fast `<Esc>o` being read as Alt+o). Ctrl+Backspace
/// and Alt+Backspace → `<C-w>`. Ctrl+[ → Esc. Ctrl+H → `<C-h>`. Shift+Tab
/// → empty. Super+Backspace (web Cmd+Backspace) → `<C-u>`.
pub fn fromKeyEvent(ev: keys.KeyEvent, out: *[2]VimKey) []const VimKey {
    if (ev.kind == .release) return out[0..0];
    const c = ev.code;
    if (keys.code.isModifier(c)) return out[0..0];
    const m = ev.mods;
    if (m.super or m.hyper or m.meta) {
        if (c == keys.code.backspace and !m.ctrl and !m.alt) return one(out, .{ .ctrl = 'u' });
        return out[0..0];
    }

    switch (c) {
        keys.code.escape => return one(out, .esc),
        keys.code.enter => return one(out, .enter),
        keys.code.tab => return if (m.shift or m.ctrl or m.alt) out[0..0] else one(out, .tab),
        keys.code.backspace => return one(out, if (m.ctrl or m.alt) .{ .ctrl = 'w' } else .backspace),
        keys.code.delete => return one(out, .delete),
        keys.code.left, keys.code.right => {
            const word = m.ctrl or m.shift or m.alt;
            if (c == keys.code.left) return one(out, if (word) .word_left else .left);
            return one(out, if (word) .word_right else .right);
        },
        keys.code.up => return one(out, if (m.ctrl) .doc_top else if (m.shift) .page_up else .up),
        keys.code.down => return one(out, if (m.ctrl) .doc_bottom else if (m.shift) .page_down else .down),
        keys.code.home => return one(out, if (m.ctrl) .doc_top else .home),
        keys.code.end => return one(out, if (m.ctrl) .doc_bottom else .end),
        keys.code.page_up => return one(out, .page_up),
        keys.code.page_down => return one(out, .page_down),
        else => {},
    }
    if (c >= keys.code.f1 and c < keys.code.f1 + 12) {
        return one(out, .{ .f = @intCast(c - keys.code.f1 + 1) });
    }
    if (c >= 0x80) return out[0..0];

    if (m.ctrl) {
        const lower: u21 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (m.alt) {
            // Legacy terminals send ESC ^H for Alt+Backspace.
            return if (lower == 'h') one(out, .{ .ctrl = 'w' }) else out[0..0];
        }
        return switch (lower) {
            'a'...'z' => one(out, .{ .ctrl = @intCast(lower) }),
            '[' => one(out, .esc),
            ']', '\\', '^', '_' => one(out, .{ .ctrl = @intCast(lower) }),
            '6' => one(out, .{ .ctrl = '^' }),
            '-' => one(out, .{ .ctrl = '_' }),
            else => out[0..0],
        };
    }
    if (m.alt) {
        const ch = producedChar(ev) orelse return out[0..0];
        out[0] = .esc;
        out[1] = .{ .char = ch };
        return out[0..2];
    }
    const ch = ev.char() orelse return out[0..0];
    if (ch < 0x20 or ch > 0x7e) return out[0..0];
    return one(out, .{ .char = @intCast(ch) });
}

fn one(out: *[2]VimKey, k: VimKey) []const VimKey {
    out[0] = k;
    return out[0..1];
}

/// The printable character a key produces ignoring Ctrl/Alt (shift applied).
fn producedChar(ev: keys.KeyEvent) ?u8 {
    const t: u21 = if (ev.text != 0) ev.text else blk: {
        if (ev.code < 0x20 or ev.code > 0x7e) return null;
        if (ev.mods.shift and ev.code >= 'a' and ev.code <= 'z') break :blk ev.code - 32;
        break :blk ev.code;
    };
    if (t < 0x20 or t > 0x7e) return null;
    return @intCast(t);
}

/// Iterator over Vim key notation: "ci(x<Esc>", "<C-w>", "<CR>", "<lt>".
/// An unrecognised `<...>` is read as a literal '<'. Raw control bytes are
/// accepted too (0x1b Esc, '\n'/'\r' Enter, '\t' Tab, 0x7f Backspace,
/// 0x01..0x1a Ctrl+letter), so register text can be replayed as a macro.
pub const Notation = struct {
    s: []const u8,
    i: usize = 0,

    pub fn init(s: []const u8) Notation {
        return .{ .s = s };
    }

    pub fn next(self: *Notation) ?VimKey {
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == '<') {
                if (std.mem.indexOfScalarPos(u8, self.s, self.i + 1, '>')) |close| {
                    if (named(self.s[self.i + 1 .. close])) |k| {
                        self.i = close + 1;
                        return k;
                    }
                }
            }
            self.i += 1;
            if (VimKey.fromByte(c)) |k| return k;
        }
        return null;
    }

    /// Number of keys in `s`.
    pub fn count(s: []const u8) usize {
        var it = Notation.init(s);
        var n: usize = 0;
        while (it.next() != null) n += 1;
        return n;
    }
};

fn named(name: []const u8) ?VimKey {
    const Entry = struct { []const u8, VimKey };
    const table = [_]Entry{
        .{ "esc", .esc },               .{ "cr", .enter },             .{ "enter", .enter },
        .{ "return", .enter },          .{ "bs", .backspace },         .{ "del", .delete },
        .{ "tab", .tab },               .{ "up", .up },                .{ "down", .down },
        .{ "left", .left },             .{ "right", .right },          .{ "home", .home },
        .{ "end", .end },               .{ "pageup", .page_up },       .{ "pagedown", .page_down },
        .{ "pagedn", .page_down },      .{ "wleft", .word_left },      .{ "wright", .word_right },
        .{ "s-left", .word_left },      .{ "c-left", .word_left },     .{ "s-right", .word_right },
        .{ "c-right", .word_right },    .{ "c-home", .doc_top },       .{ "c-end", .doc_bottom },
        .{ "c-up", .doc_top },          .{ "c-down", .doc_bottom },    .{ "lt", .{ .char = '<' } },
        .{ "space", .{ .char = ' ' } }, .{ "bar", .{ .char = '|' } },  .{ "bslash", .{ .char = '\\' } },
        .{ "c-[", .esc },               .{ "c-bs", .{ .ctrl = 'w' } }, .{ "m-bs", .{ .ctrl = 'w' } },
        .{ "nl", .enter },
    };
    var lower: [16]u8 = undefined;
    if (name.len == 0 or name.len > lower.len) return null;
    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const l = lower[0..name.len];
    for (table) |e| {
        if (std.mem.eql(u8, e[0], l)) return e[1];
    }
    if (l.len == 3 and l[0] == 'c' and l[1] == '-') {
        return switch (l[2]) {
            'a'...'z', ']', '\\', '^', '_' => .{ .ctrl = l[2] },
            else => null,
        };
    }
    if (l.len >= 2 and l.len <= 3 and l[0] == 'f') {
        const n = std.fmt.parseInt(u8, l[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return .{ .f = n };
    }
    return null;
}

/// Appends the notation of `k` to `out` (stops silently when full).
pub fn appendNotation(out: []u8, len: *usize, k: VimKey) void {
    var tmp: [8]u8 = undefined;
    const s = k.format(&tmp);
    if (len.* + s.len > out.len) {
        len.* = out.len;
        return;
    }
    @memcpy(out[len.*..][0..s.len], s);
    len.* += s.len;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectEvent(ev: keys.KeyEvent, expected: []const VimKey) !void {
    var out: [2]VimKey = undefined;
    const got = fromKeyEvent(ev, &out);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expect(e.eql(g));
}

test "fromKeyEvent: alt splits, ctrl chords, releases" {
    try expectEvent(.{ .code = 'o', .mods = .{ .alt = true } }, &.{ .esc, .{ .char = 'o' } });
    try expectEvent(.{ .code = 'o', .mods = .{ .alt = true, .shift = true } }, &.{ .esc, .{ .char = 'O' } });
    try expectEvent(.{ .code = keys.code.backspace, .mods = .{ .ctrl = true } }, &.{.{ .ctrl = 'w' }});
    try expectEvent(.{ .code = keys.code.backspace, .mods = .{ .alt = true } }, &.{.{ .ctrl = 'w' }});
    try expectEvent(.{ .code = keys.code.backspace, .mods = .{ .super = true } }, &.{.{ .ctrl = 'u' }});
    try expectEvent(.{ .code = 'a', .kind = .release }, &.{});
    try expectEvent(.{ .code = '[', .mods = .{ .ctrl = true } }, &.{.esc});
    try expectEvent(.{ .code = 'h', .mods = .{ .ctrl = true } }, &.{.{ .ctrl = 'h' }});
    try expectEvent(.{ .code = 'w', .mods = .{ .ctrl = true } }, &.{.{ .ctrl = 'w' }});
    try expectEvent(.{ .code = keys.code.tab, .mods = .{ .shift = true } }, &.{});
    try expectEvent(.{ .code = keys.code.left_shift }, &.{});
    try expectEvent(.{ .code = 'v', .mods = .{ .super = true } }, &.{});
    try expectEvent(.{ .code = '4', .mods = .{ .shift = true }, .text = '$' }, &.{.{ .char = '$' }});
    try expectEvent(.{ .code = 'x', .mods = .{ .shift = true } }, &.{.{ .char = 'X' }});
    try expectEvent(.{ .code = keys.code.left, .mods = .{ .ctrl = true } }, &.{.word_left});
    try expectEvent(.{ .code = keys.code.up, .mods = .{ .ctrl = true } }, &.{.doc_top});
    try expectEvent(.{ .code = keys.code.f(1) }, &.{.{ .f = 1 }});
    try expectEvent(.{ .code = keys.code.home }, &.{.home});
    try expectEvent(.{ .code = keys.code.delete }, &.{.delete});
    try expectEvent(.{ .code = keys.code.paste_start }, &.{});
}

test "notation round trip" {
    var it = Notation.init("ci(x<Esc><C-w><CR><lt><bar>a<foo");
    const want = [_]VimKey{
        .{ .char = 'c' }, .{ .char = 'i' }, .{ .char = '(' }, .{ .char = 'x' }, .esc,
        .{ .ctrl = 'w' }, .enter,           .{ .char = '<' }, .{ .char = '|' }, .{ .char = 'a' },
        .{ .char = '<' }, .{ .char = 'f' }, .{ .char = 'o' }, .{ .char = 'o' },
    };
    for (want) |w| try testing.expect(w.eql(it.next().?));
    try testing.expect(it.next() == null);

    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("<C-w>", (VimKey{ .ctrl = 'w' }).format(&buf));
    try testing.expectEqualStrings("<lt>", (VimKey{ .char = '<' }).format(&buf));
    try testing.expectEqualStrings("<F12>", (VimKey{ .f = 12 }).format(&buf));
    try testing.expectEqualStrings("<PageDn>", @as(VimKey, .page_down).format(&buf));
    try testing.expectEqual(@as(usize, 9), Notation.count(":s/_/-/g<CR>"));
}
