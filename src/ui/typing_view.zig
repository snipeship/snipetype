//! Words / sentences / code / custom / daily / zen while waiting or typing:
//! a stats line (or the idle config bar) over the word-wrapped text, drawn
//! word by word from the test's `Session` (contract 3).
//!
//! Per-letter colors (see `LetterKind`): typed-correct in the normal text
//! color, mistakes in `danger` with no background, extra letters in the
//! darker `error_extra`, letters skipped in a committed word (Space mid-word,
//! or Enter mid-line in code) dim and underlined, everything untyped dim.
//! Separators are always drawn as a space (or a dim `↵` before a line break
//! in code), so word gaps never disappear. The active line is kept as the
//! second visible line.
//!
//! The pace caret (`UiState.pace_wpm`) underlines, in `theme.pace`, the
//! letter a typist at that speed would be on. Zen has no target: every
//! typed letter is drawn as correct.
//!
//! The view takes the test as `anytype` (anything with `state`, `config`,
//! `start_time`, `session` and `live(now_ms)`) so tests can drive it with a
//! hand-built session.

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const pen = draw.pen;
const Frame = draw.Frame;
const Renderer = @import("../platform/renderer.zig").Renderer;
const UiState = @import("ui_state.zig").UiState;
const config_bar = @import("config_bar.zig");
const query = @import("query.zig");
const syntax = @import("../core/syntax.zig");

/// Text lines visible at once in prose modes (the caret line is the 2nd).
const PROSE_LINES: usize = 3;
/// Code shows more context.
const CODE_LINES: usize = 8;
/// The displayed live WPM only changes this often (calmer).
pub const WPM_STEP_MS: i64 = 500;

pub const NEWLINE_MARK = "↵";
pub const WRAP_MARK = "↪";

// ============================================================================
// Letters
// ============================================================================

pub const LetterKind = enum { correct, incorrect, extra, missed, pending };

pub const Letter = struct { ch: u8, kind: LetterKind };

/// Width in cells of a word: its target, or what was typed if longer.
pub fn wordWidth(wv: anytype) usize {
    return @max(wv.target.len, wv.typed.len);
}

/// Letter `j` (< `wordWidth`) of a word view.
pub fn letter(wv: anytype, j: usize) Letter {
    const committed = wv.status == .correct or wv.status == .incorrect;
    if (j < wv.typed.len) {
        if (j >= wv.target.len) return .{ .ch = wv.typed[j], .kind = .extra };
        if (wv.typed[j] == wv.target[j]) return .{ .ch = wv.target[j], .kind = .correct };
        return .{ .ch = wv.target[j], .kind = .incorrect };
    }
    return .{ .ch = wv.target[j], .kind = if (committed) .missed else .pending };
}

fn applyLetter(r: Renderer, theme: *const Theme, kind: LetterKind) void {
    switch (kind) {
        .correct => pen(r, theme.text(), null, false),
        .incorrect => pen(r, theme.danger, null, false),
        .extra => pen(r, theme.error_extra, null, false),
        .missed => {
            pen(r, theme.dim, null, false);
            draw.underline(r, true);
        },
        .pending => pen(r, theme.dim, null, false),
    }
}

// ============================================================================
// Layout
// ============================================================================

/// Where one word sits, in text-block coordinates (line, column).
pub const Placement = struct {
    word: usize,
    line: usize,
    col: usize,
    width: usize,
    /// First word of a line that continues a wrapped line (marked with
    /// `↪` in code).
    cont: bool,

    /// Line and column of letter `j` (words longer than the line wrap).
    pub fn at(self: Placement, j: usize, line_w: usize) struct { line: usize, col: usize } {
        const abs = self.col + j;
        if (abs < line_w or line_w == 0) return .{ .line = self.line, .col = abs };
        return .{ .line = self.line + abs / line_w, .col = abs % line_w };
    }
};

