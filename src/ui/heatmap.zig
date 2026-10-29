//! Per-key heatmap: a compact keyboard (number, top, home and bottom rows of
//! the active layout, one cell per key, staggered one column per row) with
//! each key coloured by accuracy (success → warning → danger, unused keys
//! dimmer), plus the "slowest" and "most missed" key lists.
//!
//! Used by the results card (this run's `Result.per_key`) and the history
//! screen's keys tab (`Log.perKey()` over all runs). The stats are `anytype`:
//! anything with `get(c) ?KeyStat` where a KeyStat has `hits`, `misses`,
//! `ms_sum` and `timed` (contract C3).

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const Color = @import("color.zig").Color;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const pen = draw.pen;
const Renderer = @import("../platform/renderer.zig").Renderer;
const types = @import("../core/types.zig");
const layout = @import("../core/layout.zig");

/// Rows a keyboard takes.
pub const ROWS: usize = 4;
/// Columns per key ("k ").
const KEY_W: usize = 2;
/// A key needs this many timed hits to count as slow.
pub const MIN_TIMED: u32 = 3;

// ============================================================================
// Layouts
// ============================================================================

/// The heatmap rows for a config: its layout's unshifted rows (number,
/// top, home, bottom).
pub fn rowsForConfig(cfg: types.Config) [4][]const u8 {
    return layout.rows(cfg.layout);
}

// ============================================================================
// Stats
// ============================================================================

pub const KeyInfo = struct {
    key: u8,
    hits: u32,
    misses: u32,
    /// Average ms per correct hit (0 when untimed).
    avg_ms: f32,
    timed: u32,

    /// 0..1, null when the key was never expected.
    pub fn accuracy(self: KeyInfo) ?f32 {
        if (self.hits == 0) return null;
        return 1 - @as(f32, @floatFromInt(@min(self.misses, self.hits))) / @as(f32, @floatFromInt(self.hits));
    }

    pub fn missRate(self: KeyInfo) f32 {
        return 1 - (self.accuracy() orelse 1);
    }
};

/// Stats of key `c` (null when it has no data).
pub fn info(per_key: anytype, c: u8) ?KeyInfo {
    const s = per_key.get(c) orelse return null;
    if (s.hits == 0 and s.timed == 0) return null;
    return .{
        .key = c,
        .hits = s.hits,
        .misses = s.misses,
        .timed = s.timed,
        .avg_ms = if (s.timed > 0) @as(f32, @floatFromInt(s.ms_sum)) / @as(f32, @floatFromInt(s.timed)) else 0,
    };
}

/// Accuracy colour: success at ≥ 98%, through warning at 92%, to danger at
/// ≤ 85%; unused keys are `dimmer`.
pub fn keyColor(theme: *const Theme, ki: ?KeyInfo) Color {
    const acc = (ki orelse return theme.dimmer).accuracy() orelse return theme.dimmer;
    if (acc >= 0.98) return theme.success;
    if (acc >= 0.92) return theme.warning.mix(theme.success, (acc - 0.92) / 0.06);
    if (acc > 0.85) return theme.danger.mix(theme.warning, (acc - 0.85) / 0.07);
    return theme.danger;
}

/// Every key of `rows` with data, at most `out.len`.
fn collect(per_key: anytype, rows: [4][]const u8, out: []KeyInfo) []KeyInfo {
    var n: usize = 0;
    for (rows) |row| {
        for (row) |c| {
            if (n == out.len) break;
            if (info(per_key, c)) |ki| {
                out[n] = ki;
                n += 1;
            }
        }
    }
    return out[0..n];
}

/// Up to `out.len` keys with at least `MIN_TIMED` timed hits, slowest first.
pub fn slowest(per_key: anytype, rows: [4][]const u8, out: []KeyInfo) []KeyInfo {
    var all: [64]KeyInfo = undefined;
    var n: usize = 0;
    for (collect(per_key, rows, &all)) |ki| {
        if (ki.timed < MIN_TIMED) continue;
        all[n] = ki;
        n += 1;
    }
    std.sort.pdq(KeyInfo, all[0..n], {}, struct {
        fn lt(_: void, a: KeyInfo, b: KeyInfo) bool {
            return a.avg_ms > b.avg_ms or (a.avg_ms == b.avg_ms and a.key < b.key);
        }
    }.lt);
    const k = @min(n, out.len);
    @memcpy(out[0..k], all[0..k]);
    return out[0..k];
}

/// Up to `out.len` keys with misses, highest miss rate first.
pub fn mostMissed(per_key: anytype, rows: [4][]const u8, out: []KeyInfo) []KeyInfo {
    var all: [64]KeyInfo = undefined;
    var n: usize = 0;
    for (collect(per_key, rows, &all)) |ki| {
        if (ki.misses == 0) continue;
        all[n] = ki;
        n += 1;
    }
    std.sort.pdq(KeyInfo, all[0..n], {}, struct {
        fn lt(_: void, a: KeyInfo, b: KeyInfo) bool {
            const ra = a.missRate();
            const rb = b.missRate();
            return ra > rb or (ra == rb and (a.misses > b.misses or (a.misses == b.misses and a.key < b.key)));
        }
    }.lt);
    const k = @min(n, out.len);
    @memcpy(out[0..k], all[0..k]);
    return out[0..k];
}

