//! Color types and utilities.
//! Provides RGB values as the single source of truth.
//! ANSI escape sequences are generated on-demand for native terminals.

const std = @import("std");

/// RGB color
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const TRANSPARENT: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const WHITE: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const BLACK: Color = .{ .r = 0, .g = 0, .b = 0 };

    /// Create color from RGB values
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    /// Pack as 32-bit RGBA (for WASM memory transfer)
    pub fn toRgba(self: Color) u32 {
        return (@as(u32, self.r) << 24) |
            (@as(u32, self.g) << 16) |
            (@as(u32, self.b) << 8) |
            0xFF;
    }

    /// Linear blend from `self` (t = 0) to `other` (t = 1); `t` is clamped.
    pub fn mix(self: Color, other: Color, t: f32) Color {
        const k = std.math.clamp(t, 0.0, 1.0);
        return .{
            .r = mixChannel(self.r, other.r, k),
            .g = mixChannel(self.g, other.g, k),
            .b = mixChannel(self.b, other.b, k),
        };
    }

    /// Relative luminance approximation in 0..1 (Rec. 601 weights, no gamma).
    pub fn luma(self: Color) f32 {
        return (0.299 * @as(f32, @floatFromInt(self.r)) +
            0.587 * @as(f32, @floatFromInt(self.g)) +
            0.114 * @as(f32, @floatFromInt(self.b))) / 255.0;
    }

    /// WCAG 2 contrast ratio between two colors (1..21).
    pub fn contrast(self: Color, other: Color) f32 {
        const a = self.relLuminance();
        const b = other.relLuminance();
        return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
    }

    /// WCAG relative luminance (sRGB, gamma-expanded).
    fn relLuminance(self: Color) f32 {
        return 0.2126 * linear(self.r) + 0.7152 * linear(self.g) + 0.0722 * linear(self.b);
    }

    fn linear(c: u8) f32 {
        const v = @as(f32, @floatFromInt(c)) / 255.0;
        return if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }

    fn mixChannel(a: u8, b: u8, t: f32) u8 {
        const fa: f32 = @floatFromInt(a);
        const fb: f32 = @floatFromInt(b);
        return @intFromFloat(@round(fa + (fb - fa) * t));
    }

    /// Write ANSI foreground escape sequence to buffer
    pub fn writeAnsiFg(self: Color, writer: anytype) !void {
        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
    }

    /// Write ANSI background escape sequence to buffer
    pub fn writeAnsiBg(self: Color, writer: anytype) !void {
        try writer.print("\x1b[48;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
    }
};

// ============================================================================
// Standard Palette (commonly used colors)
// ============================================================================

pub const Palette = struct {
    pub const INDIGO = Color.rgb(99, 102, 241);
    pub const GREEN = Color.rgb(34, 197, 94);
    pub const RED = Color.rgb(239, 68, 68);
    pub const YELLOW = Color.rgb(250, 204, 21);
    pub const ORANGE = Color.rgb(251, 146, 60);
    pub const CYAN = Color.rgb(34, 211, 238);
    pub const WHITE = Color.rgb(255, 255, 255);
    pub const DIM = Color.rgb(100, 100, 120);
    pub const DIMMER = Color.rgb(60, 60, 80);
};

test "mix blends and clamps" {
    const a = Color.rgb(0, 100, 200);
    const b = Color.rgb(200, 100, 0);
    try std.testing.expectEqual(Color.rgb(100, 100, 100), a.mix(b, 0.5));
    try std.testing.expectEqual(a, a.mix(b, -1));
    try std.testing.expectEqual(b, a.mix(b, 2));
    try std.testing.expect(Color.WHITE.luma() > 0.99 and Color.BLACK.luma() < 0.01);
}

test "contrast ratio" {
    try std.testing.expectApproxEqAbs(@as(f32, 21), Color.WHITE.contrast(Color.BLACK), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a_gray.contrast(a_gray), 0.001);
}

const a_gray = Color.rgb(128, 128, 128);