/// Greedy whole-word wrap over a session's words. Newline separators break
/// the line and start the next one at the word's `indent`; in code, lines
/// that don't fit continue at the same indent (marked with `↪`).
pub fn Wrapper(comptime S: type) type {
    return struct {
        const Self = @This();

        session: S,
        line_w: usize,
        i: usize = 0,
        line: usize = 0,
        col: usize = 0,
        /// Indent of the current logical line (code).
        indent: usize = 0,

        pub fn next(self: *Self) ?Placement {
            if (self.i >= self.session.wordCount()) return null;
            const wv = self.session.word(self.i);
            const w = wordWidth(wv);
            var cont = false;
            if (self.col > self.indent and self.col + w > self.line_w) {
                self.line += 1;
                self.col = if (self.indent + w <= self.line_w) self.indent else 0;
                cont = true;
            }
            const pl: Placement = .{ .word = self.i, .line = self.line, .col = self.col, .width = w, .cont = cont };
            // Advance past the word (long words wrap letter by letter).
            const end = self.col + w;
            if (end > self.line_w and self.line_w > 0) {
                self.line += (end - 1) / self.line_w;
                self.col = (end - 1) % self.line_w + 1;
            } else {
                self.col = end;
            }
            switch (wv.sep) {
                .space => self.col += 1,
                .newline => {
                    self.line += 1 + blankLines(wv);
                    self.indent = @min(wv.indent, self.line_w / 2);
                    self.col = self.indent;
                },
                .end => {},
            }
            self.i += 1;
            return pl;
        }
    };
}

/// Empty lines after a `.newline` word (between code snippets).
fn blankLines(wv: anytype) usize {
    return if (@hasField(@TypeOf(wv), "blank_lines")) wv.blank_lines else 0;
}

pub fn wrapper(session: anytype, line_w: usize) Wrapper(@TypeOf(session)) {
    return .{ .session = session, .line_w = line_w };
}

/// A session seen as if nothing were typed yet (`P` points to the session):
/// the layout the text settles on, which extra letters don't change.
fn TargetsOnly(comptime P: type) type {
    const S = @typeInfo(P).pointer.child;
    const View = @typeInfo(@TypeOf(S.word)).@"fn".return_type.?;
    return struct {
        session: P,

        pub fn wordCount(self: @This()) usize {
            return self.session.wordCount();
        }

        pub fn word(self: @This(), i: usize) View {
            var wv = self.session.word(i);
            wv.typed = wv.typed[0..0];
            return wv;
        }
    };
}

/// Widest wrapped line of `session` at `line_w`, in cells.
fn widestLine(session: anytype, line_w: usize) usize {
    var it = wrapper(session, line_w);
    var widest: usize = 0;
    while (it.next()) |pl| {
        const last = pl.at(pl.width -| 1, line_w);
        if (last.line != pl.line) return line_w;
        widest = @max(widest, if (pl.width == 0) pl.col else last.col + 1);
    }
    return widest;
}

pub const TextLayout = struct {
    stats_y: usize,
    text_x: usize,
    text_y: usize,
    line_gap: usize,
    line_w: usize,
    vis_lines: usize,
    first_line: usize,
    total_lines: usize,
    caret_line: usize,
    caret_col: usize,

    pub fn rowY(self: TextLayout, line: usize) ?usize {
        if (line < self.first_line or line >= self.first_line + self.vis_lines) return null;
        return self.text_y + (line - self.first_line) * self.line_gap;
    }
};

/// Code layout (more lines, `↪` continuation marks): code, and custom text
/// with line breaks.
pub fn isCode(t: anytype) bool {
    if (t.config.mode == .code) return true;
    return query.isCustom(t) and std.mem.indexOfScalar(u8, query.customText(t), '\n') != null;
}

