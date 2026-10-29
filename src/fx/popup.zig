//! Score popups drawn with the pixel font: "+240", "paste plain" with a
//! small "+1,440" under it, in five rotating styles (punch, rise, split,
//! glitch, type). Stateless: the scene keeps a list of popups with their
//! age and calls `draw` each frame.

const std = @import("std");
const canvas = @import("canvas.zig");
const color = @import("color.zig");
const font = @import("font.zig");
const rng = @import("rng.zig");

const Surface = canvas.Surface;
const Rgb = color.Rgb;
const sat = canvas.sat;
const pal = color.palette;

pub const Style = enum(u8) {
    /// Big, bold, slammed in from 1.9× with a colored outline and hard shadow.
    punch,
    /// Wide-tracked, drifts upward.
    rise,
    /// Letters drop in alternately from above and below, staggered.
    split,
    /// Stepped x-jitter and skew with red/cyan channel ghosts.
    glitch,
    /// Typewriter reveal with a teal caret.
    type,
};

pub const style_count = @typeInfo(Style).@"enum".field_names.len;

/// Pick the next style, never repeating `prev`.
pub fn nextStyle(prev: ?Style, r: *rng.Rng) Style {
    while (true) {
        const s: Style = @fromBackingInt(@intCast(r.int(style_count)));
        if (prev == null or s != prev.?) return s;
    }
}

/// Popup lifetime for an effect tier (1..3).
pub fn duration(tier: u2) f32 {
    return 0.95 + @as(f32, @floatFromInt(@max(tier, 1) - 1)) * 0.15;
}

/// Font scale for the big popup text on a surface `w` pixels wide
/// (≈ clamp(24, 0.026·W + 8, 46) CSS px at 960 px, scaled to `w`).
pub fn bigScale(w: u32) f32 {
    const fw: f32 = @floatFromInt(w);
    const css = std.math.clamp(0.026 * 960 + 8, 24, 46);
    const px = css * fw / 960.0; // cap height in surface px ≈ 0.7 × font size
    // whole-number scales keep the pixel font crisp
    return @max(@round(px * 0.7 / font.cap_h), 1);
}

pub const Popup = struct {
    style: Style,
    /// Big text ("+240" or a caption like "paste plain").
    text: []const u8,
    /// Small line under it ("+1,440"), may be "".
    sub: []const u8 = "",
    /// Adds a teal "QUICK" tag after the small line.
    quick: bool = false,
    /// Center of the big text (surface px).
    x: f32,
    y: f32,
    /// Seconds since spawn and total lifetime.
    t: f32,
    dur: f32 = 0.95,
    hue: f32 = 0.08,
    intensity: f32 = 0.5,
    /// Font scale of the big text (see `bigScale`).
    scale: f32 = 3,
    seed: u32 = 0,
};

fn easeOutBack(t: f32) f32 {
    const q = sat(t) - 1;
    const c = 1.7;
    return 1 + (c + 1) * q * q * q + c * q * q;
}

fn easeOut(t: f32) f32 {
    const q = 1 - sat(t);
    return 1 - q * q * q;
}

