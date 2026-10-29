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
    serika_dark = 7,
    catppuccin_mocha = 8,
    tokyo_night = 9,
    rose_pine = 10,
    everforest = 11,
    gruvbox_light = 12,
};

/// Stable kebab-case name used in config files and URLs ("one-dark").
pub fn slug(id: ThemeId) []const u8 {
    return switch (id) {
        inline else => |tag| comptime kebab(@tagName(tag)),
    };
}

/// Inverse of `slug` (also accepts the snake_case tag name).
pub fn fromSlug(s: []const u8) ?ThemeId {
    inline for (comptime std.meta.tags(ThemeId)) |tag| {
        if (std.mem.eql(u8, s, comptime kebab(@tagName(tag))) or std.mem.eql(u8, s, @tagName(tag))) return tag;
    }
    return null;
}

fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
        const final = out;
        return &final;
    }
}

pub const Theme = struct {
    name: []const u8,

    /// When true, use terminal's native colors instead of explicit RGB.
    /// This allows user's terminal theme (transparency, custom bg) to show through.
    use_terminal_defaults: bool = false,

    // Base colors (ignored when use_terminal_defaults is true for native)
    bg: Color,
    fg: Color,

    // Semantic colors
    accent: Color,
    success: Color,
    /// Mistyped letters (text color only; no background).
    danger: Color,
    warning: Color,
    /// Secondary highlight (orange-ish): timer warnings, settings values.
    extra: Color,
    info: Color,
    /// Extra letters typed past the end of a word: a darker `danger`.
    error_extra: Color,

    // Text emphasis
    /// Untyped text and secondary labels (readable on `bg`).
    dim: Color,
    dimmer: Color,

    // Cursor
    cursor_bg: Color,
    cursor_insert_bg: Color,
    cursor_fg: Color,
    /// Text on `cursor_insert_bg` (the vim insert/replace cursor cell):
    /// dark on the light green most themes use (WCAG ≥ 4.5, tested).
    cursor_insert_fg: Color,

    // Special
    /// Only behind the caret when it sits on a mistake.
    error_bg: Color,
    visual_bg: Color,
    visual_fg: Color,
    border: Color,

    /// Pace caret (typing view): a muted accent, underlined.
    pace: Color,

    // Syntax colours for untyped code (code mode, vim ghost text, drill
    // panes). Each is `dim` tinted toward the theme's own hue for the class
    // (45%), so untyped code stays muted and typed text (`fg`) still stands
    // out; comments sit between `dim` and `dimmer`.
    syn_keyword: Color,
    syn_string: Color,
    syn_comment: Color,
    syn_number: Color,
    syn_type: Color,
    syn_punct: Color,

    /// `bg` nudged toward `fg` by `amount`: a subtle panel or highlight
    /// surface. Null for themes that keep the terminal's own background,
    /// whose color is unknown.
    pub fn surface(self: *const Theme, amount: f32) ?Color {
        if (self.use_terminal_defaults) return null;
        return self.bg.mix(self.fg, amount);
    }

    /// Typed-correct text: `fg`, or null (the terminal's own foreground)
    /// for themes that keep the terminal's colors.
    pub fn text(self: *const Theme) ?Color {
        return if (self.use_terminal_defaults) null else self.fg;
    }

    /// Readable secondary text (list items, key hints): `fg` faded toward
    /// `bg`; a neutral gray for themes that keep the terminal's colors.
    pub fn muted(self: *const Theme) Color {
        if (self.use_terminal_defaults) return Color.rgb(150, 150, 150);
        return self.fg.mix(self.bg, 0.4);
    }
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
    .{ .id = .serika_dark, .label = "Serika Dark" },
    .{ .id = .catppuccin_mocha, .label = "Catppuccin Mocha" },
    .{ .id = .tokyo_night, .label = "Tokyo Night" },
    .{ .id = .rose_pine, .label = "Rose Pine" },
    .{ .id = .everforest, .label = "Everforest" },
    .{ .id = .gruvbox_light, .label = "Gruvbox Light" },
};