pub fn layout(t: anytype, f: Frame) TextLayout {
    const code = isCode(t);
    const line_w = @max(1, f.col_w);
    const session = &t.session;
    const active = session.activeIndex();

    // Pass 1: total lines, widest line, caret position.
    var it = wrapper(session, line_w);
    var total: usize = 1;
    var widest: usize = 0;
    var caret_line: usize = 0;
    var caret_col: usize = 0;
    var line_end: usize = 0;
    var cur_line: usize = 0;
    while (it.next()) |pl| {
        if (pl.line != cur_line) {
            widest = @max(widest, line_end);
            cur_line = pl.line;
        }
        const last = pl.at(pl.width -| 1, line_w);
        line_end = if (pl.width == 0) pl.col else last.col + 1;
        if (last.line != cur_line) {
            widest = line_w;
            cur_line = last.line;
        }
        total = @max(total, last.line + 1);
        if (pl.word == active) {
            const p = pl.at(session.caret(), line_w);
            caret_line = p.line;
            caret_col = p.col;
        }
    }
    widest = @max(widest, line_end);
    // Room for the caret (or the `↵`) after the last letter.
    const block_w = @min(line_w, widest + 1);
    // Centered on the untyped text, so extra letters don't shift the whole
    // block sideways; it only moves left when they would overflow.
    const settled: TargetsOnly(@TypeOf(session)) = .{ .session = session };
    const settled_w = @min(line_w, widestLine(settled, line_w) + 1);
    const text_x = @min(f.col_x + (f.col_w -| settled_w) / 2, f.col_x + (f.col_w -| block_w));

    const avail = f.rows();
    const want: usize = if (code) CODE_LINES else PROSE_LINES;
    var vis: usize = @max(1, @min(total, want));
    var gap: usize = 1;
    // Stats line + blank + text block; prose is double-spaced when it fits.
    if (!code and 2 + (vis - 1) * 2 + 1 + 4 <= avail) gap = 2;
    while (vis > 1 and 2 + (vis - 1) * gap + 1 > avail) vis -= 1;
    const block_h = 2 + (vis - 1) * gap + 1;
    const block_y = f.top + (avail -| block_h) * 2 / 5;

    // Context above the caret line: one line (two in tall code views).
    const lead: usize = if (vis >= 6) 2 else if (vis >= 2) 1 else 0;
    const first = @min(caret_line -| lead, total -| vis);
    return .{
        .stats_y = block_y,
        .text_x = text_x,
        .text_y = block_y + @min(2, avail -| 1),
        .line_gap = gap,
        .line_w = line_w,
        .vis_lines = vis,
        .first_line = first,
        .total_lines = total,
        .caret_line = caret_line,
        .caret_col = caret_col,
    };
}

// ============================================================================
// Rendering
// ============================================================================

/// Where the pace caret is (a word and a letter offset; `offset ==
/// target.len` is the separator after the word), or null.
pub const PaceLoc = struct { word: usize, offset: usize };

/// The pace caret for `ui.pace_wpm` at `now_ms`: never in zen, never on
/// cells already typed.
pub fn paceLoc(t: anytype, ui: *const UiState, now_ms: i64) ?PaceLoc {
    const wpm = ui.pace_wpm orelse return null;
    if (query.isZen(t) or t.state != .typing) return null;
    const chars = query.paceChars(t, now_ms, wpm) orelse return null;
    const S = @TypeOf(t.session);
    if (comptime !@hasDecl(S, "locate")) return null;
    const loc = t.session.locate(chars);
    if (loc.word >= t.session.wordCount()) return null;
    const active = t.session.activeIndex();
    if (loc.word < active) return null;
    if (loc.word == active and loc.offset < t.session.word(active).typed.len) return null;
    if (loc.word == active and loc.offset == t.session.caret()) return null;
    return .{ .word = loc.word, .offset = loc.offset };
}

