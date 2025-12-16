const std = @import("std");
const ansi = @import("ansi.zig");

pub const ThemeId = enum {
    system,
    one_dark,
    one_light,
    dracula,
    nord,
    gruvbox_dark,
    solarized_dark,
};

pub const Theme = struct {
    name: []const u8,

    bg: []const u8,
    fg: []const u8,
    base: []const u8,

    accent: []const u8,
    success: []const u8,
    danger: []const u8,
    warning: []const u8,
    extra: []const u8,
    info: []const u8,

    dim: []const u8,
    dimmer: []const u8,

    cursor_bg: []const u8,
    cursor_insert_bg: []const u8,
    cursor_fg: []const u8,

    error_bg: []const u8,
    visual_bg: []const u8,
    visual_fg: []const u8,

    border: []const u8,
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
        .system => if (systemPrefersLight()) &THEMES.system_light else &THEMES.system_dark,
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
        // In browser, query via JavaScript
        return js_system_prefers_light();
    }

    // Native: check COLORFGBG environment variable
    const raw = std.posix.getenv("COLORFGBG") orelse return false;
    const value = std.mem.sliceTo(raw, 0);

    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, value, ';');
    while (it.next()) |part| last = part;
    const last_part = last orelse return false;

    const bg = std.fmt.parseInt(u8, last_part, 10) catch return false;
    // Most terminals: 0-6 = dark bg colors, 7-15 = light bg colors.
    return bg >= 7;
}

// JavaScript import for WASM builds
extern "env" fn js_system_prefers_light() bool;

