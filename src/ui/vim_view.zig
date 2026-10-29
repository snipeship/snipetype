//! Vim `.type` view: retype the ghost target in a line-numbered buffer.
//! Also code mode with vim keys (`code · <lang> · vim keys`): the same
//! screen on one code snippet.
//!
//! Columns are display columns: a tab expands to the editor's `tabstop`, and
//! the cursor, selections (including visual-block rectangles, which never
//! extend past a short line's text) and horizontal scrolling all follow
//! `displayCol`.
//!
//! The gutter starts at the header column. The buffer scrolls vertically
//! with the editor's own viewport (`setViewport` / `viewTop`) and
//! horizontally per view in half-width steps, with `‹ ›` markers on lines
//! that continue past either edge; the caret always stays visible. Below
//! the buffer a vim-style status row shows the mode pill, `recording @q`,
//! the editor's message, pending keys (showcmd) and `row:col`, or the
//! command line while one is being typed.
//!
//! `t` is `anytype` (a `*TypingTest` or a fixture with `state`, `config`,
//! `start_time`, `vim`, `target_lines`, `live(now)` and `result()`).

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const Color = @import("color.zig").Color;
const glyph = @import("ansi.zig");
const draw = @import("draw.zig");
const pen = draw.pen;
const Frame = draw.Frame;
const Renderer = @import("../platform/renderer.zig").Renderer;
const UiState = @import("ui_state.zig").UiState;
const results = @import("results.zig");
const query = @import("query.zig");

pub const LEFT_MARK = "‹";
pub const RIGHT_MARK = "›";

/// Line-number gutter width ("nnn "), at least 3 digits.
pub fn gutterWidth(lines: usize) usize {
    var digits: usize = 1;
    var n = @max(lines, 1);
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(3, digits) + 1;
}

/// Right-aligned line number in a `gutter_w` wide gutter (last cell blank).
pub fn renderLineNumber(r: Renderer, x: usize, y: usize, n: usize, gutter_w: usize) void {
    var buf: [24]u8 = undefined;
    const s = draw.fmt(&buf, "{d}", .{n});
    r.moveTo(x + (gutter_w -| 1 -| s.len), y);
    r.write(s);
}

// ============================================================================
// Status row (shared with the drill view)
// ============================================================================

pub fn pill(theme: *const Theme, mode: anytype) ?struct { text: []const u8, color: Color } {
    if (query.is(mode, "insert")) return .{ .text = "-- INSERT --", .color = theme.success };
    if (query.is(mode, "replace")) return .{ .text = "-- REPLACE --", .color = theme.danger };
    if (query.is(mode, "visual")) return .{ .text = "-- VISUAL --", .color = theme.info };
    if (query.is(mode, "visual_line")) return .{ .text = "-- V-LINE --", .color = theme.info };
    if (query.is(mode, "visual_block")) return .{ .text = "-- VISUAL BLOCK --", .color = theme.info };
    return null;
}

/// Colours of the cursor cell: insert and replace use the insert pair.
pub fn cursorColors(theme: *const Theme, mode: anytype) struct { fg: Color, bg: Color } {
    if (query.is(mode, "insert") or query.is(mode, "replace")) return .{ .fg = theme.cursor_insert_fg, .bg = theme.cursor_insert_bg };
    return .{ .fg = theme.cursor_fg, .bg = theme.cursor_bg };
}

