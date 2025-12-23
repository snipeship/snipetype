//! Theme definitions using RGB colors.
//! Colors are the single source of truth - ANSI codes are generated on-demand.

const std = @import("std");
const Color = @import("color.zig").Color;

pub const ThemeId = enum(u8) {
    system = 0,
    one_dark = 1,
    one_light = 2,
    dracula = 3,
    nord = 4,
    gruvbox_dark = 5,
    solarized_dark = 6,
};

pub const Theme = struct {
    name: []const u8,

    // Base colors
    bg: Color,
    fg: Color,

    // Semantic colors
    accent: Color,
    success: Color,
    danger: Color,
    warning: Color,
    extra: Color,
    info: Color,

    // Text emphasis
    dim: Color,
    dimmer: Color,

    // Cursor
    cursor_bg: Color,
    cursor_insert_bg: Color,
    cursor_fg: Color,

    // Special
    error_bg: Color,
    visual_bg: Color,
    visual_fg: Color,
    border: Color,
};

pub const ThemeOption = struct {
    id: ThemeId,
    label: []const u8,
};

const OPTIONS = [_]ThemeOption{
    .{ .id = .system, .label = "System" },
    .{ .id = .one_dark, .label = "ONE Dark" },
    .{ .id = .one_light, .label = "ONE Light" },
    .{ .id = .dracula, .label = "Dracula" },
    .{ .id = .nord, .label = "Nord" },
    .{ .id = .gruvbox_dark, .label = "Gruvbox Dark" },
    .{ .id = .solarized_dark, .label = "Solarized Dark" },
};

pub fn options() []const ThemeOption {
    return &OPTIONS;
}

pub fn resolve(id: ThemeId) *const Theme {
    return switch (id) {
        .system => if (systemPrefersLight()) &THEMES.one_light else &THEMES.one_dark,
        .one_dark => &THEMES.one_dark,
        .one_light => &THEMES.one_light,
        .dracula => &THEMES.dracula,
        .nord => &THEMES.nord,
        .gruvbox_dark => &THEMES.gruvbox_dark,
        .solarized_dark => &THEMES.solarized_dark,
    };
}

fn systemPrefersLight() bool {
    const builtin = @import("builtin");

    if (comptime builtin.cpu.arch == .wasm32) {
        return js_system_prefers_light();
    }

    // Native: check COLORFGBG environment variable
    const raw = std.posix.getenv("COLORFGBG") orelse return false;
    const value = std.mem.sliceTo(raw, 0);

    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, value, ';');
    while (it.next()) |part| last = part;
    const last_part = last orelse return false;

    const bg_val = std.fmt.parseInt(u8, last_part, 10) catch return false;
    return bg_val >= 7;
}

extern "env" fn js_system_prefers_light() bool;

// ============================================================================
// Theme Definitions
// ============================================================================

