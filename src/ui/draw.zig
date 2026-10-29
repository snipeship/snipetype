//! Drawing helpers and the shared screen frame used by every classic-mode
//! view (`typing_view`, `results`, `vim_view`, `drill_view`): pens, clipped
//! writes, rounded cards, the brand header and the key-hint footer.

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const Color = @import("color.zig").Color;
const glyph = @import("ansi.zig");
const Renderer = @import("../platform/renderer.zig").Renderer;
const Config = @import("../core/types.zig").Config;
const query = @import("query.zig");
const syntax = @import("../core/syntax.zig");

/// Widest text column, in cells (a comfortable reading measure)...
pub const MAX_COLUMN: usize = 70;
/// ...widened on big terminals (at least `WIDE_TERMINAL` columns).
pub const MAX_COLUMN_WIDE: usize = 90;
pub const WIDE_TERMINAL: usize = 120;

// ============================================================================
// Pens and writes
// ============================================================================

/// Reset, then apply the given colors (null fg = theme/terminal default).
pub fn pen(r: Renderer, fg: ?Color, bg: ?Color, bold: bool) void {
    r.resetStyle();
    if (fg) |c| r.setFg(c);
    if (bg) |c| r.setBg(c);
    if (bold) r.setBold(true);
}

/// Underline on/off where the renderer supports it (contract 5); a no-op
/// on renderers without `setUnderline`.
pub fn underline(r: Renderer, on: bool) void {
    if (comptime @hasDecl(Renderer, "setUnderline")) r.setUnderline(on);
}

pub fn repeat(r: Renderer, s: []const u8, n: usize) void {
    for (0..n) |_| r.write(s);
}

pub fn clearRows(r: Renderer, from: usize, to_inclusive: usize) void {
    var y = from;
    while (y <= to_inclusive) : (y += 1) {
        r.moveTo(0, y);
        r.clearLine();
    }
}

/// Write at most `max` columns of `s` (one column per code point, as
/// everywhere in this UI); returns the columns written.
pub fn writeClip(r: Renderer, s: []const u8, max: usize) usize {
    if (max == 0) return 0;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (cols == max) break;
        r.write(s[i..@min(s.len, i + n)]);
        cols += 1;
        i += n;
    }
    return cols;
}

/// Like `writeClip`, but ends with "…" when `s` doesn't fit.
pub fn writeEllipsis(r: Renderer, s: []const u8, max: usize) usize {
    if (glyph.displayWidth(s) <= max) return writeClip(r, s, max);
    if (max == 0) return 0;
    const n = writeClip(r, s, max - 1);
    r.write(glyph.ELLIPSIS);
    return n + 1;
}

/// Writes pieces left to right while they fit in `left` columns. A piece
/// that doesn't fit is dropped whole, and so is everything after it.
pub const Pieces = struct {
    r: Renderer,
    left: usize,
    full: bool = false,

    pub fn put(self: *Pieces, fg: ?Color, bold: bool, s: []const u8) void {
        const n = glyph.displayWidth(s);
        if (self.full or n > self.left) {
            self.full = true;
            return;
        }
        pen(self.r, fg, null, bold);
        self.r.write(s);
        self.left -= n;
    }
};

/// Text color that reads on top of `accent`-like fills (pills, highlights).
pub fn onFill(theme: *const Theme) Color {
    return if (theme.use_terminal_defaults) Color.rgb(16, 16, 20) else theme.bg;
}

/// Colour of untyped code of syntax class `kind` (`dim` for plain text).
pub fn syntaxColor(theme: *const Theme, kind: syntax.Kind) Color {
    return switch (kind) {
        .plain => theme.dim,
        .keyword => theme.syn_keyword,
        .string => theme.syn_string,
        .comment => theme.syn_comment,
        .number => theme.syn_number,
        .type_name => theme.syn_type,
        .punct => theme.syn_punct,
    };
}

/// Syntax classes of a block of lines, line by line, carrying the
/// tokenizer state from the first line (block comments, multi-line
/// strings). Lines longer than `MAX_LINE` are left plain.
pub const Highlighter = struct {
    pub const MAX_LINE = 1024;

    lang: @import("../core/types.zig").Lang,
    state: syntax.State = .{},
    kinds: [MAX_LINE]syntax.Kind = undefined,

    /// Classes of the next line (consecutive calls are consecutive lines).
    pub fn line(self: *Highlighter, text: []const u8) []const syntax.Kind {
        if (text.len > MAX_LINE) {
            @memset(&self.kinds, .plain);
            return self.kinds[0..0];
        }
        syntax.highlightLine(self.lang, text, &self.state, &self.kinds);
        return self.kinds[0..text.len];
    }
};

pub fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.mem.print(buf, f, args) catch buf[0..0];
}

/// "★★☆" for `stars` out of three.
pub fn starString(buf: *[9]u8, stars: u2) []const u8 {
    var n: usize = 0;
    for (0..3) |i| {
        const s = if (i < stars) "★" else "☆";
        @memcpy(buf[n..][0..3], s);
        n += 3;
    }
    return buf[0..n];
}

