//! Results card for a finished test, drawn only from `TypingTest.result()`
//! (contract 3): big WPM digits, acc / raw / consistency / time, the PB
//! banner, the letter counts, a WPM-and-raw graph with error marks, missed
//! and slow words, and a quote's author. Vim `.type` results show
//! keystrokes and efficiency instead of raw and letter counts.
//!
//! Everything degrades with the space: the graph goes first, then the word
//! lists, then the letter counts, then the big digits; under 30x5 it is a
//! single summary line.
//!
//! `res` is `anytype` (a `*const stats.Result` or a test fixture with the
//! same fields).

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const Color = @import("color.zig").Color;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const pen = draw.pen;
const fmt = draw.fmt;
const Renderer = @import("../platform/renderer.zig").Renderer;
const Config = @import("../core/types.zig").Config;
const UiState = @import("ui_state.zig").UiState;
const font = @import("../fx/font.zig");
const anim = @import("anim.zig");
const heatmap = @import("heatmap.zig");
const query = @import("query.zig");

// ============================================================================
// Big digits
// ============================================================================

/// Three-row half-block digits (3x6 "pixels").
const BIG_DIGITS = [10][3][]const u8{
    .{ "█▀█", "█ █", "▀▀▀" },
    .{ "▀█ ", " █ ", "▀▀▀" },
    .{ "▀▀█", "█▀▀", "▀▀▀" },
    .{ "▀▀█", " ▀█", "▀▀▀" },
    .{ "█ █", "▀▀█", "  ▀" },
    .{ "█▀▀", "▀▀█", "▀▀▀" },
    .{ "█▀▀", "█▀█", "▀▀▀" },
    .{ "▀▀█", "  █", "  ▀" },
    .{ "█▀█", "█▀█", "▀▀▀" },
    .{ "█▀█", "▀▀█", "▀▀▀" },
};

pub const BigSize = enum {
    /// One line of plain text.
    none,
    /// 3 rows, 3 columns per digit.
    small,
    /// 4 rows: the arcade's 5x7 pixel font as half blocks.
    large,

    pub fn rows(self: BigSize) usize {
        return switch (self) {
            .none => 1,
            .small => 3,
            .large => 4,
        };
    }

    pub fn width(self: BigSize, digits: usize) usize {
        if (digits == 0) return 0;
        return switch (self) {
            .none => digits,
            .small => digits * 4 - 1,
            .large => digits * (font.glyph_w + 1) - 1,
        };
    }
};

pub fn renderBig(r: Renderer, x: usize, y: usize, digits: []const u8, size: BigSize) void {
    switch (size) {
        .none => {
            r.moveTo(x, y);
            r.write(digits);
        },
        .small => for (0..3) |row| {
            r.moveTo(x, y + row);
            for (digits, 0..) |d, i| {
                if (i > 0) r.write(" ");
                r.write(if (d == ' ') "   " else BIG_DIGITS[d - '0'][row]);
            }
        },
        .large => for (0..4) |row| {
            r.moveTo(x, y + row);
            for (digits, 0..) |d, i| {
                if (i > 0) r.write(" ");
                if (d == ' ') {
                    draw.repeat(r, " ", font.glyph_w);
                    continue;
                }
                const g = font.glyph(d);
                for (0..font.glyph_w) |col| {
                    const top = g.lit(col, row * 2);
                    const bot = row * 2 + 1 < font.cap_h and g.lit(col, row * 2 + 1);
                    r.write(if (top and bot) "█" else if (top) "▀" else if (bot) "▄" else " ");
                }
            }
        },
    }
}

// ============================================================================
// Stats
// ============================================================================

const Stat = struct {
    label: []const u8,
    value: []const u8,
    color: ?Color,
};

fn statsWidth(stats: []const Stat) usize {
    var lw: usize = 0;
    var vw: usize = 0;
    for (stats) |s| {
        lw = @max(lw, s.label.len);
        vw = @max(vw, s.value.len);
    }
    return lw + 1 + vw;
}