pub fn options() []const ThemeOption {
    return &OPTIONS;
}

pub fn resolve(id: ThemeId) *const Theme {
    return switch (id) {
        inline else => |tag| &@field(THEMES, @tagName(tag)),
    };
}

/// Native callers pass the value of the COLORFGBG environment variable
/// (Zig 0.16 removed `std.posix.getenv`; read it from
/// `std.process.Init.environ_map.get("COLORFGBG")` in `main`).
fn systemPrefersLight(colorfgbg: ?[]const u8) bool {
    const builtin = @import("builtin");

    if (comptime builtin.target.cpu.arch == .wasm32) {
        return js_system_prefers_light();
    }

    // Native: check COLORFGBG environment variable
    const value = colorfgbg orelse return false;

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

// Semantics shared by every theme (Monkeytype-style, calm): typed-correct
// text is `fg`, untyped text is `dim`, mistakes are `danger` text with no
// background, extra letters are the darker `error_extra`, and the caret is
// `accent`. `dim` must stay readable on `bg` (tested below).
pub const THEMES = struct {
    /// System theme: uses terminal's native colors for bg/fg.
    /// Other colors use sensible defaults that work on most terminals.
    pub const system = Theme{
        .name = "System",
        .use_terminal_defaults = true,
        // These are fallbacks - native terminal won't use bg/fg directly
        .bg = Color.rgb(0, 0, 0),
        .fg = Color.rgb(255, 255, 255),
        // Use standard ANSI-ish colors that work well on most terminals
        .accent = Color.rgb(99, 102, 241), // indigo
        .success = Color.rgb(34, 197, 94), // green
        .danger = Color.rgb(239, 68, 68), // red
        .warning = Color.rgb(250, 204, 21), // yellow
        .extra = Color.rgb(251, 146, 60), // orange
        .info = Color.rgb(34, 211, 238), // cyan
        .error_extra = Color.rgb(160, 50, 50), // dark red
        .dim = Color.rgb(128, 128, 128), // gray
        .dimmer = Color.rgb(96, 96, 96), // darker gray
        .cursor_bg = Color.rgb(99, 102, 241),
        .cursor_insert_bg = Color.rgb(34, 197, 94),
        .cursor_fg = Color.rgb(255, 255, 255),
        .cursor_insert_fg = Color.rgb(0, 0, 0),
        .error_bg = Color.rgb(60, 20, 20),
        .visual_bg = Color.rgb(60, 60, 100),
        .visual_fg = Color.rgb(255, 255, 255),
        .border = Color.rgb(96, 96, 96),
        .pace = Color.rgb(108, 110, 207),
        .syn_keyword = Color.rgb(160, 124, 170),
        .syn_string = Color.rgb(139, 158, 125),
        .syn_comment = Color.rgb(118, 118, 118),
        .syn_number = Color.rgb(164, 140, 116),
        .syn_type = Color.rgb(109, 152, 158),
        .syn_punct = Color.rgb(147, 147, 147),
    };

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
        .error_extra = Color.rgb(159, 58, 62),
        .dim = Color.rgb(107, 115, 133),
        .dimmer = Color.rgb(74, 80, 96),
        .cursor_bg = Color.rgb(99, 102, 241),
        .cursor_insert_bg = Color.rgb(34, 197, 94),
        .cursor_fg = Color.rgb(255, 255, 255),
        .cursor_insert_fg = Color.rgb(40, 44, 52),
        .error_bg = Color.rgb(80, 36, 40),
        .visual_bg = Color.rgb(60, 60, 100),
        .visual_fg = Color.rgb(255, 255, 255),
        .border = Color.rgb(74, 80, 96),
        .pace = Color.rgb(101, 106, 209),
        .syn_keyword = Color.rgb(148, 117, 173),
        .syn_string = Color.rgb(127, 151, 128),
        .syn_comment = Color.rgb(97, 104, 122),
        .syn_number = Color.rgb(153, 133, 119),
        .syn_type = Color.rgb(162, 150, 128),
        .syn_punct = Color.rgb(117, 124, 142),
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
        .error_extra = Color.rgb(140, 28, 28),
        .dim = Color.rgb(120, 131, 150),
        .dimmer = Color.rgb(170, 178, 192),
        .cursor_bg = Color.rgb(79, 70, 229),
        .cursor_insert_bg = Color.rgb(22, 163, 74),
        .cursor_fg = Color.rgb(255, 255, 255),
        .cursor_insert_fg = Color.rgb(15, 23, 42),
        .error_bg = Color.rgb(254, 226, 226),
        .visual_bg = Color.rgb(224, 231, 255),
        .visual_fg = Color.rgb(15, 23, 42),
        .border = Color.rgb(170, 178, 192),
        .pace = Color.rgb(91, 88, 205),
        .syn_keyword = Color.rgb(141, 89, 156),
        .syn_string = Color.rgb(102, 144, 118),
        .syn_comment = Color.rgb(135, 145, 163),
        .syn_number = Color.rgb(134, 119, 83),
        .syn_type = Color.rgb(153, 131, 83),
        .syn_punct = Color.rgb(104, 115, 134),
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
        .error_extra = Color.rgb(170, 60, 70),
        .dim = Color.rgb(98, 114, 164),
        .dimmer = Color.rgb(68, 71, 90),
        .cursor_bg = Color.rgb(189, 147, 249),
        .cursor_insert_bg = Color.rgb(80, 250, 123),
        .cursor_fg = Color.rgb(40, 42, 54),
        .cursor_insert_fg = Color.rgb(40, 42, 54),
        .error_bg = Color.rgb(90, 45, 58),
        .visual_bg = Color.rgb(68, 71, 90),
        .visual_fg = Color.rgb(248, 248, 242),
        .border = Color.rgb(98, 114, 164),
        .pace = Color.rgb(162, 137, 224),
        .syn_keyword = Color.rgb(169, 117, 179),
        .syn_string = Color.rgb(162, 175, 153),
        .syn_comment = Color.rgb(89, 101, 142),
        .syn_number = Color.rgb(139, 129, 202),
        .syn_type = Color.rgb(116, 168, 204),
        .syn_punct = Color.rgb(120, 134, 176),
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
        .error_extra = Color.rgb(140, 81, 91),
        .dim = Color.rgb(110, 121, 143),
        .dimmer = Color.rgb(80, 90, 110),
        .cursor_bg = Color.rgb(129, 161, 193),
        .cursor_insert_bg = Color.rgb(163, 190, 140),
        .cursor_fg = Color.rgb(46, 52, 64),
        .cursor_insert_fg = Color.rgb(46, 52, 64),
        .error_bg = Color.rgb(78, 60, 72),
        .visual_bg = Color.rgb(67, 76, 94),
        .visual_fg = Color.rgb(236, 239, 244),
        .border = Color.rgb(76, 86, 106),
        .pace = Color.rgb(123, 149, 178),
        .syn_keyword = Color.rgb(119, 139, 166),
        .syn_string = Color.rgb(134, 152, 142),
        .syn_comment = Color.rgb(101, 112, 133),
        .syn_number = Color.rgb(142, 130, 156),
        .syn_type = Color.rgb(125, 151, 163),
        .syn_punct = Color.rgb(129, 139, 158),
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
        .error_extra = Color.rgb(170, 40, 34),
        .dim = Color.rgb(146, 131, 116),
        .dimmer = Color.rgb(102, 92, 84),
        .cursor_bg = Color.rgb(102, 92, 84),
        .cursor_insert_bg = Color.rgb(152, 151, 26),
        .cursor_fg = Color.rgb(251, 241, 199),
        .cursor_insert_fg = Color.rgb(40, 40, 40),
        .error_bg = Color.rgb(80, 40, 34),
        .visual_bg = Color.rgb(80, 73, 69),
        .visual_fg = Color.rgb(251, 241, 199),
        .border = Color.rgb(102, 92, 84),
        .pace = Color.rgb(219, 172, 68),
        .syn_keyword = Color.rgb(193, 105, 87),
        .syn_string = Color.rgb(163, 156, 81),
        .syn_comment = Color.rgb(133, 119, 106),
        .syn_number = Color.rgb(175, 132, 134),
        .syn_type = Color.rgb(193, 157, 85),
        .syn_punct = Color.rgb(159, 144, 125),
    };

    pub const solarized_dark = Theme{
        .name = "Solarized Dark",
        .bg = Color.rgb(0, 43, 54),
        .fg = Color.rgb(147, 161, 161),
        .accent = Color.rgb(38, 139, 210),
        .success = Color.rgb(133, 153, 0),
        .danger = Color.rgb(220, 50, 47),
        .warning = Color.rgb(181, 137, 0),
        .extra = Color.rgb(203, 75, 22),
        .info = Color.rgb(42, 161, 152),
        .error_extra = Color.rgb(154, 48, 49),
        .dim = Color.rgb(88, 110, 117),
        .dimmer = Color.rgb(55, 85, 95),
        .cursor_bg = Color.rgb(38, 139, 210),
        .cursor_insert_bg = Color.rgb(133, 153, 0),
        .cursor_fg = Color.rgb(0, 43, 54),
        .cursor_insert_fg = Color.rgb(0, 43, 54),
        .error_bg = Color.rgb(60, 40, 45),
        .visual_bg = Color.rgb(7, 54, 66),
        .visual_fg = Color.rgb(147, 161, 161),
        .border = Color.rgb(55, 85, 95),
        .pace = Color.rgb(53, 130, 182),
        .syn_keyword = Color.rgb(108, 129, 64),
        .syn_string = Color.rgb(67, 133, 133),
        .syn_comment = Color.rgb(78, 102, 110),
        .syn_number = Color.rgb(143, 85, 123),
        .syn_type = Color.rgb(130, 122, 64),
        .syn_punct = Color.rgb(97, 118, 124),
    };

    /// Monkeytype's default: main #e2b714, sub #646669, text #d1d0c5,
    /// error #ca4754, error-extra #7e2a33 (sub and error-extra nudged up
    /// for terminals: #7e2a33 is 1.3:1 on the background).
    pub const serika_dark = Theme{
        .name = "Serika Dark",
        .bg = Color.rgb(0x32, 0x34, 0x37),
        .fg = Color.rgb(0xd1, 0xd0, 0xc5),
        .accent = Color.rgb(0xe2, 0xb7, 0x14),
        .success = Color.rgb(0x8d, 0xb1, 0x4b),
        .danger = Color.rgb(0xca, 0x47, 0x54),
        .warning = Color.rgb(0xe2, 0xb7, 0x14),
        .extra = Color.rgb(0xd9, 0x82, 0x2b),
        .info = Color.rgb(0x64, 0xb5, 0xc8),
        .error_extra = Color.rgb(0xa4, 0x42, 0x4d),
        .dim = Color.rgb(0x6c, 0x6e, 0x71),
        .dimmer = Color.rgb(0x4e, 0x50, 0x54),
        .cursor_bg = Color.rgb(0xe2, 0xb7, 0x14),
        .cursor_insert_bg = Color.rgb(0x8d, 0xb1, 0x4b),
        .cursor_fg = Color.rgb(0x32, 0x34, 0x37),
        .cursor_insert_fg = Color.rgb(0x32, 0x34, 0x37),
        .error_bg = Color.rgb(0x5a, 0x33, 0x39),
        .visual_bg = Color.rgb(0x48, 0x4a, 0x4e),
        .visual_fg = Color.rgb(0xd1, 0xd0, 0xc5),
        .border = Color.rgb(0x4e, 0x50, 0x54),
        .pace = Color.rgb(0xbf, 0xa1, 0x30),
        .syn_keyword = Color.rgb(0xa1, 0x8f, 0x47),
        .syn_string = Color.rgb(0x7b, 0x8c, 0x60),
        .syn_comment = Color.rgb(0x63, 0x65, 0x68),
        .syn_number = Color.rgb(0x9d, 0x77, 0x52),
        .syn_type = Color.rgb(0x68, 0x8e, 0x98),
        .syn_punct = Color.rgb(0x7b, 0x7d, 0x7e),
    };

    /// Catppuccin Mocha: base, text, mauve, green, red, maroon, yellow,
    /// peach, sky, overlay0, surface2, rosewater cursor, surface1 visual.
    pub const catppuccin_mocha = Theme{
        .name = "Catppuccin Mocha",
        .bg = Color.rgb(0x1e, 0x1e, 0x2e),
        .fg = Color.rgb(0xcd, 0xd6, 0xf4),
        .accent = Color.rgb(0xcb, 0xa6, 0xf7),
        .success = Color.rgb(0xa6, 0xe3, 0xa1),
        .danger = Color.rgb(0xf3, 0x8b, 0xa8),
        .warning = Color.rgb(0xf9, 0xe2, 0xaf),
        .extra = Color.rgb(0xfa, 0xb3, 0x87),
        .info = Color.rgb(0x89, 0xdc, 0xeb),
        .error_extra = Color.rgb(0xa8, 0x5f, 0x77),
        .dim = Color.rgb(0x6c, 0x70, 0x86),
        .dimmer = Color.rgb(0x58, 0x5b, 0x70),
        .cursor_bg = Color.rgb(0xf5, 0xe0, 0xdc),
        .cursor_insert_bg = Color.rgb(0xa6, 0xe3, 0xa1),
        .cursor_fg = Color.rgb(0x1e, 0x1e, 0x2e),
        .cursor_insert_fg = Color.rgb(0x1e, 0x1e, 0x2e),
        .error_bg = Color.rgb(0x4a, 0x31, 0x45),
        .visual_bg = Color.rgb(0x45, 0x47, 0x5a),
        .visual_fg = Color.rgb(0xcd, 0xd6, 0xf4),
        .border = Color.rgb(0x45, 0x47, 0x5a),
        .pace = Color.rgb(0xae, 0x96, 0xd5),
        .syn_keyword = Color.rgb(0x97, 0x88, 0xb9),
        .syn_string = Color.rgb(0x86, 0xa4, 0x92),
        .syn_comment = Color.rgb(0x66, 0x6a, 0x7f),
        .syn_number = Color.rgb(0xac, 0x8e, 0x86),
        .syn_type = Color.rgb(0xab, 0xa3, 0x98),
        .syn_punct = Color.rgb(0x7b, 0x7f, 0x96),
    };

    /// Tokyo Night ("night"): bg, fg, blue, green, red, git.delete,
    /// yellow, orange, cyan, comment, terminal_black, bg_visual.
    pub const tokyo_night = Theme{
        .name = "Tokyo Night",
        .bg = Color.rgb(0x1a, 0x1b, 0x26),
        .fg = Color.rgb(0xc0, 0xca, 0xf5),
        .accent = Color.rgb(0x7a, 0xa2, 0xf7),
        .success = Color.rgb(0x9e, 0xce, 0x6a),
        .danger = Color.rgb(0xf7, 0x76, 0x8e),
        .warning = Color.rgb(0xe0, 0xaf, 0x68),
        .extra = Color.rgb(0xff, 0x9e, 0x64),
        .info = Color.rgb(0x7d, 0xcf, 0xff),
        .error_extra = Color.rgb(0x91, 0x4c, 0x54),
        .dim = Color.rgb(0x56, 0x5f, 0x89),
        .dimmer = Color.rgb(0x41, 0x48, 0x68),
        .cursor_bg = Color.rgb(0x7a, 0xa2, 0xf7),
        .cursor_insert_bg = Color.rgb(0x9e, 0xce, 0x6a),
        .cursor_fg = Color.rgb(0x1a, 0x1b, 0x26),
        .cursor_insert_fg = Color.rgb(0x1a, 0x1b, 0x26),
        .error_bg = Color.rgb(0x45, 0x2a, 0x3a),
        .visual_bg = Color.rgb(0x28, 0x34, 0x57),
        .visual_fg = Color.rgb(0xc0, 0xca, 0xf5),
        .border = Color.rgb(0x3b, 0x42, 0x61),
        .pace = Color.rgb(0x6f, 0x8e, 0xd6),
        .syn_keyword = Color.rgb(0x83, 0x7a, 0xba),
        .syn_string = Color.rgb(0x76, 0x91, 0x7b),
        .syn_comment = Color.rgb(0x50, 0x58, 0x7f),
        .syn_number = Color.rgb(0xa2, 0x7b, 0x78),
        .syn_type = Color.rgb(0x42, 0x8c, 0xaf),
        .syn_punct = Color.rgb(0x66, 0x6f, 0x99),
    };

    /// Rosé Pine (main): base, text, iris, foam, love, gold, rose, pine,
    /// muted, highlight high/med.
    pub const rose_pine = Theme{
        .name = "Rose Pine",
        .bg = Color.rgb(0x19, 0x17, 0x24),
        .fg = Color.rgb(0xe0, 0xde, 0xf4),
        .accent = Color.rgb(0xc4, 0xa7, 0xe7),
        .success = Color.rgb(0x9c, 0xcf, 0xd8),
        .danger = Color.rgb(0xeb, 0x6f, 0x92),
        .warning = Color.rgb(0xf6, 0xc1, 0x77),
        .extra = Color.rgb(0xeb, 0xbc, 0xba),
        .info = Color.rgb(0x31, 0x74, 0x8f),
        .error_extra = Color.rgb(0x9a, 0x4a, 0x66),
        .dim = Color.rgb(0x6e, 0x6a, 0x86),
        .dimmer = Color.rgb(0x52, 0x4f, 0x67),
        .cursor_bg = Color.rgb(0xc4, 0xa7, 0xe7),
        .cursor_insert_bg = Color.rgb(0x9c, 0xcf, 0xd8),
        .cursor_fg = Color.rgb(0x19, 0x17, 0x24),
        .cursor_insert_fg = Color.rgb(0x19, 0x17, 0x24),
        .error_bg = Color.rgb(0x43, 0x23, 0x36),
        .visual_bg = Color.rgb(0x40, 0x3d, 0x52),
        .visual_fg = Color.rgb(0xe0, 0xde, 0xf4),
        .border = Color.rgb(0x40, 0x3d, 0x52),
        .pace = Color.rgb(0xaa, 0x95, 0xca),
        .syn_keyword = Color.rgb(0x53, 0x6e, 0x8a),
        .syn_string = Color.rgb(0xab, 0x91, 0x7f),
        .syn_comment = Color.rgb(0x66, 0x62, 0x7d),
        .syn_number = Color.rgb(0xa6, 0x8f, 0x9d),
        .syn_type = Color.rgb(0x83, 0x97, 0xab),
        .syn_punct = Color.rgb(0x7f, 0x7b, 0x96),
    };

    /// Everforest dark (medium): bg0, fg, green, aqua, red, yellow,
    /// orange, blue, grey0, bg5, bg_red, bg_visual, bg4.
    pub const everforest = Theme{
        .name = "Everforest",
        .bg = Color.rgb(0x2d, 0x35, 0x3b),
        .fg = Color.rgb(0xd3, 0xc6, 0xaa),
        .accent = Color.rgb(0xa7, 0xc0, 0x80),
        .success = Color.rgb(0x83, 0xc0, 0x92),
        .danger = Color.rgb(0xe6, 0x7e, 0x80),
        .warning = Color.rgb(0xdb, 0xbc, 0x7f),
        .extra = Color.rgb(0xe6, 0x98, 0x75),
        .info = Color.rgb(0x7f, 0xbb, 0xb3),
        .error_extra = Color.rgb(0x9e, 0x5a, 0x5e),
        .dim = Color.rgb(0x7a, 0x84, 0x78),
        .dimmer = Color.rgb(0x56, 0x63, 0x5f),
        .cursor_bg = Color.rgb(0xa7, 0xc0, 0x80),
        .cursor_insert_bg = Color.rgb(0x83, 0xc0, 0x92),
        .cursor_fg = Color.rgb(0x2d, 0x35, 0x3b),
        .cursor_insert_fg = Color.rgb(0x2d, 0x35, 0x3b),
        .error_bg = Color.rgb(0x51, 0x40, 0x45),
        .visual_bg = Color.rgb(0x54, 0x3a, 0x48),
        .visual_fg = Color.rgb(0xd3, 0xc6, 0xaa),
        .border = Color.rgb(0x4f, 0x58, 0x5e),
        .pace = Color.rgb(0x9a, 0xae, 0x7e),
        .syn_keyword = Color.rgb(0xab, 0x81, 0x7c),
        .syn_string = Color.rgb(0x8e, 0x9f, 0x7c),
        .syn_comment = Color.rgb(0x6f, 0x7a, 0x70),
        .syn_number = Color.rgb(0xa3, 0x8d, 0x94),
        .syn_type = Color.rgb(0xa6, 0x9d, 0x7b),
        .syn_punct = Color.rgb(0x87, 0x8e, 0x80),
    };

    /// Gruvbox light (medium): bg0, fg1, faded orange/green/red/yellow/
    /// aqua/blue, neutral red and orange, gray, bg2/bg3.
    pub const gruvbox_light = Theme{
        .name = "Gruvbox Light",
        .bg = Color.rgb(0xfb, 0xf1, 0xc7),
        .fg = Color.rgb(0x3c, 0x38, 0x36),
        .accent = Color.rgb(0xaf, 0x3a, 0x03),
        .success = Color.rgb(0x79, 0x74, 0x0e),
        .danger = Color.rgb(0xcc, 0x24, 0x1d),
        .warning = Color.rgb(0xb5, 0x76, 0x14),
        .extra = Color.rgb(0xd6, 0x5d, 0x0e),
        .info = Color.rgb(0x07, 0x66, 0x78),
        .error_extra = Color.rgb(0x9d, 0x00, 0x06),
        .dim = Color.rgb(0x92, 0x83, 0x74),
        .dimmer = Color.rgb(0xbd, 0xae, 0x93),
        .cursor_bg = Color.rgb(0xaf, 0x3a, 0x03),
        .cursor_insert_bg = Color.rgb(0x79, 0x74, 0x0e),
        .cursor_fg = Color.rgb(0xfb, 0xf1, 0xc7),
        .cursor_insert_fg = Color.rgb(0xff, 0xff, 0xff),
        .error_bg = Color.rgb(0xf6, 0xd0, 0xb8),
        .visual_bg = Color.rgb(0xd5, 0xc4, 0xa1),
        .visual_fg = Color.rgb(0x3c, 0x38, 0x36),
        .border = Color.rgb(0xbd, 0xae, 0x93),
        .pace = Color.rgb(0xa6, 0x50, 0x25),
        .syn_keyword = Color.rgb(0x97, 0x48, 0x42),
        .syn_string = Color.rgb(0x87, 0x7c, 0x46),
        .syn_comment = Color.rgb(0x9f, 0x90, 0x7d),
        .syn_number = Color.rgb(0x91, 0x64, 0x73),
        .syn_type = Color.rgb(0xa2, 0x7d, 0x49),
        .syn_punct = Color.rgb(0x85, 0x78, 0x6b),
    };
};

