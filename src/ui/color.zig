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