fn renderStatColumn(r: Renderer, theme: *const Theme, x: usize, y: usize, stats: []const Stat) void {
    var lw: usize = 0;
    for (stats) |s| lw = @max(lw, s.label.len);
    for (stats, 0..) |s, i| {
        r.moveTo(x, y + i);
        pen(r, theme.dim, null, false);
        r.write(s.label);
        draw.repeat(r, " ", lw - s.label.len + 1);
        pen(r, s.color orelse theme.text(), null, true);
        r.write(s.value);
    }
    r.resetStyle();
}

/// "label value   label value ..." on one row, as many as fit in `max_w`.
fn renderStatLine(r: Renderer, theme: *const Theme, x: usize, y: usize, max_w: usize, stats: []const Stat) void {
    r.moveTo(x, y);
    var used: usize = 0;
    for (stats, 0..) |s, i| {
        const need = (if (i > 0) @as(usize, 3) else 0) + s.label.len + 1 + s.value.len;
        if (used + need > max_w) break;
        if (i > 0) r.write("   ");
        pen(r, theme.dim, null, false);
        r.write(s.label);
        r.write(" ");
        pen(r, s.color orelse theme.text(), null, true);
        r.write(s.value);
        used += need;
    }
    r.resetStyle();
}

// ============================================================================
// Graph
// ============================================================================

const GRAPH_MAX_COLS: usize = 120;
const GRAPH_MAX_ROWS: usize = 8;

const Grid = [GRAPH_MAX_ROWS][GRAPH_MAX_COLS]u8;

/// Plot `ys[i]` at time `ts[i]` as a 2-dot-thick braille line into `cells`.
fn plotLine(cells: *Grid, cols: usize, rows: usize, ts: []const f32, ys: []const f32, t_max: f32, y_max: f32) void {
    if (ts.len == 0) return;
    const pw: f32 = @floatFromInt(cols * 2 - 1);
    const ph: f32 = @floatFromInt(rows * 4 - 1);
    const Px = struct { x: i32, y: i32 };
    var prev: Px = undefined;
    for (ts, ys, 0..) |t, v, i| {
        const cur: Px = .{
            .x = @intFromFloat(@round(std.math.clamp(t / t_max, 0, 1) * pw)),
            .y = @intFromFloat(@round((1 - std.math.clamp(v / y_max, 0, 1)) * ph)),
        };
        const a = if (i == 0) cur else prev;
        const dx = cur.x - a.x;
        const dy = cur.y - a.y;
        const steps: i32 = @intCast(@max(@max(@abs(dx), @abs(dy)), 1));
        var s: i32 = 0;
        while (s <= steps) : (s += 1) {
            const px = a.x + @divTrunc(dx * s + @divTrunc(steps, 2) * std.math.sign(dx), steps);
            const py = a.y + @divTrunc(dy * s + @divTrunc(steps, 2) * std.math.sign(dy), steps);
            const ux: usize = @intCast(std.math.clamp(px, 0, @as(i32, @intFromFloat(pw))));
            const uy: usize = @intCast(std.math.clamp(py, 0, @as(i32, @intFromFloat(ph))));
            cells[uy / 4][ux / 2] |= glyph.brailleBit(ux % 2, uy % 4);
            const uy2 = @min(uy + 1, rows * 4 - 1);
            cells[uy2 / 4][ux / 2] |= glyph.brailleBit(ux % 2, uy2 % 4);
        }
        prev = cur;
    }
}

/// Graph column of time `ts` (same mapping as `plotLine`'s pixels).
fn graphCol(ts: f32, t_max: f32, cols: usize) usize {
    const pw: f32 = @floatFromInt(cols * 2 - 1);
    const px: usize = @intFromFloat(@round(std.math.clamp(ts / @max(t_max, 0.001), 0, 1) * pw));
    return @min(cols - 1, px / 2);
}

