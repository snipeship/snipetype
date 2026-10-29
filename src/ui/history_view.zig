//! History screen (`UiState.overlay == .history`): one full-screen card
//! with three tabs.
//!
//! - **recent**: totals and a wpm-trend sparkline, then the newest runs
//!   first, one per row: UTC date, setup, wpm, accuracy and time (drills
//!   show their stars and strokes against par).
//! - **bests**: the personal best of every typing setup, then a drills
//!   summary (three-starred out of all, and per lesson when it fits).
//! - **keys**: the per-key heatmap over all history and the weakest keys.
//!
//! The list scrolls by `UiState.history_scroll`, clamped here. The App owns
//! the keys (Tab / arrows / Esc) and the data (`UiState.log`, `.pbs`);
//! `renderWith` takes them as `anytype` so tests can pass fakes.

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const pen = draw.pen;
const heatmap = @import("heatmap.zig");
const daily = @import("../core/daily.zig");
const ui_state = @import("ui_state.zig");
const UiState = ui_state.UiState;
const HistoryTab = ui_state.HistoryTab;
const Renderer = @import("../platform/renderer.zig").Renderer;
const Config = @import("../core/types.zig").Config;
const drill_mod = @import("../vim/drill.zig");

/// Most trend points drawn (two per sparkline cell).
const TREND_POINTS: usize = 60;
/// Room for `PbTable.entries` (one PbRow per key), reused every frame.
/// Every daily date and custom text is its own key, so the table only
/// grows: 256 KiB holds 8000 keys (the bests list keeps nothing else).
var entries_mem: [256 * 1024]u8 = undefined;

pub fn render(r: Renderer, theme: *const Theme, cfg: Config, ui: *const UiState) void {
    renderWith(r, theme, cfg, ui, ui.log, ui.pbs);
}

pub fn renderWith(r: Renderer, theme: *const Theme, cfg: Config, ui: *const UiState, log: anytype, pbs: anytype) void {
    const f = draw.frameFor(r.width(), r.height());
    draw.clearRows(r, 0, r.height() -| 1);
    draw.renderHeader(r, theme, f, &.{"history"}, false);

    // Card around the tabs and the list (just the inside on tiny screens).
    const area = innerArea(f);
    if (boxed(f)) draw.drawCard(r, theme, f.col_x, f.top, f.col_w, f.rows(), "");
    if (area.h == 0 or area.w == 0) return;
    renderTabs(r, theme, area, ui.history_tab);
    const body = bodyArea(area);
    if (body.h > 0) switch (ui.history_tab) {
        .recent => renderRecent(r, theme, body, ui.history_scroll, log),
        .bests => renderBests(r, theme, body, ui.history_scroll, pbs),
        .keys => renderKeys(r, theme, body, cfg, log),
    };

    draw.renderToast(r, theme, f, ui.toast);
    const hints = [_]draw.Hint{
        .{ .key = "tab", .label = "switch" },
        .{ .key = "↑↓", .label = "scroll" },
        .{ .key = "esc", .label = "close" },
    };
    draw.renderHints(r, theme, f.w, f.footer_y, &hints, false);
}

const Area = struct { x: usize, y: usize, w: usize, h: usize };

fn boxed(f: draw.Frame) bool {
    return f.rows() >= 6 and f.col_w >= 24;
}

/// Inside the card (or the whole content area on tiny screens).
fn innerArea(f: draw.Frame) Area {
    if (boxed(f)) return .{ .x = f.col_x + 2, .y = f.top + 1, .w = f.col_w -| 4, .h = f.rows() -| 2 };
    return .{ .x = f.col_x, .y = f.top, .w = f.col_w, .h = f.rows() };
}

/// Under the tabs row (and a blank row when there is room).
fn bodyArea(area: Area) Area {
    var body = area;
    body.y += 1;
    body.h -|= 1;
    if (body.h > 2) {
        body.y += 1;
        body.h -= 1;
    }
    return body;
}

/// Rows of the recent list in a body `h` rows tall (the totals and trend
/// take two when there is room).
fn recentRows(h: usize) usize {
    return if (h >= 4) h - 2 else h;
}

