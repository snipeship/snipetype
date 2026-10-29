//! Test entry for platform input/terminal/caps (run: `zig test src/platform_tests.zig`).
//! Wasm-safety check: `zig build-obj -target wasm32-freestanding -O ReleaseSmall -fno-emit-bin src/platform_tests.zig`.

const std = @import("std");
const builtin = @import("builtin");
pub const keys = @import("platform/keys.zig");
pub const input = @import("platform/input.zig");
pub const terminal = @import("platform/terminal.zig");
pub const caps = @import("platform/caps.zig");
/// Exposed for scratch harnesses that drive the platform layer directly.
pub const time = @import("platform/time.zig");
const renderer = @import("platform/renderer.zig");
const ansi_renderer = @import("platform/ansi_renderer.zig");
const cell_renderer = @import("platform/cell_renderer.zig");
/// Classic-mode diffing renderer (contract C7); its tests run from here.
pub const diff_renderer = @import("platform/diff_renderer.zig");

const testing = std.testing;
const code = keys.code;
const Event = keys.Event;
const KeyEvent = keys.KeyEvent;
const Key = keys.Key;
const Parser = input.Parser;

comptime {
    _ = diff_renderer;
    _ = keys;
    _ = input;
    _ = terminal;
    _ = caps;
    // Force semantic analysis of the per-target public API (also on wasm).
    _ = &keys.KeyEvent.toLegacy;
    _ = &input.Parser.next;
    _ = &input.Input.init;
    _ = &input.Input.readEvent;
    _ = &input.Input.readKey;
    _ = &input.Input.pushBytes;
    _ = &input.Input.pushByte;
    _ = &input.Input.queueEvent;
    _ = &terminal.Terminal.init;
    _ = &terminal.Terminal.enableRawMode;
    _ = &terminal.Terminal.restore;
    _ = &terminal.Terminal.updateSize;
    _ = &terminal.Terminal.cellPixelSize;
    _ = &terminal.Terminal.setCellPixelSize;
    _ = &terminal.Terminal.enterAltScreen;
    _ = &terminal.Terminal.leaveAltScreen;
    _ = &terminal.Terminal.hideCursor;
    _ = &terminal.Terminal.showCursor;
    _ = &terminal.Terminal.pushKeyboardFlags;
    _ = &terminal.Terminal.popKeyboardFlags;
    _ = &terminal.Terminal.setKeyboardFlags;
    _ = &terminal.Terminal.setInBandResize;
    _ = &terminal.Terminal.emergencyRestore;
    _ = &caps.detect;
    _ = &caps.Caps.fromEnv;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const max_events = 64;

const Collected = struct {
    items: [max_events]Event = undefined,
    len: usize = 0,

    fn slice(self: *const Collected) []const Event {
        return self.items[0..self.len];
    }
};

/// Parse `bytes` fully (flush at end, like a chunk from the web host).
fn parseAll(p: *Parser, bytes: []const u8) Collected {
    var out: Collected = .{};
    _ = p.feed(bytes);
    while (p.next(true)) |ev| {
        out.items[out.len] = ev;
        out.len += 1;
    }
    return out;
}

fn parseFresh(bytes: []const u8) Collected {
    var p: Parser = .{};
    return parseAll(&p, bytes);
}

fn expectOneKey(bytes: []const u8, expected: KeyEvent) !void {
    const evs = parseFresh(bytes);
    try testing.expectEqual(@as(usize, 1), evs.len);
    switch (evs.items[0]) {
        .key => |k| {
            try testing.expectEqual(expected.code, k.code);
            try testing.expect(keys.Mods.eql(expected.mods, k.mods));
            try testing.expectEqual(expected.kind, k.kind);
            try testing.expectEqual(expected.text, k.text);
        },
        .reply => return error.TestUnexpectedResult,
    }
}

fn expectOneReply(bytes: []const u8) !keys.Reply {
    var p: Parser = .{};
    _ = p.feed(bytes);
    const ev = p.next(false) orelse return error.TestUnexpectedResult;
    try testing.expect(p.next(true) == null);
    return switch (ev) {
        .reply => |r| r,
        .key => error.TestUnexpectedResult,
    };
}

fn expectNothing(bytes: []const u8) !void {
    const evs = parseFresh(bytes);
    try testing.expectEqual(@as(usize, 0), evs.len);
}

const ctrl: keys.Mods = .{ .ctrl = true };
const alt: keys.Mods = .{ .alt = true };
const shift: keys.Mods = .{ .shift = true };

// ---------------------------------------------------------------------------
// Plain bytes, UTF-8, C0 controls
// ---------------------------------------------------------------------------

test "printable ascii and shifted letters" {
    try expectOneKey("a", .{ .code = 'a', .text = 'a' });
    try expectOneKey("A", .{ .code = 'a', .mods = shift, .text = 'A' });
    try expectOneKey("$", .{ .code = '$', .text = '$' });
    try expectOneKey(" ", .{ .code = ' ', .text = ' ' });
    try expectOneKey("~", .{ .code = '~', .text = '~' });
    try expectOneKey("@", .{ .code = '@', .text = '@' });
}

test "multiple keys in one read" {
    const evs = parseFresh("hi!");
    try testing.expectEqual(@as(usize, 3), evs.len);
    try testing.expectEqual(@as(u21, 'h'), evs.items[0].key.code);
    try testing.expectEqual(@as(u21, 'i'), evs.items[1].key.code);
    try testing.expectEqual(@as(u21, '!'), evs.items[2].key.code);
}

test "utf8 text incl. split across reads" {
    try expectOneKey("é", .{ .code = 'é', .text = 'é' });
    try expectOneKey("😀", .{ .code = 0x1F600, .text = 0x1F600 });
    var p: Parser = .{};
    const bytes = "€"; // e2 82 ac
    _ = p.feed(bytes[0..1]);
    try testing.expect(p.next(false) == null);
    _ = p.feed(bytes[1..2]);
    try testing.expect(p.next(false) == null);
    _ = p.feed(bytes[2..3]);
    const ev = p.next(false).?;
    try testing.expectEqual(@as(u21, 0x20AC), ev.key.code);
    // Invalid byte is dropped, parsing resyncs.
    const evs = parseFresh("\xffa");
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u21, 'a'), evs.items[0].key.code);
}