/// WPM (accent) and raw (dim) over time, y labels on the left and an x
/// axis with a `×` under every second that had errors. Uses `rows + 1`
/// screen rows from `y`. `reveal` (0..1) draws the lines in from the left.
fn renderGraph(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, rows_in: usize, series: anytype, duration_s: f32, reveal: f32) void {
    const gutter: usize = 5;
    var tlabel_buf: [16]u8 = undefined;
    const tlabel = fmt(&tlabel_buf, "{d:.0}s", .{@round(duration_s)});
    const cols: usize = @min(GRAPH_MAX_COLS, w -| gutter -| (tlabel.len + 1));
    const rows: usize = @min(rows_in, GRAPH_MAX_ROWS);
    if (cols < 4 or rows == 0 or series.len == 0) return;

    var ts: [GRAPH_MAX_COLS * 2]f32 = undefined;
    var wpm: [GRAPH_MAX_COLS * 2]f32 = undefined;
    var raw: [GRAPH_MAX_COLS * 2]f32 = undefined;
    // Downsample long series to at most two points per column.
    const n = @min(series.len, cols * 2);
    var y_max: f32 = 10;
    for (0..n) |k| {
        const i = if (series.len <= n) k else k * series.len / n;
        const s = series[i];
        ts[k] = @floatFromInt(s.t_s);
        wpm[k] = s.wpm;
        raw[k] = s.raw;
        y_max = @max(y_max, @max(s.wpm, s.raw));
    }
    y_max = @ceil(y_max * 1.1 / 10.0) * 10.0;
    const t_max = @max(duration_s, ts[n - 1]);

    var cells_raw: Grid = @splat(@splat(0));
    var cells_wpm: Grid = @splat(@splat(0));
    plotLine(&cells_raw, cols, rows, ts[0..n], raw[0..n], t_max, y_max);
    plotLine(&cells_wpm, cols, rows, ts[0..n], wpm[0..n], t_max, y_max);

    // Y labels.
    pen(r, theme.dimmer, null, false);
    r.moveTo(x, y);
    r.print("{d:>3}", .{@as(u32, @intFromFloat(y_max))});
    if (rows >= 4) {
        r.moveTo(x, y + rows / 2);
        r.print("{d:>3}", .{@as(u32, @intFromFloat(y_max / 2))});
    }

    const gx = x + gutter;
    const shown: usize = if (reveal >= 1) cols else @intFromFloat(@floor(@as(f32, @floatFromInt(cols)) * anim.easeOut(reveal)));
    for (0..rows) |row| {
        r.moveTo(gx, y + row);
        var cur: ?Color = null;
        for (0..cols) |col| {
            const wb = cells_wpm[row][col];
            const rb = cells_raw[row][col];
            if (wb | rb == 0 or col >= shown) {
                r.write(" ");
                continue;
            }
            const c = if (wb != 0) theme.accent else theme.dimmer;
            if (cur == null or !std.meta.eql(cur.?, c)) {
                pen(r, c, null, false);
                cur = c;
            }
            r.write(&glyph.braille(wb | rb));
        }
    }

    // X axis with a mark for every second that had errors.
    const axis_y = y + rows;
    r.moveTo(x, axis_y);
    pen(r, theme.dimmer, null, false);
    r.write("  0 " ++ glyph.box.axis_corner);
    var marks: [GRAPH_MAX_COLS]bool = @splat(false);
    for (series) |s| {
        if (s.errors > 0) marks[graphCol(@floatFromInt(s.t_s), t_max, cols)] = true;
    }
    for (0..cols) |c| {
        if (marks[c] and c < shown) {
            pen(r, theme.danger, null, true);
            r.write("×");
            pen(r, theme.dimmer, null, false);
        } else {
            r.write(glyph.box.h);
        }
    }
    r.write(" ");
    r.write(tlabel);
    r.resetStyle();
}

// ============================================================================
// Card
// ============================================================================

pub fn isVimType(res: anytype) bool {
    return res.kind == .vim_type;
}

fn isZen(cfg: Config) bool {
    return query.is(cfg.mode, "zen");
}

