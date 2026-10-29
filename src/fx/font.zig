//! Embedded 5×7 bitmap pixel font (with 2-row descenders) and text drawing
//! for the pixel layer: big HUD numbers, score popups, flip-clock digits.
//!
//! Glyph cell: 5 columns × 9 rows. Rows 0..6 are cap height (baseline under
//! row 6), rows 7..8 hold descenders (g j p q y , ;). Covers printable ASCII
//! plus × · ° … ← → ↑ ↓ ✓; unknown codepoints draw a hollow box.
//!
//! Text is rasterized by exact area coverage of the font pixels, so any float
//! scale works (integer scales stay perfectly crisp) and italic skew,
//! squashing (flip clock) and clipping are anti-aliased.

const std = @import("std");
const canvas = @import("canvas.zig");
const color = @import("color.zig");

const Surface = canvas.Surface;
const Rgb = color.Rgb;
const Blend = canvas.Blend;
const sat = canvas.sat;

pub const glyph_w = 5;
pub const glyph_h = 9;
/// Cap height in font pixels (rows above the baseline).
pub const cap_h = 7;
/// Default line advance in font pixels.
pub const line_h = 10;

pub const Glyph = struct {
    /// Row bitmaps; bit 4 = leftmost column.
    rows: [glyph_h]u8,
    /// First and one-past-last inked column (for proportional spacing).
    lo: u8,
    hi: u8,

    pub fn lit(self: *const Glyph, col: usize, row: usize) bool {
        if (col >= glyph_w or row >= glyph_h) return false;
        return (self.rows[row] >> @intCast(glyph_w - 1 - col)) & 1 != 0;
    }
};

fn parse(comptime spec: []const u8) Glyph {
    @setEvalBranchQuota(20000);
    var g: Glyph = .{ .rows = @splat(0), .lo = glyph_w, .hi = 0 };
    var row: usize = 0;
    var col: usize = 0;
    for (spec) |ch| {
        switch (ch) {
            ' ' => {
                if (col != 0) {
                    if (col != glyph_w) @compileError("glyph row must be 5 wide: " ++ spec);
                    row += 1;
                    col = 0;
                }
            },
            '#', '.' => {
                if (ch == '#') {
                    g.rows[row] |= @as(u8, 1) << @intCast(glyph_w - 1 - col);
                    g.lo = @min(g.lo, col);
                    g.hi = @max(g.hi, col + 1);
                }
                col += 1;
            },
            else => @compileError("bad glyph char in: " ++ spec),
        }
    }
    if (col != 0 and col != glyph_w) @compileError("glyph row must be 5 wide: " ++ spec);
    if (g.hi == 0) {
        g.lo = 0;
        g.hi = 3; // blank glyph (space): 3 px + spacing
    }
    return g;
}