/// The text block (letters, separators, markers) for `lay`; `pace` is the
/// pace caret's position (see `paceLoc`).
pub fn renderText(r: Renderer, theme: *const Theme, t: anytype, lay: TextLayout, pace: ?PaceLoc) void {
    const session = &t.session;
    const active = session.activeIndex();
    const typing = t.state != .finished;
    const code = isCode(t);
    const zen = query.isZen(t);
    // Untyped code is tinted by its syntax class (contract C3 `syntaxKind`).
    const syn = query.cfgBool(t.config, "syntax", false) and !zen;
    var it = wrapper(session, lay.line_w);
    while (it.next()) |pl| {
        if (pl.line >= lay.first_line + lay.vis_lines) break;
        const wv = session.word(pl.word);
        const end = pl.at(pl.width, lay.line_w);
        if (end.line < lay.first_line) continue;

        if (pl.cont and code and lay.text_x >= 2) {
            if (lay.rowY(pl.line)) |y| {
                r.moveTo(lay.text_x - 2, y);
                pen(r, theme.dimmer, null, false);
                r.write(WRAP_MARK);
            }
        }

        const is_active = typing and pl.word == active;
        const caret = if (is_active) session.caret() else std.math.maxInt(usize);
        const pace_at: ?usize = if (pace) |p| (if (p.word == pl.word) p.offset else null) else null;
        var prev_kind: ?LetterKind = null;
        var prev_syn: ?syntax.Kind = null;
        var row_y: ?usize = null;
        for (0..pl.width) |j| {
            const p = pl.at(j, lay.line_w);
            const y = lay.rowY(p.line) orelse continue;
            if (row_y != y or j == 0) {
                r.moveTo(lay.text_x + p.col, y);
                row_y = y;
            }
            var l = letter(wv, j);
            // Zen has no target: whatever was typed is right.
            if (zen and j < wv.typed.len) l = .{ .ch = wv.typed[j], .kind = .correct };
            if (j == caret) {
                if (syn and l.kind == .pending)
                    pen(r, draw.syntaxColor(theme, session.syntaxKind(pl.word, j)), null, false)
                else
                    applyLetter(r, theme, l.kind);
                const after_mistake = j > 0 and letter(wv, j - 1).kind != .correct and !zen;
                if (after_mistake) r.setBg(theme.error_bg);
                r.setBold(true);
                r.writeByte(l.ch);
                prev_kind = null;
                continue;
            }
            if (pace_at == j) {
                pen(r, theme.pace, null, false);
                draw.underline(r, true);
                r.writeByte(l.ch);
                prev_kind = null;
                continue;
            }
            if (syn and l.kind == .pending) {
                const k = session.syntaxKind(pl.word, j);
                if (prev_kind != .pending or prev_syn != k) {
                    pen(r, draw.syntaxColor(theme, k), null, false);
                    prev_kind = .pending;
                    prev_syn = k;
                }
            } else if (prev_kind != l.kind) {
                applyLetter(r, theme, l.kind);
                prev_kind = l.kind;
            }
            r.writeByte(l.ch);
        }
        r.resetStyle();

        // Separator: a space, or `↵` before a code line break.
        if (lay.rowY(end.line)) |y| {
            const sep_x = lay.text_x + end.col;
            const pace_here = pace_at == pl.width;
            switch (wv.sep) {
                .space => if (end.col < lay.line_w) {
                    r.moveTo(sep_x, y);
                    if (is_active and caret == pl.width and pl.width > 0 and letter(wv, pl.width - 1).kind != .correct and !zen)
                        pen(r, null, theme.error_bg, false)
                    else if (pace_here) {
                        pen(r, theme.pace, null, false);
                        draw.underline(r, true);
                    }
                    r.writeByte(' ');
                    r.resetStyle();
                },
                .newline => {
                    r.moveTo(sep_x, y);
                    pen(r, if (pace_here) theme.pace else if (is_active and caret == pl.width) theme.dim else theme.dimmer, null, false);
                    if (pace_here) draw.underline(r, true);
                    r.write(NEWLINE_MARK);
                    r.resetStyle();
                },
                .end => {},
            }
        }
    }
    r.resetStyle();
}

/// The live WPM on display and the half-second it was taken in. This is the
/// only state kept between frames: it makes the number change twice a
/// second instead of on every keystroke (recomputing at an earlier instant
/// would divide today's characters by yesterday's time).
var shown_wpm: struct { start: i64 = 0, bucket: i64 = -1, wpm: f32 = 0 } = .{};

/// Live numbers for the stats line, with the WPM held for `WPM_STEP_MS`.
fn liveStats(t: anytype, now_ms: i64) struct { now: @TypeOf(t.live(0)), wpm: f32 } {
    const now = t.live(now_ms);
    const start = t.start_time orelse return .{ .now = now, .wpm = now.wpm };
    const bucket = @divTrunc(@max(0, now_ms - start), WPM_STEP_MS);
    if (shown_wpm.start != start or shown_wpm.bucket != bucket) {
        shown_wpm = .{ .start = start, .bucket = bucket, .wpm = now.wpm };
    }
    return .{ .now = now, .wpm = shown_wpm.wpm };
}

/// Words in the generated text, for the idle bar (code, custom and practice
/// runs, whose length isn't the configured count).
fn generatedWords(t: anytype, ui: *const UiState) ?usize {
    if (ui.practice or t.config.mode == .code or query.isCustom(t)) return t.session.wordCount();
    return null;
}

