//! Vim `.drills` view: edit the buffer until it matches the goal.
//!
//! Header: `drills › <lesson> · <challenge>` with `n / total · par N · best
//! M ★★☆` on the right. The buffer and goal panes sit side by side when the
//! width allows (`2 × longest line + 16`), otherwise stacked with the goal on
//! top; each is a rounded box with line numbers and its own scrolling.
//! Buffer letters that differ from the goal are tinted (warning), lines that
//! already match are dimmed. Under the panes: the prompt, the revealed hint
//! and a vim status row, which the solved card replaces once the drill is
//! solved. A drill is solved only back in NORMAL: while the buffer already
//! matches the goal but insert (or the command line) is still open, the
//! prompt row says "matches the goal · press esc to finish".
//!
//! Columns are display columns (tabs expand), as in `vim_view`.
//!
//! `t` is `anytype` (a `*TypingTest` or a fixture with `state`, `config`,
//! `start_time`, `drill`, `live(now)` and `result()`).

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const pen = draw.pen;
const Frame = draw.Frame;
const Renderer = @import("../platform/renderer.zig").Renderer;
const UiState = @import("ui_state.zig").UiState;
const vim_view = @import("vim_view.zig");
const query = @import("query.zig");
const syntax = @import("../core/syntax.zig");

/// Position of the challenge in the catalog (from `vim/drill.zig`).
pub const Catalog = struct { index: usize = 0, total: usize = 0 };

/// Drills use a wider measure than prose.
const MAX_WIDTH: usize = 120;
/// Side-by-side panes span at least this many columns.
const MIN_SPAN: usize = 76;

// ============================================================================
// Layout
// ============================================================================

pub const Pane = struct {
    /// Box origin and size (`h` includes the borders; 0 = no box).
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    boxed: bool,
    /// Content area.
    gutter_x: usize,
    gutter_w: usize,
    text_x: usize,
    text_w: usize,
    text_y: usize,
    rows: usize,
    top: usize = 0,
    off: usize = 0,
};

pub const Layout = struct {
    x: usize,
    w: usize,
    buffer: Pane,
    goal: ?Pane,
    prompt_y: ?usize,
    hint_y: ?usize,
    status_y: usize,
    /// Solved card (3 rows) when finished.
    card_y: usize,
    card_rows: usize,
};

/// Widest buffer or goal line, in display columns.
fn longestLine(d: anytype) usize {
    const ts = query.tabstopOf(&d.editor);
    var n: usize = 0;
    for (0..d.editor.buffer.lineCount()) |row| n = @max(n, vim_view.displayLen(d.editor.buffer.getLine(row), ts));
    for (0..d.goalLineCount()) |row| n = @max(n, vim_view.displayLen(d.goalLine(row), ts));
    return n;
}

fn cursorCol(ed: anytype) usize {
    return query.displayCol(ed, ed.cursor.row, ed.cursor.col);
}

fn makePane(x: usize, y: usize, w: usize, rows: usize, lines: usize, boxed: bool) Pane {
    const gw = vim_view.gutterWidth(lines);
    const inset: usize = if (boxed) 2 else 0;
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = rows + (if (boxed) @as(usize, 2) else 0),
        .boxed = boxed,
        .gutter_x = x + inset,
        .gutter_w = gw,
        .text_x = x + inset + gw,
        .text_w = w -| (2 * inset + gw),
        .text_y = y + (if (boxed) @as(usize, 1) else 0),
        .rows = rows,
    };
}