const ascii_specs = [95][]const u8{
    "", // space
    "..#.. ..#.. ..#.. ..#.. ..#.. ..... ..#..", // !
    ".#.#. .#.#. ..... ..... ..... ..... .....", // "
    ".#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.", // #
    "..#.. .#### #.#.. .###. ..#.# ####. ..#..", // $
    "##... ##..# ...#. ..#.. .#... #..## ...##", // %
    ".##.. #..#. #.#.. .#... #.#.# #..#. .##.#", // &
    "..#.. ..#.. ..... ..... ..... ..... .....", // '
    "...#. ..#.. .#... .#... .#... ..#.. ...#.", // (
    ".#... ..#.. ...#. ...#. ...#. ..#.. .#...", // )
    "..... ..#.. #.#.# .###. #.#.# ..#.. .....", // *
    "..... ..#.. ..#.. ##### ..#.. ..#.. .....", // +
    "..... ..... ..... ..... ..... .##.. .##.. ..#.. .#...", // ,
    "..... ..... ..... ##### ..... ..... .....", // -
    "..... ..... ..... ..... ..... .##.. .##..", // .
    "..... ....# ...#. ..#.. .#... #.... .....", // /
    ".###. #...# #..## #.#.# ##..# #...# .###.", // 0
    "..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.", // 1
    ".###. #...# ....# ...#. ..#.. .#... #####", // 2
    "##### ...#. ..#.. ...#. ....# #...# .###.", // 3
    "...#. ..##. .#.#. #..#. ##### ...#. ...#.", // 4
    "##### #.... ####. ....# ....# #...# .###.", // 5
    "..##. .#... #.... ####. #...# #...# .###.", // 6
    "##### ....# ...#. ..#.. .#... .#... .#...", // 7
    ".###. #...# #...# .###. #...# #...# .###.", // 8
    ".###. #...# #...# .#### ....# ...#. .##..", // 9
    "..... .##.. .##.. ..... .##.. .##.. .....", // :
    "..... .##.. .##.. ..... .##.. .##.. ..#.. .#...", // ;
    "...#. ..#.. .#... #.... .#... ..#.. ...#.", // <
    "..... ..... ##### ..... ##### ..... .....", // =
    ".#... ..#.. ...#. ....# ...#. ..#.. .#...", // >
    ".###. #...# ....# ...#. ..#.. ..... ..#..", // ?
    ".###. #...# ....# .##.# #.#.# #.#.# .###.", // @
    ".###. #...# #...# ##### #...# #...# #...#", // A
    "####. #...# #...# ####. #...# #...# ####.", // B
    ".###. #...# #.... #.... #.... #...# .###.", // C
    "###.. #..#. #...# #...# #...# #..#. ###..", // D
    "##### #.... #.... ####. #.... #.... #####", // E
    "##### #.... #.... ####. #.... #.... #....", // F
    ".###. #...# #.... #.### #...# #...# .####", // G
    "#...# #...# #...# ##### #...# #...# #...#", // H
    ".###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.", // I
    "..### ...#. ...#. ...#. ...#. #..#. .##..", // J
    "#...# #..#. #.#.. ##... #.#.. #..#. #...#", // K
    "#.... #.... #.... #.... #.... #.... #####", // L
    "#...# ##.## #.#.# #.#.# #...# #...# #...#", // M
    "#...# #...# ##..# #.#.# #..## #...# #...#", // N
    ".###. #...# #...# #...# #...# #...# .###.", // O
    "####. #...# #...# ####. #.... #.... #....", // P
    ".###. #...# #...# #...# #.#.# #..#. .##.#", // Q
    "####. #...# #...# ####. #.#.. #..#. #...#", // R
    ".#### #.... #.... .###. ....# ....# ####.", // S
    "##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..", // T
    "#...# #...# #...# #...# #...# #...# .###.", // U
    "#...# #...# #...# #...# #...# .#.#. ..#..", // V
    "#...# #...# #...# #.#.# #.#.# #.#.# .#.#.", // W
    "#...# #...# .#.#. ..#.. .#.#. #...# #...#", // X
    "#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..", // Y
    "##### ....# ...#. ..#.. .#... #.... #####", // Z
    ".###. .#... .#... .#... .#... .#... .###.", // [
    "..... #.... .#... ..#.. ...#. ....# .....", // backslash
    ".###. ...#. ...#. ...#. ...#. ...#. .###.", // ]
    "..#.. .#.#. #...# ..... ..... ..... .....", // ^
    "..... ..... ..... ..... ..... ..... #####", // _
    ".#... ..#.. ..... ..... ..... ..... .....", // `
    "..... ..... .###. ....# .#### #...# .####", // a
    "#.... #.... #.##. ##..# #...# #...# ####.", // b
    "..... ..... .###. #.... #.... #...# .###.", // c
    "....# ....# .##.# #..## #...# #...# .####", // d
    "..... ..... .###. #...# ##### #.... .###.", // e
    "..##. .#..# .#... ###.. .#... .#... .#...", // f
    "..... ..... .#### #...# #...# #..## .##.# ....# .###.", // g
    "#.... #.... #.##. ##..# #...# #...# #...#", // h
    "..#.. ..... .##.. ..#.. ..#.. ..#.. .###.", // i
    "...#. ..... ..##. ...#. ...#. ...#. ...#. #..#. .##..", // j
    "#.... #.... #..#. #.#.. ##... #.#.. #..#.", // k
    ".##.. ..#.. ..#.. ..#.. ..#.. ..#.. .###.", // l
    "..... ..... ##.#. #.#.# #.#.# #.#.# #.#.#", // m
    "..... ..... #.##. ##..# #...# #...# #...#", // n
    "..... ..... .###. #...# #...# #...# .###.", // o
    "..... ..... ####. #...# #...# #...# ####. #.... #....", // p
    "..... ..... .#### #...# #...# #...# .#### ....# ....#", // q
    "..... ..... #.##. ##..# #.... #.... #....", // r
    "..... ..... .###. #.... .###. ....# ####.", // s
    ".#... .#... ###.. .#... .#... .#..# ..##.", // t
    "..... ..... #...# #...# #...# #..## .##.#", // u
    "..... ..... #...# #...# #...# .#.#. ..#..", // v
    "..... ..... #...# #...# #.#.# #.#.# .#.#.", // w
    "..... ..... #...# .#.#. ..#.. .#.#. #...#", // x
    "..... ..... #...# #...# #...# #..## .##.# ....# .###.", // y
    "..... ..... ##### ...#. ..#.. .#... #####", // z
    "...#. ..#.. ..#.. .#... ..#.. ..#.. ...#.", // {
    "..#.. ..#.. ..#.. ..#.. ..#.. ..#.. ..#..", // |
    ".#... ..#.. ..#.. ...#. ..#.. ..#.. .#...", // }
    "..... ..... .#... #.#.# ...#. ..... .....", // ~
};