/// Title in the card's top border, e.g. " words · common · 25 ".
fn titleFor(buf: []u8, cfg: Config) []const u8 {
    var chips: draw.Chips = .{};
    draw.chipsFor(&chips, cfg);
    var n: usize = 0;
    buf[0] = ' ';
    n = 1;
    for (chips.slice(), 0..) |c, i| {
        const part = if (i > 0) fmt(buf[n..], " " ++ glyph.MIDDOT ++ " {s}", .{c}) else fmt(buf[n..], "{s}", .{c});
        n += part.len;
    }
    if (n < buf.len) {
        buf[n] = ' ';
        n += 1;
    }
    return buf[0..n];
}

/// PB banner text and color for `ui.pb`, or null for none. Daily runs
/// have their own wording (one PB per day).
pub fn banner(buf: []u8, theme: *const Theme, res: anytype, cfg: Config, ui: *const UiState) ?struct { text: []const u8, color: Color, bold: bool } {
    const daily = query.is(cfg.mode, "daily");
    return switch (ui.pb) {
        .none => if (ui.practice) .{ .text = "practice " ++ glyph.MIDDOT ++ " not recorded", .color = theme.dim, .bold = false } else if (!res.valid) .{ .text = "not recorded (under 1 s or pasted)", .color = theme.dim, .bold = false } else null,
        .first => .{ .text = if (daily) "first daily today" else "first result for this setup", .color = if (daily) theme.accent else theme.dim, .bold = daily },
        .improved => |old| .{ .text = if (daily) fmt(buf, "▲ new daily PB +{d:.1} wpm", .{@max(0, res.wpm - old)}) else fmt(buf, "▲ new personal best +{d:.1} wpm", .{@max(0, res.wpm - old)}), .color = theme.accent, .bold = true },
        .missed => |best| .{ .text = if (daily) fmt(buf, "daily best {d:.0} wpm", .{best}) else fmt(buf, "best {d:.0} wpm", .{best}), .color = theme.dim, .bold = false },
    };
}

/// Inline word list "label  a b c …" clipped to `max_w` columns.
fn renderWords(r: Renderer, theme: *const Theme, x: usize, y: usize, max_w: usize, label: []const u8, words: anytype, comptime slow: bool) void {
    r.moveTo(x, y);
    pen(r, theme.dim, null, false);
    var used = draw.writeClip(r, label, max_w);
    used += draw.writeClip(r, "  ", max_w -| used);
    const limit: usize = if (slow) 5 else 12;
    for (words[0..@min(words.len, limit)], 0..) |wd, i| {
        var buf: [24]u8 = undefined;
        const word = if (slow) wd.word else wd;
        const extra = if (slow) fmt(&buf, " {d}ms", .{wd.ms / @max(1, @as(u32, @intCast(word.len)))}) else "";
        const sep: usize = if (i > 0) (if (slow) 3 else 1) else 0;
        const need = sep + word.len + extra.len;
        if (used + need > max_w) {
            if (used < max_w) {
                pen(r, theme.dimmer, null, false);
                r.write(glyph.ELLIPSIS);
            }
            break;
        }
        if (sep == 3) {
            pen(r, theme.dimmer, null, false);
            r.write(" " ++ glyph.MIDDOT ++ " ");
        } else if (sep == 1) r.write(" ");
        pen(r, if (slow) theme.text() else theme.danger, null, false);
        r.write(word);
        if (extra.len > 0) {
            pen(r, theme.dimmer, null, false);
            r.write(extra);
        }
        used += need;
    }
    r.resetStyle();
}

pub const CardOpts = struct {
    /// Use the 4-row pixel-font digits when there is room.
    large_digits: bool = false,
    /// Center the card vertically in the area.
    center: bool = true,
    /// Animation frame (count-up, graph draw-in, sparkle); final = static.
    frame: anim.Frame = .final,
};

/// This run's per-key stats (contract C3), when the result has them.
fn hasPerKey(res: anytype) bool {
    const R = @typeInfo(@TypeOf(res)).pointer.child;
    if (comptime !@hasField(R, "per_key")) return false;
    return res.per_key != null;
}

