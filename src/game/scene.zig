//! The arcade scene: everything "snipetype arcade" looks like.
//!
//! `Scene.render` draws one frame into a `Surface` from the read-only state
//! of an `Arcade`:
//!
//!   backdrop (night sky, bokeh, an out-of-focus perspective RGB keyboard
//!   filling the lower play area — blurred once into the cached background,
//!   LED light animated on top — key ripples, red flashes, deck ledge +
//!   health strip)
//!   → fx.drawUnder → falling caps → fx.drawOver → score popups → fx.post
//!   → HUD / title / pause / results overlays (pixels + text layer)
//!
//! Cap rectangles are computed in terminal cells (`layout.zig`, shared with
//! the simulation) and mapped to pixels with `Surface.pxPerCol/pxPerRow`. At
//! kitty/web resolution (≈4×8 px per cell) legends are drawn into the image
//! with the pixel font, so caps glide smoothly and a legend can never drift
//! off its keycap (the terminal may show image and text a frame apart). At
//! half-block resolution (1×2 px per cell) legends go to the text layer and
//! caps step one text row at a time to stay under them.
//! They fall over the keyboard from just under the HUD to the deck near the
//! bottom. With ≥ 30 rows at kitty/web resolution caps are big: 3 rows tall
//! (legend on the middle row) and wider than `layout.zig` says; the app
//! passes `simPlayCols` to `Arcade.setPlayWidth` so spawn placement agrees.
//!
//! The scene keeps only presentation state (effects, popups, ripples, clock
//! flips); it reads `arc.events()` each frame but never clears them. Buffers
//! are (re)allocated only when the surface size changes.

const std = @import("std");
const fx = @import("../fx/fx.zig");
const model = @import("model.zig");
const lay = @import("layout.zig");
const arcade_mod = @import("arcade.zig");
const levels = @import("levels.zig");
const keys = @import("../platform/keys.zig");
const Color = @import("../ui/color.zig").Color;

const canvas = fx.canvas;
const font = fx.font;
const color = fx.color;
const popup_mod = fx.popup;
const effects = fx.effects;
const Surface = fx.Surface;
const Px = fx.Px;
const Rgb = fx.Rgb;
const pal = color.palette;
const sat = canvas.sat;
const smoothstep = canvas.smoothstep;
const Arcade = arcade_mod.Arcade;
const Cap = model.Cap;
const kc = keys.code;

/// Rendering quality knobs chosen by the app per presenter backend.
pub const Quality = struct {
    /// Bloom pass quality (forced off on half-block-sized surfaces).
    bloom: fx.BloomQuality = .low,
    /// The surface is cols × rows*2 (half-block presenter).
    halfblock: bool = false,
};

const MAX_POPUPS = 16;
const MAX_RIPPLES = 16;

// Palette additions (DESIGN.md "Look & effects").
const ink = pal.ink;
const ink_dim = Rgb.hex(0x9d99a6);
const ink_faint = Rgb.hex(0x5f5d78);
const badge_ink = Rgb.hex(0x1b1d3a);
const night_hi = Rgb.hex(0x15163a);

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// Per-frame screen layout in cells and pixels.
const Geo = struct {
    cols: i32,
    rows: i32,
    w: f32,
    h: f32,
    pxc: f32,
    pxr: f32,
    /// Low pixel density (half-block): simpler drawing, text-layer HUD.
    lo: bool,
    /// Big caps: 3 rows tall and ~1.5× wider (kitty/web with ≥ 30 rows).
    big: bool,
    /// Pixel-font scale of the big HUD numbers (0 = text layer).
    hud_scale: f32,
    hud_top: f32,
    /// Row of the small HUD labels and number of HUD rows.
    label_row: i32,
    hud_rows: i32,
    /// First row a cap (plate included) may reach up into.
    cap_top_row: i32,
    /// First deck row (the ledge is its top edge).
    deck_row: i32,
    deck_y: f32,
    kb_top: f32,
    /// Keycap height and how far a cap reaches above its legend row (px).
    key_h: f32,
    key_lift: f32,
    /// Plate padding around the keys (px, vertical).
    plate_pad: f32,
    margin: i32,

    fn x(g: *const Geo, col: f32) f32 {
        return col * g.pxc;
    }
    fn y(g: *const Geo, row: f32) f32 {
        return row * g.pxr;
    }
};

fn fi(v: anytype) f32 {
    return @floatFromInt(v);
}

/// Whether a surface gets big (3-row) caps.
fn bigCaps(s: *const Surface, q: Quality) bool {
    const lo = q.halfblock or s.pxPerRow() < 5;
    return !lo and s.rows >= 30;
}

/// Play-area width in "simulation cells" for `Arcade.setPlayWidth`: when
/// caps are drawn wider than `layout.zig` says (big caps), the simulation
/// sees a proportionally narrower field so its overlap-free placement still
/// holds on screen.
pub fn simPlayCols(s: *const Surface, q: Quality) u16 {
    if (!bigCaps(s, q)) return s.cols;
    return @intCast(@max(@as(u32, s.cols) * 2 / 3, 8));
}

/// `phrase_line`: the word phrase takes the row under the HUD, so caps
/// start one row lower.
fn computeGeo(s: *const Surface, q: Quality, phrase_line: bool) Geo {
    const pxc = s.pxPerCol();
    const pxr = s.pxPerRow();
    const rows: i32 = s.rows;
    const lo = q.halfblock or pxr < 5;
    var g: Geo = .{
        .cols = s.cols,
        .rows = rows,
        .w = fi(s.w),
        .h = fi(s.h),
        .pxc = pxc,
        .pxr = pxr,
        .lo = lo,
        .big = bigCaps(s, q),
        .hud_scale = 0,
        .hud_top = 0,
        .label_row = 1,
        .hud_rows = 2,
        .cap_top_row = 2,
        .deck_row = rows - 2,
        .deck_y = 0,
        .kb_top = 0,
        .key_h = 2 * pxr,
        .key_lift = 0,
        .plate_pad = 0,
        .margin = if (s.cols >= 90) 3 else 2,
    };
    if (!lo) {
        g.hud_scale = std.math.clamp(@round(g.h * 0.052 / font.cap_h), 1, 8);
        g.hud_top = @round(pxr * 0.5);
        // keep the label row clear of the score's descenders (the thousands
        // comma) and of the flip-clock tiles, which hang below the cap height
        const desc_bottom = g.hud_top + (font.cap_h + 2) * g.hud_scale;
        const clock_bottom = @max(1, g.hud_top - g.hud_scale * 0.5) + @round(font.cap_h * g.hud_scale / 0.66);
        const bottom = @max(desc_bottom, clock_bottom);
        g.label_row = @intFromFloat(@ceil((bottom + 1) / pxr));
        g.hud_rows = g.label_row + 1;
        g.key_h = if (g.big) @round(3 * pxr - @max(2, pxr * 0.4)) else @round(2 * pxr - @max(1, pxr * 0.14));
        g.key_lift = faceCenter(g.key_h) - pxr * 0.5;
        g.plate_pad = @round(pxr * 0.3);
    }
    // a free row between the HUD (or phrase) and the highest cap
    g.cap_top_row = g.hud_rows + @intFromBool(phrase_line) + @intFromBool(rows >= 16);
    g.deck_y = g.y(fi(g.deck_row));
    const play_top = g.y(fi(g.hud_rows));
    g.kb_top = @round(play_top + (g.deck_y - play_top) * (if (lo) @as(f32, 0.42) else 0.36));
    return g;
}

/// Vertical center of a `canvas.keycap` top face of height h, from its top.
fn faceCenter(h: f32) f32 {
    const band = @max(h * 0.16, @min(1.0, h * 0.25));
    const top = @min(2.5, h * 0.08);
    return top + (h - band - top) * 0.5;
}

/// Where a cap sits this frame (cells + pixels).
const CapGeo = struct {
    l: lay.Layout,
    col: i32,
    /// Row of the key legends.
    row: i32,
    caption_row: i32,
    key_y: f32,
    plate: bool,
    px0: f32,
    py0: f32,
    px1: f32,
    py1: f32,
    /// Center of the keys area (px).
    cx: f32,
    cy: f32,
    keys_w: f32,
    compact: bool,
};

/// Width of a key on a big (3-row) cap: word letters 5 cells, everything
/// keys 5, wider keys (Ctrl, Enter, ...) two cells wider than `layout.zig`.
fn bigKeyWidth(w: u16, compact: bool) u16 {
    if (compact or w <= 4) return 5;
    return w + 2;
}

/// `layout.layout`, widened for big caps (legends stay on cell centers).
fn capLayout(g: *const Geo, c: *const Cap) lay.Layout {
    var l = lay.layout(c);
    if (!g.big or l.n == 0) return l;
    const compact = c.kind == .word;
    const gap: u16 = if (compact) 0 else 1;
    const pad: u16 = if (l.plate) 1 else 0;
    var x: u16 = 0;
    for (l.boxes[0..l.n], 0..) |*b, i| {
        if (i > 0) x += gap;
        b.w = bigKeyWidth(b.w, compact);
        b.x = x;
        x += b.w;
    }
    var width = x + 2 * pad;
    if (l.plate) width = @max(width, lay.legendCols(c.caption) + 2);
    const shift = (width - x) / 2;
    for (l.boxes[0..l.n]) |*b| b.x += shift;
    l.width = width;
    return l;
}

/// Pixels a cap reaches above / below the top of its legend row.
const Extent = struct { above: f32, below: f32 };

fn capExtent(g: *const Geo, c: *const Cap, plate: bool) Extent {
    const pad: f32 = if (plate) g.plate_pad else 0;
    const above = g.key_lift + pad;
    var below = g.key_h - g.key_lift + pad;
    if (plate and c.caption.len > 0) below = @max(below, g.y(3)) - (if (g.lo) 0 else g.pxr * 0.1);
    return .{ .above = above, .below = below };
}

/// Legend rows a cap occupies from spawn (progress 0) to landing (1).
fn capRowRange(g: *const Geo, c: *const Cap, plate: bool) [2]i32 {
    const e = capExtent(g, c, plate);
    const first: i32 = g.cap_top_row + @as(i32, @intFromFloat(@ceil(e.above / g.pxr - 0.01)));
    const last: i32 = @intFromFloat(@floor((g.deck_y - e.below) / g.pxr + 0.01));
    return .{ first, @max(last, first) };
}

fn capGeo(g: *const Geo, c: *const Cap) CapGeo {
    const l = capLayout(g, c);
    const width: i32 = l.width;
    var col: i32 = @intFromFloat(@round(c.x * fi(g.cols) - fi(width) * 0.5));
    col = std.math.clamp(col, 0, @max(g.cols - width, 0));
    const rr = capRowRange(g, c, l.plate);
    const span: i32 = rr[1] - rr[0];
    const p = sat(c.progress);
    const step: i32 = @min(span, @as(i32, @intFromFloat(@floor(p * fi(span + 1)))));
    const row = rr[0] + step;
    // With pixels to spare (kitty/web) legends are drawn into the image, so
    // the cap glides; on half-block it steps a text row at a time so the
    // text-layer legend stays on its face.
    const top: f32 = if (g.lo) fi(row) else fi(rr[0]) + p * fi(span);
    const key_y = g.y(top) - g.key_lift;
    const ext = capExtent(g, c, l.plate);
    var cg: CapGeo = .{
        .l = l,
        .col = col,
        .row = row,
        .caption_row = row + 2,
        .key_y = key_y,
        .plate = l.plate,
        .px0 = g.x(fi(col)),
        .px1 = g.x(fi(col + width)),
        .py0 = g.y(top) - ext.above,
        .py1 = g.y(top) + ext.below,
        .cx = 0,
        .cy = key_y + g.key_h * 0.5,
        .keys_w = 0,
        .compact = c.kind == .word,
    };
    if (l.plate and !g.lo) {
        cg.px0 += g.pxc * 0.3;
        cg.px1 -= g.pxc * 0.3;
    }
    const ks = l.keys();
    if (ks.len > 0) {
        const a = keyRect(g, &cg, ks[0]);
        const b = keyRect(g, &cg, ks[ks.len - 1]);
        cg.cx = (a.x0 + b.x1) * 0.5;
        cg.keys_w = b.x1 - a.x0;
    } else {
        cg.cx = (cg.px0 + cg.px1) * 0.5;
    }
    return cg;
}

const KeyRect = struct {
    x0: f32,
    x1: f32,
    /// Legend placement in cells.
    lcol: i32,
    lrow: i32,
};

fn keyRect(g: *const Geo, cg: *const CapGeo, b: lay.KeyBox) KeyRect {
    const n: i32 = lay.legendCols(b.legend);
    const w: i32 = b.w;
    const d: i32 = @mod(w - n, 2);
    const x: i32 = cg.col + b.x;
    const lcol = x + @divFloor(w - n - d, 2);
    var e: f32 = 0;
    if (!g.lo) {
        if (cg.compact) {
            e = if (g.big) -0.3 else -0.1;
        } else {
            e = if (cg.plate) (if (d == 1) 0.15 else -0.05) else (if (d == 1) 0.35 else 0);
        }
    }
    return .{
        .x0 = g.x(fi(x) - e),
        .x1 = g.x(fi(x + w - d) + e),
        .lcol = lcol,
        .lrow = cg.row,
    };
}

// ---------------------------------------------------------------------------
// Backdrop keyboard
// ---------------------------------------------------------------------------

const KbDef = struct { at: f32, w: f32, code: u21, legend: []const u8 };

/// Comptime key row from (width, code, legend) entries; code 0 = a gap.
fn kbRow(comptime spec: []const struct { f32, u21, []const u8 }, comptime start: f32) []const KbDef {
    comptime {
        var n = 0;
        for (spec) |e| {
            if (e[1] != 0) n += 1;
        }
        var out: [n]KbDef = undefined;
        var x = start;
        var i = 0;
        for (spec) |e| {
            if (e[1] != 0) {
                out[i] = .{ .at = x, .w = e[0], .code = e[1], .legend = e[2] };
                i += 1;
            }
            x += e[0];
        }
        const final = out;
        return &final;
    }
}

const F = kc.f1;