const Extra = struct { cp: u21, g: Glyph };

const extras = [_]Extra{
    .{ .cp = 0x00D7, .g = parse("..... #...# .#.#. ..#.. .#.#. #...# .....") }, // ×
    .{ .cp = 0x00B7, .g = parse("..... ..... ..... .##.. .##.. ..... .....") }, // ·
    .{ .cp = 0x00B0, .g = parse(".##.. #..#. #..#. .##.. ..... ..... .....") }, // °
    .{ .cp = 0x2026, .g = parse("..... ..... ..... ..... ..... ..... #.#.#") }, // …
    .{ .cp = 0x2190, .g = parse("..... ..#.. .#... ##### .#... ..#.. .....") }, // ←
    .{ .cp = 0x2192, .g = parse("..... ..#.. ...#. ##### ...#. ..#.. .....") }, // →
    .{ .cp = 0x2191, .g = parse("..#.. .###. #.#.# ..#.. ..#.. ..#.. ..#..") }, // ↑
    .{ .cp = 0x2193, .g = parse("..#.. ..#.. ..#.. ..#.. #.#.# .###. ..#..") }, // ↓
    .{ .cp = 0x2713, .g = parse("..... ....# ...#. #.#.. .#... ..... .....") }, // ✓
    .{ .cp = 0x2588, .g = parse("##### ##### ##### ##### ##### ##### #####") }, // █
};

const ascii_glyphs: [95]Glyph = blk: {
    var out: [95]Glyph = undefined;
    for (ascii_specs, 0..) |spec, i| out[i] = parse(spec);
    break :blk out;
};

const box_glyph = parse("##### #...# #...# #...# #...# #...# #####");