test "C0 controls map to ctrl+key" {
    try expectOneKey("\x03", .{ .code = 'c', .mods = ctrl });
    try expectOneKey("\x10", .{ .code = 'p', .mods = ctrl });
    try expectOneKey("\x01", .{ .code = 'a', .mods = ctrl });
    try expectOneKey("\x1a", .{ .code = 'z', .mods = ctrl });
    try expectOneKey("\x08", .{ .code = 'h', .mods = ctrl });
    try expectOneKey("\x0a", .{ .code = 'j', .mods = ctrl });
    try expectOneKey("\x00", .{ .code = ' ', .mods = ctrl });
    try expectOneKey("\x1c", .{ .code = '\\', .mods = ctrl });
    try expectOneKey("\x1f", .{ .code = '_', .mods = ctrl });
    try expectOneKey("\r", .{ .code = code.enter });
    try expectOneKey("\t", .{ .code = code.tab });
    try expectOneKey("\x7f", .{ .code = code.backspace });
}

// ---------------------------------------------------------------------------
// ESC / Alt
// ---------------------------------------------------------------------------

test "lone ESC is Escape only when flushed" {
    var p: Parser = .{};
    _ = p.feed("\x1b");
    try testing.expect(p.next(false) == null);
    try testing.expectEqual(@as(usize, 1), p.pending());
    const ev = p.next(true).?;
    try testing.expectEqual(code.escape, ev.key.code);
    try testing.expect(p.isIdle());
    // Double ESC = two Escapes.
    const evs = parseFresh("\x1b\x1b");
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqual(code.escape, evs.items[0].key.code);
    try testing.expectEqual(code.escape, evs.items[1].key.code);
}

test "ESC-prefixed alt keys" {
    try expectOneKey("\x1bb", .{ .code = 'b', .mods = alt, .text = 'b' });
    try expectOneKey("\x1bB", .{ .code = 'b', .mods = .{ .alt = true, .shift = true }, .text = 'B' });
    try expectOneKey("\x1b\x7f", .{ .code = code.backspace, .mods = alt });
    try expectOneKey("\x1b\x08", .{ .code = 'h', .mods = .{ .alt = true, .ctrl = true } });
    try expectOneKey("\x1b\x01", .{ .code = 'a', .mods = .{ .alt = true, .ctrl = true } });
    try expectOneKey("\x1bé", .{ .code = 'é', .mods = alt, .text = 'é' });
    // Partial intro resolved on flush: ESC [ → Alt+[
    try expectOneKey("\x1b[", .{ .code = '[', .mods = alt, .text = '[' });
    try expectOneKey("\x1bO", .{ .code = 'o', .mods = .{ .alt = true, .shift = true }, .text = 'O' });
}

// ---------------------------------------------------------------------------
// CSI / SS3 functional keys
// ---------------------------------------------------------------------------