const kb_main = [6][]const KbDef{
    kbRow(&.{ .{ 1, kc.escape, "" }, .{ 1, 0, "" }, .{ 1, F, "" }, .{ 1, F + 1, "" }, .{ 1, F + 2, "" }, .{ 1, F + 3, "" }, .{ 0.5, 0, "" }, .{ 1, F + 4, "" }, .{ 1, F + 5, "" }, .{ 1, F + 6, "" }, .{ 1, F + 7, "" }, .{ 0.5, 0, "" }, .{ 1, F + 8, "" }, .{ 1, F + 9, "" }, .{ 1, F + 10, "" }, .{ 1, F + 11, "" } }, 0),
    kbRow(&.{ .{ 1, '`', "`" }, .{ 1, '1', "1" }, .{ 1, '2', "2" }, .{ 1, '3', "3" }, .{ 1, '4', "4" }, .{ 1, '5', "5" }, .{ 1, '6', "6" }, .{ 1, '7', "7" }, .{ 1, '8', "8" }, .{ 1, '9', "9" }, .{ 1, '0', "0" }, .{ 1, '-', "-" }, .{ 1, '=', "=" }, .{ 2, kc.backspace, "" } }, 0),
    kbRow(&.{ .{ 1.5, kc.tab, "" }, .{ 1, 'q', "Q" }, .{ 1, 'w', "W" }, .{ 1, 'e', "E" }, .{ 1, 'r', "R" }, .{ 1, 't', "T" }, .{ 1, 'y', "Y" }, .{ 1, 'u', "U" }, .{ 1, 'i', "I" }, .{ 1, 'o', "O" }, .{ 1, 'p', "P" }, .{ 1, '[', "[" }, .{ 1, ']', "]" }, .{ 1.5, '\\', "\\" } }, 0),
    kbRow(&.{ .{ 1.75, kc.caps_lock, "" }, .{ 1, 'a', "A" }, .{ 1, 's', "S" }, .{ 1, 'd', "D" }, .{ 1, 'f', "F" }, .{ 1, 'g', "G" }, .{ 1, 'h', "H" }, .{ 1, 'j', "J" }, .{ 1, 'k', "K" }, .{ 1, 'l', "L" }, .{ 1, ';', ";" }, .{ 1, '\'', "'" }, .{ 2.25, kc.enter, "" } }, 0),
    kbRow(&.{ .{ 2.25, kc.left_shift, "" }, .{ 1, 'z', "Z" }, .{ 1, 'x', "X" }, .{ 1, 'c', "C" }, .{ 1, 'v', "V" }, .{ 1, 'b', "B" }, .{ 1, 'n', "N" }, .{ 1, 'm', "M" }, .{ 1, ',', "," }, .{ 1, '.', "." }, .{ 1, '/', "/" }, .{ 2.75, kc.right_shift, "" } }, 0),
    kbRow(&.{ .{ 1.25, kc.left_control, "" }, .{ 1.25, kc.left_super, "" }, .{ 1.25, kc.left_alt, "" }, .{ 6.25, ' ', "" }, .{ 1.25, kc.right_alt, "" }, .{ 1.25, kc.right_super, "" }, .{ 1.25, 57363, "" }, .{ 1.25, kc.right_control, "" } }, 0),
};

const kb_nav = [6][]const KbDef{
    &.{},
    kbRow(&.{ .{ 1, kc.insert, "" }, .{ 1, kc.home, "" }, .{ 1, kc.page_up, "" } }, 15.5),
    kbRow(&.{ .{ 1, kc.delete, "" }, .{ 1, kc.end, "" }, .{ 1, kc.page_down, "" } }, 15.5),
    &.{},
    kbRow(&.{.{ 1, kc.up, "↑" }}, 16.5),
    kbRow(&.{ .{ 1, kc.left, "←" }, .{ 1, kc.down, "↓" }, .{ 1, kc.right, "→" } }, 15.5),
};

/// Relative height of each keyboard row (the function row is short).
const kb_row_weight = [6]f32{ 0.62, 1, 1, 1, 1, 1 };

const KB_UNITS: f32 = 18.5;
const MAX_KB_KEYS = 112;

const KbKey = struct {
    code: u21,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Horizontal position 0..1 (LED wave phase).
    u: f32,
    legend: []const u8,
};

/// Cached static background + keyboard LED mask for one surface size.
const Backdrop = struct {
    w: u32 = 0,
    h: u32 = 0,
    rows: u16 = 0,
    cols: u16 = 0,
    lo: bool = false,
    ok: bool = false,
    bg: []Px = &.{},
    kb_y0: u32 = 0,
    kb_h: u32 = 0,
    /// LED light per keyboard pixel (0..255) and the key that lights it.
    mask: []u8 = &.{},
    ids: []u8 = &.{},
    keys: [MAX_KB_KEYS]KbKey = undefined,
    n: usize = 0,
    unit: f32 = 1,

    fn free(self: *Backdrop, a: std.mem.Allocator) void {
        if (self.bg.len > 0) a.free(self.bg);
        if (self.mask.len > 0) a.free(self.mask);
        if (self.ids.len > 0) a.free(self.ids);
        self.bg = &.{};
        self.mask = &.{};
        self.ids = &.{};
        self.ok = false;
        self.w = 0;
        self.h = 0;
    }

    fn keyFor(self: *const Backdrop, code: u21) ?usize {
        const c = if (code >= 'A' and code <= 'Z') code + 32 else code;
        for (self.keys[0..self.n], 0..) |k, i| {
            if (k.code == c) return i;
        }
        return null;
    }
};

fn surfaceOver(a: std.mem.Allocator, pixels: []Px, w: u32, h: u32) Surface {
    return .{ .allocator = a, .cols = 0, .rows = 0, .w = w, .h = h, .pixels = pixels, .text = &.{} };
}

// ---------------------------------------------------------------------------
// Presentation state
// ---------------------------------------------------------------------------

const PopupSlot = struct {
    active: bool = false,
    style: popup_mod.Style = .punch,
    text: [32]u8 = undefined,
    text_len: u8 = 0,
    sub: [24]u8 = undefined,
    sub_len: u8 = 0,
    quick: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    t0: f32 = 0,
    dur: f32 = 1,
    hue: f32 = 0,
    intensity: f32 = 0.5,
    seed: u32 = 0,
    scale: f32 = 1,
    width: f32 = 0,
};

