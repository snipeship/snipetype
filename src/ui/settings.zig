const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const theme_mod = @import("theme.zig");

// Import platform-specific types via conditional compilation
const is_wasm = builtin.cpu.arch == .wasm32;
const render_buffer = if (is_wasm)
    @import("../platform/render_buffer_web.zig")
else
    @import("../platform/render_buffer.zig");
const terminal = if (is_wasm)
    @import("../platform/terminal_web.zig")
else
    @import("../platform/terminal.zig");
const input = if (is_wasm)
    @import("../platform/input_web.zig")
else
    @import("../platform/input.zig");

const types = @import("../core/types.zig");
const Mode = types.Mode;
const Key = input.Key;
const RenderBuffer = render_buffer.RenderBuffer;
const Terminal = terminal.Terminal;

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
            .ArrowUp => return self.moveSelection(-1),
            .ArrowDown => return self.moveSelection(1),
            .ArrowLeft => {
                self.panel = .theme;
                return .none;
            },
            .ArrowRight => {
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
        buf: *RenderBuffer,
        term: *Terminal,
        palette: *const theme_mod.Theme,
        theme_id: theme_mod.ThemeId,
        current_mode: Mode,
    ) void {
        if (!self.is_open) return;

        const theme_opts = theme_mod.options();
        const list_len: usize = @max(theme_opts.len, MODE_OPTIONS.len);
        const base = palette.base;

        const max_w: usize = term.width -| 2;
        const max_h: usize = term.height -| 2;
        if (max_w < 20 or max_h < 10) return;

        const w: usize = @min(max_w, 72);
        const list_h: usize = @max(1, @min(list_len, max_h -| 8));
        const h: usize = list_h + 8;
        const x0: usize = (term.width -| w) / 2;
        const y0: usize = (term.height -| h) / 2;

        drawBox(buf, x0, y0, w, h, palette);

        const inner_x = x0 + 1;
        const inner_w = w - 2;
        const left_w: usize = (inner_w - 1) / 2;
        const right_w: usize = inner_w - 1 - left_w;
        const divider_x: usize = inner_x + left_w;

        const title = "Settings";
        const title_x = x0 + (w - title.len) / 2;
        buf.moveTo(title_x, y0 + 1);
        buf.write(ansi.BOLD);
        buf.write(palette.accent);
        buf.write(title);
        buf.write(base);

        drawInnerDivider(buf, x0, y0 + 2, w, palette, null);
        drawInnerDivider(buf, x0, y0 + 4 + list_h, w, palette, divider_x);

        // Column headings
        buf.moveTo(x0 + 2, y0 + 3);
        if (self.panel == .theme) {
            buf.write(ansi.BOLD);
            buf.write(palette.accent);
        } else {
            buf.write(palette.dim);
        }
        buf.write("Theme");
        buf.write(base);

        buf.moveTo(divider_x + 2, y0 + 3);
        if (self.panel == .mode) {
            buf.write(ansi.BOLD);
            buf.write(palette.accent);
        } else {
            buf.write(palette.dim);
        }
        buf.write("Mode");
        buf.write(base);

        // Vertical divider in list area
        buf.write(palette.border);
        for (0..(list_h + 1)) |row| {
            buf.moveTo(divider_x, y0 + 3 + row);
            buf.write("│");
        }
        buf.write(base);

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

                buf.moveTo(left_text_x, y);
                if (is_selected and is_active) {
                    buf.write(palette.cursor_bg);
                    buf.write(palette.cursor_fg);
                    buf.write(ansi.BOLD);
                } else if (is_selected) {
                    buf.write(palette.visual_bg);
                    buf.write(palette.visual_fg);
                } else if (is_current) {
                    buf.write(palette.accent);
                } else {
                    buf.write(palette.dim);
                }

                buf.writeByte(if (is_current) '*' else ' ');
                buf.write(" ");
                buf.write(opt.label);
                padSpaces(buf, left_fill_w, 2 + opt.label.len);
                buf.write(base);
            }

            // Mode column
            if (row < MODE_OPTIONS.len) {
                const opt = MODE_OPTIONS[row];
                const is_selected = row == self.mode_index;
                const is_active = self.panel == .mode;
                const is_current = opt.mode == current_mode;

                buf.moveTo(right_text_x, y);
                if (is_selected and is_active) {
                    buf.write(palette.cursor_bg);
                    buf.write(palette.cursor_fg);
                    buf.write(ansi.BOLD);
                } else if (is_selected) {
                    buf.write(palette.visual_bg);
                    buf.write(palette.visual_fg);
                } else if (is_current) {
                    buf.write(palette.accent);
                } else {
                    buf.write(palette.dim);
                }

                buf.writeByte(if (is_current) '*' else ' ');
                buf.write(" ");
                buf.write(opt.label);
                padSpaces(buf, right_fill_w, 2 + opt.label.len);
                buf.write(base);
            }
        }

        // Info line
        const selected_theme = theme_opts[self.theme_index];
        const selected_mode = MODE_OPTIONS[self.mode_index].mode;

        buf.moveTo(x0 + 2, y0 + 5 + list_h);
        buf.write(palette.dimmer);
        buf.write("Theme:");
        buf.write(base);
        buf.write(" ");
        buf.write(palette.accent);
        buf.write(selected_theme.label);
        buf.write(base);
        if (selected_theme.id == .system) {
            buf.write(palette.dimmer);
            buf.write(" (");
            buf.write(palette.dim);
            buf.write(palette.name);
            buf.write(palette.dimmer);
            buf.write(")");
            buf.write(base);
        }

        buf.write(palette.dimmer);
        buf.write("  Mode:");
        buf.write(base);
        buf.write(" ");
        buf.write(palette.accent);
        buf.write(selected_mode.name());
        buf.write(base);
        if (selected_mode != current_mode) {
            buf.write(palette.extra);
            buf.write(" (restart)");
            buf.write(base);
        }

        // Help line
        buf.moveTo(x0 + 2, y0 + 6 + list_h);
        buf.write(palette.dimmer);
        buf.write("up/down select  tab switch  enter apply  esc cancel");
        buf.write(base);
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

fn padSpaces(buf: *RenderBuffer, width: usize, used: usize) void {
    if (used >= width) return;
    const rem = width - used;
    for (0..rem) |_| buf.write(" ");
}

fn drawInnerDivider(
    buf: *RenderBuffer,
    x0: usize,
    y: usize,
    w: usize,
    palette: *const theme_mod.Theme,
    divider_x: ?usize,
) void {
    buf.moveTo(x0 + 1, y);
    buf.write(palette.border);
    for (0..(w - 2)) |_| buf.write("─");
    if (divider_x) |dx| {
        buf.moveTo(dx, y);
        buf.write("┼");
    }
    buf.write(palette.base);
}

fn drawBox(buf: *RenderBuffer, x0: usize, y0: usize, w: usize, h: usize, palette: *const theme_mod.Theme) void {
    if (w < 2 or h < 2) return;

    buf.write(palette.border);

    buf.moveTo(x0, y0);
    buf.write("┌");
    for (0..(w - 2)) |_| buf.write("─");
    buf.write("┐");

    for (1..(h - 1)) |dy| {
        buf.moveTo(x0, y0 + dy);
        buf.write("│");
        for (0..(w - 2)) |_| buf.write(" ");
        buf.write("│");
    }

    buf.moveTo(x0, y0 + h - 1);
    buf.write("└");
    for (0..(w - 2)) |_| buf.write("─");
    buf.write("┘");

    buf.write(palette.base);
}