/// The largest useful `history_scroll` for the current tab on a `w` x `h`
/// terminal: the App can clamp its scroll to it, so scrolling back up
/// responds at once.
pub fn maxScroll(ui: *const UiState, w: usize, h: usize) usize {
    const body = bodyArea(innerArea(draw.frameFor(w, h)));
    switch (ui.history_tab) {
        .recent => {
            const log = ui.log orelse return 0;
            return log.runs().len -| recentRows(body.h);
        },
        .bests => {
            const pbs = ui.pbs orelse return 0;
            var fba = std.heap.FixedBufferAllocator.init(&entries_mem);
            const list = BestList.init(pbs, fba.allocator()) catch return 0;
            return list.len() -| body.h;
        },
        .keys => return 0,
    }
}

fn renderTabs(r: Renderer, theme: *const Theme, a: Area, cur: HistoryTab) void {
    r.moveTo(a.x, a.y);
    var left = a.w;
    inline for (comptime std.meta.tags(HistoryTab), 0..) |tab, i| {
        if (i > 0) {
            pen(r, theme.dimmer, null, false);
            left -|= draw.writeClip(r, " " ++ glyph.MIDDOT ++ " ", left);
        }
        if (tab == cur) pen(r, theme.accent, null, true) else pen(r, theme.dim, null, false);
        left -|= draw.writeClip(r, tab.label(), left);
    }
    r.resetStyle();
}

fn renderEmpty(r: Renderer, theme: *const Theme, a: Area, msg: []const u8) void {
    const len = @min(msg.len, a.w);
    r.moveTo(a.x + (a.w - len) / 2, a.y + (a.h -| 1) / 3);
    pen(r, theme.dim, null, false);
    _ = draw.writeClip(r, msg, a.w);
    r.resetStyle();
}

/// The first row of a `rows`-long list shown in `h` rows at `scroll`.
pub fn clampScroll(scroll: usize, rows: usize, h: usize) usize {
    return @min(scroll, rows -| h);
}

// ============================================================================
// Recent
// ============================================================================

/// "10-28 14:05" (UTC) for unix seconds `ts`.
pub fn formatTs(ts: i64, buf: *[11]u8) []const u8 {
    const t: u64 = @intCast(@max(0, ts));
    var day_buf: [10]u8 = undefined;
    const day = daily.format(@intCast(t / 86400), &day_buf);
    const sod = t % 86400;
    return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{ day[5..10], sod / 3600, sod % 3600 / 60 }) catch buf[0..0];
}

/// "42s", "3m 05s" or "2h 07m".
pub fn formatDuration(ms: u64, buf: *[24]u8) []const u8 {
    const secs = ms / 1000;
    if (secs < 60) return draw.fmt(buf, "{d}s", .{secs});
    if (secs < 3600) return draw.fmt(buf, "{d}m {d:0>2}s", .{ secs / 60, secs % 60 });
    return draw.fmt(buf, "{d}h {d:0>2}m", .{ secs / 3600, secs % 3600 / 60 });
}

/// A pbKey made readable: `words|common|w25|p1n0` → "words · common · 25 ·
/// punct", `code|rust|t30` → "code · rust · 30s".
pub fn shortKey(key: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, key, '|');
    var first = true;
    while (it.next()) |part| {
        var tmp: [16]u8 = undefined;
        const shown: []const u8 = blk: {
            if (part.len >= 2 and (part[0] == 'w' or part[0] == 't') and allDigits(part[1..])) {
                break :blk if (part[0] == 'w') part[1..] else std.fmt.bufPrint(&tmp, "{s}s", .{part[1..]}) catch part;
            }
            if (part.len == 4 and part[0] == 'p' and part[2] == 'n') {
                const p = part[1] == '1';
                const num = part[3] == '1';
                break :blk if (p and num) "punct num" else if (p) "punct" else if (num) "num" else "";
            }
            break :blk part;
        };
        if (shown.len == 0) continue;
        const sep = if (first) "" else " " ++ glyph.MIDDOT ++ " ";
        const s = std.fmt.bufPrint(buf[n..], "{s}{s}", .{ sep, shown }) catch break;
        n += s.len;
        first = false;
    }
    return buf[0..n];
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return s.len > 0;
}

