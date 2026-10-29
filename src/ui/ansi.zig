//! ANSI escape constants and the UTF-8 glyphs used by the UI renderers.

// ANSI
pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const UNDERLINE = "\x1b[4m";
pub const REVERSE = "\x1b[7m";
pub const HIDE_CURSOR = "\x1b[?25l";
pub const SHOW_CURSOR = "\x1b[?25h";
pub const CLEAR = "\x1b[2J\x1b[H";
pub const CLEAR_LINE = "\x1b[2K";
pub const SYNC_BEGIN = "\x1b[?2026h";
pub const SYNC_END = "\x1b[?2026l";

// Colors
pub const C_INDIGO = "\x1b[38;2;99;102;241m";
pub const C_GREEN = "\x1b[38;2;34;197;94m";
pub const C_RED = "\x1b[38;2;239;68;68m";
pub const C_YELLOW = "\x1b[38;2;250;204;21m";
pub const C_ORANGE = "\x1b[38;2;251;146;60m";
pub const C_CYAN = "\x1b[38;2;34;211;238m";
pub const C_DIM = "\x1b[38;2;100;100;120m";
pub const C_DIMMER = "\x1b[38;2;60;60;80m";
pub const C_WHITE = "\x1b[38;2;255;255;255m";
pub const C_BG_INDIGO = "\x1b[48;2;99;102;241m";
pub const C_BG_GREEN = "\x1b[48;2;34;197;94m";
pub const C_BG_RED = "\x1b[48;2;50;20;20m";
pub const C_BG_YELLOW = "\x1b[48;2;80;70;20m";
pub const C_BG_VISUAL = "\x1b[48;2;60;60;100m";

// Extended attributes (ghostty, kitty, wezterm, iTerm2; ignored elsewhere)
pub const UNDERLINE_OFF = "\x1b[24m";
/// Curly underline (falls back to a plain underline where unsupported).
pub const UNDERCURL = "\x1b[4:3m";

// ============================================================================
// Glyphs (UTF-8; every glyph below is one terminal column wide)
// ============================================================================

/// Rounded box-drawing set used by cards and overlays.
pub const box = struct {
    pub const tl = "╭";
    pub const tr = "╮";
    pub const bl = "╰";
    pub const br = "╯";
    pub const h = "─";
    pub const v = "│";
    pub const tee_l = "├";
    pub const tee_r = "┤";
    pub const tee_t = "┬";
    pub const tee_b = "┴";
    pub const axis_corner = "└";
};

pub const MIDDOT = "·";
pub const ELLIPSIS = "…";
pub const BULLET = "●";
pub const RING = "○";
pub const CHEVRON = "›";
pub const SPARK = "✦";

/// Bit for the braille dot at (`x` 0..1, `y` 0..3) inside one cell.
pub fn brailleBit(x: usize, y: usize) u8 {
    const bits = [2][4]u8{ .{ 0x01, 0x02, 0x04, 0x40 }, .{ 0x08, 0x10, 0x20, 0x80 } };
    return bits[x & 1][y & 3];
}

/// UTF-8 encoding of the braille pattern U+2800 + `bits`.
pub fn braille(bits: u8) [3]u8 {
    return .{ 0xE2, 0xA0 | (bits >> 6), 0x80 | (bits & 0x3F) };
}

/// Terminal columns taken by `s`, assuming every code point is one column
/// wide (true for ASCII and the glyphs used by this UI).
pub fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

test "braille encoding" {
    const std = @import("std");
    try std.testing.expectEqualStrings("⠀", &braille(0));
    try std.testing.expectEqualStrings("⣿", &braille(0xFF));
    try std.testing.expectEqualStrings("⡀", &braille(brailleBit(0, 3)));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("a✦b"));
}