const THEMES = struct {
    pub const system_dark: Theme = .{
        .name = "ONE Dark",
        .bg = "",
        .fg = "",
        .base = ansi.RESET,
        .accent = "\x1b[38;2;99;102;241m",
        .success = "\x1b[38;2;34;197;94m",
        .danger = "\x1b[38;2;239;68;68m",
        .warning = "\x1b[38;2;250;204;21m",
        .extra = "\x1b[38;2;251;146;60m",
        .info = "\x1b[38;2;34;211;238m",
        .dim = "\x1b[38;2;100;100;120m",
        .dimmer = "\x1b[38;2;60;60;80m",
        .cursor_bg = "\x1b[48;2;99;102;241m",
        .cursor_insert_bg = "\x1b[48;2;34;197;94m",
        .cursor_fg = "\x1b[38;2;255;255;255m",
        .error_bg = "\x1b[48;2;50;20;20m",
        .visual_bg = "\x1b[48;2;60;60;100m",
        .visual_fg = "\x1b[38;2;255;255;255m",
        .border = "\x1b[38;2;60;60;80m",
    };

    pub const system_light: Theme = .{
        .name = "ONE Light",
        .bg = "",
        .fg = "",
        .base = ansi.RESET,
        .accent = "\x1b[38;2;79;70;229m",
        .success = "\x1b[38;2;22;163;74m",
        .danger = "\x1b[38;2;220;38;38m",
        .warning = "\x1b[38;2;161;98;7m",
        .extra = "\x1b[38;2;234;88;12m",
        .info = "\x1b[38;2;8;145;178m",
        .dim = "\x1b[38;2;71;85;105m",
        .dimmer = "\x1b[38;2;148;163;184m",
        .cursor_bg = "\x1b[48;2;79;70;229m",
        .cursor_insert_bg = "\x1b[48;2;22;163;74m",
        .cursor_fg = "\x1b[38;2;255;255;255m",
        .error_bg = "\x1b[48;2;254;226;226m",
        .visual_bg = "\x1b[48;2;224;231;255m",
        .visual_fg = "\x1b[38;2;15;23;42m",
        .border = "\x1b[38;2;148;163;184m",
    };

    pub const one_dark: Theme = .{
        .name = "ONE Dark",
        .bg = "\x1b[48;2;40;44;52m",
        .fg = "\x1b[38;2;171;178;191m",
        .base = ansi.RESET ++ "\x1b[48;2;40;44;52m" ++ "\x1b[38;2;171;178;191m",
        .accent = "\x1b[38;2;99;102;241m",
        .success = "\x1b[38;2;34;197;94m",
        .danger = "\x1b[38;2;239;68;68m",
        .warning = "\x1b[38;2;250;204;21m",
        .extra = "\x1b[38;2;251;146;60m",
        .info = "\x1b[38;2;34;211;238m",
        .dim = "\x1b[38;2;100;100;120m",
        .dimmer = "\x1b[38;2;60;60;80m",
        .cursor_bg = "\x1b[48;2;99;102;241m",
        .cursor_insert_bg = "\x1b[48;2;34;197;94m",
        .cursor_fg = "\x1b[38;2;255;255;255m",
        .error_bg = "\x1b[48;2;50;20;20m",
        .visual_bg = "\x1b[48;2;60;60;100m",
        .visual_fg = "\x1b[38;2;255;255;255m",
        .border = "\x1b[38;2;60;60;80m",
    };

    pub const one_light: Theme = .{
        .name = "ONE Light",
        .bg = "\x1b[48;2;250;250;250m",
        .fg = "\x1b[38;2;15;23;42m",
        .base = ansi.RESET ++ "\x1b[48;2;250;250;250m" ++ "\x1b[38;2;15;23;42m",
        .accent = "\x1b[38;2;79;70;229m",
        .success = "\x1b[38;2;22;163;74m",
        .danger = "\x1b[38;2;220;38;38m",
        .warning = "\x1b[38;2;161;98;7m",
        .extra = "\x1b[38;2;234;88;12m",
        .info = "\x1b[38;2;8;145;178m",
        .dim = "\x1b[38;2;71;85;105m",
        .dimmer = "\x1b[38;2;148;163;184m",
        .cursor_bg = "\x1b[48;2;79;70;229m",
        .cursor_insert_bg = "\x1b[48;2;22;163;74m",
        .cursor_fg = "\x1b[38;2;255;255;255m",
        .error_bg = "\x1b[48;2;254;226;226m",
        .visual_bg = "\x1b[48;2;224;231;255m",
        .visual_fg = "\x1b[38;2;15;23;42m",
        .border = "\x1b[38;2;148;163;184m",
    };

    pub const dracula: Theme = .{
        .name = "Dracula",
        .bg = "\x1b[48;2;40;42;54m",
        .fg = "\x1b[38;2;248;248;242m",
        .base = ansi.RESET ++ "\x1b[48;2;40;42;54m" ++ "\x1b[38;2;248;248;242m",
        .accent = "\x1b[38;2;189;147;249m",
        .success = "\x1b[38;2;80;250;123m",
        .danger = "\x1b[38;2;255;85;85m",
        .warning = "\x1b[38;2;241;250;140m",
        .extra = "\x1b[38;2;255;184;108m",
        .info = "\x1b[38;2;139;233;253m",
        .dim = "\x1b[38;2;98;114;164m",
        .dimmer = "\x1b[38;2;68;71;90m",
        .cursor_bg = "\x1b[48;2;189;147;249m",
        .cursor_insert_bg = "\x1b[48;2;80;250;123m",
        .cursor_fg = "\x1b[38;2;40;42;54m",
        .error_bg = "\x1b[48;2;68;71;90m",
        .visual_bg = "\x1b[48;2;68;71;90m",
        .visual_fg = "\x1b[38;2;248;248;242m",
        .border = "\x1b[38;2;98;114;164m",
    };

    pub const nord: Theme = .{
        .name = "Nord",
        .bg = "\x1b[48;2;46;52;64m",
        .fg = "\x1b[38;2;236;239;244m",
        .base = ansi.RESET ++ "\x1b[48;2;46;52;64m" ++ "\x1b[38;2;236;239;244m",
        .accent = "\x1b[38;2;129;161;193m",
        .success = "\x1b[38;2;163;190;140m",
        .danger = "\x1b[38;2;191;97;106m",
        .warning = "\x1b[38;2;235;203;139m",
        .extra = "\x1b[38;2;208;135;112m",
        .info = "\x1b[38;2;136;192;208m",
        .dim = "\x1b[38;2;76;86;106m",
        .dimmer = "\x1b[38;2;59;66;82m",
        .cursor_bg = "\x1b[48;2;129;161;193m",
        .cursor_insert_bg = "\x1b[48;2;163;190;140m",
        .cursor_fg = "\x1b[38;2;46;52;64m",
        .error_bg = "\x1b[48;2;59;66;82m",
        .visual_bg = "\x1b[48;2;59;66;82m",
        .visual_fg = "\x1b[38;2;236;239;244m",
        .border = "\x1b[38;2;76;86;106m",
    };

    pub const gruvbox_dark: Theme = .{
        .name = "Gruvbox Dark",
        .bg = "\x1b[48;2;40;40;40m",
        .fg = "\x1b[38;2;235;219;178m",
        .base = ansi.RESET ++ "\x1b[48;2;40;40;40m" ++ "\x1b[38;2;235;219;178m",
        .accent = "\x1b[38;2;250;189;47m",
        .success = "\x1b[38;2;152;151;26m",
        .danger = "\x1b[38;2;204;36;29m",
        .warning = "\x1b[38;2;215;153;33m",
        .extra = "\x1b[38;2;254;128;25m",
        .info = "\x1b[38;2;131;165;152m",
        .dim = "\x1b[38;2;146;131;116m",
        .dimmer = "\x1b[38;2;102;92;84m",
        .cursor_bg = "\x1b[48;2;102;92;84m",
        .cursor_insert_bg = "\x1b[48;2;152;151;26m",
        .cursor_fg = "\x1b[38;2;251;241;199m",
        .error_bg = "\x1b[48;2;60;56;54m",
        .visual_bg = "\x1b[48;2;80;73;69m",
        .visual_fg = "\x1b[38;2;251;241;199m",
        .border = "\x1b[38;2;146;131;116m",
    };

    pub const solarized_dark: Theme = .{
        .name = "Solarized Dark",
        .bg = "\x1b[48;2;0;43;54m",
        .fg = "\x1b[38;2;131;148;150m",
        .base = ansi.RESET ++ "\x1b[48;2;0;43;54m" ++ "\x1b[38;2;131;148;150m",
        .accent = "\x1b[38;2;38;139;210m",
        .success = "\x1b[38;2;133;153;0m",
        .danger = "\x1b[38;2;220;50;47m",
        .warning = "\x1b[38;2;181;137;0m",
        .extra = "\x1b[38;2;203;75;22m",
        .info = "\x1b[38;2;42;161;152m",
        .dim = "\x1b[38;2;88;110;117m",
        .dimmer = "\x1b[38;2;101;123;131m",
        .cursor_bg = "\x1b[48;2;38;139;210m",
        .cursor_insert_bg = "\x1b[48;2;133;153;0m",
        .cursor_fg = "\x1b[38;2;0;43;54m",
        .error_bg = "\x1b[48;2;7;54;66m",
        .visual_bg = "\x1b[48;2;7;54;66m",
        .visual_fg = "\x1b[38;2;131;148;150m",
        .border = "\x1b[38;2;88;110;117m",
    };
};
