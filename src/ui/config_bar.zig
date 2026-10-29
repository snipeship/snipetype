//! Idle config bar: one centered line describing the next test, shown while
//! waiting for the first key, e.g.
//! `words · common · 25 │ punctuation · numbers │ best 87 wpm   ctrl+p to change`
//! or `code · rust · 31 words │ plain keys   ctrl+p to change`. A practice
//! run (missed words, weak keys) says so instead of the configured test:
//! `practice · weak keys · 30 words │ not recorded`.
//! Display only; the App handles keys (Ctrl+P opens the settings, Ctrl+K
//! switches code between plain and vim keys).

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const Color = @import("color.zig").Color;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const query = @import("query.zig");
const Renderer = @import("../platform/renderer.zig").Renderer;
const Config = @import("../core/types.zig").Config;
const UiState = @import("ui_state.zig").UiState;

const Tone = enum { value, on, off, label };

const Item = struct { text: []const u8, tone: Tone };

const Group = struct {
    items: [5]Item = undefined,
    len: usize = 0,
    /// Drop order: the highest rank goes first when the bar doesn't fit;
    /// rank 0 (the test's shape) always stays.
    rank: u8 = 0,

    fn add(self: *Group, text: []const u8, tone: Tone) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = .{ .text = text, .tone = tone };
        self.len += 1;
    }

    fn width(self: *const Group) usize {
        var w: usize = 0;
        for (self.items[0..self.len], 0..) |it, i| w += glyph.displayWidth(it.text) + (if (i > 0) @as(usize, 3) else 0);
        return w;
    }
};

/// Drop ranks: the "ctrl+p" hint goes first, then best, toggles, strict
/// chips and finally the code keys.
const RANK_KEYS: u8 = 1;
const RANK_STRICT: u8 = 2;
const RANK_TOGGLES: u8 = 3;
const RANK_BEST: u8 = 4;

const HINT = "ctrl+p to change";
const SEP = " " ++ glyph.box.v ++ " ";

/// What the bar can't read from the config.
pub const Info = struct {
    /// Words in the generated text (code, custom); null shows the
    /// configured count.
    words: ?usize = null,
    /// What a practice run drills ("missed words", "weak keys"); null for
    /// a normal test.
    practice: ?[]const u8 = null,
};

pub const Bar = struct {
    groups: [6]Group = @splat(.{}),
    n: usize = 0,
    bufs: [3][24]u8 = undefined,
    day_buf: [10]u8 = undefined,

    fn push(self: *Bar, g: Group) void {
        if (g.len == 0) return;
        self.groups[self.n] = g;
        self.n += 1;
    }
};

/// Length of the test: "30s" when timed, else the word count ("25", or
/// "31 words" for generated text).
fn addLength(bar: *Bar, g: *Group, cfg: Config, info: Info, generated: bool) void {
    if (cfg.time_limit > 0) {
        g.add(draw.fmt(&bar.bufs[0], "{d}s", .{cfg.time_limit}), .value);
    } else if (generated and info.words != null) {
        g.add(draw.fmt(&bar.bufs[0], "{d} words", .{info.words.?}), .value);
    } else {
        g.add(draw.fmt(&bar.bufs[0], "{d}", .{cfg.word_count}), .value);
    }
}

/// The bar's groups for `cfg`: test shape, code keys, toggles (words),
/// strict chips, best.
pub fn build(bar: *Bar, cfg: Config, ui: *const UiState, info: Info) void {
    bar.* = .{};
    var shape: Group = .{};
    const code_vim = cfg.mode == .code and query.cfgIs(cfg, "code_keys", "vim");
    if (info.practice) |what| {
        // Its own word list: the configured length, toggles, code keys and
        // best don't describe it, and the run is never recorded.
        shape.add("practice", .on);
        shape.add(what, .value);
        if (info.words) |n| shape.add(draw.fmt(&bar.bufs[0], "{d} words", .{n}), .value);
        bar.push(shape);
        bar.push(strictGroup(cfg, false));
        var note: Group = .{ .rank = RANK_BEST };
        note.add("not recorded", .label);
        bar.push(note);
        return;
    }
    if (cfg.mode == .vim) {
        shape.add("vim", .value);
        shape.add(cfg.vim_kind.name(), .value);
        if (cfg.vim_kind == .type) shape.add(cfg.lang.name(), .value);
    } else if (query.dailyDate(cfg, &bar.day_buf)) |day| {
        shape.add(cfg.mode.name(), .value);
        shape.add(day, .value);
    } else if (query.is(cfg.mode, "zen")) {
        shape.add(cfg.mode.name(), .value);
    } else {
        shape.add(cfg.mode.name(), .value);
        if (cfg.mode == .words) shape.add(cfg.tier.name(), .value);
        if (cfg.mode == .code) shape.add(cfg.lang.name(), .value);
        if (!code_vim) addLength(bar, &shape, cfg, info, cfg.mode == .code or query.is(cfg.mode, "custom"));
    }
    bar.push(shape);

    if (cfg.mode == .code) {
        var keys: Group = .{ .rank = RANK_KEYS };
        keys.add(if (code_vim) "vim keys" else "plain keys", if (code_vim) .on else .label);
        bar.push(keys);
    }

    if (cfg.mode == .words) {
        var toggles: Group = .{ .rank = RANK_TOGGLES };
        toggles.add("punctuation", if (cfg.punctuation) .on else .off);
        toggles.add("numbers", if (cfg.numbers) .on else .off);
        bar.push(toggles);
    }

    // Strict policies, layout emulation and weak-key focus (simple modes).
    if (cfg.mode != .vim and !code_vim) bar.push(strictGroup(cfg, cfg.mode == .words));

    if (ui.best_wpm) |best| {
        var g: Group = .{ .rank = RANK_BEST };
        const daily = query.is(cfg.mode, "daily");
        g.add(draw.fmt(&bar.bufs[1], "{s}best {d:.0} wpm", .{ if (daily) "daily " else "", best }), .label);
        bar.push(g);
    }
}