/// Mode pill · recording · message · showcmd and position (right), in
/// [x, x + w) on row `y`; the command line replaces it all while typed.
/// `right` is extra text drawn before showcmd (e.g. "keys 12"). Returns
/// the command-line caret column when one is shown.
pub fn renderStatus(r: Renderer, theme: *const Theme, ed: anytype, x: usize, y: usize, w: usize, done: bool, right: []const u8) ?usize {
    r.moveTo(x, y);
    if (ed.cmdline()) |cl| {
        pen(r, theme.text(), null, false);
        // Keep the end (where the caret is) visible.
        const len = glyph.displayWidth(cl);
        const max = w -| 1;
        const skip = len -| max;
        _ = draw.writeClip(r, cl[@min(cl.len, skip)..], max);
        r.resetStyle();
        return x + @min(len, max);
    }

    var used: usize = 0;
    if (done) {
        pen(r, draw.onFill(theme), theme.success, true);
        used += draw.writeClip(r, " done ", w);
        r.resetStyle();
    } else if (pill(theme, ed.mode)) |p| {
        pen(r, p.color, null, true);
        used += draw.writeClip(r, p.text, w);
        r.resetStyle();
    }
    if (ed.recording()) |reg| {
        var buf: [16]u8 = undefined;
        const s = draw.fmt(&buf, "recording @{c}", .{reg});
        if (used + 2 + s.len <= w) {
            if (used > 0) {
                r.write("  ");
                used += 2;
            }
            pen(r, theme.danger, null, false);
            r.write(s);
            used += s.len;
        }
    }

    // Right: extra · showcmd · row:col.
    var rbuf: [96]u8 = undefined;
    const sc = ed.showcmd();
    const rtext = draw.fmt(&rbuf, "{s}{s}{s}   {d}:{d}", .{
        right,
        if (right.len > 0 and sc.len > 0) "   " else "",
        sc,
        ed.cursor.row + 1,
        ed.cursor.col + 1,
    });
    const rw = glyph.displayWidth(rtext);
    const right_x = if (used + 2 + rw <= w) x + w - rw else null;

    // Centre: the editor's message, clipped to the space between.
    const msg = ed.statusMsg();
    if (msg.len > 0) {
        const left_end = x + used + 2;
        const right_start = right_x orelse x + w;
        const room = right_start -| left_end -| 2;
        if (room >= 4) {
            const mw = @min(glyph.displayWidth(msg), room);
            r.moveTo(left_end + (room - mw) / 2, y);
            const is_err = msg.len > 1 and msg[0] == 'E' and std.ascii.isDigit(msg[1]);
            pen(r, if (is_err) theme.danger else theme.dim, null, false);
            _ = draw.writeEllipsis(r, msg, room);
        }
    }

    if (right_x) |rx| {
        r.moveTo(rx, y);
        if (right.len > 0) {
            pen(r, theme.dim, null, false);
            r.write(right);
            if (sc.len > 0) r.write("   ");
        }
        if (sc.len > 0) {
            pen(r, theme.accent, null, true);
            r.write(sc);
        }
        pen(r, theme.dimmer, null, false);
        r.print("   {d}:{d}", .{ ed.cursor.row + 1, ed.cursor.col + 1 });
    }
    r.resetStyle();
    return null;
}

// ============================================================================
// Display columns
// ============================================================================

/// Widest window drawn per row (wider panes are clipped to this).
pub const MAX_CELLS: usize = 512;

/// One screen cell of a line, in display columns.
pub const Cell = struct {
    /// Byte to draw (a space for every column of a tab).
    ch: u8,
    /// Byte column in the line.
    byte: usize,
};

/// Cells of `line` for display columns [off, off + out.len); returns how
/// many of them the line covers (tabs expand to `tabstop`).
pub fn expand(line: []const u8, tabstop: usize, off: usize, out: []Cell) usize {
    var d: usize = 0;
    var n: usize = 0;
    for (line, 0..) |c, b| {
        const w = if (c == '\t') query.nextTabStop(d, tabstop) - d else 1;
        for (0..w) |k| {
            const col = d + k;
            if (col < off) continue;
            if (col - off >= out.len) return out.len;
            out[col - off] = .{ .ch = if (c == '\t') ' ' else c, .byte = b };
            n = col - off + 1;
        }
        d += w;
    }
    return n;
}

/// Display width of `line`.
pub fn displayLen(line: []const u8, tabstop: usize) usize {
    return query.displayColOf(line, line.len, tabstop);
}

// ============================================================================
// Layout
// ============================================================================

