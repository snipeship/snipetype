const theme_mod = @import("theme.zig");
const Renderer = @import("../platform/renderer.zig").Renderer;
const Key = @import("../platform/input.zig").Key;
const Mode = @import("../core/types.zig").Mode;

pub const Panel = enum { theme, mode };

pub const Action = union(enum) {
    none,
    preview_theme: theme_mod.ThemeId,
    apply_mode: Mode,
    close,
    cancel: theme_mod.ThemeId,
};

const ModeOption = struct {
    mode: Mode,
    label: []const u8,
};

const MODE_OPTIONS = [_]ModeOption{
    .{ .mode = .words, .label = "Words" },
    .{ .mode = .sentences, .label = "Sentences" },
    .{ .mode = .code, .label = "Code" },
    .{ .mode = .vim, .label = "Vim" },
};

pub const Settings = struct {
    is_open: bool = false,
    panel: Panel = .theme,
    theme_index: usize = 0,
    mode_index: usize = 0,
    original_theme: theme_mod.ThemeId = .system,
    original_mode: Mode = .words,

    pub fn open(self: *Settings, current_theme: theme_mod.ThemeId, current_mode: Mode) void {
        self.is_open = true;
        self.panel = .theme;
        self.original_theme = current_theme;
        self.original_mode = current_mode;
        self.theme_index = indexOfTheme(current_theme);
        self.mode_index = indexOfMode(current_mode);
    }

    pub fn close(self: *Settings) void {
        self.is_open = false;
    }

    pub fn handleKey(self: *Settings, key: Key) Action {
        if (!self.is_open) return .none;

        switch (key) {
            .ArrowUp, .CtrlArrowUp => return self.moveSelection(-1),
            .ArrowDown, .CtrlArrowDown => return self.moveSelection(1),
            .ArrowLeft, .ShiftArrowLeft, .CtrlArrowLeft => {
                self.panel = .theme;
                return .none;
            },
            .ArrowRight, .ShiftArrowRight, .CtrlArrowRight => {
                self.panel = .mode;
                return .none;
            },
            .Byte => |b| switch (b) {
                0x1b, 'q' => { // Esc / q
                    self.is_open = false;
                    return .{ .cancel = self.original_theme };
                },
                0x10 => { // Ctrl+P
                    return self.applyAndClose();
                },
                '\t' => {
                    self.panel = switch (self.panel) {
                        .theme => .mode,
                        .mode => .theme,
                    };
                    return .none;
                },
                '\r', '\n' => return self.applyAndClose(),
                'k' => return self.moveSelection(-1),
                'j' => return self.moveSelection(1),
                'h' => {
                    self.panel = .theme;
                    return .none;
                },
                'l' => {
                    self.panel = .mode;
                    return .none;
                },
                else => return .none,
            },
        }
    }

    fn applyAndClose(self: *Settings) Action {
        self.is_open = false;
        const selected_mode = MODE_OPTIONS[self.mode_index].mode;
        if (selected_mode != self.original_mode) return .{ .apply_mode = selected_mode };
        return .close;
    }

    fn moveSelection(self: *Settings, delta: i8) Action {
        if (self.panel == .theme) {
            self.theme_index = moveIndex(self.theme_index, theme_mod.options().len, delta);
            return .{ .preview_theme = theme_mod.options()[self.theme_index].id };
        }

        self.mode_index = moveIndex(self.mode_index, MODE_OPTIONS.len, delta);
        return .none;
    }

    pub fn renderOverlay(
        self: *const Settings,
        r: Renderer,
        palette: *const theme_mod.Theme,
        theme_id: theme_mod.ThemeId,
        current_mode: Mode,
    ) void {
        if (!self.is_open) return;

        const theme_opts = theme_mod.options();
        const list_len: usize = @max(theme_opts.len, MODE_OPTIONS.len);

        const max_w: usize = r.width() -| 2;
        const max_h: usize = r.height() -| 2;
        if (max_w < 20 or max_h < 10) return;

        const w: usize = @min(max_w, 72);
        const list_h: usize = @max(1, @min(list_len, max_h -| 8));
        const h: usize = list_h + 8;
        const x0: usize = (r.width() -| w) / 2;
        const y0: usize = (r.height() -| h) / 2;

        drawBox(r, x0, y0, w, h, palette);

        const inner_x = x0 + 1;
        const inner_w = w - 2;
        const left_w: usize = (inner_w - 1) / 2;
        const right_w: usize = inner_w - 1 - left_w;
        const divider_x: usize = inner_x + left_w;

        const title = "Settings";
        const title_x = x0 + (w - title.len) / 2;
        r.moveTo(title_x, y0 + 1);
        r.setBold(true);
        r.setFg(palette.accent);
        r.write(title);
        r.resetStyle();

        drawInnerDivider(r, x0, y0 + 2, w, palette, null);
        drawInnerDivider(r, x0, y0 + 4 + list_h, w, palette, divider_x);

        // Column headings
        r.moveTo(x0 + 2, y0 + 3);
        if (self.panel == .theme) {
            r.setBold(true);
            r.setFg(palette.accent);
        } else {
            r.setFg(palette.dim);
        }
        r.write("Theme");
        r.resetStyle();

        r.moveTo(divider_x + 2, y0 + 3);
        if (self.panel == .mode) {
            r.setBold(true);
            r.setFg(palette.accent);
        } else {
            r.setFg(palette.dim);
        }
        r.write("Mode");
        r.resetStyle();

        // Vertical divider in list area
        r.setFg(palette.border);
        for (0..(list_h + 1)) |row| {
            r.moveTo(divider_x, y0 + 3 + row);
            r.write("|");
        }
        r.resetStyle();

        const left_text_x: usize = inner_x + 1;
        const left_fill_w: usize = left_w - 1;
        const right_text_x: usize = divider_x + 2;
        const right_fill_w: usize = right_w - 1;

        for (0..list_h) |row| {
            const y = y0 + 4 + row;

            // Theme column
            if (row < theme_opts.len) {
                const opt = theme_opts[row];
                const is_selected = row == self.theme_index;
                const is_active = self.panel == .theme;
                const is_current = opt.id == theme_id;

                r.moveTo(left_text_x, y);
                if (is_selected and is_active) {
                    r.setBg(palette.cursor_bg);
                    r.setFg(palette.cursor_fg);
                    r.setBold(true);
                } else if (is_selected) {
                    r.setBg(palette.visual_bg);
                    r.setFg(palette.visual_fg);
                } else if (is_current) {
                    r.setFg(palette.accent);
                } else {
                    r.setFg(palette.dim);
                }

                r.writeByte(if (is_current) '*' else ' ');
                r.write(" ");
                r.write(opt.label);
                padSpaces(r, left_fill_w, 2 + opt.label.len);
                r.resetStyle();
            }

            // Mode column
            if (row < MODE_OPTIONS.len) {
                const opt = MODE_OPTIONS[row];
                const is_selected = row == self.mode_index;
                const is_active = self.panel == .mode;
                const is_current = opt.mode == current_mode;

                r.moveTo(right_text_x, y);
                if (is_selected and is_active) {
                    r.setBg(palette.cursor_bg);
                    r.setFg(palette.cursor_fg);
                    r.setBold(true);
                } else if (is_selected) {
                    r.setBg(palette.visual_bg);
                    r.setFg(palette.visual_fg);
                } else if (is_current) {
                    r.setFg(palette.accent);
                } else {
                    r.setFg(palette.dim);
                }

                r.writeByte(if (is_current) '*' else ' ');
                r.write(" ");
                r.write(opt.label);
                padSpaces(r, right_fill_w, 2 + opt.label.len);
                r.resetStyle();
            }
        }

        // Info line
        const selected_theme = theme_opts[self.theme_index];
        const selected_mode = MODE_OPTIONS[self.mode_index].mode;

        r.moveTo(x0 + 2, y0 + 5 + list_h);
        r.setFg(palette.dimmer);
        r.write("Theme:");
        r.resetStyle();
        r.write(" ");
        r.setFg(palette.accent);
        r.write(selected_theme.label);
        r.resetStyle();
        if (selected_theme.id == .system) {
            r.setFg(palette.dimmer);
            r.write(" (");
            r.setFg(palette.dim);
            r.write(palette.name);
            r.setFg(palette.dimmer);
            r.write(")");
            r.resetStyle();
        }

        r.setFg(palette.dimmer);
        r.write("  Mode:");
        r.resetStyle();
        r.write(" ");
        r.setFg(palette.accent);
        r.write(selected_mode.name());
        r.resetStyle();
        if (selected_mode != current_mode) {
            r.setFg(palette.extra);
            r.write(" (restart)");
            r.resetStyle();
        }

        // Help line
        r.moveTo(x0 + 2, y0 + 6 + list_h);
        r.setFg(palette.dimmer);
        r.write("up/down select  tab switch  enter apply  esc cancel");
        r.resetStyle();
    }
};