/// Glyph for a codepoint (lowercase is real lowercase); unknown → box.
pub fn glyph(cp: u21) *const Glyph {
    if (cp >= 32 and cp < 127) return &ascii_glyphs[cp - 32];
    for (&extras) |*e| if (e.cp == cp) return &e.g;
    return &box_glyph;
}

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const TextOpts = struct {
    /// Vertical scale; null = same as the horizontal scale.
    scale_y: ?f32 = null,
    /// Extra space between glyphs in font pixels.
    spacing: f32 = 1,
    /// Fixed 5-px advance for every glyph (digits are always tabular).
    mono: bool = false,
    /// Faux bold: every stroke one font pixel wider (glyphs become 6 wide).
    bold: bool = false,
    /// Italic skew: horizontal shift per font row in font px (0.2 ≈ 11°).
    italic: f32 = 0,
    alpha: f32 = 1,
    blend: Blend = .over,
    /// Bottom color for a vertical gradient fill (top = the text color).
    gradient: ?Rgb = null,
    /// Additive glow strength (0 = none).
    glow: f32 = 0,
    glow_color: ?Rgb = null,
    /// Glow radius in font pixels.
    glow_radius: f32 = 1.6,
    /// Outline drawn under the text, `outline_px` surface pixels thick.
    outline: ?Rgb = null,
    outline_px: f32 = 1,
    /// Hard drop shadow offset in font pixels.
    shadow: ?Rgb = null,
    shadow_dx: f32 = 1,
    shadow_dy: f32 = 1,
    shadow_alpha: f32 = 0.8,
    /// Only draw inside this rectangle (anti-aliased edges).
    clip: ?Rect = null,
    /// Draw only the first `max_chars` codepoints (typewriter reveal).
    max_chars: usize = std.math.maxInt(usize),
};

fn advance(g: *const Glyph, cp: u21, o: TextOpts) f32 {
    const b: f32 = if (o.bold) 1 else 0;
    if (o.mono or (cp >= '0' and cp <= '9')) return glyph_w + b + o.spacing;
    return @as(f32, @floatFromInt(g.hi - g.lo)) + b + o.spacing;
}

/// Row bits widened to 6 columns (bit 5 = leftmost); bold smears right.
inline fn rowBits(g: *const Glyph, row: usize, bold: bool) u8 {
    const b = g.rows[row];
    return if (bold) (b << 1) | b else b << 1;
}

fn leftPad(g: *const Glyph, cp: u21, o: TextOpts) f32 {
    if (o.mono or (cp >= '0' and cp <= '9')) return 0;
    return -@as(f32, @floatFromInt(g.lo));
}

/// Width in surface pixels of `text` at `scale` (no trailing spacing).
pub fn measure(text: []const u8, scale: f32, o: TextOpts) f32 {
    var w: f32 = 0;
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n >= o.max_chars) break;
        w += advance(glyph(cp), cp, o);
        n += 1;
    }
    if (n > 0) w -= o.spacing;
    return @max(w, 0) * scale;
}

/// Height in surface pixels of the cap-height box at `scale`.
pub fn height(scale: f32) f32 {
    return cap_h * scale;
}

/// Draw `text` with its top-left (cap top) at (x, y). Returns the drawn width.
pub fn drawText(s: *Surface, x: f32, y: f32, scale: f32, text: []const u8, c: Rgb, o: TextOpts) f32 {
    if (!(scale > 0)) return 0;
    const sy = o.scale_y orelse scale;
    if (!(sy > 0)) return 0;
    if (o.glow > 0) {
        const gc = o.glow_color orelse c;
        glowPass(s, x, y, scale, sy, text, gc, o);
    }
    if (o.shadow) |sc| {
        var so = o;
        so.gradient = null;
        so.alpha = o.alpha * o.shadow_alpha;
        so.blend = .over;
        rasterize(s, x + o.shadow_dx * scale, y + o.shadow_dy * sy, scale, sy, text, sc, so);
    }
    if (o.outline) |oc| {
        var oo = o;
        oo.gradient = null;
        const d = o.outline_px;
        const offs = [8][2]f32{ .{ -d, 0 }, .{ d, 0 }, .{ 0, -d }, .{ 0, d }, .{ -d * 0.7, -d * 0.7 }, .{ d * 0.7, -d * 0.7 }, .{ -d * 0.7, d * 0.7 }, .{ d * 0.7, d * 0.7 } };
        for (offs) |of| rasterize(s, x + of[0], y + of[1], scale, sy, text, oc, oo);
    }
    rasterize(s, x, y, scale, sy, text, c, o);
    return measure(text, scale, o);
}