/// True when any key of `rows` has data.
pub fn hasData(per_key: anytype, rows: [4][]const u8) bool {
    var one: [1]KeyInfo = undefined;
    return collect(per_key, rows, &one).len > 0;
}

// ============================================================================
// Drawing
// ============================================================================

/// Columns the keyboard takes (rows are staggered one column each).
pub fn keyboardWidth(rows: [4][]const u8) usize {
    var w: usize = 0;
    for (rows, 0..) |row, i| w = @max(w, i + row.len * KEY_W - 1);
    return w;
}

/// The keyboard at (`x`, `y`), clipped to `max_w` columns; slow keys
/// (in `slow`) are underlined.
pub fn renderKeyboard(r: Renderer, theme: *const Theme, x: usize, y: usize, max_w: usize, per_key: anytype, rows: [4][]const u8, slow: []const KeyInfo) void {
    for (rows, 0..) |row, i| {
        if (i >= max_w) break;
        r.moveTo(x + i, y + i);
        var used: usize = i;
        for (row, 0..) |c, j| {
            if (used + 1 > max_w) break;
            if (j > 0) {
                r.resetStyle();
                r.write(" ");
            }
            const ki = info(per_key, c);
            pen(r, keyColor(theme, ki), null, ki != null and ki.?.misses > 0);
            for (slow) |s| {
                if (s.key == c) draw.underline(r, true);
            }
            r.writeByte(c);
            used += KEY_W;
        }
        r.resetStyle();
    }
}

/// `label  k 210ms · j 190ms …` (or miss percentages) clipped to `max_w`.
pub fn renderList(r: Renderer, theme: *const Theme, x: usize, y: usize, max_w: usize, label: []const u8, keys: []const KeyInfo, comptime what: enum { ms, missed }) void {
    r.moveTo(x, y);
    pen(r, theme.dim, null, false);
    var used = draw.writeClip(r, label, max_w);
    if (keys.len == 0) {
        pen(r, theme.dimmer, null, false);
        _ = draw.writeClip(r, "  -", max_w -| used);
        r.resetStyle();
        return;
    }
    for (keys, 0..) |ki, i| {
        var buf: [24]u8 = undefined;
        const val = switch (what) {
            .ms => draw.fmt(&buf, " {d:.0}ms", .{ki.avg_ms}),
            .missed => draw.fmt(&buf, " {d:.0}%", .{ki.missRate() * 100}),
        };
        const sep: usize = if (i == 0) 2 else 3;
        if (used + sep + 1 + val.len > max_w) break;
        pen(r, theme.dimmer, null, false);
        r.write(if (i == 0) "  " else " " ++ glyph.MIDDOT ++ " ");
        pen(r, if (what == .missed) theme.danger else theme.text(), null, true);
        r.writeByte(ki.key);
        pen(r, theme.dimmer, null, false);
        r.write(val);
        used += sep + 1 + val.len;
    }
    r.resetStyle();
}

/// Width of the lists beside the keyboard.
pub const LIST_W: usize = 24;

/// How the keyboard and its lists fit in `w` columns: lists beside the
/// keyboard (4 rows), below it (6 rows), or not at all.
pub const Fit = enum { side, below, keyboard_only };

pub fn fit(rows: [4][]const u8, w: usize) ?Fit {
    const kw = keyboardWidth(rows);
    if (w >= kw + 4 + LIST_W) return .side;
    if (w >= LIST_W and w >= kw) return .below;
    if (w >= kw) return .keyboard_only;
    return null;
}

pub fn height(f: Fit) usize {
    return switch (f) {
        .side, .keyboard_only => ROWS,
        .below => ROWS + 2,
    };
}

/// The keyboard and its lists in (`x`, `y`, `w`) laid out as `f`.
pub fn render(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, f: Fit, per_key: anytype, rows: [4][]const u8) void {
    var slow_buf: [5]KeyInfo = undefined;
    var miss_buf: [5]KeyInfo = undefined;
    const slow = slowest(per_key, rows, &slow_buf);
    const missed = mostMissed(per_key, rows, &miss_buf);
    const kw = keyboardWidth(rows);
    renderKeyboard(r, theme, x, y, w, per_key, rows, slow[0..@min(slow.len, 3)]);
    switch (f) {
        .side => {
            const lx = x + kw + 4;
            const lw = w -| (kw + 4);
            renderList(r, theme, lx, y + 1, lw, "slowest", slow, .ms);
            renderList(r, theme, lx, y + 2, lw, "missed ", missed, .missed);
        },
        .below => {
            renderList(r, theme, x, y + ROWS, w, "slowest", slow, .ms);
            renderList(r, theme, x, y + ROWS + 1, w, "missed ", missed, .missed);
        },
        .keyboard_only => {},
    }
}

test "layout rows" {
    try std.testing.expectEqualStrings("aoeuidhtns-", rowsForConfig(.{ .layout = .dvorak })[2]);
    try std.testing.expectEqualStrings("asdfghjkl;'", rowsForConfig(.{})[2]);
    try std.testing.expectEqual(@as(usize, 26), keyboardWidth(rowsForConfig(.{})));
}