// ============================================================================
// Frame (shared chrome positions)
// ============================================================================

pub const Frame = struct {
    w: usize,
    h: usize,
    col_x: usize,
    col_w: usize,
    header_y: usize,
    /// Row of the thin rule under the header, if there is room for it.
    rule_y: ?usize,
    footer_y: usize,
    /// First and last (inclusive) rows of the content area. The row between
    /// `bottom` and the footer holds toasts.
    top: usize,
    bottom: usize,

    pub fn rows(self: Frame) usize {
        return if (self.bottom >= self.top) self.bottom - self.top + 1 else 0;
    }

    pub fn toastY(self: Frame) ?usize {
        const y = self.footer_y -| 1;
        return if (y > self.bottom and y > self.header_y) y else null;
    }
};

pub fn frameFor(w: usize, h: usize) Frame {
    const max_col = if (w >= WIDE_TERMINAL) MAX_COLUMN_WIDE else MAX_COLUMN;
    const col_w = @max(1, @min(max_col, w -| 4));
    const header_y: usize = if (h >= 14) 1 else 0;
    const rule_y: ?usize = if (h >= 18) header_y + 1 else null;
    const footer_y: usize = if (h >= 20) h - 2 else h -| 1;
    return .{
        .w = w,
        .h = h,
        .col_x = (w -| col_w) / 2,
        .col_w = col_w,
        .header_y = header_y,
        .rule_y = rule_y,
        .footer_y = footer_y,
        .top = header_y + 2,
        .bottom = footer_y -| 2,
    };
}

// ============================================================================
// Header
// ============================================================================

/// Brand on the left of the column, `chips` right-aligned (the first in the
/// accent color). `focus` fades everything while a test runs.
pub fn renderHeader(r: Renderer, theme: *const Theme, f: Frame, chips: []const []const u8, focus: bool) void {
    const accent = if (focus) theme.dimmer else theme.accent;
    r.moveTo(f.col_x, f.header_y);
    pen(r, accent, null, !focus);
    r.write("❯ ");
    if (focus) pen(r, theme.dimmer, null, false) else pen(r, theme.text(), null, true);
    r.write("snipe");
    pen(r, accent, null, !focus);
    r.write("type");

    var chips_w: usize = 0;
    for (chips, 0..) |p, i| chips_w += glyph.displayWidth(p) + (if (i > 0) @as(usize, 3) else 0);
    const brand_w: usize = 11;
    if (brand_w + 2 + chips_w <= f.col_w) {
        r.moveTo(f.col_x + f.col_w - chips_w, f.header_y);
        for (chips, 0..) |p, i| {
            if (i > 0) {
                pen(r, theme.dimmer, null, false);
                r.write(" " ++ glyph.MIDDOT ++ " ");
            }
            pen(r, if (focus) theme.dimmer else if (i == 0) theme.accent else theme.dim, null, false);
            r.write(p);
        }
    }
    r.resetStyle();
    renderRule(r, theme, f);
}

pub fn renderRule(r: Renderer, theme: *const Theme, f: Frame) void {
    if (f.rule_y) |y| {
        r.moveTo(f.col_x, y);
        pen(r, theme.dimmer, null, false);
        repeat(r, glyph.box.h, f.col_w);
        r.resetStyle();
    }
}

/// Header chips for a config: mode, then lang / tier / keys / date, then
/// count / time.
pub const Chips = struct {
    bufs: [3][16]u8 = undefined,
    day_buf: [10]u8 = undefined,
    items: [3][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Chips) []const []const u8 {
        return self.items[0..self.len];
    }

    fn add(self: *Chips, s: []const u8) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = s;
        self.len += 1;
    }
};

pub fn chipsFor(c: *Chips, cfg: Config) void {
    c.len = 0;
    c.add(cfg.mode.name());
    const code_vim = cfg.mode == .code and query.cfgIs(cfg, "code_keys", "vim");
    if (cfg.mode == .code or cfg.mode == .vim) {
        c.add(cfg.lang.name());
    } else if (cfg.mode == .words) {
        c.add(cfg.tier.name());
    }
    if (code_vim) {
        c.add("vim keys");
        return;
    }
    if (query.dailyDate(cfg, &c.day_buf)) |d| {
        c.add(d);
        return;
    }
    if (query.is(cfg.mode, "zen")) return;
    if (cfg.time_limit > 0) {
        c.add(fmt(&c.bufs[c.len], "{d}s", .{cfg.time_limit}));
    } else if (cfg.mode == .words) {
        c.add(fmt(&c.bufs[c.len], "{d}", .{cfg.word_count}));
    }
}

/// Header chips for a practice run: `practice · <what>` (its words come
/// from the last run, not the config).
pub fn chipsForPractice(c: *Chips, what: []const u8) void {
    c.len = 0;
    c.add("practice");
    c.add(what);
}

// ============================================================================
// Footer hints
// ============================================================================

pub const Hint = struct { key: []const u8, label: []const u8 };

pub const MAX_HINTS = 8;