/// Draw text horizontally centered on `cx`. Returns the drawn width.
pub fn drawTextCentered(s: *Surface, cx: f32, y: f32, scale: f32, text: []const u8, c: Rgb, o: TextOpts) f32 {
    const w = measure(text, scale, o);
    return drawText(s, cx - w * 0.5, y, scale, text, c, o);
}

fn glowPass(s: *Surface, x: f32, y: f32, sx: f32, sy: f32, text: []const u8, gc: Rgb, o: TextOpts) void {
    const r = o.glow_radius * @max(sx, sy);
    // Neighboring lit pixels overlap; normalize so a solid stroke peaks ~glow.
    const a = o.glow * o.alpha * @min(0.9, 1.6 / (o.glow_radius * o.glow_radius + 0.5));
    var pen = x;
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n >= o.max_chars) break;
        n += 1;
        const g = glyph(cp);
        const left = pen + leftPad(g, cp, o) * sx;
        for (0..glyph_h) |row| {
            if (g.rows[row] == 0) continue;
            const skew = o.italic * (@as(f32, cap_h) - 0.5 - @as(f32, @floatFromInt(row)));
            const bits = rowBits(g, row, o.bold);
            for (0..glyph_w + 1) |col| {
                if ((bits >> @intCast(glyph_w - col)) & 1 == 0) continue;
                const gx = left + (@as(f32, @floatFromInt(col)) + 0.5 + skew) * sx;
                const gy = y + (@as(f32, @floatFromInt(row)) + 0.5) * sy;
                canvas.glow(s, gx, gy, r, gc, a, .add);
            }
        }
        pen += advance(g, cp, o) * sx;
    }
}

/// Exact area-coverage rasterization of the glyph bitmaps.
fn rasterize(s: *Surface, x: f32, y: f32, sx: f32, sy: f32, text: []const u8, c: Rgb, o: TextOpts) void {
    var pen = x;
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n >= o.max_chars) break;
        n += 1;
        const g = glyph(cp);
        const left = pen + leftPad(g, cp, o) * sx;
        drawGlyph(s, g, left, y, sx, sy, c, o);
        pen += advance(g, cp, o) * sx;
    }
}