/// Strict policies and layout emulation; `focus` adds the weak-key focus.
fn strictGroup(cfg: Config, focus: bool) Group {
    var strict: Group = .{ .rank = RANK_STRICT };
    if (query.cfgIs(cfg, "stop_on_error", "letter")) strict.add("stop on letter", .on);
    if (query.cfgIs(cfg, "stop_on_error", "word")) strict.add("stop on word", .on);
    if (query.cfgBool(cfg, "no_backspace", false)) strict.add("no backspace", .on);
    if (comptime @hasField(Config, "layout")) {
        if (cfg.layout != .qwerty) strict.add(cfg.layout.name(), .on);
    }
    if (focus and query.cfgIs(cfg, "focus", "weak")) strict.add("weak keys", .on);
    return strict;
}

fn barWidth(bar: *const Bar, max_rank: u8) usize {
    var w: usize = 0;
    var shown: usize = 0;
    for (bar.groups[0..bar.n]) |*g| {
        if (g.rank > max_rank) continue;
        w += g.width() + (if (shown > 0) @as(usize, 3) else 0);
        shown += 1;
    }
    return w;
}

fn toneColor(theme: *const Theme, tone: Tone) ?Color {
    return switch (tone) {
        .value => theme.text(),
        .on => theme.accent,
        .off => theme.dim,
        .label => theme.dim,
    };
}

/// Draw the bar centered in [x, x + w) on row `y` (configured word count).
pub fn render(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, cfg: Config, ui: *const UiState) void {
    renderInfo(r, theme, x, y, w, cfg, ui, .{});
}

/// Draw the bar centered in [x, x + w) on row `y`. Drops, in order: the
/// "ctrl+p" hint, the best group, the toggles, the strict chips, the keys.
pub fn renderInfo(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, cfg: Config, ui: *const UiState, info: Info) void {
    var bar: Bar = undefined;
    build(&bar, cfg, ui, info);
    var max_rank: u8 = RANK_BEST;
    var hint = true;
    while (true) {
        const total = barWidth(&bar, max_rank) + (if (hint) 3 + HINT.len else 0);
        if (total <= w or (max_rank == 0 and !hint)) {
            const used = @min(total, w);
            r.moveTo(x + (w - used) / 2, y);
            var left = w;
            var shown: usize = 0;
            for (bar.groups[0..bar.n]) |*g| {
                if (g.rank > max_rank) continue;
                if (shown > 0) {
                    draw.pen(r, theme.dimmer, null, false);
                    left -|= draw.writeClip(r, SEP, left);
                }
                shown += 1;
                for (g.items[0..g.len], 0..) |it, i| {
                    if (i > 0) {
                        draw.pen(r, theme.dimmer, null, false);
                        left -|= draw.writeClip(r, " " ++ glyph.MIDDOT ++ " ", left);
                    }
                    draw.pen(r, toneColor(theme, it.tone), null, false);
                    left -|= draw.writeClip(r, it.text, left);
                }
            }
            if (hint) {
                draw.pen(r, theme.dimmer, null, false);
                left -|= draw.writeClip(r, "   " ++ HINT, left);
            }
            r.resetStyle();
            return;
        }
        if (hint) hint = false else max_rank -= 1;
    }
}

test "bar contents" {
    var bar: Bar = undefined;
    const ui: UiState = .{ .best_wpm = 87.4 };
    build(&bar, .{ .mode = .words, .word_count = 25, .punctuation = true }, &ui, .{});
    try std.testing.expectEqual(@as(usize, 3), bar.n);
    try std.testing.expectEqualStrings("common", bar.groups[0].items[1].text);
    try std.testing.expectEqualStrings("25", bar.groups[0].items[2].text);
    try std.testing.expectEqual(Tone.on, bar.groups[1].items[0].tone);
    try std.testing.expectEqual(Tone.off, bar.groups[1].items[1].tone);
    try std.testing.expectEqualStrings("best 87 wpm", bar.groups[2].items[0].text);
}

test "code shows the generated word count and the keys" {
    var bar: Bar = undefined;
    build(&bar, .{ .mode = .code, .lang = .rust, .word_count = 25 }, &.{}, .{ .words = 31 });
    try std.testing.expectEqualStrings("31 words", bar.groups[0].items[2].text);
    try std.testing.expectEqualStrings("plain keys", bar.groups[1].items[0].text);
}