test "csi arrows home end with modifiers" {
    try expectOneKey("\x1b[A", .{ .code = code.up });
    try expectOneKey("\x1b[B", .{ .code = code.down });
    try expectOneKey("\x1b[C", .{ .code = code.right });
    try expectOneKey("\x1b[D", .{ .code = code.left });
    try expectOneKey("\x1b[H", .{ .code = code.home });
    try expectOneKey("\x1b[F", .{ .code = code.end });
    try expectOneKey("\x1b[1;5C", .{ .code = code.right, .mods = ctrl });
    try expectOneKey("\x1b[1;3D", .{ .code = code.left, .mods = alt });
    try expectOneKey("\x1b[1;2A", .{ .code = code.up, .mods = shift });
    try expectOneKey("\x1b[1;6B", .{ .code = code.down, .mods = .{ .ctrl = true, .shift = true } });
    try expectOneKey("\x1b[1;4H", .{ .code = code.home, .mods = .{ .alt = true, .shift = true } });
    try expectOneKey("\x1b[1;9A", .{ .code = code.up, .mods = .{ .super = true } });
    try expectOneKey("\x1b[Z", .{ .code = code.tab, .mods = shift });
    try expectOneKey("\x1b[E", .{ .code = code.kp_begin });
}

test "csi tilde keys and F-keys" {
    try expectOneKey("\x1b[3~", .{ .code = code.delete });
    try expectOneKey("\x1b[3;3~", .{ .code = code.delete, .mods = alt });
    try expectOneKey("\x1b[2~", .{ .code = code.insert });
    try expectOneKey("\x1b[5~", .{ .code = code.page_up });
    try expectOneKey("\x1b[6;5~", .{ .code = code.page_down, .mods = ctrl });
    try expectOneKey("\x1b[1~", .{ .code = code.home });
    try expectOneKey("\x1b[4~", .{ .code = code.end });
    try expectOneKey("\x1b[7~", .{ .code = code.home });
    try expectOneKey("\x1b[8~", .{ .code = code.end });
    try expectOneKey("\x1b[15~", .{ .code = code.f(5) });
    try expectOneKey("\x1b[17~", .{ .code = code.f(6) });
    try expectOneKey("\x1b[21~", .{ .code = code.f(10) });
    try expectOneKey("\x1b[23~", .{ .code = code.f(11) });
    try expectOneKey("\x1b[24;2~", .{ .code = code.f(12), .mods = shift });
    try expectOneKey("\x1b[13~", .{ .code = code.f(3) });
    try expectOneKey("\x1b[1;5P", .{ .code = code.f(1), .mods = ctrl });
    try expectOneKey("\x1b[Q", .{ .code = code.f(2) });
    try expectOneKey("\x1b[1;2R", .{ .code = code.f(3), .mods = shift });
    try expectOneKey("\x1b[S", .{ .code = code.f(4) });
}

test "bracketed paste markers frame the pasted text" {
    const evs = parseFresh("\x1b[200~hi\x1b[201~");
    try testing.expectEqual(@as(usize, 4), evs.len);
    try testing.expectEqual(code.paste_start, evs.items[0].key.code);
    try testing.expectEqual(@as(u21, 'h'), evs.items[1].key.code);
    try testing.expectEqual(@as(u21, 'i'), evs.items[2].key.code);
    try testing.expectEqual(code.paste_end, evs.items[3].key.code);
    try testing.expect(evs.items[0].key.toLegacy() == null);
}

test "ss3 keys" {
    try expectOneKey("\x1bOP", .{ .code = code.f(1) });
    try expectOneKey("\x1bOQ", .{ .code = code.f(2) });
    try expectOneKey("\x1bOR", .{ .code = code.f(3) });
    try expectOneKey("\x1bOS", .{ .code = code.f(4) });
    try expectOneKey("\x1bOA", .{ .code = code.up });
    try expectOneKey("\x1bOH", .{ .code = code.home });
    try expectOneKey("\x1bOF", .{ .code = code.end });
    try expectOneKey("\x1bOM", .{ .code = code.enter });
    try expectOneKey("\x1bOp", .{ .code = '0' });
    try expectOneKey("\x1bOy", .{ .code = '9' });
    try expectOneKey("\x1bO5P", .{ .code = code.f(1), .mods = ctrl });
}