pub const THEMES = struct {
    pub const one_dark = Theme{
        .name = "ONE Dark",
        .bg = Color.rgb(40, 44, 52),
        .fg = Color.rgb(171, 178, 191),
        .accent = Color.rgb(99, 102, 241),
        .success = Color.rgb(34, 197, 94),
        .danger = Color.rgb(239, 68, 68),
        .warning = Color.rgb(250, 204, 21),
        .extra = Color.rgb(251, 146, 60),
        .info = Color.rgb(34, 211, 238),
        .dim = Color.rgb(100, 100, 120),
        .dimmer = Color.rgb(60, 60, 80),
        .cursor_bg = Color.rgb(99, 102, 241),
        .cursor_insert_bg = Color.rgb(34, 197, 94),
        .cursor_fg = Color.rgb(255, 255, 255),
        .error_bg = Color.rgb(50, 20, 20),
        .visual_bg = Color.rgb(60, 60, 100),
        .visual_fg = Color.rgb(255, 255, 255),
        .border = Color.rgb(60, 60, 80),
    };

    pub const one_light = Theme{
        .name = "ONE Light",
        .bg = Color.rgb(250, 250, 250),
        .fg = Color.rgb(15, 23, 42),
        .accent = Color.rgb(79, 70, 229),
        .success = Color.rgb(22, 163, 74),
        .danger = Color.rgb(220, 38, 38),
        .warning = Color.rgb(161, 98, 7),
        .extra = Color.rgb(234, 88, 12),
        .info = Color.rgb(8, 145, 178),
        .dim = Color.rgb(71, 85, 105),
        .dimmer = Color.rgb(148, 163, 184),
        .cursor_bg = Color.rgb(79, 70, 229),
        .cursor_insert_bg = Color.rgb(22, 163, 74),
        .cursor_fg = Color.rgb(255, 255, 255),
        .error_bg = Color.rgb(254, 226, 226),
        .visual_bg = Color.rgb(224, 231, 255),
        .visual_fg = Color.rgb(15, 23, 42),
        .border = Color.rgb(148, 163, 184),
    };

    pub const dracula = Theme{
        .name = "Dracula",
        .bg = Color.rgb(40, 42, 54),
        .fg = Color.rgb(248, 248, 242),
        .accent = Color.rgb(189, 147, 249),
        .success = Color.rgb(80, 250, 123),
        .danger = Color.rgb(255, 85, 85),
        .warning = Color.rgb(241, 250, 140),
        .extra = Color.rgb(255, 184, 108),
        .info = Color.rgb(139, 233, 253),
        .dim = Color.rgb(98, 114, 164),
        .dimmer = Color.rgb(68, 71, 90),
        .cursor_bg = Color.rgb(189, 147, 249),
        .cursor_insert_bg = Color.rgb(80, 250, 123),
        .cursor_fg = Color.rgb(40, 42, 54),
        .error_bg = Color.rgb(68, 71, 90),
        .visual_bg = Color.rgb(68, 71, 90),
        .visual_fg = Color.rgb(248, 248, 242),
        .border = Color.rgb(98, 114, 164),
    };

    pub const nord = Theme{
        .name = "Nord",
        .bg = Color.rgb(46, 52, 64),
        .fg = Color.rgb(236, 239, 244),
        .accent = Color.rgb(129, 161, 193),
        .success = Color.rgb(163, 190, 140),
        .danger = Color.rgb(191, 97, 106),
        .warning = Color.rgb(235, 203, 139),
        .extra = Color.rgb(208, 135, 112),
        .info = Color.rgb(136, 192, 208),
        .dim = Color.rgb(76, 86, 106),
        .dimmer = Color.rgb(59, 66, 82),
        .cursor_bg = Color.rgb(129, 161, 193),
        .cursor_insert_bg = Color.rgb(163, 190, 140),
        .cursor_fg = Color.rgb(46, 52, 64),
        .error_bg = Color.rgb(59, 66, 82),
        .visual_bg = Color.rgb(59, 66, 82),
        .visual_fg = Color.rgb(236, 239, 244),
        .border = Color.rgb(76, 86, 106),
    };

    pub const gruvbox_dark = Theme{
        .name = "Gruvbox Dark",
        .bg = Color.rgb(40, 40, 40),
        .fg = Color.rgb(235, 219, 178),
        .accent = Color.rgb(250, 189, 47),
        .success = Color.rgb(152, 151, 26),
        .danger = Color.rgb(204, 36, 29),
        .warning = Color.rgb(215, 153, 33),
        .extra = Color.rgb(254, 128, 25),
        .info = Color.rgb(131, 165, 152),
        .dim = Color.rgb(146, 131, 116),
        .dimmer = Color.rgb(102, 92, 84),
        .cursor_bg = Color.rgb(102, 92, 84),
        .cursor_insert_bg = Color.rgb(152, 151, 26),
        .cursor_fg = Color.rgb(251, 241, 199),
        .error_bg = Color.rgb(60, 56, 54),
        .visual_bg = Color.rgb(80, 73, 69),
        .visual_fg = Color.rgb(251, 241, 199),
        .border = Color.rgb(146, 131, 116),
    };

    pub const solarized_dark = Theme{
        .name = "Solarized Dark",
        .bg = Color.rgb(0, 43, 54),
        .fg = Color.rgb(131, 148, 150),
        .accent = Color.rgb(38, 139, 210),
        .success = Color.rgb(133, 153, 0),
        .danger = Color.rgb(220, 50, 47),
        .warning = Color.rgb(181, 137, 0),
        .extra = Color.rgb(203, 75, 22),
        .info = Color.rgb(42, 161, 152),
        .dim = Color.rgb(88, 110, 117),
        .dimmer = Color.rgb(101, 123, 131),
        .cursor_bg = Color.rgb(38, 139, 210),
        .cursor_insert_bg = Color.rgb(133, 153, 0),
        .cursor_fg = Color.rgb(0, 43, 54),
        .error_bg = Color.rgb(7, 54, 66),
        .visual_bg = Color.rgb(7, 54, 66),
        .visual_fg = Color.rgb(131, 148, 150),
        .border = Color.rgb(88, 110, 117),
    };
};