fn drawGlyph(s: *Surface, g: *const Glyph, gx: f32, gy: f32, sx: f32, sy: f32, c: Rgb, o: TextOpts) void {
    const max_skew = @abs(o.italic) * glyph_h * sx;
    var bx0 = gx - max_skew;
    var by0 = gy;
    var bx1 = gx + (glyph_w + 1) * sx + max_skew;
    var by1 = gy + glyph_h * sy;
    if (o.clip) |cl| {
        bx0 = @max(bx0, cl.x);
        by0 = @max(by0, cl.y);
        bx1 = @min(bx1, cl.x + cl.w);
        by1 = @min(by1, cl.y + cl.h);
    }
    const sp = canvas.span(s, bx0, by0, bx1, by1) orelse return;
    const inv_sx = 1.0 / sx;
    const inv_sy = 1.0 / sy;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy0 = @as(f32, @floatFromInt(py));
        // vertical clip coverage
        var cy0 = fy0;
        var cy1 = fy0 + 1;
        if (o.clip) |cl| {
            cy0 = @max(cy0, cl.y);
            cy1 = @min(cy1, cl.y + cl.h);
            if (cy1 <= cy0) continue;
        }
        // Clamp to just outside the glyph so tiny scales can't overflow the
        // integer row index (only rows 0..glyph_h matter).
        const v0 = std.math.clamp((cy0 - gy) * inv_sy, -1, glyph_h + 1);
        const v1 = std.math.clamp((cy1 - gy) * inv_sy, -1, glyph_h + 1);
        const r0: i32 = @intFromFloat(@floor(v0));
        const r1: i32 = @intFromFloat(@ceil(v1));
        const fill_c = if (o.gradient) |gb| c.lerp(gb, sat(((fy0 + 0.5 - gy) * inv_sy) / cap_h)) else c;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx0 = @as(f32, @floatFromInt(px));
            var cx0 = fx0;
            var cx1 = fx0 + 1;
            if (o.clip) |cl| {
                cx0 = @max(cx0, cl.x);
                cx1 = @min(cx1, cl.x + cl.w);
                if (cx1 <= cx0) continue;
            }
            var cov: f32 = 0;
            var r = @max(r0, 0);
            while (r < @min(r1, glyph_h)) : (r += 1) {
                const ur: usize = @intCast(r);
                const bits = rowBits(g, ur, o.bold);
                if (bits == 0) continue;
                const rf: f32 = @floatFromInt(r);
                const oy = @min(v1, rf + 1) - @max(v0, rf);
                if (oy <= 0) continue;
                const skew = o.italic * (@as(f32, cap_h) - 0.5 - rf);
                const ua = std.math.clamp((cx0 - gx) * inv_sx - skew, -1, glyph_w + 2);
                const ub = std.math.clamp((cx1 - gx) * inv_sx - skew, -1, glyph_w + 2);
                var col = @max(@as(i32, @intFromFloat(@floor(ua))), 0);
                const col_end = @min(@as(i32, @intFromFloat(@ceil(ub))), glyph_w + 1);
                while (col < col_end) : (col += 1) {
                    const uc: u3 = @intCast(col);
                    if ((bits >> (glyph_w - uc)) & 1 == 0) continue;
                    const cf: f32 = @floatFromInt(col);
                    const ox = @min(ub, cf + 1) - @max(ua, cf);
                    if (ox > 0) cov += ox * oy;
                }
            }
            if (cov <= 0) continue;
            // normalize by the area of a surface pixel in font units
            const k = sat(cov * sx * sy);
            canvas.blendPx(&row[px], fill_c, o.alpha * k, o.blend);
        }
    }
}

// ---------------------------------------------------------------------------
// Flip-clock digit
// ---------------------------------------------------------------------------

pub const FlipStyle = struct {
    tile: Rgb = color.palette.tile,
    ink: Rgb = Rgb.hex(0x24212b),
    /// Corner radius as a fraction of min(w, h).
    radius: f32 = 0.16,
    alpha: f32 = 1,
    /// Shadow / bezel under the tile.
    shadow: Rgb = Rgb.hex(0x05060f),
    /// Bold digits (recommended for tiles taller than ~20 px).
    bold: bool = true,
};