/// The four stats beside the big digits, counted up to `k` (0..1).
fn statsFor(res: anytype, cfg: Config, theme: *const Theme, k: f32, bufs: *[4][16]u8) [4]Stat {
    const acc = anim.countUp(res.acc, k);
    const acc_color = if (res.acc >= 97) theme.success else if (res.acc >= 90) theme.warning else theme.danger;
    const dur_s: f32 = anim.countUp(@as(f32, @floatFromInt(res.duration_ms)) / 1000.0, k);
    const time: Stat = .{ .label = "time", .value = fmt(&bufs[3], "{d:.1}s", .{dur_s}), .color = null };
    const cons: Stat = .{ .label = "consistency", .value = if (res.consistency) |c| fmt(&bufs[2], "{d:.0}%", .{anim.countUp(c, k)}) else "-", .color = null };
    if (isVimType(res)) return .{
        .{ .label = "acc", .value = fmt(&bufs[0], "{d:.1}%", .{acc}), .color = acc_color },
        .{ .label = "keys", .value = fmt(&bufs[1], "{d}", .{anim.countUpInt(res.keystrokes, k)}), .color = null },
        .{ .label = "efficiency", .value = fmt(&bufs[2], "{d:.0}%", .{anim.countUp(res.efficiency * 100.0, k)}), .color = null },
        time,
    };
    // Zen has no target: accuracy means nothing, the characters typed do.
    if (isZen(cfg)) return .{
        .{ .label = "raw", .value = fmt(&bufs[0], "{d:.0}", .{anim.countUp(res.raw, k)}), .color = null },
        .{ .label = "chars", .value = fmt(&bufs[1], "{d}", .{anim.countUpInt(res.chars.correct + res.chars.incorrect + res.chars.extra, k)}), .color = null },
        cons,
        time,
    };
    return .{
        .{ .label = "acc", .value = fmt(&bufs[0], "{d:.1}%", .{acc}), .color = acc_color },
        .{ .label = "raw", .value = fmt(&bufs[1], "{d:.0}", .{anim.countUp(res.raw, k)}), .color = null },
        cons,
        time,
    };
}

fn wpmDigits(buf: *[8]u8, wpm: f32) []const u8 {
    return fmt(buf, "{d}", .{@as(u32, @intFromFloat(@min(9999, @round(@max(0, wpm)))))});
}

/// Sparkles around the banner text at [bx, bx + bw) on row `y`, inside the
/// card's interior [lo, hi).
fn renderSparkles(r: Renderer, theme: *const Theme, ms: i64, bx: usize, bw: usize, y: usize, lo: usize, hi: usize) void {
    var buf: [8]anim.Spark = undefined;
    for (anim.sparks(ms, buf[0..6]), 0..) |sp, i| {
        const sx: i64 = if (sp.dx < 0) @as(i64, @intCast(bx)) + sp.dx else @as(i64, @intCast(bx + bw)) + sp.dx;
        if (sx < @as(i64, @intCast(lo)) or sx >= @as(i64, @intCast(hi))) continue;
        r.moveTo(@intCast(sx), y);
        pen(r, if (i % 2 == 0) theme.accent else theme.warning, null, sp.big);
        r.write(if (sp.big) glyph.SPARK else glyph.MIDDOT);
    }
    r.resetStyle();
}