fn indexOfTheme(id: theme_mod.ThemeId) usize {
    const opts = theme_mod.options();
    for (opts, 0..) |opt, i| {
        if (opt.id == id) return i;
    }
    return 0;
}

fn indexOfMode(mode: Mode) usize {
    for (MODE_OPTIONS, 0..) |opt, i| {
        if (opt.mode == mode) return i;
    }
    return 0;
}

fn moveIndex(index: usize, len: usize, delta: i8) usize {
    if (len == 0) return 0;
    const cur: isize = @intCast(index);
    const d: isize = @intCast(delta);
    const l: isize = @intCast(len);
    const next = @mod(cur + d, l);
    return @intCast(next);
}

fn padSpaces(r: Renderer, width: usize, used: usize) void {
    if (used >= width) return;
    const rem = width - used;
    for (0..rem) |_| r.write(" ");
}

fn drawInnerDivider(
    r: Renderer,
    x0: usize,
    y: usize,
    w: usize,
    palette: *const theme_mod.Theme,
    divider_x: ?usize,
) void {
    r.moveTo(x0 + 1, y);
    r.setFg(palette.border);
    for (0..(w - 2)) |_| r.write("-");
    if (divider_x) |dx| {
        r.moveTo(dx, y);
        r.write("+");
    }
    r.resetStyle();
}

fn drawBox(r: Renderer, x0: usize, y0: usize, w: usize, h: usize, palette: *const theme_mod.Theme) void {
    if (w < 2 or h < 2) return;

    r.setFg(palette.border);

    r.moveTo(x0, y0);
    r.write("+");
    for (0..(w - 2)) |_| r.write("-");
    r.write("+");

    for (1..(h - 1)) |dy| {
        r.moveTo(x0, y0 + dy);
        r.write("|");
        for (0..(w - 2)) |_| r.write(" ");
        r.write("|");
    }

    r.moveTo(x0, y0 + h - 1);
    r.write("+");
    for (0..(w - 2)) |_| r.write("-");
    r.write("+");

    r.resetStyle();
}