/// Layout of the drill screen; sets the editor's viewport to the buffer
/// pane's rows.
pub fn layout(t: anytype, f: Frame) Layout {
    const d = &t.drill;
    const ed = &d.editor;
    const solved = t.state == .finished;
    const w = @max(1, @min(MAX_WIDTH, f.w -| 4));
    const x = (f.w -| w) / 2;
    const avail = f.rows();

    // Bottom block: prompt, hint, status (or the 3-row solved card).
    const want_hint = !solved and d.hint() != null;
    const status_rows: usize = if (solved) 3 else 1;
    var bottom = status_rows;
    const prompt = avail >= bottom + 3;
    if (prompt) bottom += 1;
    const hint = want_hint and avail >= bottom + 3;
    if (hint) bottom += 1;
    const gap: usize = if (avail >= bottom + 8) 1 else 0;
    bottom += gap;

    const panes_h = avail -| bottom;
    const buf_lines = @max(1, ed.buffer.lineCount());
    const goal_lines = @max(1, d.goalLineCount());
    const lines = @max(buf_lines, goal_lines);
    const longest = longestLine(d);

    var lay: Layout = undefined;
    lay.x = x;
    lay.w = w;
    // Side by side when both panes fit their longest line.
    const pw = (w -| 2) / 2;
    const side_text_w = pw -| (4 + vim_view.gutterWidth(lines));
    const side = w >= 2 * longest + 16 and side_text_w > longest and panes_h >= 3;
    if (side) {
        const rows = @max(1, @min(lines, panes_h - 2));
        // Panes only as wide as their text needs (plus room to type).
        // Everything (header, prompt, status) then lines up with them.
        const fit = @max((@min(w, MIN_SPAN) -| 2) / 2, longest + 4 + vim_view.gutterWidth(lines) + 12);
        const sw = @min(pw, fit);
        lay.w = 2 * sw + 2;
        lay.x = x + (w - lay.w) / 2;
        lay.buffer = makePane(lay.x, f.top, sw, rows, buf_lines, true);
        lay.goal = makePane(lay.x + lay.w - sw, f.top, sw, rows, goal_lines, true);
    } else if (panes_h >= 6) {
        const content = panes_h - 4;
        const goal_rows = @max(1, @min(goal_lines, content / 2));
        const buf_rows = @max(1, @min(lines, content - goal_rows));
        lay.goal = makePane(x, f.top, w, goal_rows, goal_lines, true);
        lay.buffer = makePane(x, f.top + goal_rows + 2, w, buf_rows, buf_lines, true);
    } else {
        // Cramped: the buffer alone, without a box.
        lay.goal = null;
        lay.buffer = makePane(x, f.top, w, @max(1, @min(buf_lines, panes_h)), buf_lines, false);
    }

    const panes_end = @max(lay.buffer.y + lay.buffer.h, if (lay.goal) |g| g.y + g.h else 0);
    var y = panes_end + gap;
    lay.prompt_y = null;
    lay.hint_y = null;
    if (prompt) {
        lay.prompt_y = y;
        y += 1;
    }
    if (hint) {
        lay.hint_y = y;
        y += 1;
    }
    lay.status_y = @min(y, f.bottom);
    lay.card_y = lay.status_y;
    lay.card_rows = if (solved) @min(3, f.bottom + 1 -| lay.status_y) else 0;

    // Scrolling: the editor keeps its cursor in view; the goal follows.
    ed.setViewport(lay.buffer.rows);
    lay.buffer.top = vim_view.keepVisible(@min(ed.viewTop(), buf_lines -| 1), ed.cursor.row, lay.buffer.rows);
    if (longest + 1 > lay.buffer.text_w) lay.buffer.off = draw.hscroll(cursorCol(ed), lay.buffer.text_w);
    if (lay.goal) |*g| {
        g.top = @min(lay.buffer.top, goal_lines -| g.rows);
        g.off = if (g.text_w == lay.buffer.text_w) lay.buffer.off else 0;
    }
    return lay;
}

// ============================================================================
// Rendering
// ============================================================================

fn renderHeader(r: Renderer, theme: *const Theme, f: Frame, lay: Layout, t: anytype, ui: *const UiState, cat: Catalog) void {
    const ch = t.drill.challenge orelse return;
    var right_buf: [64]u8 = undefined;
    var star_buf: [9]u8 = undefined;
    const right = if (ui.drill_best) |b|
        draw.fmt(&right_buf, "{d} / {d}  " ++ glyph.MIDDOT ++ "  par {d}  " ++ glyph.MIDDOT ++ "  best {d} {s}", .{ cat.index + 1, cat.total, ch.par, b.strokes, draw.starString(&star_buf, b.stars) })
    else
        draw.fmt(&right_buf, "{d} / {d}  " ++ glyph.MIDDOT ++ "  par {d}", .{ cat.index + 1, cat.total, ch.par });
    const rw = glyph.displayWidth(right);
    const focus = t.state == .typing;

    r.moveTo(lay.x, f.header_y);
    pen(r, if (focus) theme.dimmer else theme.accent, null, !focus);
    var used = draw.writeClip(r, "drills " ++ glyph.CHEVRON ++ " ", lay.w);
    const left_max = if (lay.w > rw + 2 + used) lay.w - rw - 2 else lay.w;
    pen(r, if (focus) theme.dimmer else theme.dim, null, false);
    var lbuf: [160]u8 = undefined;
    const left = draw.fmt(&lbuf, "{s} " ++ glyph.MIDDOT ++ " {s}", .{ ch.lesson.title(), ch.title });
    used += draw.writeEllipsis(r, left, left_max -| used);
    if (used + 2 + rw <= lay.w) {
        r.moveTo(lay.x + lay.w - rw, f.header_y);
        pen(r, if (focus) theme.dimmer else theme.dim, null, false);
        r.write(right);
    }
    r.resetStyle();
    if (f.rule_y) |ry| {
        r.moveTo(lay.x, ry);
        pen(r, theme.dimmer, null, false);
        draw.repeat(r, glyph.box.h, lay.w);
        r.resetStyle();
    }
}