/// Draw one popup at its current age. Does nothing once t ≥ dur.
pub fn draw(s: *Surface, p: Popup) void {
    if (!(p.t >= 0 and p.t < p.dur)) return;
    const k = p.t / p.dur;
    // cream → hue tint by 80% of the lifetime; fade over the last 25%
    const col = pal.cream.lerp(color.popupTint(p.hue), sat(k / 0.8));
    const alpha = 1 - canvas.smoothstep(0.75, 1.0, k);
    const glow_c = color.accent(p.hue);
    const glow = (0.35 + 0.3 * p.intensity) * alpha;
    const base: font.TextOpts = .{ .alpha = alpha, .glow = glow, .glow_color = glow_c, .bold = true };
    var big_h = font.height(p.scale);
    var sub_y = p.y + big_h * 0.5 + p.scale * 1.5;

    switch (p.style) {
        .punch => {
            const e = easeOutBack(p.t / 0.18);
            const sc = p.scale * (1.9 - 0.9 * e);
            var o = base;
            o.italic = 0.22 - 0.08 * e;
            o.outline = glow_c.scale(0.8);
            o.outline_px = @max(sc * 0.45, 1);
            o.shadow = pal.night;
            o.shadow_dx = 0.8;
            o.shadow_dy = 0.8;
            big_h = font.height(sc);
            _ = font.drawTextCentered(s, p.x, p.y - big_h * 0.5, sc, p.text, col, o);
            sub_y = p.y + big_h * 0.5 + p.scale * 1.5;
        },
        .rise => {
            const dy = -easeOut(k) * p.scale * 8;
            var o = base;
            o.bold = false;
            o.spacing = 2;
            _ = font.drawTextCentered(s, p.x, p.y - big_h * 0.5 + dy, p.scale, p.text, col, o);
            sub_y += dy;
        },
        .split => drawSplit(s, p, col, base),
        .glitch => {
            const step: u32 = @intFromFloat(p.t * 18);
            const settle = 1 - sat(k / 0.6);
            const jx = (rng.hash01(p.seed, step) * 2 - 1) * p.scale * 2 * settle;
            var o = base;
            o.italic = (rng.hash01(p.seed +% 1, step) * 2 - 1) * 0.3 * settle;
            o.mono = true;
            const off = p.scale * (0.6 + 0.8 * settle);
            const w = font.measure(p.text, p.scale, o);
            const x0 = p.x - w * 0.5 + jx;
            const y0 = p.y - big_h * 0.5;
            var ghost = o;
            ghost.glow = 0;
            ghost.blend = .add;
            ghost.alpha = 0.7 * alpha;
            _ = font.drawText(s, x0 - off, y0, p.scale, p.text, pal.glitch_red, ghost);
            _ = font.drawText(s, x0 + off, y0, p.scale, p.text, pal.glitch_cyan, ghost);
            _ = font.drawText(s, x0, y0, p.scale, p.text, col, o);
        },
        .type => {
            const n = std.unicode.utf8CountCodepoints(p.text) catch p.text.len;
            const reveal = sat(k / 0.42);
            const shown: usize = @intFromFloat(@ceil(reveal * @as(f32, @floatFromInt(n))));
            var o = base;
            o.mono = true;
            const full_w = font.measure(p.text, p.scale, o);
            const x0 = p.x - full_w * 0.5;
            const y0 = p.y - big_h * 0.5;
            o.max_chars = shown;
            const w = font.drawText(s, x0, y0, p.scale, p.text, col, o);
            const blink = reveal < 1 or @mod(p.t * 3, 1) < 0.5;
            if (blink) canvas.fillRect(s, x0 + w + p.scale, y0 - p.scale * 0.5, @max(p.scale * 0.8, 1), big_h + p.scale, pal.quick, alpha, .over);
        },
    }

    // small line
    if (p.sub.len > 0 or p.quick) {
        const ss = @max(@round(p.scale * 0.42), 1);
        const so: font.TextOpts = .{ .alpha = alpha * sat(k * 6), .shadow = pal.night, .shadow_alpha = 0.7 };
        const quick_txt = "QUICK";
        const gap: f32 = if (p.sub.len > 0 and p.quick) ss * 4 else 0;
        const w1 = if (p.sub.len > 0) font.measure(p.sub, ss, so) else 0;
        const w2 = if (p.quick) font.measure(quick_txt, ss, so) else 0;
        var x = p.x - (w1 + gap + w2) * 0.5;
        if (p.sub.len > 0) x += font.drawText(s, x, sub_y, ss, p.sub, pal.ink, so) + gap;
        if (p.quick) _ = font.drawText(s, x, sub_y, ss, quick_txt, pal.quick, so);
    }
}

fn drawSplit(s: *Surface, p: Popup, col: Rgb, base: font.TextOpts) void {
    const total = font.measure(p.text, p.scale, base);
    var x = p.x - total * 0.5;
    const y0 = p.y - font.height(p.scale) * 0.5;
    var it = (std.unicode.Utf8View.init(p.text) catch return).iterator();
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (it.nextCodepoint()) |cp| : (i += 1) {
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        const ch = buf[0..len];
        const local = (p.t - @as(f32, @floatFromInt(i)) * 0.025) / 0.22;
        const e = easeOutBack(local);
        const from: f32 = if (i % 2 == 0) -1 else 1;
        const dy = from * (1 - e) * p.scale * 6;
        var o = base;
        o.alpha = base.alpha * sat(local * 3);
        const w = font.measure(ch, p.scale, o);
        if (local > 0) _ = font.drawText(s, x, y0 + dy, p.scale, ch, col, o);
        x += w + o.spacing * p.scale;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "nextStyle never repeats" {
    var r = rng.Rng.init(1);
    var prev: ?Style = null;
    for (0..200) |_| {
        const st = nextStyle(prev, &r);
        if (prev) |pv| try testing.expect(st != pv);
        prev = st;
    }
}

test "duration and scale" {
    try testing.expectApproxEqAbs(@as(f32, 0.95), duration(1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.25), duration(3), 1e-6);
    try testing.expect(bigScale(960) > bigScale(480));
    try testing.expect(bigScale(80) >= 1);
}

test "every style draws during its life and nothing after" {
    var s = try Surface.init(testing.allocator, 60, 17, 240, 135);
    defer s.deinit();
    inline for (comptime std.meta.tags(Style)) |st| {
        for ([_]f32{ 0, 0.05, 0.3, 0.6, 0.94 }) |t| {
            canvas.clear(&s, Rgb.black);
            draw(&s, .{ .style = st, .text = "+1,440", .sub = "paste plain", .quick = true, .x = 120, .y = 60, .t = t, .scale = 2, .hue = 0.5, .intensity = 0.7 });
            var lit = false;
            for (s.pixels) |px| lit = lit or px.r > 40;
            if (t > 0.04 and t < 0.7) try testing.expect(lit);
        }
        canvas.clear(&s, Rgb.black);
        draw(&s, .{ .style = st, .text = "x", .x = 10, .y = 10, .t = 2, .dur = 1 });
        for (s.pixels) |px| try testing.expectEqual(@as(u8, 0), px.r);
    }
}