pub const BufLayout = struct {
    stats_y: usize,
    gutter_x: usize,
    gutter_w: usize,
    text_x: usize,
    text_w: usize,
    /// Screen row of the first buffer row shown, and how many are shown.
    y: usize,
    rows: usize,
    /// First buffer row shown; horizontal offset.
    top: usize,
    off: usize,
    status_y: usize,
    /// Results card area (finished only).
    card_y: usize = 0,
    card_h: usize = 0,
};

fn totalLines(t: anytype) usize {
    return @max(t.target_lines.items.len, t.vim.buffer.lineCount());
}

/// Widest of the shown rows (target or buffer), in display columns.
fn longestLine(t: anytype, top: usize, rows: usize) usize {
    const ts = query.tabstopOf(&t.vim);
    var n: usize = 0;
    for (top..top + rows) |row| {
        const tl = if (row < t.target_lines.items.len) displayLen(t.target_lines.items[row], ts) else 0;
        const bl = if (row < t.vim.buffer.lineCount()) displayLen(t.vim.buffer.getLine(row), ts) else 0;
        n = @max(n, @max(tl, bl));
    }
    return n;
}

/// The cursor's display column.
fn cursorCol(ed: anytype) usize {
    return query.displayCol(ed, ed.cursor.row, ed.cursor.col);
}

/// Layout of the buffer view; sets the editor's viewport to the rows shown.
pub fn layout(t: anytype, f: Frame) BufLayout {
    const ed = &t.vim;
    const total = totalLines(t);
    const gw = gutterWidth(total);
    const finished = t.state == .finished;
    const roomy = f.rows() >= 8;
    const y0 = f.top + @as(usize, if (roomy) 2 else 1);
    var lay: BufLayout = .{
        .stats_y = f.top,
        .gutter_x = f.col_x,
        .gutter_w = gw,
        .text_x = f.col_x + gw,
        .text_w = f.col_w -| gw,
        .y = y0,
        .rows = 0,
        .top = 0,
        .off = 0,
        .status_y = f.bottom,
    };
    if (finished) {
        // Buffer on top, status row, results card below (when it fits).
        const avail = f.bottom + 1 -| y0;
        if (avail < 16) return lay;
        lay.rows = @max(1, @min(total, avail -| 13));
        lay.status_y = y0 + lay.rows;
        lay.card_y = lay.status_y + 2;
        lay.card_h = f.bottom + 1 -| lay.card_y;
    } else {
        const last = f.bottom -| @as(usize, if (roomy) 2 else 1);
        const avail = last + 1 -| y0;
        lay.rows = @max(1, @min(total, avail));
        // A short buffer sits a little lower in a tall area.
        lay.y = y0 + (avail -| lay.rows) / 3;
    }
    ed.setViewport(lay.rows);
    lay.top = keepVisible(@min(ed.viewTop(), total -| 1), ed.cursor.row, lay.rows);
    if (longestLine(t, lay.top, @min(lay.rows, total -| lay.top)) + 1 > lay.text_w)
        lay.off = draw.hscroll(cursorCol(ed), lay.text_w);
    return lay;
}

/// `top` adjusted so `row` is inside [top, top + rows) (the editor keeps
/// its cursor in view, but its viewport may lag a resize by a frame).
pub fn keepVisible(top: usize, row: usize, rows: usize) usize {
    if (rows == 0) return top;
    if (row < top) return row;
    if (row >= top + rows) return row + 1 - rows;
    return top;
}

// ============================================================================
// Rendering
// ============================================================================