fn renderBufferPane(r: Renderer, theme: *const Theme, t: anytype, p: Pane) void {
    const d = &t.drill;
    const ed = &d.editor;
    if (p.boxed) draw.drawCard(r, theme, p.x, p.y, p.w, p.h, " buffer ");
    const show_cursor = t.state != .finished and ed.mode != .cmdline;
    const search_bg = theme.surface(0.16) orelse theme.visual_bg;
    const cur = vim_view.cursorColors(theme, ed.mode);
    const ts = query.tabstopOf(ed);
    const cur_col = cursorCol(ed);
    const w = @min(p.text_w, vim_view.MAX_CELLS);
    var cells: [vim_view.MAX_CELLS]vim_view.Cell = undefined;
    for (0..p.rows) |i| {
        const row = p.top + i;
        if (row >= ed.buffer.lineCount()) break;
        const y = p.text_y + i;
        const is_cur = row == ed.cursor.row;
        pen(r, if (is_cur) theme.dim else theme.dimmer, null, false);
        vim_view.renderLineNumber(r, p.gutter_x, y, row + 1, p.gutter_w);
        const line = ed.buffer.getLine(row);
        const len = vim_view.displayLen(line, ts);
        const n = vim_view.expand(line, ts, p.off, cells[0..w]);
        const matches = d.lineMatches(row);
        r.moveTo(p.text_x, y);
        for (0..w) |c| {
            const col = p.off + c;
            const cursor_here = show_cursor and is_cur and col == cur_col;
            if (!cursor_here) {
                if (c == 0 and p.off > 0 and len > 0) {
                    pen(r, theme.dimmer, null, false);
                    r.write(vim_view.LEFT_MARK);
                    continue;
                }
                if (c + 1 == p.text_w and len > col + 1) {
                    pen(r, theme.dimmer, null, false);
                    r.write(vim_view.RIGHT_MARK);
                    continue;
                }
            }
            if (col >= len and !cursor_here) break;
            const cell: ?vim_view.Cell = if (c < n) cells[c] else null;
            if (cursor_here) {
                pen(r, cur.fg, cur.bg, false);
            } else if (cell != null and ed.isInSelection(row, cell.?.byte)) {
                pen(r, theme.visual_fg, theme.visual_bg, false);
            } else if (cell) |cl| {
                const fg = if (matches) theme.dim else if (d.charDiffers(row, cl.byte)) theme.warning else theme.text();
                pen(r, fg, if (ed.isSearchMatch(row, cl.byte)) search_bg else null, false);
            }
            r.writeByte(if (cell) |cl| cl.ch else ' ');
        }
        r.resetStyle();
    }
}

/// Language of the drill's code (drills are unlabelled).
fn guessLang(d: anytype) @import("../core/types.zig").Lang {
    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    for (0..d.goalLineCount()) |row| {
        const line = d.goalLine(row);
        if (n + line.len + 1 > buf.len) break;
        @memcpy(buf[n..][0..line.len], line);
        buf[n + line.len] = '\n';
        n += line.len + 1;
    }
    return syntax.guessLang(buf[0..n]);
}

/// Syntax colour on the goal pane: the theme's tint brightened halfway to
/// the text colour.
fn goalColor(theme: *const Theme, k: syntax.Kind) @import("color.zig").Color {
    const c = draw.syntaxColor(theme, k);
    return if (theme.text()) |fg| c.mix(fg, 0.4) else c;
}

