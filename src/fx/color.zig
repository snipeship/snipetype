//! Float RGB colors for the pixel effects engine.
//!
//! `Rgb` channels are 0..1 floats in display (sRGB-ish) space. Values above 1
//! are allowed while composing (additive light) and are clamped when a pixel
//! is written. Also hosts the arcade palette and the RGB LED cycle.

const std = @import("std");
const Color = @import("../ui/color.zig").Color;

pub const Rgb = struct {
    r: f32,
    g: f32,
    b: f32,

    pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Rgb = .{ .r = 1, .g = 1, .b = 1 };

    pub fn init(r: f32, g: f32, b: f32) Rgb {
        return .{ .r = r, .g = g, .b = b };
    }

    /// From a 0xRRGGBB literal.
    pub fn hex(v: u24) Rgb {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
        };
    }

    pub fn fromColor(c: Color) Rgb {
        return .{
            .r = @as(f32, @floatFromInt(c.r)) / 255.0,
            .g = @as(f32, @floatFromInt(c.g)) / 255.0,
            .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        };
    }

    pub fn toColor(self: Rgb) Color {
        return .{ .r = to8(self.r), .g = to8(self.g), .b = to8(self.b) };
    }

    pub fn scale(self: Rgb, k: f32) Rgb {
        return .{ .r = self.r * k, .g = self.g * k, .b = self.b * k };
    }

    pub fn add(a: Rgb, b: Rgb) Rgb {
        return .{ .r = a.r + b.r, .g = a.g + b.g, .b = a.b + b.b };
    }

    pub fn mul(a: Rgb, b: Rgb) Rgb {
        return .{ .r = a.r * b.r, .g = a.g * b.g, .b = a.b * b.b };
    }

    /// Linear interpolation a→b by t (unclamped).
    pub fn lerp(a: Rgb, b: Rgb, t: f32) Rgb {
        return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t };
    }

    /// Mix toward white by t.
    pub fn lighten(self: Rgb, t: f32) Rgb {
        return self.lerp(white, t);
    }

    /// Mix toward black by t.
    pub fn darken(self: Rgb, t: f32) Rgb {
        return self.scale(1 - t);
    }

    /// Rec. 709 luma.
    pub fn luma(self: Rgb) f32 {
        return 0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b;
    }

    pub fn clamp01(self: Rgb) Rgb {
        return .{ .r = sat(self.r), .g = sat(self.g), .b = sat(self.b) };
    }
};

pub fn sat(v: f32) f32 {
    return @min(@max(v, 0), 1);
}

/// 0..1 float → 0..255 byte, clamped and rounded.
pub fn to8(v: f32) u8 {
    return @intFromFloat(sat(v) * 255.0 + 0.5);
}

/// HSV → RGB; h wraps (0..1 = full circle), s and v in 0..1.
pub fn hsv(h: f32, s: f32, v: f32) Rgb {
    const hh = (h - @floor(h)) * 6.0;
    const i: u32 = @intFromFloat(@floor(hh));
    const f = hh - @floor(hh);
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const t = v * (1 - s * (1 - f));
    return switch (i % 6) {
        0 => .{ .r = v, .g = t, .b = p },
        1 => .{ .r = q, .g = v, .b = p },
        2 => .{ .r = p, .g = v, .b = t },
        3 => .{ .r = p, .g = q, .b = v },
        4 => .{ .r = t, .g = p, .b = v },
        else => .{ .r = v, .g = p, .b = q },
    };
}

/// HSL → RGB; h wraps, s and l in 0..1 (CSS `hsl()` semantics).
pub fn hsl(h: f32, s: f32, l: f32) Rgb {
    const v = l + s * @min(l, 1 - l);
    const sv: f32 = if (v <= 0) 0 else 2 * (1 - l / v);
    return hsv(h, sv, v);
}

/// The arcade palette (see DESIGN.md "Look & effects").
pub const palette = struct {
    pub const night = Rgb.hex(0x0b0c22);
    pub const ink = Rgb.hex(0xf3eee4);
    pub const coral = Rgb.hex(0xff6b4a);
    pub const coral_deep = Rgb.hex(0xc4442b);
    pub const amber = Rgb.hex(0xffbf5e);
    pub const teal = Rgb.hex(0x5fe0d8);
    pub const panel = Rgb.hex(0x131432);
    pub const cream = Rgb.hex(0xfff4de);
    pub const quick = Rgb.hex(0x7ff3e3);
    pub const tile = Rgb.hex(0xefe6d2);
    pub const glitch_red = Rgb.hex(0xff285a);
    pub const glitch_cyan = Rgb.hex(0x1ee6ff);
    pub const photon = Rgb.init(0.92, 0.74, 0.34);
    pub const ice_deep = Rgb.hex(0x0d2f7a);
    pub const ice = Rgb.hex(0x5fa8ff);
    pub const ice_light = Rgb.hex(0xd8f3ff);
    pub const derez = Rgb.hex(0x35f2ff);
    pub const miss = Rgb.hex(0xff2a3a);

    /// Keycap skins: top / legend / side.
    pub const cap_letter = [3]Rgb{ Rgb.hex(0xece3cf), Rgb.hex(0x25232a), Rgb.hex(0xcfc3a9) };
    pub const cap_modifier = [3]Rgb{ Rgb.hex(0x3d3e45), Rgb.hex(0xefe7d4), Rgb.hex(0x2a2b30) };
    pub const cap_named = [3]Rgb{ Rgb.hex(0xef7458), Rgb.hex(0x1c0b08), Rgb.hex(0xb9533c) };
    pub const cap_arrow = [3]Rgb{ Rgb.hex(0x29aaa0), Rgb.hex(0x04181a), Rgb.hex(0x1d7a73) };
};