/// One-row braille sparkline of `pts` (min..max scaled), `cols` wide.
fn sparkline(r: Renderer, x: usize, y: usize, cols: usize, pts: []const f32) void {
    if (pts.len == 0 or cols == 0) return;
    var lo: f32 = pts[0];
    var hi: f32 = pts[0];
    for (pts) |p| {
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    const span = @max(hi - lo, 1);
    const n = @min(pts.len, cols * 2);
    const shown = pts[pts.len - n ..];
    r.moveTo(x, y);
    for (0..(n + 1) / 2) |cell| {
        var bits: u8 = 0;
        for (0..2) |half| {
            const i = cell * 2 + half;
            if (i >= n) continue;
            const level: usize = @intFromFloat(@round(std.math.clamp((shown[i] - lo) / span, 0, 1) * 3.0));
            for (0..level + 1) |k| bits |= glyph.brailleBit(half, 3 - k);
        }
        r.write(&glyph.braille(bits));
    }
}

fn renderRecent(r: Renderer, theme: *const Theme, a: Area, scroll_in: usize, log_opt: anytype) void {
    const log = log_opt orelse return renderEmpty(r, theme, a, "no runs yet");
    const runs = log.runs();
    if (runs.len == 0) return renderEmpty(r, theme, a, "no runs yet");

    var y = a.y;
    const bottom = a.y + a.h;
    // Totals and the trend (when there are rows to spare).
    if (recentRows(a.h) < a.h) {
        var buf: [64]u8 = undefined;
        var dur_buf: [24]u8 = undefined;
        const totals = draw.fmt(&buf, "{d} run{s} " ++ glyph.MIDDOT ++ " {s} typed", .{ log.count(), if (log.count() == 1) "" else "s", formatDuration(log.totalMs(), &dur_buf) });
        r.moveTo(a.x, y);
        pen(r, theme.dim, null, false);
        var used = draw.writeClip(r, totals, a.w);
        var pts_buf: [TREND_POINTS]f32 = undefined;
        const pts = log.trend(null, &pts_buf);
        if (pts.len >= 2 and used + 14 <= a.w) {
            const cols = @min((pts.len + 1) / 2, a.w - used - 12);
            pen(r, theme.dimmer, null, false);
            r.write("   ");
            used += 3;
            pen(r, theme.accent, null, false);
            sparkline(r, a.x + used, y, cols, pts);
            used += @min(cols, (pts.len + 1) / 2);
            var lb: [16]u8 = undefined;
            const last = draw.fmt(&lb, " {d:.0} wpm", .{pts[pts.len - 1]});
            pen(r, theme.dim, null, false);
            _ = draw.writeClip(r, last, a.w -| used);
        }
        r.resetStyle();
        y += 2;
    }
    if (y >= bottom) return;

    // Newest first.
    const rows = bottom - y;
    const scroll = clampScroll(scroll_in, runs.len, rows);
    const show_time = a.w >= 56;
    const show_acc = a.w >= 44;
    const right_w: usize = 8 + (if (show_acc) @as(usize, 7) else 0) + (if (show_time) @as(usize, 8) else 0);
    for (0..rows) |i| {
        const idx = scroll + i;
        if (idx >= runs.len) break;
        const run = &runs[runs.len - 1 - idx];
        renderRun(r, theme, a.x, y + i, a.w, run, right_w, show_acc, show_time);
    }
    // Scroll markers on the right edge.
    if (scroll > 0) {
        r.moveTo(a.x + a.w - 1, y);
        pen(r, theme.dimmer, null, false);
        r.write("↑");
    }
    if (scroll + rows < runs.len) {
        r.moveTo(a.x + a.w - 1, bottom - 1);
        pen(r, theme.dimmer, null, false);
        r.write("↓");
    }
    r.resetStyle();
}

fn renderRun(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, run: anytype, right_w: usize, show_acc: bool, show_time: bool) void {
    var tb: [11]u8 = undefined;
    var kb: [96]u8 = undefined;
    r.moveTo(x, y);
    pen(r, theme.dimmer, null, false);
    var used = draw.writeClip(r, formatTs(run.ts, &tb), w);
    used += draw.writeClip(r, "  ", w -| used);
    // The last column holds the scroll markers.
    const key_w = (w -| 2) -| used -| right_w;
    pen(r, theme.text(), null, false);
    used += draw.writeEllipsis(r, shortKey(run.key(), &kb), key_w);

    var buf: [32]u8 = undefined;
    const is_drill = run.kind == .drill;
    const right = if (is_drill) blk: {
        var sb: [9]u8 = undefined;
        break :blk draw.fmt(&buf, "{s} {d}/{d}", .{ draw.starString(&sb, run.stars), run.strokes, run.par });
    } else draw.fmt(&buf, "{d:.0} wpm", .{run.wpm});
    if (right_w > w -| 2) return;
    const rx = x + (w -| 2) - right_w;
    r.moveTo(rx, y);
    pen(r, if (is_drill) theme.accent else theme.text(), null, !is_drill);
    var rest = right_w;
    // Right-align the first column in 8 cells.
    const first_w = glyph.displayWidth(right);
    draw.repeat(r, " ", 8 -| first_w);
    rest -|= @max(8, first_w);
    _ = draw.writeClip(r, right, @max(8, first_w));
    if (is_drill) {
        r.resetStyle();
        return;
    }
    if (show_acc) {
        const acc_color = if (run.acc >= 97) theme.success else if (run.acc >= 90) theme.warning else theme.danger;
        pen(r, acc_color, null, false);
        const v = draw.fmt(&buf, "{d:.0}%", .{run.acc});
        draw.repeat(r, " ", 7 -| v.len);
        r.write(v);
    }
    if (show_time) {
        pen(r, theme.dim, null, false);
        const v = draw.fmt(&buf, "{d:.1}s", .{@as(f32, @floatFromInt(run.ms)) / 1000.0});
        draw.repeat(r, " ", 8 -| v.len);
        _ = draw.writeClip(r, v, 8);
    }
    r.resetStyle();
}

// ============================================================================
// Bests
// ============================================================================

const DRILL_PREFIX = "drill|";

fn isDrillKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, DRILL_PREFIX);
}