fn renderGoalPane(r: Renderer, theme: *const Theme, t: anytype, p: Pane) void {
    const d = &t.drill;
    draw.drawCard(r, theme, p.x, p.y, p.w, p.h, " goal ");
    const ts = query.tabstopOf(&d.editor);
    const w = @min(p.text_w, vim_view.MAX_CELLS);
    var cells: [vim_view.MAX_CELLS]vim_view.Cell = undefined;
    // Lines still to reach are tinted by syntax class (brightened toward
    // the text colour: the goal is reference text, not untyped text).
    const syn = query.cfgBool(t.config, "syntax", false);
    var hl: draw.Highlighter = .{ .lang = if (syn) guessLang(d) else .mixed };
    if (syn) {
        for (0..@min(p.top, d.goalLineCount())) |row| _ = hl.line(d.goalLine(row));
    }
    for (0..p.rows) |i| {
        const row = p.top + i;
        if (row >= d.goalLineCount()) break;
        const y = p.text_y + i;
        pen(r, theme.dimmer, null, false);
        vim_view.renderLineNumber(r, p.gutter_x, y, row + 1, p.gutter_w);
        const line = d.goalLine(row);
        const len = vim_view.displayLen(line, ts);
        const n = vim_view.expand(line, ts, p.off, cells[0..w]);
        const kinds = if (syn) hl.line(line) else &.{};
        const matches = d.lineMatches(row);
        r.moveTo(p.text_x, y);
        const base = if (matches) theme.dim else theme.text();
        pen(r, base, null, false);
        var prev: ?syntax.Kind = null;
        for (0..n) |c| {
            const col = p.off + c;
            if ((c == 0 and p.off > 0) or (c + 1 == p.text_w and len > col + 1)) {
                pen(r, theme.dimmer, null, false);
                r.write(if (c == 0) vim_view.LEFT_MARK else vim_view.RIGHT_MARK);
                prev = null;
                continue;
            }
            const b = cells[c].byte;
            if (!matches and b < kinds.len and kinds[b] != .plain) {
                if (prev != kinds[b]) pen(r, goalColor(theme, kinds[b]), null, false);
                prev = kinds[b];
            } else if (prev != .plain) {
                pen(r, base, null, false);
                prev = .plain;
            }
            r.writeByte(cells[c].ch);
        }
        r.resetStyle();
    }
}

/// Solved card:
///   solved ★★☆  9 keys (par 5) · 3.1s        ▲ new best
///   you   F(ldt)ix<Esc>
///   par   ci(x<Esc>   — why
fn renderSolved(r: Renderer, theme: *const Theme, t: anytype, ui: *const UiState, lay: Layout) void {
    const d = &t.drill;
    const ch = d.challenge orelse return;
    const res = t.result() orelse return;
    const x = lay.x;
    const w = lay.w;
    var y = lay.card_y;
    if (lay.card_rows == 0) return;

    var buf: [96]u8 = undefined;
    var star_buf: [9]u8 = undefined;
    r.moveTo(x, y);
    pen(r, theme.success, null, true);
    var used = draw.writeClip(r, "solved ", w);
    pen(r, theme.accent, null, true);
    used += draw.writeClip(r, draw.starString(&star_buf, res.stars), w -| used);
    pen(r, theme.dim, null, false);
    const strokes = if (res.strokes > 0) res.strokes else d.strokes();
    const par = if (res.par > 0) res.par else ch.par;
    const secs = @as(f32, @floatFromInt(res.duration_ms)) / 1000.0;
    used += draw.writeClip(r, draw.fmt(&buf, "  {d} keys (par {d}) " ++ glyph.MIDDOT ++ " {d:.1}s", .{ strokes, par, secs }), w -| used);
    if (ui.pb == .improved and used + 14 <= w) {
        r.moveTo(x + w - 12, y);
        pen(r, theme.accent, null, true);
        r.write("▲ new best");
    }
    r.resetStyle();
    y += 1;
    if (y >= lay.card_y + lay.card_rows) return;

    r.moveTo(x, y);
    pen(r, theme.dim, null, false);
    used = draw.writeClip(r, "you   ", w);
    pen(r, theme.text(), null, false);
    _ = draw.writeEllipsis(r, d.keylog(), w -| used);
    r.resetStyle();
    y += 1;
    if (y >= lay.card_y + lay.card_rows) return;

    if (ch.solutions.len > 0) {
        r.moveTo(x, y);
        pen(r, theme.dim, null, false);
        used = draw.writeClip(r, "par   ", w);
        pen(r, theme.accent, null, false);
        used += draw.writeClip(r, ch.solutions[0], w -| used);
        if (ch.why.len > 0 and used + 8 < w) {
            pen(r, theme.dim, null, false);
            used += draw.writeClip(r, "   — ", w -| used);
            _ = draw.writeEllipsis(r, ch.why, w -| used);
        }
        r.resetStyle();
    }
}