fn renderStatsLine(r: Renderer, theme: *const Theme, t: anytype, ui: *const UiState, lay: TextLayout, f: Frame, now_ms: i64) void {
    if (t.state == .waiting) {
        config_bar.renderInfo(r, theme, f.col_x, lay.stats_y, f.col_w, t.config, ui, .{
            .words = generatedWords(t, ui),
            .practice = if (ui.practice) query.practiceKind(t) else null,
        });
        return;
    }
    const zen = query.isZen(t);
    const s = liveStats(t, now_ms);
    const lv = s.now;
    const max_x = f.col_x + f.col_w;
    var buf: [48]u8 = undefined;
    r.moveTo(lay.text_x, lay.stats_y);
    var x = lay.text_x;

    // Time: remaining when timed, else elapsed.
    if (lv.remaining_ms) |rem| {
        const secs: i64 = @divTrunc(@max(0, rem) + 999, 1000);
        pen(r, if (secs <= 5) theme.danger else if (secs <= 10) theme.extra else theme.accent, null, true);
        const v = draw.fmt(&buf, "{d}", .{secs});
        r.write(v);
        pen(r, theme.dimmer, null, false);
        r.write("s");
        x += v.len + 1;
    } else {
        pen(r, theme.dim, null, false);
        const v = draw.fmt(&buf, "{d:.1}", .{@as(f64, @floatFromInt(@max(0, lv.elapsed_ms))) / 1000.0});
        r.write(v);
        pen(r, theme.dimmer, null, false);
        r.write("s");
        x += v.len + 1;
    }

    // Progress: done / total (or just done when endless); zen has none.
    if (!zen) {
        const v = if (lv.words_total) |tot|
            draw.fmt(&buf, "{d}/{d}", .{ lv.words_done, tot })
        else
            draw.fmt(&buf, "{d}", .{lv.words_done});
        if (x + 3 + v.len <= max_x) {
            r.write("   ");
            pen(r, theme.dim, null, false);
            r.write(v);
            x += 3 + v.len;
        }
    }

    if (s.wpm > 0) {
        const v = draw.fmt(&buf, "{d:.0}", .{s.wpm});
        if (x + 3 + v.len + 4 <= max_x) {
            r.resetStyle();
            r.write("   ");
            pen(r, theme.accent, null, true);
            r.write(v);
            pen(r, theme.dimmer, null, false);
            r.write(" wpm");
            x += 3 + v.len + 4;
        }
    }

    // The pace caret's speed, next to the live one.
    if (ui.pace_wpm != null and !zen and t.state == .typing) {
        const v = draw.fmt(&buf, "pace {d:.0}", .{ui.pace_wpm.?});
        if (x + 3 + v.len <= max_x) {
            r.resetStyle();
            r.write("   ");
            pen(r, theme.dim, null, false);
            r.write(v);
            x += 3 + v.len;
        }
    }

    if (t.state == .typing and lv.keystrokes > 0 and !zen) {
        const v = draw.fmt(&buf, "{d:.0}%", .{lv.acc});
        if (x + 3 + v.len <= max_x) {
            r.resetStyle();
            r.write("   ");
            pen(r, theme.dim, null, false);
            r.write(v);
            x += 3 + v.len;
        }
    }
    r.resetStyle();

    // Sparkline of recent word speeds, right-aligned to the text block.
    const block_right = @min(max_x, lay.text_x + lay.line_w);
    if (t.state == .typing and block_right >= x + 4 + SPARK_COLS) {
        var speeds: [SPARK_COLS * 2]f32 = undefined;
        const n = wordSpeeds(&t.session, &speeds);
        if (n >= 2) renderSparkline(r, theme, block_right - SPARK_COLS, lay.stats_y, speeds[speeds.len - n ..]);
    }
}

const SPARK_COLS: usize = 12;

/// WPM of each recently committed word (its letters plus the space over the
/// time since the previous commit), oldest first, right-aligned in `out`.
/// Returns how many were filled (0 when the session has no word timing).
fn wordSpeeds(session: anytype, out: []f32) usize {
    const S = @typeInfo(@TypeOf(session)).pointer.child;
    if (comptime !@hasDecl(S, "commitMs")) return 0;
    var n: usize = 0;
    var i = session.activeIndex();
    while (i > 1 and n < out.len) : (i -= 1) {
        const end = session.commitMs(i - 1) orelse break;
        const begin = session.commitMs(i - 2) orelse break;
        if (end <= begin) continue;
        const chars: f32 = @floatFromInt(session.word(i - 1).target.len + 1);
        out[out.len - 1 - n] = chars / 5.0 / (@as(f32, @floatFromInt(end - begin)) / 60000.0);
        n += 1;
    }
    return n;
}

