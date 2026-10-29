//! Settings overlay (Ctrl+P): theme and mode pickers plus the test options
//! of the selected mode, in a rounded card. Themes preview live while
//! moving; Enter applies the mode and options (restarting the test), Esc
//! reverts. Tab cycles theme / mode / test / options; in the test and
//! options panels Up/Down pick a row and Left/Right change its value
//! (Shift+Left/Right steps the pace wpm by 1 instead of 5).
//!
//! The options panel holds the settings shared by the simple modes: pace
//! caret, stop on error, backspace, layout emulation and (web) typing
//! sounds. It is not offered for arcade.

const std = @import("std");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const Color = @import("color.zig").Color;
const glyph = @import("ansi.zig");
const Renderer = @import("../platform/renderer.zig").Renderer;
const Key = @import("../platform/input.zig").Key;
const types = @import("../core/types.zig");
const Mode = types.Mode;
const Config = types.Config;
const drill = @import("../vim/drill.zig");

pub const Panel = enum { theme, mode, @"test", options };

pub const Action = union(enum) {
    none,
    preview_theme: theme_mod.ThemeId,
    /// Only the mode changed.
    apply_mode: Mode,
    /// Test options (and maybe the mode) changed: the new config.
    apply_config: Config,
    /// Web: the custom `text` row was activated (the host opens its dialog;
    /// the overlay closes).
    edit_custom_text,
    close,
    cancel: theme_mod.ThemeId,
};

/// One row of the test or options panel.
pub const Row = enum {
    length,
    tier,
    punctuation,
    numbers,
    lang,
    kind,
    lesson,
    /// Code: plain or vim keys.
    keys,
    /// Code: syntax colours.
    syntax,
    /// Words: normal or weak-key word choice.
    focus,
    /// Custom: read-only preview of the text (web: opens the dialog).
    text,
    // Options panel.
    pace,
    pace_wpm,
    stop_on_error,
    backspace,
    layout,
    sounds,

    pub fn label(self: Row) []const u8 {
        return switch (self) {
            .pace_wpm => "pace wpm",
            .stop_on_error => "stop on error",
            else => @tagName(self),
        };
    }
};

/// Length presets: word counts, then time limits (seconds).
const WORD_PRESETS = [_]usize{ 10, 25, 50, 100 };
const TIME_PRESETS = [_]usize{ 15, 30, 60, 120 };
const LENGTH_COUNT = WORD_PRESETS.len + TIME_PRESETS.len;
/// Pace wpm step (Shift: 1).
const PACE_STEP: u16 = 5;

/// Test-panel rows for a mode (the vim rows depend on the kind; code with
/// vim keys retypes one snippet, so it has no length).
pub fn rowsFor(cfg: Config) []const Row {
    return switch (cfg.mode) {
        .words => &.{ .length, .tier, .punctuation, .numbers, .focus },
        .sentences => &.{.length},
        .code => switch (cfg.code_keys) {
            .plain => &.{ .length, .lang, .keys, .syntax },
            .vim => &.{ .lang, .keys, .syntax },
        },
        .vim => switch (cfg.vim_kind) {
            .drills => &.{ .kind, .lesson },
            .type => &.{ .kind, .lang },
        },
        .custom => &.{ .length, .text },
        .zen, .daily, .arcade => &.{},
    };
}

/// Options-panel rows (none for arcade; `sounds` only on the web; the
/// fixed pace speed only with a fixed pace).
pub fn optionRowsFor(cfg: Config, is_web: bool) []const Row {
    if (cfg.mode == .arcade) return &.{};
    const fixed = cfg.caret_pace == .fixed;
    if (is_web) {
        return if (fixed)
            &.{ .pace, .pace_wpm, .stop_on_error, .backspace, .layout, .sounds }
        else
            &.{ .pace, .stop_on_error, .backspace, .layout, .sounds };
    }
    return if (fixed)
        &.{ .pace, .pace_wpm, .stop_on_error, .backspace, .layout }
    else
        &.{ .pace, .stop_on_error, .backspace, .layout };
}

const ModeOption = struct {
    mode: Mode,
    label: []const u8,
    blurb: []const u8,
};

const BASE_MODES = [_]ModeOption{
    .{ .mode = .words, .label = "words", .blurb = "common words, no punctuation" },
    .{ .mode = .sentences, .label = "sentences", .blurb = "whole sentences with punctuation" },
    .{ .mode = .code, .label = "code", .blurb = "real-world code snippets" },
    .{ .mode = .vim, .label = "vim", .blurb = "edit the buffer to match, vim keys" },
    .{ .mode = .zen, .label = "zen", .blurb = "free typing " ++ glyph.MIDDOT ++ " esc to finish" },
    .{ .mode = .custom, .label = "custom", .blurb = "your own text" },
    .{ .mode = .daily, .label = "daily", .blurb = "the same 50 words for everyone today" },
};

/// Mode entries; "arcade" is listed once `Mode.arcade` exists.
const MODE_OPTIONS = if (@hasField(Mode, "arcade"))
    BASE_MODES ++ [_]ModeOption{.{
        .mode = @field(Mode, "arcade"),
        .label = "arcade " ++ glyph.SPARK,
        .blurb = "falling words and keys " ++ glyph.MIDDOT ++ " type them in time",
    }}