// ============================================================================
// Tests
// ============================================================================

test "slug round-trips for every theme" {
    inline for (comptime std.meta.tags(ThemeId)) |id| {
        try std.testing.expectEqual(@as(?ThemeId, id), fromSlug(slug(id)));
        try std.testing.expect(std.mem.indexOfScalar(u8, slug(id), '_') == null);
    }
    try std.testing.expectEqualStrings("one-dark", slug(.one_dark));
    try std.testing.expectEqual(@as(?ThemeId, .rose_pine), fromSlug("rose_pine"));
    try std.testing.expectEqual(@as(?ThemeId, null), fromSlug("nope"));
}

test "every theme is listed once and keeps its numeric id" {
    try std.testing.expectEqual(std.meta.tags(ThemeId).len, options().len);
    for (options(), 0..) |opt, i| try std.testing.expectEqual(i, @backingInt(opt.id));
    try std.testing.expectEqual(@as(u8, 6), @backingInt(ThemeId.solarized_dark));
    try std.testing.expectEqual(@as(u8, 12), @backingInt(ThemeId.gruvbox_light));
}

test "text colors are readable and distinct" {
    inline for (comptime std.meta.tags(ThemeId)) |id| {
        const t = resolve(id);
        errdefer std.debug.print("theme {s}\n", .{slug(id)});
        try std.testing.expect(!std.meta.eql(t.fg, t.dim));
        try std.testing.expect(!std.meta.eql(t.danger, t.error_extra));
        if (!t.use_terminal_defaults) {
            try std.testing.expect(t.fg.contrast(t.bg) >= 4.5);
            // Untyped text is what you read while typing.
            try std.testing.expect(t.dim.contrast(t.bg) >= 2.4);
            // Typed vs untyped must be told apart at a glance.
            try std.testing.expect(t.fg.contrast(t.dim) >= 2.0);
            try std.testing.expect(t.danger.contrast(t.bg) >= 2.5);
            // Extra letters are mistakes too: darker, but still visible.
            try std.testing.expect(t.error_extra.contrast(t.bg) >= 2.0);
        }
    }
}