/// A split-flap tile at (x, y, w, h) showing glyph `from` turning into `to`.
/// `flip` 0..1: 0 shows `from`, 1 shows `to`; in between the top flap falls
/// (squashing toward the hinge) and then the new bottom flap unfolds.
pub fn drawFlipDigit(s: *Surface, x: f32, y: f32, w: f32, h: f32, from: u21, to: u21, flip: f32, st: FlipStyle) void {
    if (!(w > 1 and h > 1)) return;
    const t = sat(flip);
    const r = @min(w, h) * st.radius;
    const hinge = y + h * 0.5;
    const half = h * 0.5;
    // bezel shadow
    canvas.roundRect(s, x - 0.5, y + h * 0.04, w + 1, h + 0.5, r, st.shadow, 0.55 * st.alpha, .over);
    // glyph metrics: 5×7 cap box centered in the tile
    const gcols: f32 = if (st.bold) glyph_w + 1 else glyph_w;
    const sx = w * 0.62 / gcols;
    const sy = h * 0.66 / cap_h;
    const gw = gcols * sx;
    const gx = x + (w - gw) * 0.5;
    const gy = y + (h - cap_h * sy) * 0.5;
    const top_clip: Rect = .{ .x = x, .y = y, .w = w, .h = half };
    const bot_clip: Rect = .{ .x = x, .y = hinge, .w = w, .h = half };

    const top_static: u21 = if (t > 0) to else from;
    const bot_static: u21 = if (t >= 1) to else from;
    // static halves
    halfTile(s, x, y, w, half, r, st, true, 1.0);
    halfTile(s, x, hinge, w, half, r, st, false, 1.0);
    digitClipped(s, top_static, gx, gy, sx, sy, st, top_clip);
    digitClipped(s, bot_static, gx, gy, sx, sy, st, bot_clip);

    if (t > 0 and t < 1) {
        if (t < 0.5) {
            // old top flap falling toward the hinge
            const k = @cos(t * std.math.pi); // 1 → 0
            const fh = half * k;
            const shade = 1 - (1 - k) * 0.45;
            halfTile(s, x, hinge - fh, w, fh, r * k, st, true, shade);
            const clip: Rect = .{ .x = x, .y = hinge - fh, .w = w, .h = fh };
            digitClipped(s, from, gx, hinge - (hinge - gy) * k, sx, sy * k, st, clip);
        } else {
            // new bottom flap unfolding from the hinge
            const k = -@cos(t * std.math.pi); // 0 → 1
            const fh = half * k;
            const shade = 1 - (1 - k) * 0.35;
            halfTile(s, x, hinge, w, fh, r * k, st, false, shade);
            const clip: Rect = .{ .x = x, .y = hinge, .w = w, .h = fh };
            digitClipped(s, to, gx, hinge - (hinge - gy) * k, sx, sy * k, st, clip);
        }
    }
    // hinge line
    canvas.fillRect(s, x, hinge - @max(h * 0.02, 0.5), w, @max(h * 0.035, 0.75), st.shadow, 0.65 * st.alpha, .over);
}

fn halfTile(s: *Surface, x: f32, y: f32, w: f32, h: f32, r: f32, st: FlipStyle, is_top: bool, shade: f32) void {
    if (!(h > 0.05)) return;
    const base = st.tile.scale(shade);
    const top_c = if (is_top) base.lighten(0.08) else base.scale(0.9);
    const bot_c = if (is_top) base.scale(0.96) else base.scale(0.8);
    // Round only the outer corners: draw a rounded rect extended past the
    // hinge, clipped by drawing a straight rect over the overlap.
    const ext = @min(r, h);
    if (is_top) {
        canvas.roundRectV(s, x, y, w, h + ext, r, top_c, bot_c, st.alpha, .over);
        // cover the rounded lower part with a straight band
        canvas.gradientV(s, x, y + h - ext * 0.5, w, ext * 0.5, bot_c, bot_c, st.alpha, .over);
    } else {
        canvas.roundRectV(s, x, y - ext, w, h + ext, r, top_c, bot_c, st.alpha, .over);
        canvas.gradientV(s, x, y, w, ext * 0.5, top_c, top_c, st.alpha, .over);
    }
}

fn digitClipped(s: *Surface, cp: u21, gx: f32, gy: f32, sx: f32, sy: f32, st: FlipStyle, clip: Rect) void {
    if (!(sy > 0.01) or !(clip.h > 0)) return;
    drawGlyph(s, glyph(cp), gx, gy, sx, sy, st.ink, .{ .clip = clip, .alpha = st.alpha, .bold = st.bold });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every ascii glyph parsed, digits full width" {
    for (ascii_glyphs[1..]) |g| {
        var any = false;
        for (g.rows) |r| any = any or r != 0;
        try testing.expect(any);
        try testing.expect(g.hi > g.lo);
    }
    try testing.expect(glyph('0').lit(0, 1));
    try testing.expect(!glyph('0').lit(0, 0));
    try testing.expect(glyph('g').rows[8] != 0); // descender
    try testing.expectEqual(glyph(0x1F600), &box_glyph);
    try testing.expect(glyph(0x00D7) != &box_glyph); // ×
}