/// Lines of the bests list: typing setups, a blank, the drills summary and
/// one line per lesson.
const BestLine = union(enum) {
    setup: struct { key: []const u8, wpm: f32 },
    blank,
    drills: struct { three: usize, done: usize, total: usize },
    lesson: struct { title: []const u8, three: usize, done: usize, total: usize },
};

const Lesson = @TypeOf(drill_mod.all[0].lesson);
const LESSONS = std.meta.tags(Lesson).len;

/// The bests list over `pbs.entries` (sorted by key), indexed line by line
/// so it needs no room beyond the rows: drill keys (`drill|…`) sort into
/// one contiguous run, and every other row is a typing setup.
fn BestListOf(comptime Row: type) type {
    return struct {
        const Self = @This();

        rows: []const Row,
        /// The drill rows are `rows[drill_lo..drill_hi]`.
        drill_lo: usize,
        drill_hi: usize,
        three: usize = 0,
        lessons: [LESSONS]BestLine = undefined,
        n_lessons: usize = 0,

        fn setups(self: *const Self) usize {
            return self.rows.len - (self.drill_hi - self.drill_lo);
        }

        fn done(self: *const Self) usize {
            return self.drill_hi - self.drill_lo;
        }

        pub fn len(self: *const Self) usize {
            if (self.done() == 0) return self.setups();
            return self.setups() + @intFromBool(self.setups() > 0) + 1 + self.n_lessons;
        }

        pub fn line(self: *const Self, i: usize) BestLine {
            const n = self.setups();
            if (i < n) {
                const row = if (i < self.drill_lo) self.rows[i] else self.rows[self.drill_hi + i - self.drill_lo];
                return .{ .setup = .{ .key = row.key, .wpm = row.wpm } };
            }
            var k = i - n;
            if (n > 0) {
                if (k == 0) return .blank;
                k -= 1;
            }
            if (k == 0) return .{ .drills = .{ .three = self.three, .done = self.done(), .total = drill_mod.all.len } };
            return self.lessons[k - 1];
        }
    };
}

const BestList = struct {
    /// The bests of `pbs` (rows allocated from `alloc`).
    fn init(pbs: anytype, alloc: std.mem.Allocator) !BestListOf(RowOf(@TypeOf(pbs))) {
        const rows = try pbs.entries(alloc);
        var lo: usize = 0;
        while (lo < rows.len and !isDrillKey(rows[lo].key)) lo += 1;
        var hi = lo;
        while (hi < rows.len and isDrillKey(rows[hi].key)) hi += 1;
        var list: BestListOf(RowOf(@TypeOf(pbs))) = .{ .rows = rows, .drill_lo = lo, .drill_hi = hi };
        for (rows[lo..hi]) |row| {
            if (row.stars == 3) list.three += 1;
        }
        if (hi > lo) addLessons(&list, rows[lo..hi]);
        return list;
    }

    fn RowOf(comptime P: type) type {
        const T = switch (@typeInfo(P)) {
            .pointer => |p| p.child,
            else => P,
        };
        const E = @typeInfo(@TypeOf(T.entries)).@"fn".return_type.?;
        return @typeInfo(@typeInfo(E).error_union.payload).pointer.child;
    }
};