test "xterm modifyOtherKeys" {
    try expectOneKey("\x1b[27;6;118~", .{ .code = 'v', .mods = .{ .ctrl = true, .shift = true } });
    try expectOneKey("\x1b[27;5;13~", .{ .code = code.enter, .mods = ctrl });
    try expectOneKey("\x1b[27;2;9~", .{ .code = code.tab, .mods = shift });
    try expectOneKey("\x1b[27;6;86~", .{ .code = 'v', .mods = .{ .ctrl = true, .shift = true }, .text = 'V' });
    try expectOneKey("\x1b[27;2;36~", .{ .code = '$', .mods = shift });
}

test "kitty CSI u full grammar" {
    // Plain code.
    try expectOneKey("\x1b[97u", .{ .code = 'a' });
    // Mods.
    try expectOneKey("\x1b[118;6u", .{ .code = 'v', .mods = .{ .ctrl = true, .shift = true } });
    try expectOneKey("\x1b[116;7u", .{ .code = 't', .mods = .{ .ctrl = true, .alt = true } });
    // Alternate keys (shifted:base) + shift → text from shifted key.
    try expectOneKey("\x1b[118:86;6u", .{ .code = 'v', .mods = .{ .ctrl = true, .shift = true }, .text = 'V' });
    try expectOneKey("\x1b[52:36:52;2u", .{ .code = '4', .mods = shift, .text = '$' });
    // Event types.
    try expectOneKey("\x1b[97;1:1u", .{ .code = 'a', .kind = .press });
    try expectOneKey("\x1b[97;1:2u", .{ .code = 'a', .kind = .repeat });
    try expectOneKey("\x1b[97;1:3u", .{ .code = 'a', .kind = .release });
    // Associated text (with empty mods field defaulting to 1).
    try expectOneKey("\x1b[97;;97u", .{ .code = 'a', .text = 'a' });
    try expectOneKey("\x1b[97;2;65u", .{ .code = 'a', .mods = shift, .text = 'A' });
    try expectOneKey("\x1b[52:36;2:1;36u", .{ .code = '4', .mods = shift, .text = '$' });
    // Every field at once.
    try expectOneKey("\x1b[97:65:97;2:2;65u", .{ .code = 'a', .mods = shift, .kind = .repeat, .text = 'A' });
    // Functional keys as CSI u.
    try expectOneKey("\x1b[13u", .{ .code = code.enter });
    try expectOneKey("\x1b[13;2u", .{ .code = code.enter, .mods = shift });
    try expectOneKey("\x1b[27u", .{ .code = code.escape });
    try expectOneKey("\x1b[127;5u", .{ .code = code.backspace, .mods = ctrl });
    try expectOneKey("\x1b[9;2u", .{ .code = code.tab, .mods = shift });
    try expectOneKey("\x1b[57441;2u", .{ .code = code.left_shift, .mods = shift });
    try expectOneKey("\x1b[57442;5:3u", .{ .code = code.left_control, .mods = ctrl, .kind = .release });
    // Arrow with event type (flag 2).
    try expectOneKey("\x1b[1;1:3A", .{ .code = code.up, .kind = .release });
    try expectOneKey("\x1b[3;1:2~", .{ .code = code.delete, .kind = .repeat });
    // Keypad normalization.
    try expectOneKey("\x1b[57400u", .{ .code = '1' });
    try expectOneKey("\x1b[57414u", .{ .code = code.enter });
    try expectOneKey("\x1b[57417u", .{ .code = code.left });
    // Lock modifiers survive in mods but don't affect chord matching.
    const evs = parseFresh("\x1b[97;65u"); // caps_lock
    try testing.expect(evs.items[0].key.mods.caps_lock);
    try testing.expect(keys.Mods.eql(evs.items[0].key.mods, .{}));
    // F13+ come as CSI u codes.
    try expectOneKey("\x1b[57376u", .{ .code = code.f(13) });
}

test "sequences split across reads" {
    const seqs = [_][]const u8{
        "\x1b[1;5C",
        "\x1b[118:86;6:1;86u",
        "\x1bOP",
        "\x1b[27;6;118~",
        "\x1b_Gi=31;OK\x1b\\",
        "\x1bP>|ghostty 1.4.0\x1b\\",
        "\x1b[?62;22c",
    };
    for (seqs) |seq| {
        // Every split point, without flushing between parts.
        for (1..seq.len) |cut| {
            var p: Parser = .{};
            _ = p.feed(seq[0..cut]);
            try testing.expect(p.next(false) == null);
            _ = p.feed(seq[cut..]);
            const ev = p.next(false) orelse return error.TestUnexpectedResult;
            _ = ev;
            try testing.expect(p.next(false) == null);
            try testing.expect(p.isIdle());
        }
    }
}