/// The results card in the area (`x`, `y`, `w` x `max_h`).
pub fn renderCard(r: Renderer, theme: *const Theme, res: anytype, cfg: Config, ui: *const UiState, x: usize, y: usize, w: usize, max_h: usize, opts: CardOpts) void {
    if (max_h == 0 or w == 0) return;
    const vim_type = isVimType(res);
    const zen = isZen(cfg);
    const k = opts.frame.count;
    const acc_color = if (res.acc >= 97) theme.success else if (res.acc >= 90) theme.warning else theme.danger;
    const dur_s: f32 = @as(f32, @floatFromInt(res.duration_ms)) / 1000.0;

    // Layout uses the final values, so nothing moves while counting up.
    var final_bufs: [4][16]u8 = undefined;
    const final_stats = statsFor(res, cfg, theme, 1, &final_bufs);
    var shown_bufs: [4][16]u8 = undefined;
    const stats = statsFor(res, cfg, theme, k, &shown_bufs);

    var digits_buf: [8]u8 = undefined;
    const digits = wpmDigits(&digits_buf, res.wpm);
    var shown_buf: [8]u8 = undefined;
    var pad_buf: [8]u8 = undefined;
    const shown_digits = blk: {
        const sd = wpmDigits(&shown_buf, anim.countUp(res.wpm, k));
        const pad = digits.len -| sd.len;
        @memset(pad_buf[0..pad], ' ');
        @memcpy(pad_buf[pad..][0..sd.len], sd);
        break :blk pad_buf[0 .. pad + sd.len];
    };

    var ban_buf: [64]u8 = undefined;
    const ban = banner(&ban_buf, theme, res, cfg, ui);

    if (max_h < 5 or w < 30) {
        // Single summary line.
        r.moveTo(x, y + max_h / 2);
        pen(r, theme.accent, null, true);
        r.write(std.mem.trimStart(u8, shown_digits, " "));
        pen(r, theme.dim, null, false);
        r.write(" wpm  ");
        if (zen) {
            if (w >= 20) r.print("{d:.1}s", .{anim.countUp(dur_s, k)});
        } else {
            pen(r, acc_color, null, true);
            r.print("{d:.0}%", .{anim.countUp(res.acc, k)});
            pen(r, theme.dim, null, false);
            if (w >= 26) r.print(" acc  {d:.1}s", .{anim.countUp(dur_s, k)});
        }
        r.resetStyle();
        return;
    }

    // Horizontal plan: big digits, then two stat columns, one, or a line.
    const inner_w = w - 2;
    const cx = x + 2;
    const right_edge = x + w - 2;
    var big: BigSize = if (opts.large_digits) .large else .small;
    if (big == .large and (max_h < 14 or inner_w < big.width(digits.len) + 34)) big = .small;
    if (max_h < 7 or inner_w < big.width(digits.len) + 8) big = .none;
    const used = big.width(digits.len) + 4;
    const stats_x0 = cx + used + 2;
    const wa = statsWidth(final_stats[0..2]);
    const wb = statsWidth(final_stats[2..4]);
    const w1 = statsWidth(&final_stats);
    const Plan = enum { two, one, inline_ };
    const plan: Plan = if (big == .none)
        .inline_
    else if (stats_x0 + wa + 4 + wb <= right_edge)
        .two
    else if (stats_x0 + w1 <= right_edge)
        .one
    else
        .inline_;
    const stat_rows: usize = switch (plan) {
        .two => 2,
        .one => 4,
        .inline_ => 0,
    };
    // An inline plan with big digits puts the stats on a line below them.
    const below_rows: usize = if (plan == .inline_ and big != .none) 1 else 0;
    const head_h = @max(big.rows(), stat_rows) + below_rows;

    // Vertical budget, in drop order: heatmap, graph, words, chars.
    var rest = (max_h - 2) -| head_h;
    const ban_rows: usize = if (ban != null and rest >= 1) 1 else 0;
    rest -= ban_rows;
    const chars_rows: usize = if (!vim_type and !zen and rest >= 2) 2 else 0;
    rest -= chars_rows;
    var word_lines: usize = 0;
    if (!vim_type) {
        if (res.missed_words.len > 0) word_lines += 1;
        if (res.slow_words.len > 0) word_lines += 1;
    }
    if (res.quote_by != null) word_lines += 1;
    const words_rows: usize = if (word_lines > 0 and rest >= word_lines + 1) word_lines + 1 else 0;
    rest -= words_rows;
    var graph_rows: usize = 0;
    if (!vim_type and res.series.len >= 2 and rest >= 4 and inner_w >= 30) {
        const cap: usize = if (opts.large_digits) 7 else 5;
        graph_rows = @min(cap, rest - 2);
    }
    const graph_h: usize = if (graph_rows > 0) graph_rows + 2 else 0;
    rest -= graph_h;
    const key_rows = heatmap.rowsForConfig(cfg);
    var heat: ?heatmap.Fit = null;
    if (!vim_type and !zen and hasPerKey(res)) {
        const R = @typeInfo(@TypeOf(res)).pointer.child;
        if (comptime @hasField(R, "per_key")) {
            if (heatmap.hasData(res.per_key.?, key_rows)) {
                if (heatmap.fit(key_rows, right_edge -| (cx + 1))) |hf| {
                    if (rest >= heatmap.height(hf) + 1) heat = hf;
                }
            }
        }
    }
    const heat_h: usize = if (heat) |hf| heatmap.height(hf) + 1 else 0;
    rest -= heat_h;
    const pad: usize = if (rest >= 2) 1 else 0;
    const card_h = 2 + 2 * pad + head_h + ban_rows + chars_rows + words_rows + graph_h + heat_h;
    const y0 = if (opts.center) y + (max_h -| card_h) * 2 / 5 else y;

    var title_buf: [64]u8 = undefined;
    draw.drawCard(r, theme, x, y0, w, card_h, titleFor(&title_buf, cfg));

    // Headline.
    var row = y0 + 1 + pad;
    const big_x = cx + 1;
    pen(r, theme.accent, null, true);
    renderBig(r, big_x, row, shown_digits, big);
    pen(r, theme.dim, null, false);
    if (big == .none) {
        r.write(" wpm");
    } else {
        r.moveTo(big_x + big.width(digits.len) + 1, row + big.rows() - 1);
        r.write("wpm");
    }
    r.resetStyle();

    switch (plan) {
        .two => {
            const free = right_edge -| stats_x0 -| wa -| wb;
            const xa = stats_x0 + free / 3;
            renderStatColumn(r, theme, xa, row, stats[0..2]);
            renderStatColumn(r, theme, xa + wa + free / 3, row, stats[2..4]);
        },
        .one => renderStatColumn(r, theme, stats_x0 + (right_edge -| stats_x0 -| w1) / 3, row, &stats),
        .inline_ => if (big == .none)
            renderStatLine(r, theme, big_x + digits.len + 6, row, right_edge -| (big_x + digits.len + 6), &stats)
        else
            renderStatLine(r, theme, big_x, row + big.rows(), right_edge -| big_x, &stats),
    }
    row += head_h;

    if (ban_rows > 0) {
        const b = ban.?;
        const bw = @min(glyph.displayWidth(b.text), inner_w -| 2);
        const bx = x + 1 + (inner_w - bw) / 2;
        r.moveTo(bx, row);
        pen(r, b.color, null, b.bold);
        _ = draw.writeEllipsis(r, b.text, inner_w -| 2);
        r.resetStyle();
        if (opts.frame.sparkle_ms) |ms| renderSparkles(r, theme, ms, bx, bw, row, x + 1, x + w - 1);
        row += 1;
    }

    if (chars_rows > 0) {
        row += 1;
        r.moveTo(big_x, row);
        const c = res.chars;
        pen(r, theme.dim, null, false);
        r.write("chars ");
        pen(r, theme.text(), null, true);
        r.print("{d}", .{c.correct});
        pen(r, theme.dimmer, null, false);
        r.write("/");
        pen(r, if (c.incorrect > 0) theme.danger else theme.dim, null, c.incorrect > 0);
        r.print("{d}", .{c.incorrect});
        pen(r, theme.dimmer, null, false);
        r.write("/");
        pen(r, if (c.extra > 0) theme.error_extra else theme.dim, null, c.extra > 0);
        r.print("{d}", .{c.extra});
        pen(r, theme.dimmer, null, false);
        r.write("/");
        pen(r, theme.dim, null, false);
        r.print("{d}", .{c.missed});
        var cbuf: [32]u8 = undefined;
        const corr = fmt(&cbuf, "corrected {d}", .{res.corrected});
        if (big_x + 40 + corr.len <= right_edge) {
            r.moveTo(right_edge -| corr.len -| 1, row);
            pen(r, theme.dim, null, false);
            r.write(corr);
        }
        r.resetStyle();
        row += 1;
    }

    if (graph_rows > 0) {
        row += 1;
        renderGraph(r, theme, big_x, row, right_edge -| big_x, graph_rows, res.series, dur_s, opts.frame.graph);
        row += graph_rows + 1;
    }

    if (heat) |hf| {
        const R = @typeInfo(@TypeOf(res)).pointer.child;
        if (comptime @hasField(R, "per_key")) {
            row += 1;
            heatmap.render(r, theme, big_x, row, right_edge -| big_x, hf, res.per_key.?, key_rows);
            row += heatmap.height(hf);
        }
    }

    if (words_rows > 0) {
        row += 1;
        const ww = right_edge -| big_x;
        if (!vim_type and res.missed_words.len > 0) {
            renderWords(r, theme, big_x, row, ww, "missed", res.missed_words, false);
            row += 1;
        }
        if (!vim_type and res.slow_words.len > 0) {
            renderWords(r, theme, big_x, row, ww, "slowest", res.slow_words, true);
            row += 1;
        }
        if (res.quote_by) |by| {
            const len = @min(ww, 2 + glyph.displayWidth(by));
            r.moveTo(right_edge -| len, row);
            pen(r, theme.dim, null, false);
            r.write("— ");
            _ = draw.writeEllipsis(r, by, ww -| 2);
            r.resetStyle();
            row += 1;
        }
    }
}