test "measure: proportional, tabular digits, mono, scale" {
    // "11" uses tabular digits: 5 + 1 + 5
    try testing.expectEqual(@as(f32, 11), measure("11", 1, .{}));
    // "il" proportional: i is 3 wide (cols 1..4), l 3 wide → 3+1+3
    try testing.expectEqual(@as(f32, 7), measure("il", 1, .{}));
    try testing.expectEqual(@as(f32, 11), measure("il", 1, .{ .mono = true }));
    try testing.expectEqual(@as(f32, 22), measure("11", 2, .{}));
    try testing.expectEqual(@as(f32, 0), measure("", 3, .{}));
    try testing.expectEqual(@as(f32, 5), measure("123", 1, .{ .max_chars = 1 }));
    try testing.expectEqual(@as(f32, 13), measure("11", 1, .{ .bold = true }));
}

test "drawText integer scale is crisp and matches bitmap" {
    var s = try Surface.init(testing.allocator, 4, 4, 32, 24);
    defer s.deinit();
    canvas.clear(&s, Rgb.black);
    const w = drawText(&s, 2, 2, 2, "1", Rgb.white, .{});
    try testing.expectEqual(@as(f32, 10), w);
    const g = glyph('1');
    for (0..cap_h) |row| for (0..glyph_w) |col| {
        const px = s.pixels[(2 + row * 2) * 32 + 2 + col * 2];
        const expect: u8 = if (g.lit(col, row)) 255 else 0;
        try testing.expectEqual(expect, px.r);
    };
}

test "drawText fractional scale, clip, effects don't crash" {
    var s = try Surface.init(testing.allocator, 8, 8, 64, 48);
    defer s.deinit();
    canvas.clear(&s, Rgb.black);
    _ = drawText(&s, -3.3, 5.7, 1.7, "+1,440 ×8 quick?", Rgb.white, .{
        .italic = 0.2,
        .glow = 0.8,
        .outline = Rgb.init(1, 0, 0),
        .shadow = Rgb.black,
        .gradient = Rgb.init(1, 0.5, 0),
    });
    canvas.clear(&s, Rgb.black);
    _ = drawText(&s, 0, 0, 3, "8", Rgb.white, .{ .clip = .{ .x = 0, .y = 0, .w = 64, .h = 6 } });
    for (8..48) |y| for (0..64) |x| try testing.expectEqual(@as(u8, 0), s.pixels[y * 64 + x].r);
    _ = drawText(&s, 0, 0, 0, "x", Rgb.white, .{});
    _ = drawText(&s, 0, 0, 1, "\xff\xfe", Rgb.white, .{}); // invalid utf-8 ignored
    _ = drawTextCentered(&s, 32, 20, 0.6, "tiny", Rgb.white, .{});
    // degenerate vertical / tiny scales must not overflow the row index
    _ = drawText(&s, 10.3, 10.5, 2, "8", Rgb.white, .{ .scale_y = 0 });
    _ = drawText(&s, 10.3, 10.5, 1e-10, "8", Rgb.white, .{});
}

test "flip digit endpoints show the right digit" {
    var s = try Surface.init(testing.allocator, 4, 4, 40, 60);
    defer s.deinit();
    var a = try Surface.init(testing.allocator, 4, 4, 40, 60);
    defer a.deinit();
    canvas.clear(&s, Rgb.black);
    canvas.clear(&a, Rgb.black);
    drawFlipDigit(&s, 4, 4, 32, 52, '3', '7', 1, .{});
    drawFlipDigit(&a, 4, 4, 32, 52, '7', '7', 0, .{});
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.pixels), std.mem.sliceAsBytes(s.pixels));
    for ([_]f32{ 0.1, 0.3, 0.5, 0.7, 0.9 }) |t| drawFlipDigit(&s, 4, 4, 32, 52, '3', '7', t, .{});
}