fn renderBuffer(r: Renderer, theme: *const Theme, t: anytype, lay: BufLayout) void {
    const ed = &t.vim;
    const target = t.target_lines.items;
    const search_bg = theme.surface(0.16) orelse theme.visual_bg;
    const show_cursor = t.state != .finished and ed.mode != .cmdline;
    const cur = cursorColors(theme, ed.mode);
    const ts = query.tabstopOf(ed);
    const cur_col = cursorCol(ed);
    const w = @min(lay.text_w, MAX_CELLS);
    var bcells: [MAX_CELLS]Cell = undefined;
    var tcells: [MAX_CELLS]Cell = undefined;
    // The ghost target is tinted by syntax class, tokenized from its first
    // line so block comments and strings carry over.
    const syn = query.cfgBool(t.config, "syntax", false);
    var hl: draw.Highlighter = .{ .lang = query.codeLang(t) };
    if (syn) {
        for (target[0..@min(lay.top, target.len)]) |line| _ = hl.line(line);
    }
    for (0..lay.rows) |i| {
        const row = lay.top + i;
        const y = lay.y + i;
        const is_cur = row == ed.cursor.row;
        if (row >= totalLines(t)) break;

        pen(r, if (is_cur) theme.dim else theme.dimmer, null, false);
        renderLineNumber(r, lay.gutter_x, y, row + 1, lay.gutter_w);

        const tl = if (row < target.len) target[row] else "";
        const bl = if (row < ed.buffer.lineCount()) ed.buffer.getLine(row) else "";
        const len = @max(displayLen(tl, ts), displayLen(bl, ts));
        const bn = expand(bl, ts, lay.off, bcells[0..w]);
        const tn = expand(tl, ts, lay.off, tcells[0..w]);
        const kinds = if (syn and row < target.len) hl.line(tl) else &.{};
        r.moveTo(lay.text_x, y);
        for (0..w) |c| {
            const col = lay.off + c;
            const cursor_here = show_cursor and is_cur and col == cur_col;
            if (!cursor_here) {
                if (c == 0 and lay.off > 0 and len > 0) {
                    pen(r, theme.dimmer, null, false);
                    r.write(LEFT_MARK);
                    continue;
                }
                if (c + 1 == lay.text_w and len > col + 1) {
                    pen(r, theme.dimmer, null, false);
                    r.write(RIGHT_MARK);
                    continue;
                }
            }
            if (col >= len and !cursor_here) break;
            const typed: ?Cell = if (c < bn) bcells[c] else null;
            const tgt: ?Cell = if (c < tn) tcells[c] else null;
            if (cursor_here) {
                pen(r, cur.fg, cur.bg, false);
            } else if (typed != null and ed.isInSelection(row, typed.?.byte)) {
                pen(r, theme.visual_fg, theme.visual_bg, false);
            } else if (typed) |b| {
                const fg = if (tgt) |g| (if (g.ch == b.ch) theme.text() else theme.danger) else theme.error_extra;
                pen(r, fg, if (ed.isSearchMatch(row, b.byte)) search_bg else null, false);
            } else if (tgt != null and tgt.?.byte < kinds.len) {
                pen(r, draw.syntaxColor(theme, kinds[tgt.?.byte]), null, false);
            } else {
                pen(r, theme.dim, null, false);
            }
            r.writeByte(if (typed) |b| b.ch else if (tgt) |g| g.ch else ' ');
        }
        r.resetStyle();
    }
}

fn renderStatsLine(r: Renderer, theme: *const Theme, t: anytype, lay: BufLayout, width: usize, now_ms: i64) void {
    r.moveTo(lay.gutter_x, lay.stats_y);
    var out: draw.Pieces = .{ .r = r, .left = width };
    var buf: [32]u8 = undefined;
    switch (t.state) {
        .waiting => out.put(theme.dim, false, "press i to start typing" ++ glyph.ELLIPSIS),
        .typing => {
            const lv = t.live(now_ms);
            if (lv.remaining_ms) |rem| {
                const secs: i64 = @divTrunc(@max(0, rem) + 999, 1000);
                out.put(if (secs <= 5) theme.danger else if (secs <= 10) theme.extra else theme.accent, true, draw.fmt(&buf, "{d}", .{secs}));
            } else {
                out.put(theme.dim, false, draw.fmt(&buf, "{d:.1}", .{@as(f64, @floatFromInt(@max(0, lv.elapsed_ms))) / 1000.0}));
            }
            out.put(theme.dimmer, false, "s");
            if (lv.wpm > 0) {
                out.put(null, false, "   ");
                out.put(theme.accent, true, draw.fmt(&buf, "{d:.0}", .{lv.wpm}));
                out.put(theme.dimmer, false, " wpm");
            }
            out.put(null, false, "   ");
            out.put(theme.dim, false, draw.fmt(&buf, "{d}", .{t.vim.stats().keystrokes}));
            out.put(theme.dimmer, false, " keys");
        },
        .finished => {},
    }
    r.resetStyle();
}