test "unknown sequences are consumed silently" {
    try expectNothing("\x1b[?1;2R"); // DECXCPR
    try expectNothing("\x1b[5;10R"); // cursor position report
    try expectNothing("\x1b[I"); // focus in
    try expectNothing("\x1b[O"); // focus out
    try expectNothing("\x1b[>1;10;0c"); // DA2
    try expectNothing("\x1b[99x");
    try expectNothing("\x1b]11;rgb:0000/0000/0000\x07"); // OSC reply (BEL)
    try expectNothing("\x1b]11;rgb:0000/0000/0000\x1b\\"); // OSC reply (ST)
    try expectNothing("\x1bP1$r0m\x1b\\"); // DECRQSS reply
    try expectNothing("\x1b_Xsomething\x1b\\"); // non-graphics APC
    try expectNothing("\x1bOz");
    // Unknown sequence followed by text: text survives.
    const evs = parseFresh("\x1b[99xok");
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqual(@as(u21, 'o'), evs.items[0].key.code);
}

test "malformed CSI drops prefix and reparses" {
    // ESC [ 1 then Ctrl+C: the Ctrl+C must not be swallowed.
    const evs = parseFresh("\x1b[1\x03");
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u21, 'c'), evs.items[0].key.code);
    try testing.expect(evs.items[0].key.mods.ctrl);
    // Partial CSI at flush is dropped, not typed.
    try expectNothing("\x1b[1;5");
}

test "over-long string is skipped until ST" {
    var p: Parser = .{};
    _ = p.feed("\x1b_G");
    var filler: [1500]u8 = undefined;
    @memset(&filler, 'x');
    _ = p.feed(&filler);
    try testing.expect(p.next(false) == null);
    _ = p.feed("yyy\x1b");
    try testing.expect(p.next(false) == null);
    _ = p.feed("\\a");
    const ev = p.next(false).?;
    try testing.expectEqual(@as(u21, 'a'), ev.key.code);
}

test "over-long CSI split across reads never leaks params as text" {
    var p: Parser = .{};
    var seq: [300]u8 = undefined;
    seq[0] = 0x1b;
    seq[1] = '[';
    @memset(seq[2..299], '1');
    seq[299] = 'u';
    _ = p.feed(seq[0..200]);
    try testing.expect(p.next(false) == null);
    _ = p.feed(seq[200..]);
    _ = p.feed("a");
    const ev = p.next(false).?;
    try testing.expectEqual(@as(u21, 'a'), ev.key.code);
    try testing.expect(p.next(true) == null);
    try testing.expect(p.isIdle());
    // Unterminated and flushed: skipping stops, the next chunk is intact.
    _ = p.feed(seq[0..200]);
    try testing.expect(p.next(true) == null);
    try testing.expect(p.isIdle());
    const evs = parseAll(&p, "b");
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u21, 'b'), evs.items[0].key.code);
}

test "unterminated over-long string does not eat the next chunk's sequence" {
    var big: [2000]u8 = undefined;
    @memset(&big, 'x');
    big[0] = 0x1b;
    big[1] = '_';
    // Chunk ends mid-string, then (second pass) with the ESC that may start ST.
    for (0..2) |pass| {
        if (pass == 1) big[big.len - 1] = 0x1b;
        var w: input.WasmInput = .{};
        w.pushBytes(&big);
        w.pushBytes("\x1b[97u");
        try testing.expectEqual(@as(u21, 'a'), w.readEvent().?.key.code);
        try testing.expect(w.readEvent() == null);
    }
    // ST split across flushed chunks: the `\` is swallowed, not typed.
    var w: input.WasmInput = .{};
    w.pushBytes(&big);
    w.pushBytes("\\b");
    try testing.expectEqual(@as(u21, 'b'), w.readEvent().?.key.code);
    try testing.expect(w.readEvent() == null);
}

// ---------------------------------------------------------------------------
// Replies
// ---------------------------------------------------------------------------