/// One-row braille sparkline: two samples per cell, bars of 1..4 dots.
fn renderSparkline(r: Renderer, theme: *const Theme, x: usize, y: usize, pts: []const f32) void {
    var max: f32 = 1;
    for (pts) |p| max = @max(max, p);
    const pad = SPARK_COLS * 2 - pts.len;
    r.moveTo(x, y);
    pen(r, theme.dim, null, false);
    for (0..SPARK_COLS) |cell| {
        var bits: u8 = 0;
        for (0..2) |half| {
            const slot = cell * 2 + half;
            if (slot < pad) continue;
            const level: usize = @intFromFloat(@round(std.math.clamp(pts[slot - pad] / max, 0, 1) * 3.0));
            for (0..level + 1) |k| bits |= glyph.brailleBit(half, 3 - k);
        }
        r.write(&glyph.braille(bits));
    }
    r.resetStyle();
}

fn footerHints(t: anytype, ui: *const UiState, out: *[draw.MAX_HINTS]draw.Hint) []const draw.Hint {
    var n: usize = 0;
    const add = struct {
        fn f(o: *[draw.MAX_HINTS]draw.Hint, i: *usize, key: []const u8, label: []const u8) void {
            o[i.*] = .{ .key = key, .label = label };
            i.* += 1;
        }
    }.f;
    const delete_word: []const u8 = if (ui.is_web) "ctrl+backspace" else "ctrl+w";
    if (query.isZen(t)) {
        add(out, &n, "esc", "finish");
        add(out, &n, "tab", "clear");
        add(out, &n, "ctrl+p", "settings");
        return out[0..n];
    }
    // When the row is too narrow, the hint just before the last one goes
    // first, so the least important hints sit there.
    add(out, &n, "esc", "restart");
    if (t.config.mode == .code and t.state == .waiting) {
        // Code can be retyped with real vim editing instead.
        add(out, &n, "ctrl+k", "vim keys");
        add(out, &n, "ctrl+p", "settings");
    } else if (isCode(t) and t.state == .typing) {
        add(out, &n, "enter", "skip line");
        add(out, &n, "ctrl+p", "settings");
        add(out, &n, delete_word, "delete word");
    } else {
        add(out, &n, delete_word, "delete word");
        add(out, &n, "ctrl+p", "settings");
    }
    if (t.state == .waiting) add(out, &n, "f2", "history");
    add(out, &n, "ctrl+c", if (ui.is_web) "restart" else "quit");
    return out[0..n];
}

/// Custom mode without text of its own: how to add some (above the text).
fn renderCustomHint(r: Renderer, theme: *const Theme, t: anytype, ui: *const UiState, lay: TextLayout, f: Frame) void {
    if (!query.isCustom(t) or t.state != .waiting or query.customText(t).len > 0) return;
    if (lay.text_y < lay.stats_y + 2) return;
    const msg: []const u8 = if (ui.is_web)
        "no custom text yet " ++ glyph.MIDDOT ++ " use the custom text button"
    else
        "no custom text yet " ++ glyph.MIDDOT ++ " paste here, or --text / --file";
    const len = @min(glyph.displayWidth(msg), f.col_w);
    r.moveTo(f.col_x + (f.col_w - len) / 2, lay.text_y - 1);
    pen(r, theme.dim, null, false);
    _ = draw.writeEllipsis(r, msg, f.col_w);
    r.resetStyle();
}

/// Whole screen for a simple-mode test that isn't finished.
pub fn render(r: Renderer, theme: *const Theme, t: anytype, ui: *const UiState, now_ms: i64) void {
    const f = draw.frameFor(r.width(), r.height());
    draw.clearRows(r, 0, r.height() -| 1);
    const focus = t.state == .typing;

    var chips: draw.Chips = .{};
    if (ui.practice) draw.chipsForPractice(&chips, query.practiceKind(t)) else draw.chipsFor(&chips, t.config);
    draw.renderHeader(r, theme, f, chips.slice(), focus);

    const lay = layout(t, f);
    renderStatsLine(r, theme, t, ui, lay, f, now_ms);
    renderCustomHint(r, theme, t, ui, lay, f);
    renderText(r, theme, t, lay, paceLoc(t, ui, now_ms));

    draw.renderToast(r, theme, f, ui.toast);
    var hints: [draw.MAX_HINTS]draw.Hint = undefined;
    draw.renderHints(r, theme, f.w, f.footer_y, footerHints(t, ui, &hints), focus);
}

/// Screen position of the caret.
pub fn cursorPos(t: anytype, w: usize, h: usize) struct { x: usize, y: usize } {
    const f = draw.frameFor(w, h);
    const lay = layout(t, f);
    const y = lay.rowY(lay.caret_line) orelse lay.text_y;
    return .{ .x = lay.text_x + lay.caret_col, .y = y };
}