fn footerHints(t: anytype, ui: *const UiState, out: *[draw.MAX_HINTS]draw.Hint) []const draw.Hint {
    const ed = &t.vim;
    var n: usize = 0;
    if (ed.mode == .insert or ed.mode == .replace) {
        out[n] = .{ .key = "esc", .label = "normal" };
        n += 1;
        out[n] = .{ .key = if (ui.is_web) "ctrl+backspace" else "ctrl+w", .label = "delete word" };
        n += 1;
    } else {
        out[n] = .{ .key = "tab", .label = "new" };
        n += 1;
        out[n] = .{ .key = ":w", .label = "finish" };
        n += 1;
        // Code with vim keys: one key back to plain typing.
        if (query.isCodeVim(t) and t.state == .waiting) {
            out[n] = .{ .key = "ctrl+k", .label = "plain keys" };
            n += 1;
        }
    }
    out[n] = .{ .key = "ctrl+p", .label = "settings" };
    n += 1;
    out[n] = .{ .key = ":q!", .label = if (ui.is_web) "restart" else "quit" };
    n += 1;
    return out[0..n];
}

pub fn render(r: Renderer, theme: *const Theme, t: anytype, ui: *const UiState, now_ms: i64) void {
    const f = draw.frameFor(r.width(), r.height());
    const finished = t.state == .finished;
    const lay = layout(t, f);
    if (finished and lay.rows == 0) {
        if (t.result()) |res| return results.renderAnimated(r, theme, res, t.config, ui, now_ms);
    }

    draw.clearRows(r, 0, r.height() -| 1);
    var chips: draw.Chips = .{};
    draw.chipsFor(&chips, t.config);
    draw.renderHeader(r, theme, f, chips.slice(), t.state == .typing);

    renderStatsLine(r, theme, t, lay, f.col_w, now_ms);
    renderBuffer(r, theme, t, lay);
    _ = renderStatus(r, theme, &t.vim, lay.gutter_x, lay.status_y, f.col_w, finished, "");

    var hints: [draw.MAX_HINTS]draw.Hint = undefined;
    if (finished) {
        if (t.result()) |res| {
            results.renderCard(r, theme, res, t.config, ui, f.col_x, lay.card_y, f.col_w, lay.card_h, .{ .center = false, .frame = results.frameAt(ui, now_ms) });
            draw.renderToast(r, theme, f, ui.toast);
            draw.renderHints(r, theme, f.w, f.footer_y, results.hints(res, t.config, ui, &hints), false);
            return;
        }
    }
    draw.renderToast(r, theme, f, ui.toast);
    draw.renderHints(r, theme, f.w, f.footer_y, footerHints(t, ui, &hints), t.state == .typing);
}

pub const Pos = struct { x: usize, y: usize, visible: bool };

/// Hardware cursor: the command line, else the (scrolled) buffer cursor.
pub fn cursorPos(t: anytype, w: usize, h: usize) Pos {
    const f = draw.frameFor(w, h);
    if (t.state == .finished) return .{ .x = 0, .y = f.footer_y, .visible = false };
    const ed = &t.vim;
    const lay = layout(t, f);
    if (ed.cmdline()) |cl| {
        return .{ .x = lay.gutter_x + @min(glyph.displayWidth(cl), f.col_w -| 1), .y = lay.status_y, .visible = true };
    }
    const row = ed.cursor.row -| lay.top;
    return .{
        .x = lay.text_x + @min(cursorCol(ed) -| lay.off, lay.text_w -| 1),
        .y = lay.y + @min(row, lay.rows -| 1),
        .visible = true,
    };
}