/// Weak-key practice is offered after the simple modes (not zen, not the
/// vim screens, not a practice run).
fn offersWeakKeys(res: anytype, cfg: Config, ui: *const UiState) bool {
    if (isVimType(res) or res.kind == .vim_drill or ui.practice or isZen(cfg)) return false;
    return cfg.mode != .vim and cfg.mode != .arcade;
}

pub fn hints(res: anytype, cfg: Config, ui: *const UiState, out: *[draw.MAX_HINTS]draw.Hint) []const draw.Hint {
    var n: usize = 0;
    out[n] = .{ .key = "enter", .label = "next" };
    n += 1;
    out[n] = .{ .key = "r", .label = "retry" };
    n += 1;
    out[n] = .{ .key = "tab", .label = "new" };
    n += 1;
    if (!isVimType(res) and res.missed_words.len > 0) {
        out[n] = .{ .key = "m", .label = "missed words" };
        n += 1;
    }
    if (offersWeakKeys(res, cfg, ui)) {
        out[n] = .{ .key = "w", .label = "weak keys" };
        n += 1;
    }
    out[n] = .{ .key = "h", .label = "history" };
    n += 1;
    out[n] = .{ .key = "ctrl+p", .label = "settings" };
    n += 1;
    return out[0..n];
}

/// Whole results screen: header, card, toast, hint row (final frame).
pub fn render(r: Renderer, theme: *const Theme, res: anytype, cfg: Config, ui: *const UiState) void {
    renderFrame(r, theme, res, cfg, ui, .final);
}