fn renderBests(r: Renderer, theme: *const Theme, a: Area, scroll_in: usize, pbs_opt: anytype) void {
    const pbs = pbs_opt orelse return renderEmpty(r, theme, a, "no runs yet");
    var fba = std.heap.FixedBufferAllocator.init(&entries_mem);
    const list = BestList.init(pbs, fba.allocator()) catch return renderEmpty(r, theme, a, "too many bests to list");
    const n = list.len();
    if (n == 0) return renderEmpty(r, theme, a, "no runs yet");
    const scroll = clampScroll(scroll_in, n, a.h);
    for (0..a.h) |i| {
        const idx = scroll + i;
        if (idx >= n) break;
        renderBestLine(r, theme, a.x, a.y + i, a.w, list.line(idx));
    }
}

/// One line per drill lesson with any drill done: three-starred and done
/// out of the lesson's drills (`drill_rows`: the `drill|…` rows).
fn addLessons(list: anytype, drill_rows: anytype) void {
    inline for (comptime std.meta.tags(Lesson)) |lesson| {
        var total: usize = 0;
        var done: usize = 0;
        var three: usize = 0;
        for (drill_mod.all) |ch| {
            if (ch.lesson != lesson) continue;
            total += 1;
            for (drill_rows) |row| {
                if (!std.mem.eql(u8, row.key[DRILL_PREFIX.len..], ch.id)) continue;
                done += 1;
                if (row.stars == 3) three += 1;
            }
        }
        if (done > 0) {
            list.lessons[list.n_lessons] = .{ .lesson = .{ .title = lesson.title(), .three = three, .done = done, .total = total } };
            list.n_lessons += 1;
        }
    }
}

fn renderBestLine(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, line: BestLine) void {
    var buf: [96]u8 = undefined;
    var vb: [32]u8 = undefined;
    r.moveTo(x, y);
    const label: []const u8, const value: []const u8, const bold = switch (line) {
        .blank => return,
        .setup => |s| .{ shortKey(s.key, &buf), draw.fmt(&vb, "{d:.0} wpm", .{s.wpm}), true },
        .drills => |d| .{ "drills", draw.fmt(&vb, "{d}/{d} ★★★  {d} done", .{ d.three, d.total, d.done }), true },
        .lesson => |l| .{ draw.fmt(&buf, "  {s}", .{l.title}), draw.fmt(&vb, "{d}/{d} ★★★", .{ l.three, l.total }), false },
    };
    const vw = glyph.displayWidth(value);
    pen(r, if (line == .lesson) theme.dim else theme.text(), null, false);
    _ = draw.writeEllipsis(r, label, w -| vw -| 2);
    if (vw + 2 <= w) {
        r.moveTo(x + w - vw, y);
        pen(r, if (line == .setup) theme.accent else theme.dim, null, bold);
        r.write(value);
    }
    r.resetStyle();
}

// ============================================================================
// Keys
// ============================================================================