test "replies" {
    const g = try expectOneReply("\x1b_Gi=31;OK\x1b\\");
    try testing.expectEqual(@as(u32, 31), g.kitty_graphics.id);
    try testing.expect(g.kitty_graphics.ok);

    const ge = try expectOneReply("\x1b_Gi=32;ENOENT:No such file\x1b\\");
    try testing.expectEqual(@as(u32, 32), ge.kitty_graphics.id);
    try testing.expect(!ge.kitty_graphics.ok);

    const kk = try expectOneReply("\x1b[?27u");
    try testing.expectEqual(@as(u32, 27), kk.kitty_keyboard);
    const kk0 = try expectOneReply("\x1b[?0u");
    try testing.expectEqual(@as(u32, 0), kk0.kitty_keyboard);

    const d = try expectOneReply("\x1b[?62;22;52c");
    try testing.expect(d == .da1);

    const cs = try expectOneReply("\x1b[6;20;10t");
    try testing.expectEqual(@as(u16, 10), cs.cell_size.w);
    try testing.expectEqual(@as(u16, 20), cs.cell_size.h);

    const ta = try expectOneReply("\x1b[4;800;1200t");
    try testing.expectEqual(@as(u16, 1200), ta.text_area.w);
    try testing.expectEqual(@as(u16, 800), ta.text_area.h);

    const rs = try expectOneReply("\x1b[48;40;120;800;1200t");
    try testing.expectEqual(@as(u16, 1200), rs.text_area.w);
    try testing.expectEqual(@as(u16, 800), rs.text_area.h);

    const rq = try expectOneReply("\x1b[?2026;2$y");
    try testing.expectEqual(@as(u16, 2026), rq.decrqm.mode);
    try testing.expectEqual(@as(u8, 2), rq.decrqm.value);

    // XTVERSION points into the parser, so keep it alive while checking.
    var p: Parser = .{};
    _ = p.feed("\x1bP>|ghostty 1.4.0\x1b\\\x1bP>|kitty(0.40.0)\x1b\\");
    try testing.expectEqualStrings("ghostty 1.4.0", p.next(false).?.reply.xtversion);
    try testing.expectEqualStrings("kitty(0.40.0)", p.next(false).?.reply.xtversion);
    try testing.expect(p.next(true) == null);
}

test "full probe answer stream parses to replies in order" {
    const stream = "\x1b_Gi=31;OK\x1b\\" ++ "\x1b[?0u" ++ "\x1b[6;18;9t" ++ "\x1b[4;720;1080t" ++
        "\x1bP>|ghostty 1.4.0\x1b\\" ++ "\x1b[?2026;2$y" ++ "\x1b[?62;22c";
    const evs = parseFresh(stream);
    try testing.expectEqual(@as(usize, 7), evs.len);
    try testing.expect(evs.items[0].reply == .kitty_graphics);
    try testing.expect(evs.items[1].reply == .kitty_keyboard);
    try testing.expect(evs.items[2].reply == .cell_size);
    try testing.expect(evs.items[3].reply == .text_area);
    try testing.expect(evs.items[4].reply == .xtversion);
    try testing.expect(evs.items[5].reply == .decrqm);
    try testing.expect(evs.items[6].reply == .da1);
}

// ---------------------------------------------------------------------------
// toLegacy mapping table
// ---------------------------------------------------------------------------

fn legacyOf(bytes: []const u8) ?Key {
    const evs = parseFresh(bytes);
    if (evs.len != 1) return null;
    return switch (evs.items[0]) {
        .key => |k| k.toLegacy(),
        .reply => null,
    };
}