test "cursor text reads on the cursor cells" {
    inline for (comptime std.meta.tags(ThemeId)) |id| {
        const t = resolve(id);
        errdefer std.debug.print("theme {s}: insert {d:.2} normal {d:.2}\n", .{ slug(id), t.cursor_insert_fg.contrast(t.cursor_insert_bg), t.cursor_fg.contrast(t.cursor_bg) });
        try std.testing.expect(t.cursor_insert_fg.contrast(t.cursor_insert_bg) >= 4.5);
        try std.testing.expect(t.cursor_fg.contrast(t.cursor_bg) >= 4.0);
    }
}

test "syntax and pace colours are readable and stay muted" {
    inline for (comptime std.meta.tags(ThemeId)) |id| {
        const t = resolve(id);
        if (!t.use_terminal_defaults) {
            const syn = [_]Color{ t.syn_keyword, t.syn_string, t.syn_number, t.syn_type, t.syn_punct, t.pace };
            for (syn) |c| {
                errdefer std.debug.print("theme {s}: {any} bg {d:.2} fg {d:.2}\n", .{ slug(id), c, c.contrast(t.bg), c.contrast(t.fg) });
                try std.testing.expect(c.contrast(t.bg) >= 2.4);
                // Untyped code must not pass for typed text.
                try std.testing.expect(c.contrast(t.fg) >= 1.3);
            }
            try std.testing.expect(t.syn_comment.contrast(t.bg) >= 2.0);
            try std.testing.expect(t.syn_comment.contrast(t.fg) >= 2.0);
        }
    }
}