fn renderKeys(r: Renderer, theme: *const Theme, a: Area, cfg: Config, log_opt: anytype) void {
    const log = log_opt orelse return renderEmpty(r, theme, a, "no key data yet");
    const pk = log.perKey();
    const rows = heatmap.rowsForConfig(cfg);
    if (!heatmap.hasData(pk, rows)) return renderEmpty(r, theme, a, "no key data yet");
    const kw = heatmap.keyboardWidth(rows);
    if (a.w < kw or a.h < heatmap.ROWS) return renderEmpty(r, theme, a, "too small for the keyboard");
    heatmap.renderKeyboard(r, theme, a.x, a.y, a.w, pk, rows, &.{});

    // The weakest keys: missed most often, then slowest.
    var all: [64]heatmap.KeyInfo = undefined;
    var n: usize = 0;
    for (rows) |row| for (row) |c| {
        if (heatmap.info(pk, c)) |ki| {
            if (ki.hits == 0 or n == all.len) continue;
            all[n] = ki;
            n += 1;
        }
    };
    std.sort.pdq(heatmap.KeyInfo, all[0..n], {}, weakerThan);
    const side = a.w >= kw + 6 + 26;
    const lx = if (side) a.x + kw + 6 else a.x;
    var ly = if (side) a.y else a.y + heatmap.ROWS + 1;
    const lw = if (side) a.w - kw - 6 else a.w;
    if (ly >= a.y + a.h) return;
    r.moveTo(lx, ly);
    pen(r, theme.dim, null, false);
    _ = draw.writeClip(r, "weakest keys", lw);
    ly += 1;
    for (all[0..@min(n, 5)]) |ki| {
        if (ly >= a.y + a.h) break;
        var buf: [48]u8 = undefined;
        r.moveTo(lx, ly);
        pen(r, heatmap.keyColor(theme, ki), null, true);
        r.writeByte(ki.key);
        pen(r, theme.dim, null, false);
        const v = if (ki.timed > 0)
            draw.fmt(&buf, "  {d:.1}% missed  {d:.0}ms", .{ ki.missRate() * 100, ki.avg_ms })
        else
            draw.fmt(&buf, "  {d:.1}% missed", .{ki.missRate() * 100});
        _ = draw.writeClip(r, v, lw -| 1);
        ly += 1;
    }
    r.resetStyle();
}

/// Weakest first: the higher miss rate (as shown, to 0.1%), then the slower
/// key, then the key itself (stable order).
fn weakerThan(_: void, x: heatmap.KeyInfo, y: heatmap.KeyInfo) bool {
    const mx = shownRate(x);
    const my = shownRate(y);
    if (mx != my) return mx > my;
    if (x.avg_ms != y.avg_ms) return x.avg_ms > y.avg_ms;
    return x.key < y.key;
}

/// Miss rate in tenths of a percent (the precision the list shows).
fn shownRate(ki: heatmap.KeyInfo) u32 {
    return @intFromFloat(@round(ki.missRate() * 1000));
}

test "weakest keys: higher miss rate first, slowness breaks ties" {
    const k = struct {
        fn f(key: u8, hits: u32, misses: u32, ms: f32) heatmap.KeyInfo {
            return .{ .key = key, .hits = hits, .misses = misses, .avg_ms = ms, .timed = hits - misses };
        }
    }.f;
    var keys = [_]heatmap.KeyInfo{
        k('a', 100, 0, 900), // slow but never missed
        k('b', 1000, 92, 250),
        k('c', 1000, 97, 230),
        k('d', 1000, 92, 300),
        k('e', 100, 0, 100),
    };
    std.sort.pdq(heatmap.KeyInfo, &keys, {}, weakerThan);
    var order: [5]u8 = undefined;
    for (keys, 0..) |ki, i| order[i] = ki.key;
    try std.testing.expectEqualStrings("cdbae", &order);
}

test "short keys" {
    var b: [96]u8 = undefined;
    try std.testing.expectEqualStrings("words · common · 25 · punct", shortKey("words|common|w25|p1n0", &b));
    try std.testing.expectEqualStrings("words · 5k · 30s", shortKey("words|5k|t30|p0n0", &b));
    try std.testing.expectEqualStrings("code · rust · vim", shortKey("code|rust|vim", &b));
    try std.testing.expectEqualStrings("drill · motion/w-01", shortKey("drill|motion/w-01", &b));
}

test "timestamps" {
    var b: [11]u8 = undefined;
    try std.testing.expectEqualStrings("10-28 14:05", formatTs(20754 * 86400 + 14 * 3600 + 5 * 60 + 7, &b));
    try std.testing.expectEqualStrings("01-01 00:00", formatTs(0, &b));
}

test "durations" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("42s", formatDuration(42_900, &b));
    try std.testing.expectEqualStrings("3m 05s", formatDuration(185_000, &b));
    try std.testing.expectEqualStrings("2h 07m", formatDuration(7_620_000, &b));
}

test "scroll clamps" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10));
    try std.testing.expectEqual(@as(usize, 7), clampScroll(50, 17, 10));
    try std.testing.expectEqual(@as(usize, 2), clampScroll(2, 17, 10));
}