fn expectLegacy(bytes: []const u8, expected: ?Key) !void {
    const got = legacyOf(bytes);
    if (expected) |e| {
        const g = got orelse {
            std.debug.print("bytes {any}: expected {any}, got null\n", .{ bytes, e });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualDeep(e, g);
    } else {
        if (got != null) {
            std.debug.print("bytes {any}: expected null, got {any}\n", .{ bytes, got.? });
            return error.TestUnexpectedResult;
        }
    }
}

test "toLegacy reproduces legacy byte semantics" {
    // Every printable ASCII byte maps to itself.
    var b: u8 = 0x20;
    while (b < 0x7f) : (b += 1) try expectLegacy(&[_]u8{b}, .{ .Byte = b });
    // Every C0 control except ESC maps to itself.
    b = 0;
    while (b < 0x20) : (b += 1) {
        if (b == 0x1b) continue;
        try expectLegacy(&[_]u8{b}, .{ .Byte = b });
    }
    try expectLegacy("\x7f", .{ .Byte = 0x7f });
    try expectLegacy("\x1b", .{ .Byte = 0x1b });

    // Arrows and modified arrows.
    try expectLegacy("\x1b[A", .ArrowUp);
    try expectLegacy("\x1b[B", .ArrowDown);
    try expectLegacy("\x1b[C", .ArrowRight);
    try expectLegacy("\x1b[D", .ArrowLeft);
    try expectLegacy("\x1bOA", .ArrowUp);
    try expectLegacy("\x1b[1;2C", .ShiftArrowRight);
    try expectLegacy("\x1b[1;2D", .ShiftArrowLeft);
    try expectLegacy("\x1b[1;3C", .AltArrowRight);
    try expectLegacy("\x1b[1;3D", .AltArrowLeft);
    try expectLegacy("\x1b[1;5A", .CtrlArrowUp);
    try expectLegacy("\x1b[1;5B", .CtrlArrowDown);
    try expectLegacy("\x1b[1;5C", .CtrlArrowRight);
    try expectLegacy("\x1b[1;5D", .CtrlArrowLeft);
    try expectLegacy("\x1b[1;2A", null);
    try expectLegacy("\x1b[1;7C", null);

    // Delete family.
    try expectLegacy("\x1b[3~", .Delete);
    try expectLegacy("\x1b[3;3~", .AltDelete);
    try expectLegacy("\x1b[3;5~", null);
    try expectLegacy("\x1b\x7f", .AltBackspace);
    try expectLegacy("\x1b\x08", .AltBackspace);

    // ESC-prefixed word motions.
    try expectLegacy("\x1bb", .AltArrowLeft);
    try expectLegacy("\x1bB", .AltArrowLeft);
    try expectLegacy("\x1bf", .AltArrowRight);
    try expectLegacy("\x1bF", .AltArrowRight);
    try expectLegacy("\x1bd", .AltDelete);
    try expectLegacy("\x1bD", .AltDelete);
    try expectLegacy("\x1bx", null);

    // Home/End/F-keys/Insert have no legacy form (no more typed "[H").
    try expectLegacy("\x1b[H", null);
    try expectLegacy("\x1b[F", null);
    try expectLegacy("\x1bOP", null);
    try expectLegacy("\x1b[15~", null);
    try expectLegacy("\x1b[2~", null);

    // Kitty-encoded keys map to the same legacy bytes.
    try expectLegacy("\x1b[99;5u", .{ .Byte = 0x03 }); // Ctrl+C
    try expectLegacy("\x1b[112;5u", .{ .Byte = 0x10 }); // Ctrl+P
    try expectLegacy("\x1b[112;6u", .{ .Byte = 0x10 }); // Ctrl+Shift+P
    try expectLegacy("\x1b[13u", .{ .Byte = '\r' });
    try expectLegacy("\x1b[13;2u", .{ .Byte = '\r' });
    try expectLegacy("\x1b[9u", .{ .Byte = '\t' });
    try expectLegacy("\x1b[127u", .{ .Byte = 0x7f });
    try expectLegacy("\x1b[127;3u", .AltBackspace);
    try expectLegacy("\x1b[127;5u", .{ .Byte = 0x08 });
    try expectLegacy("\x1b[27u", .{ .Byte = 0x1b });
    try expectLegacy("\x1b[97;;97u", .{ .Byte = 'a' });
    try expectLegacy("\x1b[97;2;65u", .{ .Byte = 'A' });
    try expectLegacy("\x1b[52:36;2;36u", .{ .Byte = '$' });
    try expectLegacy("\x1b[98;3u", .AltArrowLeft);
    try expectLegacy("\x1b[27;5;99~", .{ .Byte = 0x03 }); // modifyOtherKeys Ctrl+C

    // Releases, modifier-only keys, super chords, non-ASCII → null.
    try expectLegacy("\x1b[97;1:3u", null);
    try expectLegacy("\x1b[57441;2u", null);
    try expectLegacy("\x1b[97;9u", null);
    try expectLegacy("é", null);
    // Repeats still type.
    try expectLegacy("\x1b[97;1:2u", .{ .Byte = 'a' });
}

// ---------------------------------------------------------------------------
// Byte sources
// ---------------------------------------------------------------------------

test "wasm input: chunks parsed at push time, ESC at end of chunk = Escape" {
    var in = input.WasmInput.init();
    in.pushBytes("\x1b");
    in.pushBytes("j");
    try testing.expectEqualDeep(@as(?Key, .{ .Byte = 0x1b }), in.readKey());
    try testing.expectEqualDeep(@as(?Key, .{ .Byte = 'j' }), in.readKey());
    try testing.expect(in.readKey() == null);

    in.pushBytes("\x1b[H\x1b[1;5Cx\x1b[97;1:3u");
    // Home has no legacy form and the release is skipped.
    try testing.expectEqualDeep(@as(?Key, .CtrlArrowRight), in.readKey());
    try testing.expectEqualDeep(@as(?Key, .{ .Byte = 'x' }), in.readKey());
    try testing.expect(in.readKey() == null);

    in.pushBytes("\x1b[H");
    const ev = in.readEvent().?;
    try testing.expectEqual(code.home, ev.key.code);

    // Large paste beyond the parser buffer is fully delivered.
    var big: [9000]u8 = undefined;
    @memset(&big, 'q');
    in.pushBytes(&big);
    var n: usize = 0;
    while (in.readEvent()) |_| n += 1;
    try testing.expectEqual(@as(usize, @min(big.len, @import("core/constants.zig").WEB_EVENT_QUEUE_SIZE)), n);
}

test "native input: injected bytes, backlog first, readKey wrapper" {
    if (builtin.target.cpu.arch == .wasm32) return;
    var in = input.NativeInput.init();
    in.fd = -1; // never touch the real stdin in tests (poll on -1 reports nothing)
    in.pushBytes("ab");
    in.queueEvent(.{ .key = .{ .code = 'z', .text = 'z' } });
    try testing.expectEqual(@as(u21, 'z'), in.readEvent().?.key.code);
    try testing.expectEqualDeep(@as(?Key, .{ .Byte = 'a' }), in.readKey());
    try testing.expectEqualDeep(@as(?Key, .{ .Byte = 'b' }), in.readKey());
    try testing.expect(in.readEvent() == null);
    // Trailing lone ESC resolves to Escape after the (short) wait.
    in.pushBytes("\x1b");
    try testing.expectEqual(code.escape, in.readEvent().?.key.code);
}

// ---------------------------------------------------------------------------
// Caps (pure parts)
// ---------------------------------------------------------------------------

test "caps from env" {
    const c = caps.Caps.fromEnv(.{
        .term = "xterm-ghostty",
        .term_program = "ghostty",
        .tmux = "/tmp/tmux-501/default,1,0",
        .colorterm = "truecolor",
        .snipetype_gfx = "cells",
    }, .{});
    try testing.expect(c.in_tmux);
    try testing.expect(c.truecolor);
    try testing.expectEqual(caps.GfxOverride.cells, c.gfx);
    try testing.expectEqualStrings("ghostty", c.termName());
    try testing.expect(!c.useKittyGraphics());

    const k = caps.Caps.fromEnv(.{ .snipetype_gfx = "cells" }, .{ .gfx = .kitty });
    try testing.expectEqual(caps.GfxOverride.kitty, k.gfx);
    try testing.expect(k.useKittyGraphics());

    var t = caps.Caps.fromEnv(.{ .tmux = "" }, .{});
    try testing.expect(!t.in_tmux);
    t.kitty_graphics = true;
    try testing.expect(t.useKittyGraphics());
    t.in_tmux = true;
    try testing.expect(!t.useKittyGraphics());

    const f = caps.Caps.fallback();
    try testing.expect(!f.kitty_graphics and !f.kitty_keyboard and !f.sync);
    try testing.expectEqual(caps.Media.direct, f.kitty_media);
    try testing.expectEqual(@as(?caps.GfxOverride, .off), caps.GfxOverride.parse("OFF"));
    try testing.expectEqual(@as(?caps.GfxOverride, null), caps.GfxOverride.parse("bogus"));
}

test "probe sequence contains every query and ends with DA1" {
    const s = caps.probe_sequence;
    try testing.expect(std.mem.startsWith(u8, s, "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"));
    try testing.expect(std.mem.endsWith(u8, s, "\x1b[c"));
    for ([_][]const u8{ "\x1b[?u", "\x1b[16t", "\x1b[14t", "\x1b[>0q", "\x1b[?2026$p" }) |q| {
        try testing.expect(std.mem.indexOf(u8, s, q) != null);
    }
}

test "terminal keyboard flag presets" {
    try testing.expectEqual(@as(u8, 1), terminal.keyboard_flags.typing);
    try testing.expectEqual(@as(u8, 27), terminal.keyboard_flags.arcade);
}

test "renderer underline: ansi SGR 4/24 and cell flag" {
    var ar = ansi_renderer.AnsiRenderer.init(testing.allocator, 4, 1);
    defer ar.deinit();
    const r = ar.renderer();
    r.setUseTerminalDefaults(true);
    r.setUnderline(true);
    r.writeByte('x');
    r.setUnderline(false);
    try testing.expectEqualStrings("\x1b[4mx\x1b[24m", ar.output());

    var cr = try cell_renderer.CellRenderer.init(testing.allocator, 3, 1);
    defer cr.deinit();
    const c = cr.renderer();
    c.setBold(true);
    c.setUnderline(true);
    c.write("ab");
    c.resetStyle();
    c.write("c");
    const ab: renderer.CellFlags = @bitCast(cr.cells[1].flags);
    try testing.expect(ab.bold and ab.underline);
    try testing.expectEqual(@as(u8, 0), cr.cells[2].flags);
}