const Ripple = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    t0: f32 = 0,
    c: Rgb = Rgb.white,
    strength: f32 = 1,
    /// Ring speed in keyboard units per second.
    speed: f32 = 14,
    dur: f32 = 1.2,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    fx: fx.Fx,
    rng: fx.rng.Rng,
    /// Scene clock in seconds (stops while paused).
    time: f32 = 0,
    last_ms: ?i64 = null,
    popups: [MAX_POPUPS]PopupSlot = @splat(.{}),
    last_style: ?popup_mod.Style = null,
    ripples: [MAX_RIPPLES]Ripple = @splat(.{}),
    ripple_next: usize = 0,
    /// Red keyboard flash (wrong key / miss), 0..1.
    red: f32 = 0,
    /// LED pulse (level up / milestone), 0..1.
    pulse: f32 = 0,
    bd: Backdrop = .{},
    key_col: [MAX_KB_KEYS][3]u32 = undefined,
    key_hint: [MAX_KB_KEYS]f32 = undefined,
    hint_col: [MAX_KB_KEYS]Rgb = undefined,
    clock: [4]u8 = .{ '0', '9', '0', '0' },
    clock_from: [4]u8 = .{ '0', '9', '0', '0' },
    clock_t0: [4]f32 = .{ -9, -9, -9, -9 },
    clock_init: bool = false,
    phase: model.Phase = .title,
    phase_t0: f32 = 0,
    phrase_text: []const u8 = "",
    phrase_done_t: ?f32 = null,
    fx_w: u32 = 0,
    fx_h: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !Scene {
        var e = try fx.Fx.init(allocator);
        e.seed(@truncate(seed ^ (seed >> 32)));
        return .{
            .allocator = allocator,
            .fx = e,
            .rng = fx.rng.Rng.init(@truncate((seed *% 0x9E37_79B9_7F4A_7C15) >> 32)),
        };
    }

    pub fn deinit(self: *Scene) void {
        self.fx.deinit();
        self.bd.free(self.allocator);
    }

    /// Drop effects, popups and ripples (mode switch, new game).
    pub fn reset(self: *Scene) void {
        self.fx.reset();
        for (&self.popups) |*p| p.active = false;
        for (&self.ripples) |*r| r.active = false;
        self.red = 0;
        self.pulse = 0;
        self.clock_init = false;
        self.last_ms = null;
        self.phrase_done_t = null;
    }

    /// Draw a full frame into `s` (pixels + text layer). Reads `arc.events()`
    /// for this frame (spawns effects, popups, ripples) but does not clear
    /// them; the caller calls `arc.clearEvents()` afterwards.
    pub fn render(self: *Scene, s: *Surface, arc: *const Arcade, now_ms: i64, q: Quality) void {
        if (s.w == 0 or s.h == 0 or s.cols == 0 or s.rows == 0) return;
        const g = computeGeo(s, q, arc.hud.word_stage and arc.hud.phrase != null);

        const dt: f32 = if (self.last_ms) |l| std.math.clamp(fi(now_ms - l) / 1000.0, 0, 0.1) else 1.0 / 60.0;
        self.last_ms = now_ms;
        const paused = arc.phase == .paused;
        const dts: f32 = if (paused) 0 else dt;
        self.time += dts;
        if (arc.phase != self.phase) {
            if (!(self.phase == .paused or arc.phase == .paused)) self.phase_t0 = self.time;
            if (arc.phase == .title or arc.phase == .results) for (&self.popups) |*p| {
                p.active = false;
            };
            self.phase = arc.phase;
        }

        self.configure(s, &g, q);
        self.ensureBackdrop(s, &g);

        for (arc.events()) |ev| self.onEvent(&g, arc, ev);
        if (dts > 0) self.fx.update(dts);
        self.red *= @exp(-dts * 3.5);
        self.pulse *= @exp(-dts * 2.2);

        s.clearText();
        self.drawBackdrop(s, &g, arc);
        self.fx.drawUnder(s);
        self.drawCaps(s, &g, arc);
        self.fx.drawOver(s);
        self.drawPopups(s, &g, arc.phase == .paused);
        self.fx.post(s);

        switch (arc.phase) {
            .title => self.drawTitle(s, &g, arc),
            .playing => {
                self.drawDeckHealth(s, &g, arc);
                self.drawLanes(s, &g, arc);
                self.drawHud(s, &g, arc);
            },
            .paused => {
                self.drawDeckHealth(s, &g, arc);
                self.drawLanes(s, &g, arc);
                self.drawHud(s, &g, arc);
                self.drawPaused(s, &g, arc);
            },
            .results => self.drawResults(s, &g, arc),
        }
    }

    fn configure(self: *Scene, s: *const Surface, g: *const Geo, q: Quality) void {
        if (self.fx_w != s.w or self.fx_h != s.h) {
            self.fx.setCellPx(g.pxc, g.pxr);
            self.fx_w = s.w;
            self.fx_h = s.h;
        }
        self.fx.floor_y = g.deck_y;
        self.fx.setSurfacePx(g.w, g.h);
        self.fx.bloom_quality = if (g.lo) .off else q.bloom;
        self.fx.bloom_threshold = 0.72;
        self.fx.bloom_strength = 0.6;
        self.fx.vignette = 0;
    }

    // -----------------------------------------------------------------------
    // Events

    fn onEvent(self: *Scene, g: *const Geo, arc: *const Arcade, ev: model.Event) void {
        switch (ev) {
            .hit => |h| self.onHit(g, arc, h),
            .miss => |m| {
                var cx = m.x * g.w;
                if (findCap(arc, m.cap_id)) |c| cx = capGeo(g, c).cx;
                self.fx.missBurst(cx, g.deck_y - g.key_h * 0.4);
                self.red = 1;
            },
            .wrong => |w| {
                self.red = @max(self.red, 0.75);
                self.rippleAt(w.code, pal.miss, 0.9);
            },
            .key_press => |k| {
                const kp = Rgb.init(0.55, 0.75, 1.0);
                self.rippleAt(k.code, kp, 0.45);
                if (k.mods.ctrl) self.rippleAt(kc.left_control, kp, 0.35);
                if (k.mods.alt) self.rippleAt(kc.left_alt, kp, 0.35);
                if (k.mods.shift) self.rippleAt(kc.left_shift, kp, 0.35);
            },
            .level_up => {
                self.pulse = 1;
                self.addRipple(KB_UNITS * 0.5, 2.0, pal.amber, 1.6, 10, 1.8);
                self.fx.flash(pal.amber, 0.06);
            },
            .milestone => {
                self.pulse = @max(self.pulse, 0.8);
                self.addRipple(KB_UNITS * 0.5, 2.0, pal.teal, 1.2, 12, 1.4);
            },
            .phrase_done => |p| {
                var buf: [40]u8 = undefined;
                var num: [40]u8 = undefined;
                const t = std.mem.print(&buf, "+{s}", .{fmtThousands(&num, p.points)}) catch "";
                const y = g.y(fi(g.hud_rows) + 3.5);
                self.addPopup(g, arc, t, "line complete", false, g.w * 0.5, y, 0.12, 0.9, 3);
            },
            .game_over => {
                self.fx.flash(pal.miss, 0.22);
                self.fx.shake(0.5);
                self.red = 1;
            },
            .start => {
                for (&self.popups) |*p| p.active = false;
                self.clock_init = false;
                self.phrase_done_t = null;
                self.pulse = 1;
                self.addRipple(KB_UNITS * 0.5, 2.0, pal.teal, 1.4, 12, 1.6);
            },
            .step => {},
        }
    }

    fn onHit(self: *Scene, g: *const Geo, arc: *const Arcade, h: anytype) void {
        const tier = h.effect.tier();
        var px = h.x * g.w;
        var py = g.y(fi(g.cap_top_row)) + h.y * (g.deck_y - g.y(fi(g.cap_top_row)));
        var top_y = py - g.key_h * 0.5;
        if (findCap(arc, h.cap_id)) |c| {
            const cg = capGeo(g, c);
            px = cg.cx;
            py = cg.cy;
            top_y = cg.key_y;
            const ks = cg.l.keys();
            const compact = c.kind == .word;
            const single = tier == 3 or compact or ks.len > 4 or ks.len == 0;
            if (single) {
                var look = lookOf(c, if (ks.len > 0) ks[ks.len - 1] else null);
                if (compact) look.text = "" else if (ks.len > 0) look.text = ks[ks.len - 1].legend;
                const w = if (cg.keys_w > 0) cg.keys_w else g.key_h;
                self.fx.spawnEx(h.effect, .{ .cx = px, .cy = py, .w = w, .h = g.key_h, .hue = h.hue, .intensity = h.intensity, .look = look });
            } else {
                for (ks, 0..) |b, i| {
                    const r = keyRect(g, &cg, b);
                    var look = lookOf(c, b);
                    look.text = b.legend;
                    const k: f32 = if (i + 1 == ks.len) 1 else 0.7;
                    self.fx.spawnEx(h.effect, .{
                        .cx = (r.x0 + r.x1) * 0.5,
                        .cy = py,
                        .w = r.x1 - r.x0,
                        .h = g.key_h,
                        .hue = h.hue,
                        .intensity = h.intensity * k,
                        .look = look,
                    });
                }
            }
            // backdrop ripple from the key that completed the cap
            const last = c.steps[if (c.len > 0) c.len - 1 else 0];
            self.rippleAt(last.code, color.accent(h.hue), 1.1 + 0.35 * fi(tier) + 0.5 * h.intensity);
        } else {
            self.fx.spawn(h.effect, px, py, g.key_h, g.key_h, h.hue, h.intensity);
        }

        if (arc.phase == .title) return;
        var num: [40]u8 = undefined;
        var buf: [40]u8 = undefined;
        const pts = std.mem.print(&buf, "+{s}", .{fmtThousands(&num, h.points)}) catch "";
        if (h.caption.len > 0) {
            self.addPopup(g, arc, h.caption, pts, h.quick, px, top_y - g.key_h * 0.6, h.hue, h.intensity, tier);
        } else {
            self.addPopup(g, arc, pts, "", h.quick, px, top_y - g.key_h * 0.6, h.hue, h.intensity, tier);
        }
    }

    fn addPopup(self: *Scene, g: *const Geo, arc: *const Arcade, text: []const u8, sub: []const u8, quick: bool, x: f32, y: f32, hue: f32, intensity: f32, tier: u2) void {
        var slot: *PopupSlot = &self.popups[0];
        for (&self.popups) |*p| {
            if (!p.active) {
                slot = p;
                break;
            }
            if (p.t0 < slot.t0) slot = p;
        }
        slot.active = false;
        const style = popup_mod.nextStyle(self.last_style, &self.rng);
        self.last_style = style;
        const tl = @min(text.len, slot.text.len);
        const sl = @min(sub.len, slot.sub.len);
        // long captions step down a size so they don't span the screen
        var scale: f32 = if (g.lo) 1 else popup_mod.bigScale(@intFromFloat(g.w));
        while (!g.lo and scale > 1 and font.measure(text[0..tl], scale, .{ .bold = true }) > g.w * 0.26) scale -= 1;
        slot.* = .{
            .active = true,
            .style = style,
            .quick = quick,
            .x = x,
            .y = y,
            .t0 = self.time,
            .dur = popup_mod.duration(tier),
            .hue = hue,
            .intensity = intensity,
            .seed = self.rng.next(),
            .scale = scale,
        };
        @memcpy(slot.text[0..tl], text[0..tl]);
        slot.text_len = @intCast(tl);
        @memcpy(slot.sub[0..sl], sub[0..sl]);
        slot.sub_len = @intCast(sl);
        const tw = if (g.lo) fi(lay.legendCols(slot.text[0..tl])) * g.pxc else font.measure(slot.text[0..tl], scale, .{ .bold = true });
        slot.width = tw;
        const bh = if (g.lo) g.pxr else font.height(scale);
        // Placement: keep on screen below the HUD, then pick the nearby spot
        // that overlaps the fewest live popups and falling caps.
        // (hi-res: room for the rise animation, so popups never drift up
        // into the phrase / callout lanes under the HUD; see popupRect)
        const min_y = g.y(fi(g.cap_top_row)) + bh * (if (g.lo) @as(f32, 1.6) else 1.5);
        const max_y = @max(g.deck_y - bh * 1.5, min_y);
        const lo_x = tw * 0.5 + 2;
        const hi_x = @max(g.w - tw * 0.5 - 2, lo_x);
        const x0 = std.math.clamp(x, lo_x, hi_x);
        const y0 = std.math.clamp(y, min_y, max_y);
        const step = bh * 1.25;
        const dys = [_]f32{ 0, -1, 1, -2, 2, -3, 3 };
        const dxs = [_]f32{ 0, -0.7, 0.7 };
        var best_x = x0;
        var best_y = y0;
        var best: f32 = std.math.inf(f32);
        outer: for (dxs) |dx| {
            for (dys) |dy| {
                const cx = std.math.clamp(x0 + dx * (tw + g.pxc * 4), lo_x, hi_x);
                const cy = std.math.clamp(y0 + dy * step, min_y, max_y);
                const r = popupRect(g, cx, cy, tw, bh, sl > 0 or quick);
                var cost: f32 = (@abs(dx) * 2 + @abs(dy)) * 0.02 * bh * tw;
                for (&self.popups) |*o| {
                    if (o == slot or !o.active or self.time - o.t0 > o.dur * 0.8) continue;
                    const obh = if (g.lo) g.pxr else font.height(o.scale);
                    cost += overlapArea(r, popupRect(g, o.x, o.y, o.width, obh, o.sub_len > 0 or o.quick));
                }
                for (arc.caps()) |*c| {
                    if (c.state != .falling) continue;
                    const cg = capGeo(g, c);
                    cost += 0.6 * overlapArea(r, .{ cg.px0, cg.py0, cg.px1, cg.py1 });
                }
                if (cost < best) {
                    best = cost;
                    best_x = cx;
                    best_y = cy;
                    if (cost <= 0) break :outer;
                }
            }
        }
        slot.x = best_x;
        slot.y = best_y;
    }

    fn rippleAt(self: *Scene, code: u21, c: Rgb, strength: f32) void {
        const i = self.bd.keyFor(code) orelse return;
        const k = self.bd.keys[i];
        const u = self.bd.unit;
        self.addRipple((k.x + k.w * 0.5) / u, (k.y + k.h * 0.5) / u, c, strength, 14, 1.1);
    }

    /// (x, y) in keyboard units.
    fn addRipple(self: *Scene, x: f32, y: f32, c: Rgb, strength: f32, speed: f32, dur: f32) void {
        self.ripples[self.ripple_next] = .{ .active = true, .x = x, .y = y, .t0 = self.time, .c = c, .strength = strength, .speed = speed, .dur = dur };
        self.ripple_next = (self.ripple_next + 1) % MAX_RIPPLES;
    }

    // -----------------------------------------------------------------------
    // Backdrop

    fn ensureBackdrop(self: *Scene, s: *const Surface, g: *const Geo) void {
        const bd = &self.bd;
        if (bd.w == s.w and bd.h == s.h and bd.rows == s.rows and bd.cols == s.cols and bd.lo == g.lo) return;
        bd.free(self.allocator);
        bd.w = s.w;
        bd.h = s.h;
        bd.rows = s.rows;
        bd.cols = s.cols;
        bd.lo = g.lo;
        self.buildBackdrop(g) catch {
            bd.free(self.allocator);
            bd.w = s.w;
            bd.h = s.h;
            bd.rows = s.rows;
            bd.cols = s.cols;
        };
    }

    fn buildBackdrop(self: *Scene, g: *const Geo) !void {
        const a = self.allocator;
        const bd = &self.bd;
        const w = bd.w;
        const h = bd.h;
        bd.bg = try a.alloc(Px, @as(usize, w) * h);
        var bs = surfaceOver(a, bd.bg, w, h);
        paintSky(&bs, g);

        // keyboard geometry
        bd.kb_y0 = @intFromFloat(std.math.clamp(g.kb_top - g.pxr * 1.2, 0, fi(h)));
        const kb_y1: u32 = @intFromFloat(@min(@max(g.deck_y, fi(bd.kb_y0)), fi(h)));
        bd.kb_h = kb_y1 - bd.kb_y0;
        layoutKeyboard(bd, g);

        // keyboard slab + keys into the background, softened out of focus
        paintKeyboard(&bs, bd, g);
        const n = @as(usize, w) * bd.kb_h;
        const blur_tmp = try a.alloc(Px, @max(w, h));
        defer a.free(blur_tmp);
        if (!g.lo and n > 0) {
            // radius follows the key size so every resolution looks as soft
            const r: usize = @intFromFloat(std.math.clamp(@round(bd.unit * 0.06), 1, 8));
            boxBlur(bd.bg, w, bd.kb_y0, kb_y1, r, blur_tmp);
            boxBlur(bd.bg, w, bd.kb_y0, kb_y1, r, blur_tmp);
        }
        paintDeck(&bs, g);
        fx.post.vignette(&bs, if (g.lo) 0.35 else 0.55, Rgb.hex(0x03030c));

        // LED mask (grayscale, blurred into soft light) + per-pixel key ids
        bd.mask = try a.alloc(u8, n);
        bd.ids = try a.alloc(u8, n);
        if (n > 0) {
            const tmp = try a.alloc(Px, n);
            defer a.free(tmp);
            @memset(tmp, Px.black);
            var ms = surfaceOver(a, tmp, w, bd.kb_h);
            paintMask(&ms, bd, g);
            if (!g.lo) {
                const r: usize = @intFromFloat(std.math.clamp(@round(bd.unit * 0.08), 1, 10));
                boxBlur(tmp, w, 0, bd.kb_h, r, blur_tmp);
                boxBlur(tmp, w, 0, bd.kb_h, r, blur_tmp);
            }
            for (tmp, 0..) |p, i| bd.mask[i] = p.r;
            fillIds(bd);
        }
        bd.ok = true;
    }

    fn drawBackdrop(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const bd = &self.bd;
        if (!bd.ok or bd.bg.len != s.pixels.len) {
            const stops = [_]canvas.Stop{
                .{ .at = 0, .c = pal.night },
                .{ .at = 0.6, .c = night_hi },
                .{ .at = 1, .c = Rgb.hex(0x07071a) },
            };
            canvas.backgroundV(s, &stops);
            return;
        }
        @memcpy(s.pixels, bd.bg);
        const t = self.time;

        // drifting bokeh
        if (!g.lo) {
            for (0..6) |i| {
                const fi_: f32 = fi(i);
                const bx = @mod(fi_ * 0.173 + 0.07 + t * 0.006 * (1 + fi_ * 0.3), 1.0) * g.w;
                const by = g.h * (0.18 + 0.28 * fx.rng.hash01(@intCast(i), 7)) + @sin(t * 0.3 + fi_) * g.pxr;
                const r = g.w * (0.025 + 0.02 * fx.rng.hash01(@intCast(i), 3));
                canvas.glow(s, bx, by, r, color.ledCycle(t, fi_ * 0.2), 0.05, .add);
            }
        }

        // energy from combo, LED colors per key
        const energy: f32 = switch (arc.phase) {
            .title => 0.45,
            .results => 0.25,
            else => sat(fi(arc.stats.combo) / 40.0),
        };
        self.computeKeyHints(g, arc);
        const bright = (if (g.lo) @as(f32, 0.26) else 0.36) + 0.4 * energy + 0.35 * self.pulse;
        const red_c = Rgb.init(1.0, 0.12, 0.16);
        var sum = Rgb.black;
        for (bd.keys[0..bd.n], 0..) |k, i| {
            var c = color.ledCycle(t, k.u * 0.6).scale(bright);
            const kx = (k.x + k.w * 0.5) / bd.unit;
            const ky = (k.y + k.h * 0.5) / bd.unit;
            for (&self.ripples) |*r| {
                if (!r.active) continue;
                const age = t - r.t0;
                if (age > r.dur or age < 0) {
                    if (age > r.dur) r.active = false;
                    continue;
                }
                const dx = kx - r.x;
                const dy = (ky - r.y) * 1.3;
                const d = @sqrt(dx * dx + dy * dy);
                const ring = (d - age * r.speed) / 1.5;
                const fade = 1 - age / r.dur;
                var amp = r.strength * @exp(-ring * ring) * fade * fade * 0.5;
                if (d < 0.7) amp += r.strength * @exp(-age * 5.0) * 0.8;
                c = c.add(r.c.scale(amp));
            }
            if (self.key_hint[i] > 0.01) c = c.add(self.hint_col[i].scale(self.key_hint[i]));
            if (self.red > 0.01) c = c.lerp(red_c.scale(1.0 + 0.4 * self.red), self.red * 0.8);
            sum = sum.add(c);
            self.key_col[i] = .{ scale255(c.r), scale255(c.g), scale255(c.b) };
        }
        // composite LED light through the mask
        const w: usize = bd.w;
        var y: usize = 0;
        while (y < bd.kb_h) : (y += 1) {
            const row = s.pixels[(bd.kb_y0 + y) * w ..][0..w];
            const mrow = bd.mask[y * w ..][0..w];
            const irow = bd.ids[y * w ..][0..w];
            for (row, mrow, irow) |*p, m, id| {
                if (m < 2) continue;
                const col = self.key_col[id];
                p.r = @intCast(@min(@as(u32, p.r) + ((col[0] * m) >> 8), 255));
                p.g = @intCast(@min(@as(u32, p.g) + ((col[1] * m) >> 8), 255));
                p.b = @intCast(@min(@as(u32, p.b) + ((col[2] * m) >> 8), 255));
            }
        }
        // LED haze above the keyboard
        if (bd.n > 0) {
            const avg = sum.scale(1.0 / fi(bd.n));
            const haze_h = (g.kb_top - g.y(fi(g.hud_rows))) * 0.5;
            canvas.gradientV(s, 0, g.kb_top - haze_h, g.w, haze_h, Rgb.black, avg, 0.10 + 0.12 * energy, .add);
        }
        // deck ledge glow line (LED gradient)
        self.drawLedge(s, g);
        // light pools under falling caps on the polished deck
        for (arc.caps()) |*c| {
            if (c.state != .falling) continue;
            const p = c.progress;
            if (p < 0.35) continue;
            const cg = capGeo(g, c);
            const k = smoothstep(0.35, 1.0, p);
            const rx = @max(cg.keys_w * 0.7, g.key_h);
            canvas.glowEllipse(s, cg.cx, g.deck_y + (if (g.lo) 0.5 else g.pxr * 0.4), rx, @max(g.pxr * 0.7, 1.5), color.accent(c.hue), 0.55 * k, .add);
        }
    }

    fn computeKeyHints(self: *Scene, g: *const Geo, arc: *const Arcade) void {
        _ = g;
        const bd = &self.bd;
        @memset(self.key_hint[0..bd.n], 0);
        for (arc.caps()) |*c| {
            if (c.state != .falling or c.typed >= c.len) continue;
            const st = c.steps[c.typed];
            const i = bd.keyFor(st.code) orelse continue;
            const k = (0.15 + 0.85 * smoothstep(0.25, 1.0, c.progress)) * 0.9;
            if (k > self.key_hint[i]) {
                self.key_hint[i] = k;
                self.hint_col[i] = color.accent(c.hue);
            }
        }
    }

    fn drawLedge(self: *Scene, s: *Surface, g: *const Geo) void {
        const t = self.time;
        const y = g.deck_y;
        const segs: usize = 24;
        const sw = g.w / fi(segs);
        for (0..segs) |i| {
            const c = color.ledCycle(t, fi(i) / fi(segs) * 0.6).lerp(Rgb.init(1, 0.15, 0.2), self.red * 0.7);
            const x0 = @floor(fi(i) * sw);
            const ww = @floor(fi(i + 1) * sw) - x0;
            if (g.lo) {
                canvas.fillRect(s, x0, y, ww, 1, c.lighten(0.25), 0.9, .over);
            } else {
                canvas.fillRect(s, x0, y - 1, ww, 2, c.lighten(0.35), 0.95, .over);
                canvas.gradientV(s, x0, @round(y - g.pxr * 0.9), ww, @round(g.pxr * 0.9) - 1, Rgb.black, c, 0.35, .add);
                canvas.gradientV(s, x0, y + 1, ww, @round(g.pxr * 0.7), c, Rgb.black, 0.25, .add);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Caps

    fn drawCaps(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const active_word = activeWord(arc);
        // draw higher caps first so lower ones (more urgent) sit on top
        var order: [arcade_mod.MAX_CAPS]u8 = undefined;
        const list = arc.caps();
        const n = @min(list.len, order.len);
        for (0..n) |i| order[i] = @intCast(i);
        std.mem.sort(u8, order[0..n], list, struct {
            fn lt(l: []const Cap, a: u8, b: u8) bool {
                return l[a].progress < l[b].progress;
            }
        }.lt);
        for (order[0..n]) |i| {
            const c = &list[i];
            switch (c.state) {
                .hit => {},
                .falling => self.drawCap(s, g, c, c.id == active_word, active_word != 0, arc.phase == .title),
                .missed => self.drawMissed(s, g, c),
            }
        }
    }

    /// `any_active`: some word cap is the active one (others recede).
    fn drawCap(self: *Scene, s: *Surface, g: *const Geo, c: *const Cap, active_word: bool, any_active: bool, attract: bool) void {
        const cg = capGeo(g, c);
        const p = sat(c.progress);
        const near = smoothstep(0.55, 1.0, p);
        const fade_in = sat(c.age / 0.18);
        const hue_c = color.accent(c.hue);
        const word = c.kind == .word;
        const waiting = word and any_active and !active_word;
        const skin = plateSkin(c.rarity);
        const rare_glow: ?Rgb = switch (c.rarity) {
            .common => null,
            else => effects.lookFor(.letter, c.rarity).glow,
        };
        const pw = cg.px1 - cg.px0;
        const ph = cg.py1 - cg.py0;
        if (!g.lo) {
            // drop shadow: darkens the backdrop keyboard so the cap reads
            canvas.roundRectGlow(s, cg.px0, cg.py0 + g.pxr * 0.2, pw, ph, g.pxr * 0.5, g.pxr * 1.2, Rgb.hex(0x020208), 0.6 * fade_in, .over);
            // motion streak above the cap
            if (!attract) {
                const sh = g.pxr * (1.2 + 2.5 * p);
                canvas.gradientV(s, cg.cx - cg.keys_w * 0.3, cg.py0 - sh, cg.keys_w * 0.6, sh, Rgb.black, hue_c, 0.08 * fade_in, .add);
            }
        }
        // plate
        if (cg.plate) {
            const rad = if (g.lo) 0.6 else @min(g.pxr * 0.55, 5);
            if (!g.lo) {
                const gc = if (active_word) pal.coral else rare_glow orelse hue_c;
                const ga = 0.10 + 0.3 * near + (if (rare_glow != null) @as(f32, 0.25) else 0) + (if (active_word) @as(f32, 0.22) else 0);
                canvas.roundRectGlow(s, cg.px0, cg.py0, pw, ph, rad, g.pxr * (if (active_word) @as(f32, 1.1) else 0.8), gc, ga * fade_in, .add);
            }
            canvas.roundRect(s, cg.px0, cg.py0, pw, ph, rad, skin.fill, 0.9 * fade_in, .over);
            if (!g.lo) {
                // inner top sheen
                canvas.gradientV(s, cg.px0 + rad * 0.5, cg.py0 + 1, pw - rad, @max(ph * 0.3, 1), skin.edge, skin.fill, 0.10 * fade_in, .add);
                const oc = if (active_word) pal.coral else skin.edge;
                const oa: f32 = if (active_word) 0.85 else if (c.rarity != .common) 0.55 else 0.14;
                canvas.roundRectOutline(s, cg.px0, cg.py0, pw, ph, rad, if (g.big and active_word) 1.5 else 1, oc, oa * fade_in, .over);
                if (c.rarity == .epic) {
                    for (0..7) |si| {
                        const sx = cg.px0 + pw * (0.05 + 0.9 * fx.rng.hash01(c.id, @intCast(si + 20)));
                        const sy = cg.py0 + ph * (0.08 + 0.84 * fx.rng.hash01(c.id, @intCast(si + 40)));
                        const tw = 0.5 + 0.5 * @sin(self.time * 5 + fi(si) * 2.1);
                        canvas.dot(s, sx, sy, Rgb.init(0.85, 0.8, 1), 0.25 + 0.55 * tw, .add);
                    }
                } else if (c.rarity == .legendary) {
                    const k = @mod(self.time * 0.7, 1.6);
                    const sx = cg.px0 + pw * k;
                    canvas.glowEllipse(s, sx, cg.py0 + 1, g.pxr * 1.5, 1.5, Rgb.hex(0xffe7a8), 0.6 * (1 - sat(k - 0.9)), .add);
                    canvas.glowEllipse(s, cg.px1 - pw * k, cg.py1 - 1, g.pxr * 1.5, 1.5, Rgb.hex(0xffe7a8), 0.5 * (1 - sat(k - 0.9)), .add);
                }
            } else if (active_word) {
                canvas.fillRect(s, cg.px0, cg.py1 - 1, pw, 1, pal.coral, 0.8, .over);
            }
            if (c.caption.len > 0) {
                const cc = if (c.typed > 0) pal.quick else ink.lerp(ink_dim, 0.3);
                if (g.lo) {
                    const n: i32 = lay.legendCols(c.caption);
                    const col = cg.col + @divFloor(@as(i32, cg.l.width) - n, 2);
                    put(s, col, cg.caption_row, c.caption, cc, false);
                } else {
                    // caption row center, gliding with the plate
                    const cy = cg.key_y + faceCenter(g.key_h) + g.pxr * 2;
                    legendPx(s, g, cg.px0, cg.px1, cy, c.caption, cc, false, fade_in, 1);
                }
            }
        }
        // keys
        for (cg.l.keys()) |b| {
            const r = keyRect(g, &cg, b);
            const typed = b.step < c.typed;
            const next = !typed and b.step == c.typed and !b.is_mod and (active_word or (!word and c.typed > 0));
            var look = lookOf(c, b);
            var y = cg.key_y;
            var glow: ?Rgb = null;
            var glow_amt: f32 = 0;
            var tint: ?Rgb = null;
            var tint_amt: f32 = 0;
            if (typed) {
                look.top = pal.teal;
                look.side = Rgb.hex(0x1d7a73);
                look.legend = Rgb.hex(0x04181a);
                glow = pal.quick;
                glow_amt = if (g.lo) 0.5 else 0.7;
                if (!g.lo) y += @max(1, g.pxr * 0.12);
            } else if (!cg.plate) {
                if (rare_glow) |rg| {
                    glow = rg;
                    glow_amt = 0.45 + 0.25 * @sin(self.time * 5);
                }
                if (near > 0.01) {
                    glow = if (glow) |gc| gc.lerp(hue_c, near) else hue_c;
                    glow_amt = @max(glow_amt, 0.25 + 0.6 * near);
                } else if (glow == null) {
                    glow = hue_c;
                    glow_amt = 0.12;
                }
            } else if (waiting) {
                tint = pal.night;
                tint_amt = 0.28;
            }
            if (g.lo) glow_amt *= 0.6;
            canvas.keycap(s, r.x0, y, r.x1 - r.x0, g.key_h, look.top, look.side, .{
                .alpha = fade_in,
                .radius = if (g.lo) 0.12 else 0.2,
                .glow = glow,
                .glow_amount = glow_amt,
                .tint = tint,
                .tint_amount = tint_amt,
            });
            if (next and !g.lo) {
                // caret under the next letter to type
                const pulse = 0.65 + 0.35 * @sin(self.time * 9);
                const cw = (r.x1 - r.x0) * 0.56;
                const cy = @min(cg.key_y + g.key_h + 1, cg.py1 - 1.5);
                canvas.fillRect(s, (r.x0 + r.x1) * 0.5 - cw * 0.5, cy, cw, @max(1, g.pxr * 0.14), pal.quick, pulse, .over);
                canvas.glowEllipse(s, (r.x0 + r.x1) * 0.5, cy + 0.5, cw * 0.8, g.pxr * 0.4, pal.quick, 0.35 * pulse, .add);
            }
            if (c.rarity == .epic and !typed and !g.lo and !cg.plate) {
                for (0..4) |si| {
                    const sx = r.x0 + (r.x1 - r.x0) * (0.15 + 0.7 * fx.rng.hash01(c.id, @intCast(si)));
                    const sy = y + g.key_h * (0.15 + 0.55 * fx.rng.hash01(c.id, @intCast(si + 9)));
                    const tw = 0.5 + 0.5 * @sin(self.time * 6 + fi(si) * 1.7);
                    canvas.dot(s, sx, sy, Rgb.init(0.9, 0.85, 1), 0.5 + 0.5 * tw, .add);
                }
            }
            if (c.rarity == .legendary and !typed and !g.lo) {
                const sx = r.x0 + (r.x1 - r.x0) * @mod(self.time * 0.8, 1.4);
                canvas.line(s, sx - 2, y + g.key_h * 0.75, sx + 2, y + g.key_h * 0.1, 1.5, Rgb.white, 0.35, .add);
            }
            var lc = look.legend;
            if (next and g.lo) lc = Rgb.hex(0xc2402a);
            if (waiting) lc = lc.lerp(look.top, 0.3);
            if (g.lo) {
                if (fade_in > 0.5) put(s, r.lcol, r.lrow, b.legend, lc, isBold(b));
            } else {
                legendPx(s, g, r.x0, r.x1, y + faceCenter(g.key_h), b.legend, lc, isBold(b), fade_in, legendScale(g));
            }
        }
    }

    fn drawMissed(self: *Scene, s: *Surface, g: *const Geo, c: *const Cap) void {
        _ = self;
        const t = c.state_t;
        const alpha = 1 - smoothstep(0.15, 0.75, t);
        if (alpha <= 0.01) return;
        const cg = capGeo(g, c);
        const sink = if (g.lo) @floor(t * 2) else t * g.key_h * 0.5;
        const jit = if (g.lo) 0 else @sin(t * 70) * (1 - sat(t * 4)) * g.pxc * 0.4;
        if (cg.plate) {
            canvas.roundRect(s, cg.px0 + jit, cg.py0 + sink, cg.px1 - cg.px0, cg.py1 - cg.py0, 2, pal.panel, 0.7 * alpha, .over);
        }
        for (cg.l.keys()) |b| {
            const r = keyRect(g, &cg, b);
            const look = lookOf(c, b);
            const x0 = r.x0 + jit;
            const y = cg.key_y + sink;
            const kw = r.x1 - r.x0;
            canvas.keycap(s, x0, y, kw, g.key_h, look.top, look.side, .{
                .alpha = alpha,
                .tint = pal.miss,
                .tint_amount = 0.55 + 0.3 * sat(t * 3),
                .glow = pal.miss,
                .glow_amount = 0.7 * alpha,
            });
            if (!g.lo) {
                // crack
                const pts = [_][2]f32{
                    .{ x0 + kw * 0.2, y + 1 },
                    .{ x0 + kw * 0.45, y + g.key_h * 0.4 },
                    .{ x0 + kw * 0.35, y + g.key_h * 0.6 },
                    .{ x0 + kw * 0.7, y + g.key_h * 0.95 },
                };
                canvas.polyline(s, &pts, 1, Rgb.hex(0x2a0508), 0.85 * alpha, .over);
            }
            if (g.lo) {
                if (alpha > 0.45) put(s, r.lcol, r.lrow + @as(i32, @intFromFloat(sink / g.pxr)), b.legend, Rgb.hex(0x3a0a0e), false);
            } else {
                legendPx(s, g, x0, x0 + kw, y + faceCenter(g.key_h), b.legend, Rgb.hex(0x3a0a0e), false, alpha, legendScale(g));
            }
        }
    }

    // -----------------------------------------------------------------------
    // Popups

    /// `paused`: text-layer (half-block) popups are hidden; they would show
    /// through the pause dim as plain text.
    fn drawPopups(self: *Scene, s: *Surface, g: *const Geo, paused: bool) void {
        for (&self.popups) |*p| {
            if (!p.active) continue;
            const t = self.time - p.t0;
            if (t >= p.dur) {
                p.active = false;
                continue;
            }
            const sub = p.sub[0..p.sub_len];
            if (g.lo) {
                if (!paused) drawPopupText(s, g, p, t);
                continue;
            }
            popup_mod.draw(s, .{
                .style = p.style,
                .text = p.text[0..p.text_len],
                .sub = sub,
                .quick = p.quick,
                .x = p.x,
                .y = p.y,
                .t = @max(t, 0),
                .dur = p.dur,
                .hue = p.hue,
                .intensity = p.intensity,
                .scale = p.scale,
                .seed = p.seed,
            });
        }
    }

    /// Half-block popups: crisp text-layer lines (the pixel font would be
    /// 3–4 rows tall) over a soft colored glow, rising a row as they fade.
    fn drawPopupText(s: *Surface, g: *const Geo, p: *const PopupSlot, t: f32) void {
        const k = t / p.dur;
        if (k > 0.85) return;
        const text = p.text[0..p.text_len];
        const sub = p.sub[0..p.sub_len];
        const n: i32 = lay.legendCols(text);
        const rise: f32 = switch (p.style) {
            .rise, .punch => 1 - (1 - sat(k * 1.6)) * (1 - sat(k * 1.6)),
            else => sat(k * 1.2) * 0.6,
        };
        const row: i32 = @intFromFloat(@floor(p.y / g.pxr - rise * 1.5));
        const col: i32 = @as(i32, @intFromFloat(@round(p.x / g.pxc))) - @divFloor(n, 2);
        const fade = 1 - smoothstep(0.55, 0.85, k);
        canvas.glowEllipse(s, p.x, g.y(fi(row) + 0.5), fi(n) * g.pxc * 0.7 + 2, g.pxr * 1.6, color.accent(p.hue), (0.25 + 0.25 * p.intensity) * fade, .add);
        const fg = pal.cream.lerp(color.popupTint(p.hue), sat(k / 0.5)).lerp(pal.night, 1 - fade);
        var shown = text;
        if (p.style == .type) {
            const m: usize = @intFromFloat(@ceil(sat(k / 0.42) * fi(text.len)));
            shown = text[0..@min(m, text.len)];
        }
        put(s, col, row, shown, fg, true);
        if (p.style == .glitch and k < 0.3) {
            // a red/cyan ghost cell either side
            put(s, col - 1, row, "▌", pal.glitch_red, false);
            put(s, col + n, row, "▐", pal.glitch_cyan, false);
        }
        var buf: [40]u8 = undefined;
        const line = if (p.quick and sub.len > 0)
            std.mem.print(&buf, "{s} quick", .{sub}) catch sub
        else if (p.quick) "quick" else sub;
        if (line.len > 0 and k > 0.05) {
            const ln: i32 = lay.legendCols(line);
            const lc: i32 = @as(i32, @intFromFloat(@round(p.x / g.pxc))) - @divFloor(ln, 2);
            put(s, lc, row + 1, line, (if (p.quick and sub.len == 0) pal.quick else ink_dim).lerp(pal.night, 1 - fade), false);
        }
    }

    // -----------------------------------------------------------------------
    // HUD

    fn drawScrim(s: *Surface, g: *const Geo, rows: f32) void {
        const h = g.y(rows);
        canvas.gradientV(s, 0, 0, g.w, h * 0.62, pal.night, pal.night, 0.72, .over);
        canvas.gradientV(s, 0, h * 0.62, g.w, h * 0.38, pal.night, pal.night, 0.4, .over);
        canvas.gradientV(s, 0, h, g.w, g.pxr * 1.5, pal.night, Rgb.black, 0.25, .over);
    }

    fn drawHud(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const st = arc.stats;
        const hud = arc.hud;
        drawScrim(s, g, fi(g.hud_rows));

        var nb: [40]u8 = undefined;
        const score_txt = fmtThousands(&nb, st.score);
        var mb: [16]u8 = undefined;
        const mult_txt = std.mem.print(&mb, "×{d}", .{st.mult}) catch "";
        var cb: [32]u8 = undefined;
        const combo_n = std.mem.print(&cb, "{d}", .{st.combo}) catch "";
        const rate: f32 = if (hud.word_stage) st.wpm else st.kpm;
        var rb: [16]u8 = undefined;
        const rate_txt = std.mem.print(&rb, "{d}", .{@as(u32, @intFromFloat(@round(@max(rate, 0))))}) catch "";
        const rate_label = if (hud.word_stage) "wpm" else "keys/min";
        // words: keys/min rides along small next to the wpm label
        var kb2: [24]u8 = undefined;
        const kpm_small = if (hud.word_stage) std.mem.print(&kb2, "{d} keys/min  |", .{@as(u32, @intFromFloat(@round(@max(st.kpm, 0))))}) catch "" else "";
        var pb: [24]u8 = undefined;
        const badge = if (hud.pace_mult > 1)
            std.mem.print(&pb, "{s} ×{d}", .{ hud.pace.label(), hud.pace_mult }) catch hud.pace.label()
        else
            hud.pace.label();

        const m = g.margin;
        const right_col = g.cols - m; // exclusive
        const clock_cols = self.drawClock(s, g, hud.clock_minutes);
        const center = @divFloor(g.cols, 2);
        const clock_c0 = center - @divFloor(clock_cols, 2);
        const clock_c1 = center + @divFloor(clock_cols + 1, 2);

        // level name under the clock
        {
            const n: i32 = lay.legendCols(hud.level_name);
            const col = center - @divFloor(n, 2);
            const row = g.label_row;
            if (!g.lo) {
                canvas.roundRect(s, g.x(fi(col) - 1), g.y(fi(row)) + 1, g.x(fi(n + 2)), g.pxr - 1, 3, pal.panel, 0.85, .over);
            }
            put(s, col, row, hud.level_name, ink.lerp(ink_dim, 0.25), true);
        }

        if (g.hud_scale > 0) {
            const sc = g.hud_scale;
            // score
            const sx = g.x(fi(m));
            const sw = font.drawText(s, sx, g.hud_top, sc, score_txt, ink, .{ .bold = true, .shadow = pal.night, .glow = 0.12, .glow_color = ink });
            // ×N pill
            const pill_row: i32 = @intFromFloat(@floor((g.hud_top + font.height(sc) * 0.5) / g.pxr));
            const pc: i32 = @as(i32, @intFromFloat(@ceil((sx + sw) / g.pxc))) + 2;
            const mn: i32 = lay.legendCols(mult_txt);
            if (pc + mn < clock_c0 - 1) {
                canvas.roundRect(s, g.x(fi(pc) - 0.8), g.y(fi(pill_row)) + 0.5, g.x(fi(mn) + 1.6), g.pxr - 1, 3, pal.panel, 0.92, .over);
                put(s, pc, pill_row, mult_txt, if (st.mult > 1) pal.coral else ink_dim, true);
            }
            // combo label
            put(s, m, g.label_row, "combo", ink_dim, false);
            put(s, m + 6, g.label_row, combo_n, ink, true);

            // rate (right)
            const rw = font.measure(rate_txt, sc, .{ .bold = true });
            const rx = g.x(fi(right_col)) - rw;
            _ = font.drawText(s, rx, g.hud_top, sc, rate_txt, pal.amber, .{ .bold = true, .shadow = pal.night, .glow = 0.25, .glow_color = pal.amber });
            const ln: i32 = lay.legendCols(rate_label);
            put(s, right_col - ln, g.label_row, rate_label, ink_dim, false);
            // pace badge left of the rate number, else left of the label
            const bn: i32 = lay.legendCols(badge);
            var bcol: i32 = @as(i32, @intFromFloat(@floor(rx / g.pxc))) - 2 - bn;
            var brow = pill_row;
            if (bcol < clock_c1 + 2) {
                bcol = right_col - ln - 3 - bn;
                brow = g.label_row;
            }
            if (bcol > clock_c1 + 1 or brow == g.label_row and bcol > center + @divFloor(lay.legendCols(hud.level_name), 2) + 2) {
                drawBadge(s, g, bcol, brow, badge);
            }
            const kn: i32 = lay.legendCols(kpm_small);
            const label_l = center + @divFloor(lay.legendCols(hud.level_name), 2) + 2;
            if (kn > 0 and brow != g.label_row and right_col - ln - 1 - kn > label_l) put(s, right_col - ln - 1 - kn, g.label_row, kpm_small, ink_faint.lerp(ink_dim, 0.5), false);
        } else {
            // text-layer HUD (half-block)
            put(s, m, 0, score_txt, ink, true);
            const pc = m + @as(i32, @intCast(score_txt.len)) + 1;
            const mn: i32 = lay.legendCols(mult_txt);
            if (pc + mn < clock_c0 - 1) putBg(s, pc, 0, mult_txt, if (st.mult > 1) pal.coral else ink_dim, pal.panel, true);
            put(s, m, 1, "combo", ink_dim, false);
            put(s, m + 6, 1, combo_n, ink, true);

            const rn: i32 = @intCast(rate_txt.len);
            put(s, right_col - rn, 0, rate_txt, pal.amber, true);
            const ln: i32 = lay.legendCols(rate_label);
            put(s, right_col - ln, 1, rate_label, ink_dim, false);
            const kn: i32 = lay.legendCols(kpm_small);
            if (kn > 0 and right_col - ln - 1 - kn > center + @divFloor(lay.legendCols(hud.level_name), 2) + 2) put(s, right_col - ln - 1 - kn, 1, kpm_small, ink_faint.lerp(ink_dim, 0.5), false);
            const bn: i32 = lay.legendCols(badge);
            const bcol = right_col - rn - 2 - bn;
            if (bcol > clock_c1 + 1) drawBadge(s, g, bcol, 0, badge);
        }
    }

    /// Flip clock centered at the top. Returns its width in cells.
    fn drawClock(self: *Scene, s: *Surface, g: *const Geo, minutes: u16) i32 {
        const hh = (minutes / 60) % 24;
        const mm = minutes % 60;
        const digits = [4]u8{ @intCast('0' + hh / 10), @intCast('0' + hh % 10), @intCast('0' + mm / 10), @intCast('0' + mm % 10) };
        if (!self.clock_init) {
            self.clock = digits;
            self.clock_from = digits;
            self.clock_t0 = .{ -9, -9, -9, -9 };
            self.clock_init = true;
        }
        for (0..4) |i| {
            if (digits[i] != self.clock[i]) {
                self.clock_from[i] = self.clock[i];
                self.clock[i] = digits[i];
                self.clock_t0[i] = self.time;
            }
        }
        const flip_dur: f32 = 0.38;
        const center = g.w * 0.5;
        if (g.hud_scale > 0) {
            const fs = g.hud_scale;
            const th = @round(font.cap_h * fs / 0.66);
            const tw = @round(6 * fs / 0.62);
            const gap = @max(1, @round(fs));
            const colon = 3 * fs;
            const total = 4 * tw + 2 * gap + colon + 2 * gap;
            var x = @round(center - total * 0.5);
            const y = @max(1, g.hud_top - fs * 0.5);
            // dark bezel behind the tiles
            canvas.roundRect(s, x - gap * 2, y - gap, total + gap * 4, th + gap * 2.5, 4, Rgb.hex(0x07081a), 0.75, .over);
            for (0..4) |i| {
                const f = sat((self.time - self.clock_t0[i]) / flip_dur);
                font.drawFlipDigit(s, x, y, tw, th, self.clock_from[i], self.clock[i], f, .{});
                x += tw + gap;
                if (i == 1) {
                    const cx = x + colon * 0.5 - gap * 0.5 + gap;
                    const blink: f32 = if (@mod(self.time, 1.0) < 0.5) 1 else 0.45;
                    canvas.disc(s, cx, y + th * 0.33, fs * 0.9, pal.tile, blink, .over);
                    canvas.disc(s, cx, y + th * 0.67, fs * 0.9, pal.tile, blink, .over);
                    x += colon + gap;
                }
            }
            return @intFromFloat(@ceil((total + gap * 4) / g.pxc));
        }
        // text tiles: [ 1 ][ 7 ]:[ 2 ][ 0 ]
        const total: i32 = 4 * 3 + 2 + 3;
        var col = @divFloor(g.cols, 2) - @divFloor(total, 2);
        const tile = pal.tile;
        for (0..4) |i| {
            const f = sat((self.time - self.clock_t0[i]) / flip_dur);
            const ch: u8 = if (f < 0.5) self.clock_from[i] else self.clock[i];
            const flipping = f > 0 and f < 1;
            const bg = if (flipping) tile.scale(0.72 + 0.28 * @abs(f - 0.5) * 2) else tile;
            var buf = [3]u8{ ' ', ch, ' ' };
            putBg(s, col, 0, &buf, Rgb.hex(0x24212b), bg, true);
            col += 3;
            if (i == 0 or i == 2) col += 1;
            if (i == 1) {
                const blink = @mod(self.time, 1.0) < 0.5;
                put(s, col + 1, 0, ":", if (blink) pal.tile else ink_faint, true);
                col += 3;
            }
        }
        return total;
    }

    fn drawDeckHealth(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const hp = sat(arc.stats.health / 100);
        const full = g.w * 0.62;
        const len = full * hp;
        const cx = g.w * 0.5;
        const y = if (g.lo) g.deck_y + 2 else g.deck_y + g.pxr * 0.95;
        const th = if (g.lo) 1 else @max(2, @round(g.pxr * 0.28));
        var c = if (hp > 0.5) pal.amber.lerp(Rgb.hex(0x5fe0d8), (hp - 0.5) / 0.5) else pal.miss.lerp(pal.amber, hp / 0.5);
        if (hp < 0.25) c = c.scale(0.65 + 0.35 * (0.5 + 0.5 * @sin(self.time * 10)));
        if (self.red > 0.05) c = c.lerp(pal.miss, self.red * 0.6);
        canvas.fillRect(s, cx - full * 0.5, y, full, th, ink, 0.08, .over);
        if (len > 0.5) {
            if (!g.lo) canvas.roundRectGlow(s, cx - len * 0.5, y, len, th, th * 0.5, g.pxr * 0.7, c, 0.5, .add);
            canvas.roundRect(s, cx - len * 0.5, y, len, th, th * 0.5, c.lighten(0.15), 1, .over);
            if (!g.lo) canvas.fillRect(s, cx - len * 0.5 + 1, y, @max(len - 2, 0), 1, Rgb.white, 0.35, .over);
        }
    }

    /// Banner (level up), milestone callout and the deep-work phrase.
    fn drawLanes(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const hud = arc.hud;
        var lane = g.hud_rows;
        if (hud.phrase) |ph| {
            self.drawPhrase(s, g, &ph, lane);
            lane += if (ph.complete) 2 else 1;
        } else {
            self.phrase_done_t = null;
        }
        if (hud.banner.len > 0 and hud.banner_t < arcade_mod.BANNER_SECONDS) {
            const k = laneFade(hud.banner_t);
            drawPill(s, g, @divFloor(g.cols, 2), lane, hud.banner, ink.lerp(pal.panel, 1 - k), pal.panel, 0.9 * k, ink);
            lane += 2;
        }
        if (hud.callout.len > 0 and hud.callout_t < arcade_mod.BANNER_SECONDS) {
            const k = laneFade(hud.callout_t);
            const n: i32 = lay.legendCols(hud.callout);
            const col = @divFloor(g.cols, 2) - @divFloor(n, 2);
            if (!g.lo) canvas.roundRectGlow(s, g.x(fi(col - 2)), g.y(fi(lane)), g.x(fi(n + 4)), g.pxr, 4, g.pxr * 1.2, pal.amber, 0.22 * k, .add);
            drawPill(s, g, @divFloor(g.cols, 2), lane, hud.callout, pal.amber.lerp(pal.panel, 1 - k), pal.panel, 0.9 * k, pal.amber);
        }
    }

    fn drawPhrase(self: *Scene, s: *Surface, g: *const Geo, ph: *const model.Phrase, row: i32) void {
        if (ph.complete) {
            if (self.phrase_done_t == null or !std.mem.eql(u8, self.phrase_text, ph.text)) self.phrase_done_t = self.time;
        } else self.phrase_done_t = null;
        self.phrase_text = ph.text;

        const text = ph.text;
        const avail: usize = @intCast(@max(g.cols - 4, 8));
        const n = text.len;
        var start: usize = 0;
        var end: usize = n;
        if (n > avail) {
            const ws: usize = ph.word_start;
            start = if (ws > avail / 3) ws - avail / 3 else 0;
            if (start + avail > n) start = n - avail;
            end = start + avail;
        }
        const shown: i32 = @intCast(end - start);
        const col0 = @divFloor(g.cols - shown, 2);
        // scrim
        canvas.roundRect(s, g.x(fi(col0 - 2)), g.y(fi(row)), g.x(fi(shown + 4)), g.pxr, if (g.lo) @as(f32, 0.5) else 4, pal.night, 0.78, .over);
        var word: usize = 0;
        var in_word = false;
        for (text, 0..) |ch, i| {
            if (ch == ' ') {
                if (in_word) word += 1;
                in_word = false;
            } else in_word = true;
            if (i < start or i >= end) continue;
            if (ch == ' ') continue;
            const col = col0 + @as(i32, @intCast(i - start));
            const done = ph.complete or word < ph.word_index;
            const active = !ph.complete and word == ph.word_index;
            const missed = ph.isMissed(word);
            var fg: Rgb = ink_faint;
            if (done and missed) {
                fg = pal.coral.scale(0.8);
                canvas.fillRect(s, g.x(fi(col)), g.y(fi(row) + 0.5) - 0.5, g.pxc, if (g.lo) 1 else @max(1, g.pxr * 0.12), pal.coral, 0.9, .over);
            } else if (done) {
                fg = ink;
            } else if (active) {
                fg = if (i < ph.done_upto) pal.teal else ink;
                const uy = if (g.lo) g.y(fi(row + 1)) else g.y(fi(row + 1)) - @max(1, g.pxr * 0.15);
                canvas.fillRect(s, g.x(fi(col)), uy, g.pxc, if (g.lo) 1 else @max(1, g.pxr * 0.15), pal.coral, 1, .over);
            }
            var cb: [1]u8 = .{ch};
            put(s, col, row, &cb, fg, active);
        }
        if (start > 0) put(s, col0 - 1, row, "…", ink_faint, false);
        if (end < n) put(s, col0 + shown, row, "…", ink_faint, false);
        if (self.phrase_done_t) |t0| {
            if (ph.attribution.len > 0) {
                const k = sat((self.time - t0) / 0.8);
                var ab: [96]u8 = undefined;
                const at = std.mem.print(&ab, "— {s}", .{ph.attribution}) catch ph.attribution;
                const an: i32 = lay.legendCols(at);
                put(s, @divFloor(g.cols - an, 2), row + 1, at, pal.night.lerp(pal.amber, k * 0.9), false);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Title

    fn drawTitle(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const t = self.time;
        const cols = g.cols;
        const cc = @divFloor(cols, 2);
        const logo = "snipetype";
        // Rows: [top, hint_row) hold the logo block and the menu body.
        const top: i32 = 1;
        const hint_row = g.deck_row - 1;
        const avail: i32 = hint_row - 1 - top;

        // menu body variants (rows), roomiest first
        const Body = struct { rows: i32, game_blurb: bool, gap: i32 };
        const bodies = [_]Body{
            .{ .rows = 10, .game_blurb = true, .gap = 1 },
            .{ .rows = 7, .game_blurb = false, .gap = 1 },
            .{ .rows = 5, .game_blurb = false, .gap = 0 },
        };
        // logo: biggest pixel scale whose block fits with the roomiest body
        const text_logo_w = font.measure(logo, 1, .{ .bold = true }) > g.w * 0.92;
        var L: f32 = 0;
        var body = bodies[bodies.len - 1];
        var logo_rows: i32 = 2; // text logo + text ARCADE
        if (!text_logo_w) {
            outer: for (bodies) |bo| {
                var l: f32 = 12;
                while (l >= 1) : (l -= 1) {
                    if (font.measure(logo, l, .{ .bold = true }) > g.w * 0.62) continue;
                    if (font.height(l) > g.h * 0.15) continue;
                    const lr = titleLogoRows(g, l);
                    if (lr + bo.rows + 1 <= avail) {
                        L = l;
                        body = bo;
                        logo_rows = lr;
                        break :outer;
                    }
                }
            }
        }
        if (L == 0) {
            for (bodies) |bo| {
                body = bo;
                if (logo_rows + 1 + bo.rows <= avail) break;
            }
        }
        const block = logo_rows + 1 + body.rows;
        const r0: i32 = top + @max(@divFloor(avail - block, 2), 0);

        // panel behind the title block
        {
            const logo_w = if (L > 0) font.measure(logo, L, .{ .bold = true }) else g.x(17);
            const pw: i32 = @min(cols - 2, @max(@as(i32, @intFromFloat(@ceil(logo_w / g.pxc))) + 10, 52));
            const pc0 = cc - @divFloor(pw, 2);
            const pr0 = @max(r0 - 1, 0);
            const pr1 = @min(r0 + block + 1, hint_row);
            const rad: f32 = if (g.lo) 1 else 8;
            const py = g.y(fi(pr0)) + (if (g.lo) @as(f32, 0) else g.pxr * 0.5);
            const ph = g.y(fi(pr1 - pr0)) - (if (g.lo) @as(f32, 0) else g.pxr * 0.5);
            canvas.roundRectGlow(s, g.x(fi(pc0)), py, g.x(fi(pw)), ph, rad, g.pxr * 2, pal.night, 0.6, .over);
            canvas.roundRect(s, g.x(fi(pc0)), py, g.x(fi(pw)), ph, rad, pal.night, 0.74, .over);
            clearTextRect(s, pc0, pr0, pc0 + pw, pr1);
        }

        // "snipetype" + "ARCADE"
        var row = r0;
        if (L > 0) {
            const logo_y = g.y(fi(row)) + g.pxr * 0.4;
            const logo_w = font.measure(logo, L, .{ .bold = true });
            var x = g.w * 0.5 - logo_w * 0.5;
            for (logo, 0..) |ch, i| {
                const led = color.ledCycle(t, fi(i) * 0.06);
                var b = [1]u8{ch};
                const adv = font.drawText(s, x, logo_y, L, &b, pal.cream, .{
                    .bold = true,
                    .gradient = pal.cream.lerp(led, 0.75),
                    .glow = 0.55,
                    .glow_color = led,
                    .glow_radius = 2.2,
                    .shadow = Rgb.hex(0x05060f),
                    .shadow_dx = 0.6,
                    .shadow_dy = 0.6,
                });
                x += adv + L;
            }
            row += logo_rows - titleArcadeRows(g, L);
        } else {
            var col = cc - 8;
            canvas.glowEllipse(s, g.w * 0.5, g.y(fi(row) + 0.5), g.x(11), g.pxr * 1.5, color.ledCycle(t, 0.1), 0.35, .add);
            for (logo, 0..) |ch, i| {
                var b = [1]u8{ch};
                put(s, col, row, &b, pal.cream.lerp(color.ledCycle(t, fi(i) * 0.06).lighten(0.3), 0.5), true);
                col += 2;
            }
            row += 1;
        }
        {
            const word = "ARCADE";
            if (g.lo or L == 0) {
                const n: i32 = word.len * 2 - 1;
                var col = cc - @divFloor(n, 2);
                for (word, 0..) |ch, i| {
                    var b = [1]u8{ch};
                    put(s, col, row, &b, color.ledCycle(t, 0.3 + fi(i) * 0.08).lighten(0.25), true);
                    col += 2;
                }
            } else {
                const A = titleArcadeScale(L);
                const o: font.TextOpts = .{ .bold = true, .spacing = 3, .glow = 0.6, .glow_radius = 2 };
                const aw = font.measure(word, A, o);
                var x = g.w * 0.5 - aw * 0.5;
                const y = g.y(fi(row)) + g.pxr * 0.15;
                for (word, 0..) |ch, i| {
                    const led = color.ledCycle(t, 0.3 + fi(i) * 0.08).lighten(0.2);
                    var b = [1]u8{ch};
                    var oo = o;
                    oo.glow_color = led;
                    x += font.drawText(s, x, y, A, &b, led, oo) + 3 * A;
                }
            }
        }
        row = r0 + logo_rows + 1;

        // game picker
        const game = arc.selectedGame();
        {
            const labels = [_][]const u8{ model.Game.words.label(), model.Game.keys.label() };
            const span = drawPicker(s, g, cc, row, &labels, @backingInt(game), pal.teal, t);
            put(s, span[1] + 3, row, "tab", ink_faint, false);
        }
        row += 1;
        if (body.game_blurb) {
            putCenter(s, cc, row, gameBlurb(game), ink_faint.lerp(ink_dim, 0.6), false);
            row += 1;
        }
        row += body.gap;
        // pace picker
        {
            const paces = [_]model.Pace{ .junior, .senior, .staff, .tenx };
            var labels: [paces.len][]const u8 = undefined;
            for (paces, 0..) |p, i| labels[i] = p.label();
            const sel = arc.selectedPace();
            const span = drawPicker(s, g, cc, row, &labels, @backingInt(sel), pal.coral, t);
            put(s, span[0] - 3, row, "←", ink_dim, false);
            put(s, span[1] + 2, row, "→", ink_dim, false);
        }
        row += 1;
        putCenter(s, cc, row, paceBlurb(arc.selectedPace()), ink_faint.lerp(ink_dim, 0.6), false);
        row += 1 + body.gap;
        {
            var b: [48]u8 = undefined;
            const sp = std.mem.print(&b, "speed ×{d}", .{arc.selectedSpeed()}) catch "";
            const n: i32 = lay.legendCols(sp);
            const col = cc - @divFloor(n + 4, 2);
            put(s, col, row, "speed", ink_dim, false);
            put(s, col + 6, row, sp[6..], pal.amber, true);
            put(s, col + n + 2, row, "↑↓", ink_faint, false);
        }
        row += 1 + body.gap;
        if (row < hint_row) {
            const k = 0.55 + 0.45 * (0.5 + 0.5 * @sin(t * 3.2));
            putCenter(s, cc, row, "press enter to clock in", pal.night.lerp(pal.amber, k), true);
        }
        // key hints just above the deck
        const hint = if (cols >= 84)
            "tab game · ←/→ pace · ↑/↓ speed · enter clock in · esc pause"
        else if (cols >= 44)
            "tab game · ←→ pace · ↑↓ speed · enter"
        else
            "tab · ←→ · ↑↓ · enter";
        clearTextRect(s, 0, hint_row, cols, hint_row + 1);
        putCenter(s, cc, hint_row, hint, ink_faint.lerp(ink_dim, 0.4), false);
    }

    // -----------------------------------------------------------------------
    // Pause

    fn drawPaused(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        _ = self;
        // dim + desaturate everything
        for (s.pixels) |*p| {
            const l = (@as(u32, p.r) * 54 + @as(u32, p.g) * 183 + @as(u32, p.b) * 19) >> 8;
            p.r = @intCast(((@as(u32, p.r) + l) * 45 >> 8) + 4);
            p.g = @intCast(((@as(u32, p.g) + l) * 45 >> 8) + 4);
            p.b = @intCast(((@as(u32, p.b) + l) * 52 >> 8) + 10);
        }
        for (s.text) |*c| {
            if (c.cp != 0) c.fg = c.fg.mix(Color.rgb(20, 20, 40), 0.6);
        }
        const cc = @divFloor(g.cols, 2);
        const mid = @divFloor(g.rows, 2) - 1;
        if (!g.lo) {
            const sc = @max(1, @round(g.h * 0.09 / font.cap_h));
            // descenders (the p) end just above the info row
            const y = g.y(fi(mid + 1)) - (font.cap_h + 2) * sc - 1;
            clearTextRect(s, 0, @as(i32, @intFromFloat(@floor(y / g.pxr))), g.cols, mid + 1);
            _ = font.drawTextCentered(s, g.w * 0.5, y, sc, "paused", pal.cream, .{ .bold = true, .glow = 0.4, .glow_color = pal.teal, .shadow = pal.night });
        } else {
            clearTextRect(s, 0, mid - 1, g.cols, mid + 4);
            putCenter(s, cc, mid - 1, "P A U S E D", pal.cream, true);
        }
        var b: [64]u8 = undefined;
        const hh = (arc.hud.clock_minutes / 60) % 24;
        const mm = arc.hud.clock_minutes % 60;
        const info = std.mem.print(&b, "{d:0>2}:{d:0>2} · {s}", .{ hh, mm, arc.hud.level_name }) catch "";
        clearTextRect(s, 0, mid + 1, g.cols, mid + 4);
        putCenter(s, cc, mid + 1, info, ink_dim, false);
        putCenter(s, cc, mid + 3, "esc resume · q quit to title", pal.amber, false);
    }

    // -----------------------------------------------------------------------
    // Results

    fn drawResults(self: *Scene, s: *Surface, g: *const Geo, arc: *const Arcade) void {
        const t = self.time - self.phase_t0;
        const appear = smoothstep(0, 0.45, t);
        const st = arc.stats;
        const cols = g.cols;
        const cc = @divFloor(cols, 2);
        const compact = g.rows < 28;
        const big = !g.lo;

        // rows under the big score: cap height + descender (thousands comma)
        const score_rows: i32 = if (big) @intFromFloat(@ceil((g.pxr * 0.2 + (font.cap_h + 2) * @max(1, @round(g.h * 0.075 / font.cap_h)) + 1) / g.pxr)) else 1;
        const lines: i32 = 1 + 1 + score_rows + 1 + 2 + 1 + 3 + 1 + 1 + 1 + 1 + @as(i32, if (compact) 0 else 4);
        const card_h: i32 = @min(lines + 2, g.rows - 2);
        const card_w: i32 = @min(cols - 4, 60);
        const c0 = cc - @divFloor(card_w, 2);
        const r0: i32 = @max(@divFloor(g.rows - card_h, 2) - 1, 1);
        const slide = (1 - appear) * g.pxr * 2;

        // dim the scene, then the card
        canvas.fillRect(s, 0, 0, g.w, g.h, pal.night, 0.45 * appear, .over);
        clearTextRect(s, 0, 0, cols, g.rows);
        const cx0 = g.x(fi(c0));
        const cy0 = g.y(fi(r0)) + slide;
        const cw = g.x(fi(card_w));
        const ch = g.y(fi(card_h));
        if (!g.lo) canvas.roundRectGlow(s, cx0, cy0, cw, ch, 10, g.pxr * 2, color.ledCycle(self.time, 0), 0.18 * appear, .add);
        canvas.roundRect(s, cx0, cy0, cw, ch, if (g.lo) @as(f32, 1) else 10, pal.panel, 0.94 * appear, .over);
        if (!g.lo) canvas.roundRectOutline(s, cx0, cy0, cw, ch, 10, 1, ink, 0.1 * appear, .over);
        if (appear < 0.6) return;

        var row: i32 = r0 + 1;
        var b1: [64]u8 = undefined;
        const hh = (arc.hud.clock_minutes / 60) % 24;
        const mm = arc.hud.clock_minutes % 60;
        const head = std.mem.print(&b1, "SHIFT OVER AT {d:0>2}:{d:0>2}", .{ hh, mm }) catch "";
        putCenter(s, cc, row, head, pal.amber, true);
        row += if (compact) 1 else 2;

        var nb: [40]u8 = undefined;
        const score_txt = fmtThousands(&nb, st.score);
        if (big) {
            const sc = @max(1, @round(g.h * 0.075 / font.cap_h));
            // count up over the first second
            const k = sat((t - 0.3) / 0.9);
            var cb: [40]u8 = undefined;
            const shown = fmtThousands(&cb, @intFromFloat(@round(fi(st.score) * (1 - (1 - k) * (1 - k)))));
            _ = font.drawTextCentered(s, g.w * 0.5, g.y(fi(row)) + g.pxr * 0.2, sc, if (k >= 1) score_txt else shown, pal.cream, .{ .bold = true, .glow = 0.35, .glow_color = pal.coral, .shadow = pal.night });
            row += score_rows;
        } else {
            putCenter(s, cc, row, score_txt, pal.cream, true);
            row += 1;
        }
        putCenter(s, cc, row, "points", ink_dim, false);
        row += if (compact) 1 else 2;

        // stats
        {
            const words = arc.selectedGame() == .words;
            const sep = if (cols >= 70) "  ·  " else " · ";
            const r = struct {
                fn r(v: f32) u32 {
                    return @intFromFloat(@round(@max(v, 0)));
                }
            }.r;
            var b: [112]u8 = undefined;
            const acc: u32 = @intFromFloat(@round(st.accuracy() * 100));
            const l1 = if (words)
                std.mem.print(&b, "peak {d} wpm{s}best combo {d}{s}accuracy {d}%", .{ r(st.peak_wpm), sep, st.best_combo, sep, acc }) catch ""
            else
                std.mem.print(&b, "best combo {d}{s}peak {d} kpm{s}accuracy {d}%", .{ st.best_combo, sep, r(st.peak_kpm), sep, acc }) catch "";
            putCenter(s, cc, row, l1, ink, false);
            row += 1;
            var b2: [112]u8 = undefined;
            var kb: [40]u8 = undefined;
            const ks = fmtThousands(&kb, st.keystrokes);
            const l2 = if (words)
                std.mem.print(&b2, "keystrokes {s}{s}avg {d} kpm{s}peak {d} kpm", .{ ks, sep, r(arc.avgKpm()), sep, r(st.peak_kpm) }) catch ""
            else if (st.peak_wpm > 0)
                std.mem.print(&b2, "keystrokes {s}{s}avg {d} kpm{s}peak {d} wpm", .{ ks, sep, r(arc.avgKpm()), sep, r(st.peak_wpm) }) catch ""
            else
                std.mem.print(&b2, "keystrokes {s}{s}avg {d} kpm", .{ ks, sep, r(arc.avgKpm()) }) catch "";
            putCenter(s, cc, row, l2, ink_dim, false);
            row += if (compact) 2 else 3;
        }

        // rank keycap
        const rank = arc.rank();
        {
            const n: i32 = lay.legendCols(rank.name);
            const kw: i32 = @max(n + 8, 18);
            const k0 = cc - @divFloor(kw, 2);
            const rh = 3 * g.pxr - (if (g.lo) 0 else @max(1, g.pxr * 0.15));
            const lift = if (g.lo) 0 else faceCenter(rh) - g.pxr * 1.5;
            const ky = g.y(fi(row)) - lift;
            const hue_c = color.accent(rank.hue);
            const pulse = 0.6 + 0.25 * @sin(self.time * 2.5);
            const top = color.hsl(rank.hue, 0.55, 0.8);
            const side = color.hsl(rank.hue, 0.45, 0.52);
            const pop = 1 - smoothstep(0.6, 1.1, t);
            canvas.keycap(s, g.x(fi(k0)), ky - pop * g.pxr, g.x(fi(kw)), rh, top, side, .{ .glow = hue_c, .glow_amount = pulse, .radius = 0.25 });
            put(s, cc - @divFloor(n, 2), row + 1, rank.name, Rgb.hex(0x1a1420), true);
            row += 3;
        }
        putCenter(s, cc, row, rank.blurb, ink.lerp(ink_dim, 0.3), false);
        row += if (compact) 1 else 2;
        putCenter(s, cc, row, arc.heardLine(), pal.teal, false);
        row += if (compact) 1 else 2;
        const ready = arc.results_ticks >= arcade_mod.RESULTS_LOCK_TICKS;
        if (row < r0 + card_h) putCenter(s, cc, row, "enter again · esc title", if (ready) pal.amber else ink_faint, ready);
    }
};

// ---------------------------------------------------------------------------
// Backdrop painting (cached)
// ---------------------------------------------------------------------------

fn paintSky(s: *Surface, g: *const Geo) void {
    const stops = [_]canvas.Stop{
        .{ .at = 0, .c = Rgb.hex(0x08091c) },
        .{ .at = 0.35, .c = pal.night },
        .{ .at = 0.6, .c = Rgb.hex(0x14123a) },
        .{ .at = 0.78, .c = Rgb.hex(0x1a1040) },
        .{ .at = 1, .c = Rgb.hex(0x06061a) },
    };
    canvas.backgroundV(s, &stops);
    // warm city glow (left) and cool glow (right)
    canvas.glowEllipse(s, g.w * 0.08, g.h * 0.3, g.w * 0.35, g.h * 0.35, Rgb.hex(0xff7a3c), 0.10, .add);
    canvas.glowEllipse(s, g.w * 0.92, g.h * 0.22, g.w * 0.3, g.h * 0.3, Rgb.hex(0x2e6bff), 0.09, .add);
    canvas.glowEllipse(s, g.w * 0.55, g.kb_top, g.w * 0.6, g.h * 0.18, Rgb.hex(0x9442ff), 0.07, .add);
    // bokeh
    if (!g.lo) {
        var r = fx.rng.Rng.init(0xB0CE);
        for (0..14) |_| {
            const bx = r.float() * g.w;
            const by = g.h * (0.12 + r.float() * 0.4);
            const rad = g.w * (0.012 + r.float() * 0.03);
            const c = color.ledAt(r.float());
            canvas.disc(s, bx, by, rad, c, 0.035 + 0.04 * r.float(), .add);
            canvas.glow(s, bx, by, rad * 1.6, c, 0.03, .add);
        }
        // faint perspective grid in the sky
        const grid_y1 = g.kb_top - g.pxr;
        const step = g.w / 24;
        var gx: f32 = 0;
        while (gx < g.w) : (gx += step) canvas.fillRect(s, gx, g.y(fi(g.hud_rows)), 1, grid_y1 - g.y(fi(g.hud_rows)), Rgb.hex(0x6a6cff), 0.035, .add);
        var gy = grid_y1;
        var k: f32 = 1;
        while (gy > g.y(fi(g.hud_rows))) : (k *= 1.25) {
            canvas.fillRect(s, 0, gy, g.w, 1, Rgb.hex(0x6a6cff), 0.04, .add);
            gy -= step * 0.45 * k;
        }
    } else {
        var r = fx.rng.Rng.init(0xB0CE);
        for (0..8) |_| {
            const bx = r.float() * g.w;
            const by = g.h * (0.15 + r.float() * 0.35);
            canvas.glow(s, bx, by, g.w * 0.04, color.ledAt(r.float()), 0.08, .add);
        }
    }
}

fn layoutKeyboard(bd: *Backdrop, g: *const Geo) void {
    bd.n = 0;
    const kb_top = g.kb_top;
    const kb_bot = g.deck_y - (if (g.lo) 1 else g.pxr * 0.5);
    const total = kb_bot - kb_top;
    if (total < 3) return;
    // perspective: rows get taller and wider toward the viewer
    const grow: f32 = if (g.lo) 0.14 else 0.22;
    const nrows = kb_main.len;
    var weights: [nrows]f32 = undefined;
    var wsum: f32 = 0;
    for (0..nrows) |i| {
        weights[i] = kb_row_weight[i] * (1 + grow * fi(i));
        wsum += weights[i];
    }
    var y = kb_top;
    // the main block fills the width; the bottom rows run off both edges
    const base = if (g.lo) g.w / KB_UNITS else g.w / (KB_UNITS - 2.5);
    bd.unit = base;
    for (0..nrows) |ri| {
        const rh = total * weights[ri] / wsum;
        const t = (fi(ri) + 0.5) / fi(nrows);
        const unit = base * (if (g.lo) 0.96 + 0.14 * t else 0.9 + 0.32 * t);
        const gap_x = if (g.lo) 1 else @max(1, unit * 0.1);
        const gap_y = if (g.lo) 1 else @max(1, rh * 0.12);
        const rows = [2][]const KbDef{ kb_main[ri], kb_nav[ri] };
        for (rows) |row| {
            for (row) |k| {
                if (bd.n >= MAX_KB_KEYS) break;
                const x0 = g.w * 0.5 + (k.at - KB_UNITS * 0.5) * unit;
                var kx = x0 + gap_x * 0.5;
                var kw = k.w * unit - gap_x;
                var ky = y + gap_y * 0.5;
                var kh = rh - gap_y;
                if (g.lo) {
                    kx = @round(kx);
                    kw = @max(@round(x0 + k.w * unit) - kx - 1, 1);
                    ky = @round(y);
                    kh = @max(@round(y + rh) - ky - 1, 1);
                }
                bd.keys[bd.n] = .{ .code = k.code, .x = kx, .y = ky, .w = kw, .h = kh, .u = std.math.clamp((kx + kw * 0.5) / g.w, 0, 1), .legend = k.legend };
                bd.n += 1;
            }
        }
        y += rh;
    }
}

fn paintKeyboard(s: *Surface, bd: *const Backdrop, g: *const Geo) void {
    if (bd.n == 0) return;
    // slab: fades in from the sky so the keyboard sits in the dark
    const slab_y = g.kb_top - (if (g.lo) 1 else g.pxr * 0.8);
    if (g.lo) {
        canvas.gradientV(s, -2, slab_y, g.w + 4, g.deck_y - slab_y, Rgb.hex(0x0b0c20), Rgb.hex(0x06061a), 0.95, .over);
    } else {
        // soft top edge: the slab fades in over ~1.5 rows
        const fade = g.pxr * 1.5;
        const strips: usize = 8;
        for (0..strips) |i| {
            const k = (fi(i) + 0.5) / fi(strips);
            canvas.fillRect(s, -2, slab_y - fade + fade * fi(i) / fi(strips), g.w + 4, fade / fi(strips), Rgb.hex(0x0a0b1e), 0.96 * k * k, .over);
        }
        canvas.gradientV(s, -2, slab_y, g.w + 4, g.deck_y - slab_y, Rgb.hex(0x0a0b1e), Rgb.hex(0x050514), 0.96, .over);
    }
    for (bd.keys[0..bd.n]) |k| {
        if (g.lo) {
            canvas.fillRect(s, k.x, k.y, k.w, k.h, Rgb.hex(0x111226), 1, .over);
            if (k.h >= 2) canvas.fillRect(s, k.x, k.y + k.h - 1, k.w, 1, Rgb.hex(0x0a0b1a), 1, .over);
        } else {
            const r = @min(k.w, k.h) * 0.2;
            canvas.roundRectV(s, k.x, k.y, k.w, k.h, r, Rgb.hex(0x15172b), Rgb.hex(0x08091a), 1, .over);
            const inset = @max(1, k.w * 0.08);
            canvas.roundRectV(s, k.x + inset, k.y + 0.5, k.w - 2 * inset, k.h * 0.72, r * 0.8, Rgb.hex(0x1b1d36), Rgb.hex(0x111225), 1, .over);
        }
    }
    if (!g.lo) {
        // atmospheric depth: the far rows sink into the night
        const fog_h = (g.deck_y - slab_y) * 0.35;
        canvas.gradientV(s, -2, slab_y, g.w + 4, fog_h, Rgb.hex(0x202048), Rgb.white, 0.45, .multiply);
    }
}

fn paintMask(s: *Surface, bd: *const Backdrop, g: *const Geo) void {
    const oy = fi(bd.kb_y0);
    const white = Rgb.white;
    for (bd.keys[0..bd.n]) |k| {
        const y = k.y - oy;
        if (g.lo) {
            canvas.fillRect(s, k.x - 1, y - 1, k.w + 2, k.h + 2, white, 0.11, .add);
            canvas.fillRect(s, k.x, y + k.h, k.w, 1, white, 0.09, .add);
        } else {
            // underglow leaking around each key
            canvas.roundRectGlow(s, k.x, y, k.w, k.h, @min(k.w, k.h) * 0.2, @max(1.5, k.h * 0.35), white, 0.6, .add);
        }
    }
    for (bd.keys[0..bd.n]) |k| {
        const y = k.y - oy;
        // key bodies block most of the light; the top face catches a little
        canvas.fillRect(s, k.x, y, k.w, k.h, Rgb.init(0.08, 0.08, 0.08), 1, .over);
        if (!g.lo) canvas.fillRect(s, k.x + 1, y + k.h - 1.2, k.w - 2, 1.2, white, 0.3, .add);
        // legends glow through the caps
        const fh = k.h * 0.72;
        const cx = k.x + k.w * 0.5;
        if (g.lo) {
            if (k.legend.len > 0 or k.w > 2) canvas.fillRect(s, @floor(cx), y, 1, 1, white, 0.45, .over);
        } else if (k.legend.len > 0 and fh >= 9) {
            const sc = @max(1, @floor(fh * 0.5 / font.cap_h));
            _ = font.drawText(s, k.x + k.w * 0.2, y + fh * 0.18, sc, k.legend, white, .{});
        } else {
            const ds = @max(1.5, fh * 0.14);
            canvas.roundRect(s, k.x + k.w * 0.2, y + fh * 0.25, ds, ds, ds * 0.5, white, 0.8, .over);
        }
    }
}

/// Separable box blur of rows [y0, y1) of a w-wide pixel buffer (radius r,
/// clamped edges). Build-time only (cached backdrop / LED mask).
fn boxBlur(buf: []Px, w: usize, y0: usize, y1: usize, r: usize, tmp: []Px) void {
    if (w == 0 or y1 <= y0 or r == 0) return;
    const div: u32 = @intCast(2 * r + 1);
    // horizontal
    for (y0..y1) |yy| {
        const row = buf[yy * w ..][0..w];
        @memcpy(tmp[0..w], row);
        for (0..w) |xx| {
            var sr: u32 = 0;
            var sg: u32 = 0;
            var sb: u32 = 0;
            var k: usize = 0;
            while (k < 2 * r + 1) : (k += 1) {
                const xi = std.math.clamp(@as(i64, @intCast(xx + k)) - @as(i64, @intCast(r)), 0, @as(i64, @intCast(w - 1)));
                const p = tmp[@intCast(xi)];
                sr += p.r;
                sg += p.g;
                sb += p.b;
            }
            row[xx] = .{ .r = @intCast(sr / div), .g = @intCast(sg / div), .b = @intCast(sb / div), .a = 255 };
        }
    }
    // vertical
    const hh = y1 - y0;
    for (0..w) |xx| {
        for (0..hh) |i| tmp[i] = buf[(y0 + i) * w + xx];
        for (0..hh) |i| {
            var sr: u32 = 0;
            var sg: u32 = 0;
            var sb: u32 = 0;
            var k: usize = 0;
            while (k < 2 * r + 1) : (k += 1) {
                const yi = std.math.clamp(@as(i64, @intCast(i + k)) - @as(i64, @intCast(r)), 0, @as(i64, @intCast(hh - 1)));
                const p = tmp[@intCast(yi)];
                sr += p.r;
                sg += p.g;
                sb += p.b;
            }
            buf[(y0 + i) * w + xx] = .{ .r = @intCast(sr / div), .g = @intCast(sg / div), .b = @intCast(sb / div), .a = 255 };
        }
    }
}

fn fillIds(bd: *Backdrop) void {
    const w: usize = bd.w;
    for (0..bd.kb_h) |yy| {
        const py = fi(yy + bd.kb_y0) + 0.5;
        for (0..w) |xx| {
            const px = fi(xx) + 0.5;
            var best: usize = 0;
            var bd2: f32 = std.math.inf(f32);
            for (bd.keys[0..bd.n], 0..) |k, i| {
                const dx = @max(@max(k.x - px, px - (k.x + k.w)), 0);
                const dy = @max(@max(k.y - py, py - (k.y + k.h)), 0);
                const d = dx * dx + dy * dy * 1.5;
                if (d < bd2) {
                    bd2 = d;
                    best = i;
                    if (d == 0) break;
                }
            }
            bd.ids[yy * w + xx] = @intCast(best);
        }
    }
}

fn paintDeck(s: *Surface, g: *const Geo) void {
    canvas.gradientV(s, 0, g.deck_y, g.w, g.h - g.deck_y, Rgb.hex(0x1a1b36), Rgb.hex(0x05050f), 1, .over);
    if (!g.lo) canvas.fillRect(s, 0, g.deck_y + 2, g.w, 1, Rgb.hex(0x2a2c50), 0.6, .over);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn findCap(arc: *const Arcade, id: u32) ?*const Cap {
    for (arc.caps()) |*c| {
        if (c.id == id) return c;
    }
    return null;
}

/// Screen rect {x0, y0, x1, y1} a popup centered at (x, y) covers over its
/// life (it rises; the small line sits under the big one).
fn popupRect(g: *const Geo, x: f32, y: f32, tw: f32, bh: f32, sub: bool) [4]f32 {
    const pad = g.pxc;
    if (g.lo) return .{ x - tw * 0.5 - pad, y - g.pxr * 1.6, x + tw * 0.5 + pad, y + g.pxr * (if (sub) @as(f32, 2) else 1) };
    return .{ x - tw * 0.5 - pad, y - bh * 1.5, x + tw * 0.5 + pad, y + bh * (if (sub) @as(f32, 1.2) else 0.6) };
}

fn overlapArea(a: [4]f32, b: [4]f32) f32 {
    const w = @min(a[2], b[2]) - @max(a[0], b[0]);
    const h = @min(a[3], b[3]) - @max(a[1], b[1]);
    return if (w > 0 and h > 0) w * h else 0;
}

/// The word cap the player is typing: the one with progress, else the
/// lowest falling word. 0 = none.
fn activeWord(arc: *const Arcade) u32 {
    var id: u32 = 0;
    var best: f32 = -1;
    for (arc.caps()) |*c| {
        if (c.kind != .word or c.state != .falling) continue;
        const k = c.progress + (if (c.typed > 0) @as(f32, 10) + fi(c.typed) else 0);
        if (k > best) {
            best = k;
            id = c.id;
        }
    }
    return id;
}

const PlateSkin = struct { fill: Rgb, edge: Rgb };

fn plateSkin(r: model.Rarity) PlateSkin {
    return switch (r) {
        .common => .{ .fill = Rgb.hex(0x111230), .edge = ink },
        .rare => .{ .fill = Rgb.hex(0x0c1a46), .edge = Rgb.hex(0x4f8dff) },
        .epic => .{ .fill = Rgb.hex(0x1a0e42), .edge = Rgb.hex(0x9a6bff) },
        .legendary => .{ .fill = Rgb.hex(0x261a08), .edge = Rgb.hex(0xffd27a) },
    };
}

fn lookOf(c: *const Cap, b: ?lay.KeyBox) effects.CapLook {
    const role: model.CapRole = if (b) |k| k.role else if (c.len > 0) c.steps[0].role else .letter;
    const is_mod = if (b) |k| k.is_mod else false;
    return effects.lookFor(role, if (is_mod) .common else c.rarity);
}

fn isBold(b: lay.KeyBox) bool {
    return lay.legendCols(b.legend) == 1;
}

fn scale255(v: f32) u32 {
    return @intFromFloat(std.math.clamp(v, 0, 1.35) * 255);
}

fn laneFade(t: f32) f32 {
    return sat(t / 0.2) * (1 - smoothstep(arcade_mod.BANNER_SECONDS - 0.4, arcade_mod.BANNER_SECONDS, t));
}

fn gameBlurb(game: model.Game) []const u8 {
    return switch (game) {
        .words => "falling words, code and quotes · scored in wpm",
        .keys => "keys, vim motions and chords · scored in keys/min",
    };
}

/// Pixel-font scale of "ARCADE" under a logo of scale L.
fn titleArcadeScale(L: f32) f32 {
    return @max(1, @round(L * 0.45));
}

fn titleArcadeRows(g: *const Geo, L: f32) i32 {
    if (g.lo) return 1;
    return @intFromFloat(@ceil((font.height(titleArcadeScale(L)) + g.pxr * 0.3) / g.pxr));
}

/// Rows of the pixel logo block (logo, its glow, "ARCADE").
fn titleLogoRows(g: *const Geo, L: f32) i32 {
    const logo: i32 = @intFromFloat(@ceil((g.pxr * 0.4 + font.height(L) + L * 3) / g.pxr));
    return logo + titleArcadeRows(g, L);
}

/// A row of options centered on `center`, the selected one on a pill.
/// Returns the first column and the column just past the last option.
fn drawPicker(s: *Surface, g: *const Geo, center: i32, row: i32, labels: []const []const u8, sel: usize, pill: Rgb, t: f32) [2]i32 {
    var total: i32 = 0;
    for (labels) |l| total += lay.legendCols(l) + 4;
    total -= 4;
    const start = center - @divFloor(total, 2);
    var col = start;
    for (labels, 0..) |l, i| {
        const n: i32 = lay.legendCols(l);
        if (i == sel) {
            const k = 0.85 + 0.15 * @sin(t * 4);
            canvas.roundRect(s, g.x(fi(col - 1)), g.y(fi(row)) + (if (g.lo) @as(f32, 0) else 0.5), g.x(fi(n + 2)), g.pxr - (if (g.lo) @as(f32, 0) else 1), if (g.lo) @as(f32, 0.4) else 3, pill.scale(k), 1, .over);
            if (!g.lo) canvas.roundRectGlow(s, g.x(fi(col - 1)), g.y(fi(row)), g.x(fi(n + 2)), g.pxr, 3, g.pxr, pill, 0.35, .add);
            put(s, col, row, l, badge_ink, true);
        } else {
            put(s, col, row, l, ink_dim, false);
        }
        col += n + 4;
    }
    return .{ start, col - 4 };
}

fn paceBlurb(p: model.Pace) []const u8 {
    return switch (p) {
        .junior => "gentle ramp · forgiving misses",
        .senior => "the standard shift",
        .staff => "fast from the first standup",
        .tenx => "ship it. no reviews.",
    };
}

/// Pixel-font scale for cap legends: about a text cell's cap height, a
/// crisp integer scale (2 on big caps).
fn legendScale(g: *const Geo) f32 {
    const target = if (g.big) g.pxr * 0.95 else g.pxr * 0.62;
    return @max(1, @round(target / font.cap_h));
}

/// Cap legend drawn into the pixel layer, centered on (x0..x1, cy) and
/// shrunk to fit the key; it moves with the keycap image, never apart.
fn legendPx(s: *Surface, g: *const Geo, x0: f32, x1: f32, cy: f32, text: []const u8, c: Rgb, bold: bool, alpha: f32, scale: f32) void {
    _ = g;
    if (text.len == 0 or alpha <= 0.01) return;
    const o: font.TextOpts = .{ .bold = bold, .alpha = alpha };
    var sc = scale;
    var w = font.measure(text, sc, o);
    const avail = (x1 - x0) * 0.86;
    if (w > avail and w > 0) {
        sc *= avail / w;
        w = avail;
    }
    const exact = sc == @round(sc);
    var x = x0 + (x1 - x0 - w) * 0.5;
    var y = cy - font.height(sc) * 0.5;
    if (exact) {
        x = @round(x);
        y = @round(y);
    }
    _ = font.drawText(s, x, y, sc, text, c, o);
}

fn put(s: *Surface, col: i32, row: i32, str: []const u8, fg: Rgb, bold: bool) void {
    s.putText(col, row, str, fg.toColor(), null, bold);
}

fn putBg(s: *Surface, col: i32, row: i32, str: []const u8, fg: Rgb, bg: Rgb, bold: bool) void {
    s.putText(col, row, str, fg.toColor(), bg.toColor(), bold);
}

fn putCenter(s: *Surface, center: i32, row: i32, str: []const u8, fg: Rgb, bold: bool) void {
    const n: i32 = lay.legendCols(str);
    put(s, center - @divFloor(n, 2), row, str, fg, bold);
}

fn clearTextRect(s: *Surface, c0: i32, r0: i32, c1: i32, r1: i32) void {
    var r = @max(r0, 0);
    while (r < @min(r1, @as(i32, s.rows))) : (r += 1) {
        var c = @max(c0, 0);
        while (c < @min(c1, @as(i32, s.cols))) : (c += 1) {
            s.text[@as(usize, @intCast(r)) * s.cols + @as(usize, @intCast(c))] = .{};
        }
    }
}

/// Text in a rounded pill centered on `center` (pixels behind, text layer).
fn drawPill(s: *Surface, g: *const Geo, center: i32, row: i32, text: []const u8, fg: Rgb, bg: Rgb, a: f32, edge: Rgb) void {
    if (a <= 0.02) return;
    const n: i32 = lay.legendCols(text);
    const col = center - @divFloor(n, 2);
    const x = g.x(fi(col - 2));
    const w = g.x(fi(n + 4));
    if (g.lo) {
        canvas.fillRect(s, x, g.y(fi(row)), w, g.pxr, bg, a, .over);
    } else {
        canvas.roundRect(s, x, g.y(fi(row)) - g.pxr * 0.2, w, g.pxr * 1.4, g.pxr * 0.7, bg, a, .over);
        canvas.roundRectOutline(s, x, g.y(fi(row)) - g.pxr * 0.2, w, g.pxr * 1.4, g.pxr * 0.7, 1, edge, 0.14 * a, .over);
    }
    put(s, col, row, text, fg, true);
}

fn drawBadge(s: *Surface, g: *const Geo, col: i32, row: i32, text: []const u8) void {
    const n: i32 = lay.legendCols(text);
    if (g.lo) {
        putBg(s, col - 1, row, " ", badge_ink, pal.amber, true);
        putBg(s, col, row, text, badge_ink, pal.amber, true);
        putBg(s, col + n, row, " ", badge_ink, pal.amber, true);
        return;
    }
    canvas.roundRect(s, g.x(fi(col) - 0.9), g.y(fi(row)) + 0.5, g.x(fi(n) + 1.8), g.pxr - 1, 3, pal.amber, 1, .over);
    put(s, col, row, text, badge_ink, true);
}

/// "1234567" → "1,234,567" in `buf`.
fn fmtThousands(buf: []u8, n: u64) []const u8 {
    var tmp: [24]u8 = undefined;
    const digits = std.mem.print(&tmp, "{d}", .{n}) catch return "";
    var o: usize = 0;
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            if (o >= buf.len) break;
            buf[o] = ',';
            o += 1;
        }
        if (o >= buf.len) break;
        buf[o] = d;
        o += 1;
    }
    return buf[0..o];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fmtThousands" {
    var b: [40]u8 = undefined;
    try testing.expectEqualStrings("0", fmtThousands(&b, 0));
    try testing.expectEqualStrings("999", fmtThousands(&b, 999));
    try testing.expectEqualStrings("1,000", fmtThousands(&b, 1000));
    try testing.expectEqualStrings("390,160", fmtThousands(&b, 390160));
    try testing.expectEqualStrings("12,345,678", fmtThousands(&b, 12345678));
}

fn testCap(kind: model.TargetKind, word: []const u8, caption: []const u8) Cap {
    var c: Cap = .{ .id = 1, .kind = kind, .len = 0, .x = 0.5, .hue = 0.3, .progress = 0.5, .caption = caption };
    for (word, 0..) |ch, i| {
        c.steps[i] = .{ .code = ch, .legend = word[i .. i + 1], .role = .letter, .text = ch };
        c.len += 1;
    }
    return c;
}

test "legends land inside their keycaps" {
    // 120×35: big caps at kitty resolution, 2-row caps in half-block;
    // 80×24: 2-row caps at kitty resolution
    const sizes = [_][4]u16{ .{ 120, 35, 480, 280 }, .{ 120, 35, 120, 70 }, .{ 80, 24, 320, 192 } };
    for (sizes) |d| {
        var s = try Surface.init(testing.allocator, d[0], d[1], d[2], d[3]);
        defer s.deinit();
        const half = d[2] == d[0];
        const g = computeGeo(&s, .{ .halfblock = half }, false);
        try testing.expectEqual(!half and d[1] >= 30, g.big);
        var chord: Cap = .{ .id = 1, .kind = .chord2, .len = 1, .x = 0.5, .hue = 0.3, .progress = 0.5, .caption = "save" };
        chord.steps[0] = .{ .code = 's', .mods = .{ .ctrl = true }, .legend = "S", .role = .letter };
        const caps = [_]Cap{ chord, testCap(.word, "while", ""), testCap(.key, "j", ""), testCap(.sequence, "ciw", "change word") };
        for (&caps) |*c| {
            for ([_]f32{ 0, 0.5, 1 }) |p| {
                var cc = c.*;
                cc.progress = p;
                const cg = capGeo(&g, &cc);
                for (cg.l.keys()) |b| {
                    const r = keyRect(&g, &cg, b);
                    const n: f32 = fi(lay.legendCols(b.legend));
                    const lx0 = fi(r.lcol) * g.pxc;
                    const lx1 = (fi(r.lcol) + n) * g.pxc;
                    try testing.expect(lx0 >= r.x0 - 0.01 and lx1 <= r.x1 + 0.01);
                    // legend center == key center
                    try testing.expectApproxEqAbs((r.x0 + r.x1) * 0.5, (lx0 + lx1) * 0.5, 0.01);
                    const ly = (fi(r.lrow) + 0.5) * g.pxr;
                    try testing.expect(ly > cg.key_y and ly < cg.key_y + g.key_h);
                }
                // the whole cap stays between the HUD gap and the deck
                try testing.expect(cg.py0 >= g.y(fi(g.cap_top_row)) - 0.01);
                try testing.expect(cg.py1 <= g.deck_y + 0.01);
                if (c.caption.len > 0) try testing.expect(cg.caption_row < g.deck_row);
            }
            // the fall path runs over the keyboard to the deck
            var lo = c.*;
            lo.progress = 1;
            try testing.expect(capGeo(&g, &lo).py1 > g.kb_top);
        }
    }
}

test "simPlayCols narrows the field for big caps" {
    var s = try Surface.init(testing.allocator, 120, 35, 480, 280);
    defer s.deinit();
    try testing.expectEqual(@as(u16, 80), simPlayCols(&s, .{}));
    try testing.expectEqual(@as(u16, 120), simPlayCols(&s, .{ .halfblock = true }));
    try s.resize(80, 24, 320, 192);
    try testing.expectEqual(@as(u16, 80), simPlayCols(&s, .{}));
}

test "box blur keeps flat areas and softens edges" {
    var buf: [8 * 3]Px = @splat(Px.black);
    var tmp: [8]Px = undefined;
    for (4..8) |x| for (0..3) |y| {
        buf[y * 8 + x] = .{ .r = 255, .g = 255, .b = 255 };
    };
    boxBlur(&buf, 8, 0, 3, 1, &tmp);
    try testing.expectEqual(@as(u8, 0), buf[8 + 1].r);
    try testing.expectEqual(@as(u8, 255), buf[8 + 6].r);
    try testing.expect(buf[8 + 3].r > 0 and buf[8 + 3].r < 255);
}

test "render every phase without allocating per frame" {
    var arc = try Arcade.init(testing.allocator, 7, .{ .play_cols = 80 });
    defer arc.deinit();
    var sc = try Scene.init(testing.allocator, 7);
    defer sc.deinit();
    var s = try Surface.init(testing.allocator, 80, 24, 320, 192);
    defer s.deinit();
    var now: i64 = 0;
    for (0..120) |_| {
        now += 16;
        arc.update(now);
        sc.render(&s, &arc, now, .{});
        arc.clearEvents();
    }
    arc.startGame();
    for (0..400) |i| {
        now += 16;
        arc.update(now);
        if (i % 7 == 0) {
            for (arc.caps()) |c| {
                if (c.state == .falling and c.progress > 0.3) {
                    arc.handleKey(levels.eventForStep(c.steps[c.typed]), now);
                    break;
                }
            }
        }
        sc.render(&s, &arc, now, .{});
        arc.clearEvents();
    }
    // half-block size
    try s.resize(60, 20, 60, 40);
    sc.render(&s, &arc, now + 16, .{ .halfblock = true, .bloom = .off });
    arc.handleKey(.{ .code = keys.code.escape }, now);
    sc.render(&s, &arc, now + 32, .{ .halfblock = true });
    arc.stats.health = 0;
    arc.phase = .results;
    sc.render(&s, &arc, now + 48, .{ .halfblock = true });
    sc.reset();
}

test "tiny terminals: hits, popups and results do not trip clamps" {
    var arc = try Arcade.init(testing.allocator, 11, .{ .play_cols = 20 });
    defer arc.deinit();
    var sc = try Scene.init(testing.allocator, 11);
    defer sc.deinit();
    // rows <= 5: the popup band (below the HUD, above the deck) is empty
    for ([_][4]u16{ .{ 20, 4, 20, 8 }, .{ 12, 3, 48, 24 }, .{ 1, 1, 1, 2 } }) |d| {
        var s = try Surface.init(testing.allocator, d[0], d[1], d[2], d[3]);
        defer s.deinit();
        const q: Quality = .{ .halfblock = d[2] == d[0] };
        arc.reset(11);
        arc.setPlayWidth(d[0]);
        arc.startGame();
        var now: i64 = 0;
        var hits: usize = 0;
        while (now < 20_000 and hits < 6) {
            now += 16;
            for (arc.caps()) |c| {
                if (c.state == .falling and c.progress > 0.2) {
                    arc.handleKey(levels.eventForStep(c.steps[c.typed]), now);
                    hits += 1;
                    break;
                }
            }
            arc.update(now);
            sc.render(&s, &arc, now, q);
            arc.clearEvents();
        }
        try testing.expect(hits > 0);
        arc.phase = .results;
        sc.render(&s, &arc, now + 16, q);
    }
}