else
    BASE_MODES;

pub const Settings = struct {
    is_open: bool = false,
    panel: Panel = .theme,
    theme_index: usize = 0,
    mode_index: usize = 0,
    original_theme: theme_mod.ThemeId = .system,
    original_mode: Mode = .words,
    /// The app's config; the App keeps it current while the overlay is
    /// closed so `open` starts the draft from it.
    base: Config = .{},
    /// Config being edited (mode follows the mode list selection).
    draft: Config = .{},
    row_index: usize = 0,
    /// Web host (shows the `sounds` row; the `text` row opens a dialog).
    is_web: bool = false,
    /// Custom text preview for the `text` row (set by the App on open).
    custom_text: []const u8 = "",

    pub fn open(self: *Settings, current_theme: theme_mod.ThemeId, current_mode: Mode) void {
        self.is_open = true;
        self.panel = .theme;
        self.original_theme = current_theme;
        self.original_mode = current_mode;
        self.theme_index = indexOfTheme(current_theme);
        self.mode_index = indexOfMode(current_mode);
        self.base.mode = current_mode;
        self.draft = self.base;
        self.row_index = 0;
    }

    pub fn close(self: *Settings) void {
        self.is_open = false;
    }

    pub fn handleKey(self: *Settings, key: Key) Action {
        if (!self.is_open) return .none;

        switch (key) {
            .ArrowUp, .CtrlArrowUp => return self.moveSelection(-1),
            .ArrowDown, .CtrlArrowDown => return self.moveSelection(1),
            .ArrowLeft, .CtrlArrowLeft, .AltArrowLeft => return self.horizontal(-1, false),
            .ArrowRight, .CtrlArrowRight, .AltArrowRight => return self.horizontal(1, false),
            .ShiftArrowLeft => return self.horizontal(-1, true),
            .ShiftArrowRight => return self.horizontal(1, true),
            .Byte => |b| switch (b) {
                0x1b, 'q' => { // Esc / q
                    self.is_open = false;
                    return .{ .cancel = self.original_theme };
                },
                0x10 => { // Ctrl+P
                    return self.applyAndClose();
                },
                '\t' => {
                    self.panel = self.nextPanel(self.panel);
                    self.row_index = 0;
                    return .none;
                },
                '\r', '\n' => return self.applyAndClose(),
                'k' => return self.moveSelection(-1),
                'j' => return self.moveSelection(1),
                'h' => return self.horizontal(-1, false),
                'l' => return self.horizontal(1, false),
                else => return .none,
            },
            else => return .none,
        }
    }

    /// Tab order: theme, mode, test, options (empty panels skipped).
    fn nextPanel(self: *const Settings, p: Panel) Panel {
        var next = p;
        for (0..4) |_| {
            next = switch (next) {
                .theme => .mode,
                .mode => .@"test",
                .@"test" => .options,
                .options => .theme,
            };
            if (self.panelRows(next) != null) return next;
        }
        return .theme;
    }

    /// Rows of a row panel (null: not a row panel, or empty).
    fn panelRows(self: *const Settings, p: Panel) ?[]const Row {
        const rows = switch (p) {
            .theme, .mode => return &.{},
            .@"test" => rowsFor(self.draft),
            .options => optionRowsFor(self.draft, self.is_web),
        };
        return if (rows.len > 0) rows else null;
    }

    /// The selected row of the test/options panel.
    pub fn currentRow(self: *const Settings) ?Row {
        if (self.panel != .@"test" and self.panel != .options) return null;
        const rows = self.panelRows(self.panel) orelse return null;
        return rows[@min(self.row_index, rows.len - 1)];
    }

    /// Left/Right: change the value in the test/options panel, else switch
    /// column. `fine`: Shift held (pace wpm ±1).
    fn horizontal(self: *Settings, delta: i8, fine: bool) Action {
        switch (self.panel) {
            .theme => {
                if (delta > 0) self.panel = .mode;
            },
            .mode => {
                if (delta < 0) {
                    self.panel = .theme;
                } else {
                    const next = self.nextPanel(.mode);
                    if (next != .theme) {
                        self.panel = next;
                        self.row_index = 0;
                    }
                }
            },
            .@"test", .options => {
                const row = self.currentRow() orelse return .none;
                if (row == .text) {
                    if (!self.is_web) return .none;
                    self.is_open = false;
                    return .edit_custom_text;
                }
                if (row == .pace_wpm and fine) {
                    self.stepPaceWpm(delta, 1);
                } else {
                    self.changeValue(row, delta);
                }
                // Rows may come and go (keys, pace): keep the selection valid.
                if (self.panelRows(self.panel)) |rows| self.row_index = @min(self.row_index, rows.len - 1);
            },
        }
        return .none;
    }

    fn stepPaceWpm(self: *Settings, delta: i8, step: u16) void {
        const d = &self.draft;
        const cur = std.math.clamp(d.caret_wpm, types.CARET_WPM_MIN, types.CARET_WPM_MAX);
        d.caret_wpm = if (delta < 0)
            @max(types.CARET_WPM_MIN, cur -| step)
        else
            @min(types.CARET_WPM_MAX, cur + step);
    }

    fn applyAndClose(self: *Settings) Action {
        self.is_open = false;
        const selected_mode = MODE_OPTIONS[self.mode_index].mode;
        self.draft.mode = selected_mode;
        var base = self.base;
        base.mode = selected_mode;
        if (!sameOptions(self.draft, base)) return .{ .apply_config = self.draft };
        if (selected_mode != self.original_mode) return .{ .apply_mode = selected_mode };
        return .close;
    }

    /// Step the value of `row` in the draft config.
    pub fn changeValue(self: *Settings, row: Row, delta: i8) void {
        const d = &self.draft;
        switch (row) {
            .length => if (d.mode == .custom) {
                // Custom: the whole text once, or a time preset.
                const cur: usize = if (d.time_limit == 0) 0 else if (std.mem.indexOfScalar(usize, &TIME_PRESETS, d.time_limit)) |i| i + 1 else 0;
                const next = moveIndex(cur, TIME_PRESETS.len + 1, delta);
                d.time_limit = if (next == 0) 0 else TIME_PRESETS[next - 1];
            } else {
                const cur = lengthIndex(d.*);
                const next: usize = if (cur) |c|
                    moveIndex(c, LENGTH_COUNT, delta)
                else if (delta > 0) 0 else LENGTH_COUNT - 1;
                if (next < WORD_PRESETS.len) {
                    d.word_count = WORD_PRESETS[next];
                    d.time_limit = 0;
                } else {
                    d.time_limit = TIME_PRESETS[next - WORD_PRESETS.len];
                }
            },
            .keys => d.code_keys = cycleEnum(types.CodeKeys, d.code_keys, delta),
            .syntax => d.syntax = !d.syntax,
            .focus => d.focus = cycleEnum(types.Focus, d.focus, delta),
            .text => {},
            .pace => d.caret_pace = cycleEnum(types.CaretPace, d.caret_pace, delta),
            .pace_wpm => self.stepPaceWpm(delta, PACE_STEP),
            .stop_on_error => d.stop_on_error = cycleEnum(types.StopOnError, d.stop_on_error, delta),
            .backspace => d.no_backspace = !d.no_backspace,
            .layout => d.layout = cycleEnum(types.Layout, d.layout, delta),
            .sounds => d.sounds = !d.sounds,
            .tier => d.tier = cycleEnum(types.WordTier, d.tier, delta),
            .punctuation => d.punctuation = !d.punctuation,
            .numbers => d.numbers = !d.numbers,
            .lang => d.lang = cycleEnum(types.Lang, d.lang, delta),
            .kind => {
                d.vim_kind = cycleEnum(types.VimKind, d.vim_kind, delta);
                self.row_index = 0;
            },
            .lesson => {
                const cur = currentLesson(d.*);
                var l = cur;
                // Skip lessons without challenges.
                for (0..std.meta.tags(drill.Lesson).len) |_| {
                    l = cycleEnum(drill.Lesson, l, delta);
                    if (firstOfLesson(l)) |ch| {
                        d.drill_id = ch.id;
                        break;
                    }
                }
            },
        }
    }

    /// Display text of a row's current value.
    pub fn rowValue(self: *const Settings, row: Row, buf: []u8) []const u8 {
        const d = self.draft;
        return switch (row) {
            .length => if (d.mode == .custom and d.time_limit == 0)
                "whole text"
            else if (d.time_limit > 0)
                std.fmt.bufPrint(buf, "{d}s", .{d.time_limit}) catch "?"
            else
                std.fmt.bufPrint(buf, "{d} words", .{d.word_count}) catch "?",
            .tier => d.tier.name(),
            .punctuation => if (d.punctuation) "on" else "off",
            .numbers => if (d.numbers) "on" else "off",
            .lang => d.lang.name(),
            .kind => d.vim_kind.name(),
            .lesson => currentLesson(d).title(),
            .keys => d.code_keys.name(),
            .syntax => if (d.syntax) "on" else "off",
            .focus => d.focus.name(),
            .text => self.textPreview(buf),
            .pace => switch (d.caret_pace) {
                .off => "off",
                .pb => "personal best",
                .fixed => "fixed",
            },
            .pace_wpm => std.fmt.bufPrint(buf, "{d} wpm", .{d.caret_wpm}) catch "?",
            .stop_on_error => d.stop_on_error.name(),
            .backspace => if (d.no_backspace) "off" else "on",
            .layout => d.layout.name(),
            .sounds => if (d.sounds) "on" else "off",
        };
    }

    /// `text` row: the first ~24 chars and the word count, or a hint.
    fn textPreview(self: *const Settings, buf: []u8) []const u8 {
        const t = self.custom_text;
        if (t.len == 0) return if (self.is_web) "none " ++ glyph.MIDDOT ++ " edit\u{2026}" else "none " ++ glyph.MIDDOT ++ " paste on idle, --text, --file";
        var words: usize = 0;
        var it = std.mem.tokenizeAny(u8, t, " \t\n");
        while (it.next()) |_| words += 1;
        var head: [24]u8 = undefined;
        var n: usize = 0;
        for (t) |c| {
            if (n == head.len) break;
            head[n] = if (c == '\n' or c == '\t') ' ' else c;
            n += 1;
        }
        const more = if (t.len > head.len) "\u{2026}" else "";
        return std.fmt.bufPrint(buf, "{s}{s} ({d} words)", .{ head[0..n], more, words }) catch "?";
    }

    fn moveSelection(self: *Settings, delta: i8) Action {
        switch (self.panel) {
            .theme => {
                self.theme_index = moveIndex(self.theme_index, theme_mod.options().len, delta);
                return .{ .preview_theme = theme_mod.options()[self.theme_index].id };
            },
            .mode => {
                self.mode_index = moveIndex(self.mode_index, MODE_OPTIONS.len, delta);
                self.draft.mode = MODE_OPTIONS[self.mode_index].mode;
                self.row_index = 0;
            },
            .@"test", .options => {
                const rows = self.panelRows(self.panel) orelse return .none;
                self.row_index = moveIndex(self.row_index, rows.len, delta);
            },
        }
        return .none;
    }

    pub fn renderOverlay(
        self: *const Settings,
        r: Renderer,
        palette: *const Theme,
        theme_id: theme_mod.ThemeId,
        current_mode: Mode,
    ) void {
        if (!self.is_open) return;

        const theme_opts = theme_mod.options();
        const list_len: usize = @max(theme_opts.len, MODE_OPTIONS.len);

        const sw = r.width();
        const sh = r.height();
        if (sw < 24 or sh < 6) return;

        // Card size: generous padding when there is room, compact otherwise.
        const w: usize = @min(sw -| 2, MAX_COLUMN_COVER);
        const roomy = sh >= list_len + 12;
        const show_rule = sh >= list_len + 9;
        const show_blurb = sh >= list_len + 8;
        const pad: usize = if (roomy) 1 else 0;
        const test_rows = rowsFor(self.draft);
        const option_rows = optionRowsFor(self.draft, self.is_web);
        // The lower section shows the test rows, or the options while that
        // panel is active; its height fits either so the card stays put.
        const rows = if (self.panel == .options) option_rows else test_rows;
        const lower_rows = @max(test_rows.len, option_rows.len);
        const max_h = if (sh >= 12) sh - 2 else sh;
        // Test panel: a title row plus one row per option (and a gap),
        // dropped when it can't fit next to a one-row list.
        const base_chrome: usize = 2 + 2 * pad + 1 + @as(usize, @intFromBool(show_rule)) + @as(usize, @intFromBool(show_blurb)) + 1 + pad;
        const full_test_h: usize = if (lower_rows > 0) lower_rows + 1 + pad else 0;
        const show_test = full_test_h > 0 and base_chrome + full_test_h + 1 <= max_h;
        const test_h: usize = if (show_test) full_test_h else 0;
        const chrome: usize = base_chrome + test_h;
        const list_h: usize = @max(1, @min(list_len, max_h -| chrome));
        const h: usize = list_h + chrome;
        const x0: usize = (sw -| w) / 2;
        const y0: usize = (sh -| h) / 2;

        drawCard(r, x0, y0, w, h, " settings ", palette);

        const inner_x = x0 + 3;
        const inner_w = w - 6;
        const col_gap: usize = 2;
        const left_w: usize = (inner_w - col_gap) / 2 + 2;
        const right_w: usize = inner_w - col_gap - left_w;
        const right_x = inner_x + left_w + col_gap;

        var y = y0 + 1 + pad;

        // Section titles.
        sectionTitle(r, inner_x + 2, y, "theme", self.panel == .theme, palette);
        sectionTitle(r, right_x + 2, y, "mode", self.panel == .mode, palette);
        y += 1;
        if (show_rule) {
            pen(r, palette.border, null);
            r.moveTo(inner_x + 2, y);
            repeat(r, glyph.box.h, left_w - 2);
            r.moveTo(right_x + 2, y);
            repeat(r, glyph.box.h, right_w - 2);
            r.resetStyle();
            y += 1;
        }

        // Lists (each scrolls independently to keep its selection visible).
        var longest: usize = 0;
        for (theme_opts) |opt| longest = @max(longest, glyph.displayWidth(opt.label));
        const swatches = 4 + longest + 2 + SWATCH_W <= left_w;
        const theme_first = scrollFirst(self.theme_index, theme_opts.len, list_h);
        const mode_first = scrollFirst(self.mode_index, MODE_OPTIONS.len, list_h);
        for (0..list_h) |row| {
            const ti = theme_first + row;
            if (ti < theme_opts.len) {
                const opt = theme_opts[ti];
                drawRow(r, palette, inner_x, y + row, left_w, opt.label, ti == self.theme_index, self.panel == .theme, opt.id == theme_id, if (swatches) theme_mod.resolve(opt.id) else null);
            }
            const mi = mode_first + row;
            if (mi < MODE_OPTIONS.len) {
                const opt = MODE_OPTIONS[mi];
                drawRow(r, palette, right_x, y + row, right_w, opt.label, mi == self.mode_index, self.panel == .mode, opt.mode == current_mode, null);
            }
        }
        y += list_h + pad;

        // Test options of the selected mode.
        if (show_test) {
            const y_rows = y + 1;
            var title_buf: [48]u8 = undefined;
            if (test_rows.len > 0) {
                const title = std.fmt.bufPrint(&title_buf, "test " ++ glyph.MIDDOT ++ " {s}", .{self.draft.mode.name()}) catch "test";
                sectionTitle(r, inner_x + 2, y, title, self.panel == .@"test", palette);
            }
            if (option_rows.len > 0) sectionTitle(r, right_x + 2, y, "options", self.panel == .options, palette);
            y += 1;
            // Narrow cards drop the ‹ › arrows so the value stays readable.
            const label_w: usize = if (inner_w >= 13 + 4 + 12) 13 else 12;
            const arrows = inner_w >= 2 + label_w + 4 + 10;
            const value_w = inner_w -| (label_w + if (arrows) @as(usize, 8) else 2);
            const rows_active = self.panel == .@"test" or self.panel == .options;
            for (rows, 0..) |row, i| {
                const selected = rows_active and i == @min(self.row_index, rows.len - 1);
                r.moveTo(inner_x, y);
                pen(r, if (selected) palette.accent else palette.muted(), null);
                if (selected) r.setBold(true);
                r.write(if (selected) glyph.CHEVRON ++ " " else "  ");
                r.write(row.label());
                repeat(r, " ", label_w -| row.label().len);
                var vbuf: [64]u8 = undefined;
                const v = self.rowValue(row, &vbuf);
                if (arrows) {
                    pen(r, if (selected) palette.dim else palette.border, null);
                    r.write(if (selected) "‹ " else "  ");
                }
                pen(r, if (selected) palette.fg else palette.muted(), null);
                if (selected) r.setBold(true);
                writeClipped(r, v, value_w);
                if (arrows) {
                    pen(r, if (selected) palette.dim else palette.border, null);
                    r.write(if (selected) " ›" else "  ");
                }
                r.resetStyle();
                y += 1;
            }
            y = y_rows + lower_rows + pad;
        }

        // Blurb for the focused selection.
        if (show_blurb) {
            r.moveTo(inner_x + 2, y);
            const sel = MODE_OPTIONS[self.mode_index];
            if (self.panel == .mode) {
                pen(r, palette.dim, null);
                writeClipped(r, sel.blurb, inner_w -| 2);
                if (sel.mode != current_mode and glyph.displayWidth(sel.blurb) + 14 <= inner_w) {
                    pen(r, palette.extra, null);
                    r.write("  (restarts)");
                }
            } else {
                pen(r, palette.dim, null);
                const hint = if (self.currentRow() == .text)
                    (if (self.is_web) "←→ edit the text" else "paste on the idle screen " ++ glyph.MIDDOT ++ " --text " ++ glyph.MIDDOT ++ " --file")
                else if (self.currentRow() == .pace_wpm)
                    "←→ ±5 " ++ glyph.MIDDOT ++ " shift ±1 " ++ glyph.MIDDOT ++ " enter applies"
                else if (self.panel == .@"test" or self.panel == .options)
                    "←→ change " ++ glyph.MIDDOT ++ " enter applies and restarts"
                else
                    "live preview " ++ glyph.MIDDOT ++ " enter keeps it " ++ glyph.MIDDOT ++ " esc reverts";
                writeClipped(r, hint, inner_w -| 2);
            }
            r.resetStyle();
            y += 1;
        }

        // Key help, as long as fits.
        const helps = [_][]const [2][]const u8{
            &.{ .{ "↑↓", "select" }, .{ "←→", "column" }, .{ "tab", "panel" }, .{ "enter", "apply" }, .{ "esc", "cancel" } },
            &.{ .{ "↑↓", "select" }, .{ "←→", "column" }, .{ "enter", "apply" }, .{ "esc", "cancel" } },
            &.{ .{ "↑↓", "select" }, .{ "enter", "apply" }, .{ "esc", "cancel" } },
            &.{ .{ "↑↓", "" }, .{ "←→", "" }, .{ "enter", "" }, .{ "esc", "" } },
        };
        for (helps) |help| {
            var total: usize = 0;
            for (help, 0..) |kv, i| total += glyph.displayWidth(kv[0]) + (if (kv[1].len > 0) 1 + kv[1].len else 0) + (if (i > 0) @as(usize, 3) else 0);
            if (total > inner_w) continue;
            r.moveTo(x0 + (w - total) / 2, y);
            for (help, 0..) |kv, i| {
                if (i > 0) r.write("   ");
                pen(r, palette.muted(), null);
                r.write(kv[0]);
                if (kv[1].len > 0) {
                    pen(r, palette.dim, null);
                    r.write(" ");
                    r.write(kv[1]);
                }
            }
            r.resetStyle();
            break;
        }
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

/// Same test options (theme excluded; drill ids compared by text).
fn sameOptions(a: Config, b: Config) bool {
    const ids_eql = if (a.drill_id) |x| (if (b.drill_id) |y| std.mem.eql(u8, x, y) else false) else b.drill_id == null;
    return a.mode == b.mode and a.word_count == b.word_count and a.time_limit == b.time_limit and
        a.lang == b.lang and a.tier == b.tier and a.punctuation == b.punctuation and
        a.numbers == b.numbers and a.vim_kind == b.vim_kind and ids_eql and
        a.code_keys == b.code_keys and a.caret_pace == b.caret_pace and a.caret_wpm == b.caret_wpm and
        a.stop_on_error == b.stop_on_error and a.no_backspace == b.no_backspace and
        a.layout == b.layout and a.focus == b.focus and a.syntax == b.syntax and a.sounds == b.sounds;
}

/// Index into the combined word/time presets, null for a custom length.
fn lengthIndex(cfg: Config) ?usize {
    if (cfg.time_limit > 0) {
        for (TIME_PRESETS, 0..) |t, i| if (t == cfg.time_limit) return WORD_PRESETS.len + i;
        return null;
    }
    for (WORD_PRESETS, 0..) |w, i| if (w == cfg.word_count) return i;
    return null;
}

fn cycleEnum(comptime E: type, v: E, delta: i8) E {
    const tags = comptime std.meta.tags(E);
    const i = std.mem.indexOfScalar(E, tags, v) orelse 0;
    return tags[moveIndex(i, tags.len, delta)];
}

/// Lesson of the configured drill (the first lesson when unset/unknown).
fn currentLesson(cfg: Config) drill.Lesson {
    if (cfg.drill_id) |id| {
        if (drill.byId(id)) |ch| return ch.lesson;
    }
    return if (drill.all.len > 0) drill.all[0].lesson else std.meta.tags(drill.Lesson)[0];
}

fn firstOfLesson(l: drill.Lesson) ?*const drill.Challenge {
    for (drill.all) |*ch| {
        if (ch.lesson == l) return ch;
    }
    return null;
}

fn moveIndex(index: usize, len: usize, delta: i8) usize {
    if (len == 0) return 0;
    const cur: isize = @intCast(index);
    const d: isize = @intCast(delta);
    const l: isize = @intCast(len);
    const next = @mod(cur + d, l);
    return @intCast(next);
}

/// First visible index so that `sel` stays inside a window of `h` rows.
fn scrollFirst(sel: usize, len: usize, h: usize) usize {
    if (len <= h) return 0;
    return @min(sel -| (h / 2), len - h);
}

fn pen(r: Renderer, fg: ?Color, bg: ?Color) void {
    r.resetStyle();
    if (fg) |c| r.setFg(c);
    if (bg) |c| r.setBg(c);
}

fn repeat(r: Renderer, s: []const u8, n: usize) void {
    for (0..n) |_| r.write(s);
}

/// Write `s`, cut at `max` columns.
fn writeClipped(r: Renderer, s: []const u8, max: usize) void {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (cols >= max) break;
        r.write(s[i..@min(s.len, i + len)]);
        cols += 1;
        i += len;
    }
}

fn sectionTitle(r: Renderer, x: usize, y: usize, label: []const u8, active: bool, palette: *const Theme) void {
    r.moveTo(x, y);
    if (active) {
        pen(r, palette.accent, null);
        r.setBold(true);
    } else {
        pen(r, palette.dim, null);
    }
    r.write(label);
    r.resetStyle();
}

const SWATCH_W: usize = 7;
/// Card width cap: a bit wider than the 70-cell text column it covers.
const MAX_COLUMN_COVER: usize = 74;

/// One list row: "› ● label" with a full-width highlight when selected.
fn drawRow(
    r: Renderer,
    palette: *const Theme,
    x: usize,
    y: usize,
    w: usize,
    label: []const u8,
    selected: bool,
    active: bool,
    current: bool,
    swatch: ?*const Theme,
) void {
    const hl_bg: ?Color = if (selected and active)
        palette.cursor_bg
    else if (selected)
        palette.surface(0.10) orelse palette.visual_bg
    else
        null;
    const text_fg: ?Color = if (selected and active)
        palette.cursor_fg
    else if (selected)
        palette.visual_fg
    else if (current)
        palette.accent
    else
        palette.muted();

    r.moveTo(x, y);
    pen(r, text_fg, hl_bg);
    if (selected and active) r.setBold(true);
    r.write(if (selected and active) glyph.CHEVRON ++ " " else "  ");
    if (current) {
        if (!selected) pen(r, palette.accent, hl_bg);
        r.write(glyph.BULLET ++ " ");
        pen(r, text_fg, hl_bg);
        if (selected and active) r.setBold(true);
    } else {
        r.write("  ");
    }
    const label_max = w -| 4;
    writeClipped(r, label, label_max);
    var used = 4 + @min(glyph.displayWidth(label), label_max);

    // Theme swatch: its accent / success / danger dots on its own background.
    const sw_w = SWATCH_W;
    if (swatch) |th| {
        if (used + 1 + sw_w <= w) {
            repeat(r, " ", w - used - sw_w);
            const sbg: ?Color = if (th.use_terminal_defaults) hl_bg else th.bg;
            pen(r, null, sbg);
            r.write(" ");
            for ([_]Color{ th.accent, th.success, th.danger }) |c| {
                pen(r, c, sbg);
                r.write(glyph.BULLET ++ " ");
            }
            used = w;
        }
    }
    if (used < w) {
        pen(r, null, hl_bg);
        repeat(r, " ", w - used);
    }
    r.resetStyle();
}

/// Rounded, opaque card with a title in the top border.
fn drawCard(r: Renderer, x0: usize, y0: usize, w: usize, h: usize, title: []const u8, palette: *const Theme) void {
    if (w < 4 or h < 2) return;
    const inner = w - 2;

    r.moveTo(x0, y0);
    pen(r, palette.border, null);
    r.write(glyph.box.tl ++ glyph.box.h);
    pen(r, palette.accent, null);
    r.setBold(true);
    r.write(title);
    pen(r, palette.border, null);
    repeat(r, glyph.box.h, inner -| (1 + glyph.displayWidth(title)));
    r.write(glyph.box.tr);

    for (1..(h - 1)) |dy| {
        r.moveTo(x0, y0 + dy);
        pen(r, palette.border, null);
        r.write(glyph.box.v);
        r.resetStyle();
        repeat(r, " ", inner);
        pen(r, palette.border, null);
        r.write(glyph.box.v);
    }

    r.moveTo(x0, y0 + h - 1);
    pen(r, palette.border, null);
    r.write(glyph.box.bl);
    repeat(r, glyph.box.h, inner);
    r.write(glyph.box.br);
    r.resetStyle();
}

test "mode options include every mode exactly once" {
    inline for (comptime std.meta.tags(Mode)) |mode| {
        var count: usize = 0;
        for (MODE_OPTIONS) |opt| {
            if (opt.mode == mode) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "enter on a different mode applies it" {
    var s = Settings{};
    s.open(.system, .words);
    _ = s.handleKey(.{ .Byte = '\t' });
    var last: Action = .none;
    for (0..MODE_OPTIONS.len - 1) |_| last = s.handleKey(.ArrowDown);
    try std.testing.expect(last == .none);
    const a = s.handleKey(.{ .Byte = '\r' });
    try std.testing.expect(a == .apply_mode);
    try std.testing.expectEqual(MODE_OPTIONS[MODE_OPTIONS.len - 1].mode, a.apply_mode);
    try std.testing.expect(!s.is_open);
}

test "test panel: rows per mode, values step, enter applies a config" {
    var s = Settings{};
    s.base = .{ .mode = .words, .word_count = 10 };
    s.open(.system, .words);
    try std.testing.expectEqual(@as(usize, 5), rowsFor(s.draft).len);
    _ = s.handleKey(.{ .Byte = '\t' });
    _ = s.handleKey(.{ .Byte = '\t' });
    try std.testing.expectEqual(Panel.@"test", s.panel);
    // length: 10 words → 25 words; down to tier: common → 5k.
    _ = s.handleKey(.ArrowRight);
    try std.testing.expectEqual(@as(usize, 25), s.draft.word_count);
    _ = s.handleKey(.ArrowDown);
    _ = s.handleKey(.ArrowRight);
    try std.testing.expectEqual(types.WordTier.k5, s.draft.tier);
    _ = s.handleKey(.ArrowDown);
    _ = s.handleKey(.{ .Byte = 'l' });
    try std.testing.expect(s.draft.punctuation);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("25 words", s.rowValue(.length, &buf));
    const a = s.handleKey(.{ .Byte = '\r' });
    try std.testing.expect(a == .apply_config);
    try std.testing.expectEqual(@as(usize, 25), a.apply_config.word_count);
    try std.testing.expect(a.apply_config.punctuation);

    // Length wraps from 100 words into the time presets.
    var t = Settings{};
    t.base = .{ .word_count = 100 };
    t.open(.system, .words);
    t.changeValue(.length, 1);
    try std.testing.expectEqual(@as(usize, 15), t.draft.time_limit);
    t.changeValue(.length, -1);
    try std.testing.expectEqual(@as(usize, 0), t.draft.time_limit);

    // Vim rows follow the kind; unchanged options close without applying.
    try std.testing.expectEqual(@as(usize, 2), rowsFor(.{ .mode = .vim }).len);
    try std.testing.expectEqual(Row.lang, rowsFor(.{ .mode = .vim, .vim_kind = .type })[1]);
    var u = Settings{};
    u.open(.system, .words);
    try std.testing.expect(u.handleKey(.{ .Byte = '\r' }) == .close);
}

test "lesson row picks the first challenge of the next lesson" {
    // Needs challenges in at least two lessons.
    if (drill.all.len == 0 or drill.all[0].lesson == drill.all[drill.all.len - 1].lesson) return error.SkipZigTest;
    var s = Settings{};
    s.base = .{ .mode = .vim };
    s.open(.system, .vim);
    const first = currentLesson(s.draft);
    s.changeValue(.lesson, 1);
    const id = s.draft.drill_id orelse return error.TestUnexpectedResult;
    const ch = drill.byId(id).?;
    try std.testing.expect(ch.lesson != first);
    try std.testing.expectEqual(ch, firstOfLesson(ch.lesson).?);
}

test "scroll window keeps the selection visible" {
    try std.testing.expectEqual(@as(usize, 0), scrollFirst(3, 5, 6));
    try std.testing.expectEqual(@as(usize, 2), scrollFirst(6, 7, 5));
    try std.testing.expectEqual(@as(usize, 0), scrollFirst(1, 7, 5));
}

test "round 2: code keys hide the length, options panel rows and values" {
    try std.testing.expectEqual(@as(usize, 4), rowsFor(.{ .mode = .code }).len);
    const cv = rowsFor(.{ .mode = .code, .code_keys = .vim });
    try std.testing.expectEqual(@as(usize, 3), cv.len);
    try std.testing.expect(std.mem.indexOfScalar(Row, cv, .length) == null);
    try std.testing.expectEqual(@as(usize, 0), rowsFor(.{ .mode = .zen }).len);
    try std.testing.expectEqual(@as(usize, 0), rowsFor(.{ .mode = .daily }).len);
    try std.testing.expectEqual(Row.text, rowsFor(.{ .mode = .custom })[1]);
    try std.testing.expectEqual(Row.focus, rowsFor(.{ .mode = .words })[4]);
    // Sounds only on the web, pace wpm only when fixed, nothing in arcade.
    try std.testing.expect(std.mem.indexOfScalar(Row, optionRowsFor(.{}, false), .sounds) == null);
    try std.testing.expect(std.mem.indexOfScalar(Row, optionRowsFor(.{}, true), .sounds) != null);
    try std.testing.expect(std.mem.indexOfScalar(Row, optionRowsFor(.{}, false), .pace_wpm) == null);
    try std.testing.expect(std.mem.indexOfScalar(Row, optionRowsFor(.{ .caret_pace = .fixed }, false), .pace_wpm) != null);
    try std.testing.expectEqual(@as(usize, 0), optionRowsFor(.{ .mode = .arcade }, true).len);

    // Tab reaches the options panel; values change and apply.
    var s = Settings{};
    s.base = .{ .mode = .words };
    s.open(.system, .words);
    for (0..3) |_| _ = s.handleKey(.{ .Byte = '\t' });
    try std.testing.expectEqual(Panel.options, s.panel);
    _ = s.handleKey(.ArrowRight); // pace: pb → fixed
    try std.testing.expectEqual(types.CaretPace.fixed, s.draft.caret_pace);
    _ = s.handleKey(.ArrowDown); // pace wpm
    _ = s.handleKey(.ArrowRight);
    try std.testing.expectEqual(@as(u16, 85), s.draft.caret_wpm);
    _ = s.handleKey(.ShiftArrowLeft);
    try std.testing.expectEqual(@as(u16, 84), s.draft.caret_wpm);
    _ = s.handleKey(.ArrowDown); // stop on error
    _ = s.handleKey(.ArrowRight);
    try std.testing.expectEqual(types.StopOnError.letter, s.draft.stop_on_error);
    _ = s.handleKey(.ArrowDown); // backspace
    _ = s.handleKey(.ArrowRight);
    try std.testing.expect(s.draft.no_backspace);
    _ = s.handleKey(.ArrowDown); // layout
    _ = s.handleKey(.ArrowRight);
    try std.testing.expectEqual(types.Layout.dvorak, s.draft.layout);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("off", s.rowValue(.backspace, &buf));
    const a = s.handleKey(.{ .Byte = '\r' });
    try std.testing.expect(a == .apply_config);
    try std.testing.expectEqual(types.Layout.dvorak, a.apply_config.layout);
    try std.testing.expectEqual(@as(u16, 84), a.apply_config.caret_wpm);
    // Wraps back to the theme panel; zen skips the empty test panel.
    var z = Settings{};
    z.base = .{ .mode = .zen };
    z.open(.system, .zen);
    _ = z.handleKey(.{ .Byte = '\t' });
    _ = z.handleKey(.{ .Byte = '\t' });
    try std.testing.expectEqual(Panel.options, z.panel);
    _ = z.handleKey(.{ .Byte = '\t' });
    try std.testing.expectEqual(Panel.theme, z.panel);
}

test "round 2: custom length and text row" {
    var s = Settings{};
    s.base = .{ .mode = .custom };
    s.custom_text = "hello brave\nnew world";
    s.open(.system, .custom);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("whole text", s.rowValue(.length, &buf));
    s.changeValue(.length, 1);
    try std.testing.expectEqual(@as(usize, 15), s.draft.time_limit);
    s.changeValue(.length, -1);
    try std.testing.expectEqual(@as(usize, 0), s.draft.time_limit);
    try std.testing.expectEqualStrings("hello brave new world (4 words)", s.rowValue(.text, &buf));
    // Natively the row is read-only; on the web it asks for the dialog.
    _ = s.handleKey(.{ .Byte = '\t' });
    _ = s.handleKey(.{ .Byte = '\t' });
    _ = s.handleKey(.ArrowDown);
    try std.testing.expectEqual(Row.text, s.currentRow().?);
    try std.testing.expect(s.handleKey(.ArrowRight) == .none);
    s.is_web = true;
    try std.testing.expect(s.handleKey(.ArrowRight) == .edit_custom_text);
    try std.testing.expect(!s.is_open);
}

test "round 2: overlay fits 80x24 with every mode" {
    const CellRenderer = @import("../platform/cell_renderer.zig").CellRenderer;
    var cr = try CellRenderer.init(std.testing.allocator, 80, 24);
    defer cr.deinit();
    for (std.meta.tags(Mode)) |m| {
        var s = Settings{ .is_web = true };
        s.base = .{ .mode = m, .caret_pace = .fixed };
        s.open(.system, m);
        s.panel = .options;
        s.renderOverlay(cr.renderer(), theme_mod.resolve(.one_dark), .one_dark, m);
    }
}