/// Centered key hints on the footer row. Fit: drop trailing middle hints,
/// then labels (restarting from the full set), then middle hints again,
/// then the last hint. `focus` dims the whole row.
pub fn renderHints(r: Renderer, theme: *const Theme, w: usize, y: usize, in_hints: []const Hint, focus: bool) void {
    var hints: [MAX_HINTS]Hint = undefined;
    const n = @min(in_hints.len, MAX_HINTS);
    if (n == 0) return;
    @memcpy(hints[0..n], in_hints[0..n]);
    const all = hints;
    const gap: usize = 3;
    const chip_bg = if (focus) null else theme.surface(0.08);
    const chip_pad: usize = if (chip_bg != null) 2 else 0;
    var show_labels = true;
    var count = n;
    while (count > 0) {
        var total: usize = 0;
        for (hints[0..count], 0..) |hnt, i| {
            total += glyph.displayWidth(hnt.key) + chip_pad + (if (show_labels) 1 + glyph.displayWidth(hnt.label) else 0) + (if (i > 0) gap else 0);
        }
        if (total + 2 <= w or (count == 1 and !show_labels)) {
            r.moveTo((w -| total) / 2, y);
            var used: usize = 0;
            for (hints[0..count], 0..) |hnt, i| {
                if (i > 0) {
                    r.write("   ");
                    used += 3;
                }
                // Keys sit on small keycap-like chips when the bg is known.
                pen(r, if (focus) theme.dimmer else theme.muted(), chip_bg, false);
                if (chip_bg != null) r.write(" ");
                used += writeClip(r, hnt.key, w -| used);
                if (chip_bg != null) r.write(" ");
                if (show_labels) {
                    pen(r, if (focus) theme.dimmer else theme.dim, null, false);
                    r.write(" ");
                    r.write(hnt.label);
                }
            }
            r.resetStyle();
            return;
        }
        if (count > 2) {
            // Keep the first and last hints longest.
            hints[count - 2] = hints[count - 1];
            count -= 1;
        } else if (show_labels) {
            show_labels = false;
            hints = all;
            count = n;
        } else {
            count -= 1;
        }
    }
}

/// One-line toast centered above the footer.
pub fn renderToast(r: Renderer, theme: *const Theme, f: Frame, toast: ?[]const u8) void {
    const msg = toast orelse return;
    const y = f.toastY() orelse return;
    const max = f.w -| 2;
    const len = @min(glyph.displayWidth(msg), max);
    r.moveTo((f.w -| len) / 2, y);
    pen(r, theme.warning, null, false);
    _ = writeEllipsis(r, msg, max);
    r.resetStyle();
}

// ============================================================================
// Cards
// ============================================================================

/// Rounded box (border color) with `title` set into the top edge; the
/// inside is cleared to the default background.
pub fn drawCard(r: Renderer, theme: *const Theme, x: usize, y: usize, w: usize, h: usize, title: []const u8) void {
    if (w < 4 or h < 2) return;
    const inner_w = w - 2;
    r.moveTo(x, y);
    pen(r, theme.border, null, false);
    r.write(glyph.box.tl);
    var used: usize = 0;
    if (title.len > 0 and inner_w >= 4) {
        r.write(glyph.box.h);
        pen(r, theme.dim, null, false);
        used = 1 + writeEllipsis(r, title, inner_w - 2);
        pen(r, theme.border, null, false);
    }
    repeat(r, glyph.box.h, inner_w -| used);
    r.write(glyph.box.tr);
    for (1..h - 1) |dy| {
        r.moveTo(x, y + dy);
        r.write(glyph.box.v);
        r.resetStyle();
        repeat(r, " ", inner_w);
        pen(r, theme.border, null, false);
        r.write(glyph.box.v);
    }
    r.moveTo(x, y + h - 1);
    r.write(glyph.box.bl);
    repeat(r, glyph.box.h, inner_w);
    r.write(glyph.box.br);
    r.resetStyle();
}

/// Horizontal scroll offset that keeps column `cur` visible in a `width`
/// wide window, moving in half-window steps; with an offset the caret also
/// stays clear of the first and last cells (which hold `‹ ›` markers).
pub fn hscroll(cur: usize, width: usize) usize {
    if (width < 4) return cur -| (width -| 1);
    const step = width / 2;
    var off: usize = 0;
    while (cur >= off + width - 1) off += step;
    return off;
}

test "hscroll keeps the caret inside the window, away from markers" {
    for ([_]usize{ 4, 5, 10, 33 }) |w| {
        for (0..300) |cur| {
            const off = hscroll(cur, w);
            try std.testing.expect(cur >= off and cur < off + w - 1);
            if (off > 0) try std.testing.expect(cur > off);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), hscroll(8, 10));
    try std.testing.expect(hscroll(9, 10) > 0);
}

test "stars" {
    var b: [9]u8 = undefined;
    try std.testing.expectEqualStrings("★★☆", starString(&b, 2));
    try std.testing.expectEqualStrings("☆☆☆", starString(&b, 0));
}