fn footerHints(t: anytype, ui: *const UiState, out: *[draw.MAX_HINTS]draw.Hint) []const draw.Hint {
    _ = ui;
    if (t.state == .finished) {
        out[0] = .{ .key = "enter", .label = "next" };
        out[1] = .{ .key = "r", .label = "retry" };
        out[2] = .{ .key = "tab", .label = "skip" };
        return out[0..3];
    }
    out[0] = .{ .key = "f1", .label = "hint" };
    out[1] = .{ .key = ":e!", .label = "retry" };
    out[2] = .{ .key = "tab", .label = "skip (normal mode)" };
    out[3] = .{ .key = "ctrl+p", .label = "settings" };
    return out[0..4];
}

pub fn render(r: Renderer, theme: *const Theme, t: anytype, ui: *const UiState, cat: Catalog, now_ms: i64) void {
    const f = draw.frameFor(r.width(), r.height());
    draw.clearRows(r, 0, r.height() -| 1);
    var hints: [draw.MAX_HINTS]draw.Hint = undefined;
    const d = &t.drill;
    const ch = d.challenge orelse {
        r.moveTo(f.col_x, f.top);
        pen(r, theme.dim, null, false);
        _ = draw.writeClip(r, "no drill loaded", f.col_w);
        r.resetStyle();
        draw.renderHints(r, theme, f.w, f.footer_y, footerHints(t, ui, &hints), false);
        return;
    };
    const lay = layout(t, f);
    renderHeader(r, theme, f, lay, t, ui, cat);
    if (lay.goal) |g| renderGoalPane(r, theme, t, g);
    renderBufferPane(r, theme, t, lay.buffer);

    const ready = t.state != .finished and query.drillMatchesGoal(d) and !query.drillSolved(d);
    if (ready) {
        // Solved only back in NORMAL: say so where the prompt was.
        if (lay.prompt_y orelse lay.hint_y) |py| {
            r.moveTo(lay.x, py);
            pen(r, theme.success, null, true);
            _ = draw.writeEllipsis(r, "matches the goal " ++ glyph.MIDDOT ++ " press esc to finish", lay.w);
            r.resetStyle();
        }
    } else if (lay.prompt_y) |py| {
        r.moveTo(lay.x, py);
        pen(r, theme.dim, null, false);
        var used = draw.writeClip(r, "\u{201C}", lay.w);
        pen(r, theme.text(), null, false);
        used += draw.writeEllipsis(r, ch.prompt, lay.w -| used -| 1);
        pen(r, theme.dim, null, false);
        _ = draw.writeClip(r, "\u{201D}", lay.w -| used);
        r.resetStyle();
    }
    if (lay.hint_y) |hy| {
        if (d.hint()) |h| {
            r.moveTo(lay.x, hy);
            pen(r, theme.info, null, false);
            const used = draw.writeClip(r, "hint  ", lay.w);
            pen(r, theme.text(), null, false);
            _ = draw.writeEllipsis(r, h, lay.w -| used);
            r.resetStyle();
        }
    }

    if (t.state == .finished) {
        renderSolved(r, theme, t, ui, lay);
    } else {
        var buf: [48]u8 = undefined;
        const lv = t.live(now_ms);
        const right = if (t.state == .typing)
            draw.fmt(&buf, "keys {d}   {d:.1}s", .{ d.strokes(), @as(f64, @floatFromInt(@max(0, lv.elapsed_ms))) / 1000.0 })
        else
            draw.fmt(&buf, "keys {d}", .{d.strokes()});
        _ = vim_view.renderStatus(r, theme, &d.editor, lay.x, lay.status_y, lay.w, false, right);
    }

    draw.renderToast(r, theme, f, ui.toast);
    draw.renderHints(r, theme, f.w, f.footer_y, footerHints(t, ui, &hints), t.state == .typing);
}

pub const Pos = vim_view.Pos;

/// Hardware cursor: the command line, else the buffer pane's cursor; hidden
/// once solved.
pub fn cursorPos(t: anytype, w: usize, h: usize) Pos {
    const f = draw.frameFor(w, h);
    if (t.state == .finished or t.drill.challenge == null) return .{ .x = 0, .y = f.footer_y, .visible = false };
    const ed = &t.drill.editor;
    const lay = layout(t, f);
    if (ed.cmdline()) |cl| {
        return .{ .x = lay.x + @min(glyph.displayWidth(cl), lay.w -| 1), .y = lay.status_y, .visible = true };
    }
    const p = lay.buffer;
    return .{
        .x = p.text_x + @min(cursorCol(ed) -| p.off, p.text_w -| 1),
        .y = p.text_y + @min(ed.cursor.row -| p.top, p.rows -| 1),
        .visible = true,
    };
}