/// RGB LED cycle stops (keyboard backdrop).
pub const led_stops = [_]Rgb{
    Rgb.hex(0x1AE6CC),
    Rgb.hex(0x2E6BFF),
    Rgb.hex(0x9442FF),
    Rgb.hex(0xFF339E),
    Rgb.hex(0xFF7542),
};

/// Cycles per second of the LED palette.
pub const led_speed: f32 = 0.09;

/// LED palette at cycle phase `phase` (wraps; 0..1 = all 5 stops).
/// Interpolates with squared channels (i.e. in roughly linear light) and
/// converts back, so midpoints stay saturated instead of going muddy.
pub fn ledAt(phase: f32) Rgb {
    const n: f32 = @floatFromInt(led_stops.len);
    const p = (phase - @floor(phase)) * n;
    const i: usize = @min(@as(usize, @intFromFloat(@floor(p))), led_stops.len - 1);
    const j = (i + 1) % led_stops.len;
    const t = p - @floor(p);
    const a = led_stops[i];
    const b = led_stops[j];
    return .{
        .r = @sqrt(a.r * a.r + (b.r * b.r - a.r * a.r) * t),
        .g = @sqrt(a.g * a.g + (b.g * b.g - a.g * a.g) * t),
        .b = @sqrt(a.b * a.b + (b.b * b.b - a.b * a.b) * t),
    };
}

/// LED palette color at time `seconds` plus a spatial `offset` (in cycles),
/// e.g. `ledCycle(now, key_x * 0.35)` for a wave across the keyboard.
pub fn ledCycle(seconds: f32, offset: f32) Rgb {
    return ledAt(seconds * led_speed + offset);
}

/// Bright accent for a cap hue (glows, particles).
pub fn accent(hue: f32) Rgb {
    return hsl(hue, 0.95, 0.62);
}

/// Pale popup tint for a cap hue.
pub fn popupTint(hue: f32) Rgb {
    return hsl(hue, 0.9, 0.74);
}

test "hex and byte round trip" {
    const c = Rgb.hex(0xff6b4a);
    const b = c.toColor();
    try std.testing.expectEqual(@as(u8, 0xff), b.r);
    try std.testing.expectEqual(@as(u8, 0x6b), b.g);
    try std.testing.expectEqual(@as(u8, 0x4a), b.b);
    try std.testing.expectEqual(@as(u8, 255), to8(3.0));
    try std.testing.expectEqual(@as(u8, 0), to8(-1.0));
}

test "hsv primaries and wrap" {
    const r = hsv(0, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.r, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.g, 1e-5);
    const g = hsv(1.0 / 3.0, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), g.g, 1e-4);
    const w = hsv(1.0 + 2.0 / 3.0, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), w.b, 1e-4);
    const neg = hsv(-1.0 / 3.0, 1, 1); // == 2/3 → blue
    try std.testing.expectApproxEqAbs(@as(f32, 1), neg.b, 1e-4);
}

test "hsl matches css" {
    // hsl(0, 100%, 50%) = red; hsl(x, 0, 0.5) = gray 0.5
    const r = hsl(0, 1, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.r, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.g, 1e-4);
    const gray = hsl(0.3, 0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gray.r, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gray.b, 1e-4);
}

test "led cycle hits stops and wraps" {
    const s0 = ledAt(0);
    try std.testing.expectApproxEqAbs(led_stops[0].g, s0.g, 1e-4);
    const s2 = ledAt(2.0 / 5.0);
    try std.testing.expectApproxEqAbs(led_stops[2].r, s2.r, 1e-4);
    const wrap = ledAt(1.0);
    try std.testing.expectApproxEqAbs(s0.b, wrap.b, 1e-4);
    // midpoint between stop 4 and stop 0 is a real wrap blend
    const mid = ledAt(0.9);
    try std.testing.expect(mid.r > 0.5 and mid.g > 0.5);
}