/// `render` at `now_ms`, animated from `ui.finished_ms` (see `anim`).
pub fn renderAnimated(r: Renderer, theme: *const Theme, res: anytype, cfg: Config, ui: *const UiState, now_ms: i64) void {
    renderFrame(r, theme, res, cfg, ui, frameAt(ui, now_ms));
}

/// The animation frame for the results at `now_ms`.
pub fn frameAt(ui: *const UiState, now_ms: i64) anim.Frame {
    return anim.Frame.at(ui.finished_ms, now_ms, ui.pb == .first or ui.pb == .improved);
}

fn renderFrame(r: Renderer, theme: *const Theme, res: anytype, cfg: Config, ui: *const UiState, frame: anim.Frame) void {
    const f = draw.frameFor(r.width(), r.height());
    draw.clearRows(r, 0, r.height() -| 1);
    var chips: draw.Chips = .{};
    draw.chipsFor(&chips, cfg);
    draw.renderHeader(r, theme, f, chips.slice(), false);
    renderCard(r, theme, res, cfg, ui, f.col_x, f.top, f.col_w, f.rows(), .{ .large_digits = f.h >= 30, .frame = frame });
    draw.renderToast(r, theme, f, ui.toast);
    var hb: [draw.MAX_HINTS]draw.Hint = undefined;
    draw.renderHints(r, theme, f.w, f.footer_y, hints(res, cfg, ui, &hb), false);
}
