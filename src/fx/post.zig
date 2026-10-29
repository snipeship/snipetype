//! Full-frame post passes: shockwave / gravitational-lens displacement,
//! glitch slices with RGB split, screen shake, additive flash, vignette and
//! bloom. Passes that read the frame while writing it take a caller-owned
//! `scratch` buffer (same length as `s.pixels`); bloom owns its own
//! low-resolution buffers. Nothing here allocates per frame.

const std = @import("std");
const canvas = @import("canvas.zig");
const color = @import("color.zig");
const rng = @import("rng.zig");

const Surface = canvas.Surface;
const Px = canvas.Px;
const Rgb = color.Rgb;
const sat = canvas.sat;
const smoothstep = canvas.smoothstep;
const f = canvas.f;

/// A circular shockwave ring that bends the image radially.
pub const Shockwave = struct {
    cx: f32,
    cy: f32,
    /// Current ring radius (px).
    radius: f32,
    /// Half width of the distorted band (px).
    width: f32,
    /// Peak displacement (px).
    amp: f32,
    /// Additive ring light amount (0..1).
    light: f32,
    tint: Rgb = Rgb.init(0.55, 0.75, 1.0),
};

/// Gravitational lens around a black hole.
/// Source sample = center + dir·(r − shift), shift = min(rE²/r · k, 0.8 r),
/// faded out toward `reach`. Inside `horizon` the image is black, with a thin
/// photon ring just outside it.
pub const Lens = struct {
    cx: f32,
    cy: f32,
    horizon: f32,
    einstein: f32,
    reach: f32,
    k: f32 = 1,
    photon: f32 = 1,
};

/// A rectangle cut into horizontally offset slices (digital glitch).
pub const GlitchRegion = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// 0..1 strength (offsets, split, noise).
    amount: f32,
    /// Pixel scale of the effect (e.g. cap height) for offsets / slice heights.
    unit: f32,
    seed: u32,
    /// Effect time in seconds (slices re-roll ~24× per second).
    t: f32,
};

/// Displace the region touched by `waves` and `lenses`. `scratch.len` must be
/// ≥ `s.pixels.len`.
pub fn displace(s: *Surface, scratch: []Px, waves: []const Shockwave, lenses: []const Lens) void {
    if (waves.len == 0 and lenses.len == 0) return;
    if (scratch.len < s.pixels.len or s.w == 0 or s.h == 0) return;
    // Union bounding box of everything that moves pixels.
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for (waves) |wv| {
        const r = wv.radius + wv.width + 1;
        x0 = @min(x0, wv.cx - r);
        y0 = @min(y0, wv.cy - r);
        x1 = @max(x1, wv.cx + r);
        y1 = @max(y1, wv.cy + r);
    }
    for (lenses) |l| {
        const r = l.reach + 1;
        x0 = @min(x0, l.cx - r);
        y0 = @min(y0, l.cy - r);
        x1 = @max(x1, l.cx + r);
        y1 = @max(y1, l.cy + r);
    }
    const sp = canvas.span(s, x0, y0, x1, y1) orelse return;
    // Copy just the rows we read from (sampling clamps to the frame, and
    // displacement fades to zero at the box edge, so rows outside are only
    // ever read when the box is clipped — copy a margin for safety).
    const max_shift: u32 = blk: {
        var m: f32 = 2;
        for (waves) |wv| m = @max(m, wv.amp * 1.3 + 2);
        for (lenses) |l| m = @max(m, l.reach);
        break :blk @intFromFloat(@min(m, @as(f32, @floatFromInt(s.h))));
    };
    const cy0 = sp.y0 -| max_shift;
    const cy1 = @min(sp.y1 + max_shift, s.h);
    const lo = @as(usize, cy0) * s.w;
    const hi = @as(usize, cy1) * s.w;
    @memcpy(scratch[lo..hi], s.pixels[lo..hi]);

    // Squared band limits so untouched pixels skip the sqrt.
    var band_lo: [8]f32 = undefined;
    var band_hi: [8]f32 = undefined;
    const nw = @min(waves.len, band_lo.len);
    for (waves[0..nw], 0..) |wv, i| {
        const a = @max(wv.radius - wv.width, 0);
        const b = wv.radius + wv.width;
        band_lo[i] = a * a;
        band_hi[i] = b * b;
    }
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            var any = false;
            for (waves[0..nw], 0..) |wv, i| {
                const dx = fx - wv.cx;
                const dy = fy - wv.cy;
                const d2 = dx * dx + dy * dy;
                if (d2 > band_lo[i] and d2 < band_hi[i]) any = true;
            }
            for (lenses) |l| {
                const dx = fx - l.cx;
                const dy = fy - l.cy;
                if (dx * dx + dy * dy < l.reach * l.reach) any = true;
            }
            if (!any) continue;
            var ox: f32 = 0;
            var oy: f32 = 0;
            var light: f32 = 0;
            var tint = Rgb.black;
            var ca: f32 = 0; // chromatic aberration amount (px)
            var dark: f32 = 0; // horizon coverage
            var photon: f32 = 0;
            var touched = false;
            for (waves[0..nw]) |wv| {
                const dx = fx - wv.cx;
                const dy = fy - wv.cy;
                const d = @sqrt(dx * dx + dy * dy);
                const x = (d - wv.radius) / wv.width;
                if (x <= -1 or x >= 1 or d < 1e-3) continue;
                touched = true;
                const env = (1 - x * x);
                // Push content outward inside the ring, pull it in outside:
                // a lens-like bulge that travels with the ring.
                const amt = wv.amp * @sin(x * std.math.pi) * env;
                const inv = 1.0 / d;
                ox += dx * inv * amt;
                oy += dy * inv * amt;
                const lt = wv.light * env * env * env;
                light += lt;
                tint = tint.add(wv.tint.scale(lt));
                ca += @abs(amt) * 0.35;
            }
            for (lenses) |l| {
                const dx = fx - l.cx;
                const dy = fy - l.cy;
                const r = @sqrt(dx * dx + dy * dy);
                if (r >= l.reach) continue;
                touched = true;
                if (r < 1e-3) {
                    dark = 1;
                    continue;
                }
                const fade = 1 - smoothstep(l.reach * 0.55, l.reach, r);
                const sh = @min(l.einstein * l.einstein / r * l.k, 0.8 * r) * fade;
                const inv = 1.0 / r;
                ox += dx * inv * sh;
                oy += dy * inv * sh;
                dark = @max(dark, sat(l.horizon - r + 0.5));
                const pr = l.horizon * 1.12 + 0.5;
                const pw = @max(l.horizon * 0.14, 0.8);
                const q = 1 - @abs(r - pr) / pw;
                if (q > 0) photon += q * q * l.photon;
            }
            if (!touched) continue;
            var c: Rgb = undefined;
            if (ca > 0.6) {
                const len = @sqrt(ox * ox + oy * oy) + 1e-6;
                const ux = ox / len * ca;
                const uy = oy / len * ca;
                const cr = canvas.sampleNearest(scratch, s.w, s.h, fx - ox - ux, fy - oy - uy);
                const cb = canvas.sampleNearest(scratch, s.w, s.h, fx - ox + ux, fy - oy + uy);
                c = canvas.sampleBuf(scratch, s.w, s.h, fx - ox, fy - oy);
                c.r = f(cr.r);
                c.b = f(cb.b);
            } else {
                c = canvas.sampleBuf(scratch, s.w, s.h, fx - ox, fy - oy);
            }
            if (light > 0) c = c.add(tint.scale(0.6)).add(Rgb.white.scale(light * 0.15));
            if (photon > 0) c = c.add(color.palette.photon.scale(photon * 1.4)).add(Rgb.white.scale(photon * 0.35));
            if (dark > 0) c = c.scale(1 - dark);
            canvas.store(&row[px], c);
        }
    }
}

/// Horizontal slice offsets with RGB split along slice edges and scanline
/// noise, clipped to the region (feathered at its left/right ends).
pub fn glitch(s: *Surface, g: GlitchRegion) void {
    if (!(g.amount > 0.01)) return;
    const sp = canvas.span(s, g.x, g.y, g.x + g.w, g.y + g.h) orelse return;
    const width = sp.x1 - sp.x0;
    if (width == 0) return;
    var rowbuf: [1024]Px = undefined;
    const step: u32 = @intFromFloat(@max(g.t, 0) * 24);
    const max_off = g.amount * g.unit * 0.55 + 1;
    const max_h = @max(g.unit * 0.35, 1);
    const split = @max(g.amount * g.unit * 0.12, if (g.amount > 0.3) @as(f32, 1) else 0);
    var y = sp.y0;
    var slice: u32 = 0;
    while (y < sp.y1) : (slice += 1) {
        const hh = rng.hash01(g.seed +% slice *% 7919, step);
        const sh: u32 = @intFromFloat(@max(1, @floor(1 + hh * max_h)));
        const hm = rng.hash01(g.seed ^ 0xabc +% slice, step *% 31 +% 3);
        const moving = hm < 0.25 + 0.5 * g.amount;
        const dx: f32 = if (moving) (rng.hash01(slice +% g.seed, step +% 99) * 2 - 1) * max_off else 0;
        const y_end = @min(y + sh, sp.y1);
        var yy = y;
        while (yy < y_end) : (yy += 1) {
            const row = s.pixels[@as(usize, yy) * s.w ..][0..s.w];
            const n = @min(width, rowbuf.len);
            @memcpy(rowbuf[0..n], row[sp.x0 .. sp.x0 + n]);
            const edge = moving and (yy == y or yy + 1 == y_end);
            const sx: f32 = if (edge) split else if (moving) split * 0.35 else 0;
            const noise = rng.hash01(yy +% g.seed, step) < 0.12 * g.amount;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const fx: f32 = @floatFromInt(i);
                const feather = sat(@min(fx + 0.5, @as(f32, @floatFromInt(n)) - fx - 0.5) / 2.5);
                const r = rowSample(rowbuf[0..n], fx - dx - sx);
                const gch = rowSample(rowbuf[0..n], fx - dx);
                const b = rowSample(rowbuf[0..n], fx - dx + sx);
                var c = Rgb.init(r.r, gch.g, b.b);
                if (noise) c = c.add(Rgb.init(0.12, 0.14, 0.18).scale(g.amount));
                const orig = &row[sp.x0 + i];
                if (feather < 1) {
                    const o = Rgb.init(f(orig.r), f(orig.g), f(orig.b));
                    c = o.lerp(c, feather);
                }
                canvas.store(orig, c);
            }
        }
        y = y_end;
    }
}

fn rowSample(row: []const Px, x: f32) Rgb {
    const maxx: f32 = @floatFromInt(row.len - 1);
    const fx = @min(@max(x, 0), maxx);
    const x0: usize = @intFromFloat(fx);
    const x1 = @min(x0 + 1, row.len - 1);
    const t = fx - @as(f32, @floatFromInt(x0));
    const a = row[x0];
    const b = row[x1];
    return .{
        .r = f(a.r) + (f(b.r) - f(a.r)) * t,
        .g = f(a.g) + (f(b.g) - f(a.g)) * t,
        .b = f(a.b) + (f(b.b) - f(a.b)) * t,
    };
}

/// Shift the whole frame by an integer offset, repeating edge pixels.
pub fn shift(s: *Surface, scratch: []Px, dx: i32, dy: i32) void {
    if (dx == 0 and dy == 0) return;
    if (scratch.len < s.pixels.len or s.w == 0 or s.h == 0) return;
    @memcpy(scratch[0..s.pixels.len], s.pixels);
    const w: i32 = @intCast(s.w);
    const h: i32 = @intCast(s.h);
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        const sy: usize = @intCast(std.math.clamp(y - dy, 0, h - 1));
        const dst = s.pixels[@as(usize, @intCast(y)) * s.w ..][0..s.w];
        const src = scratch[sy * s.w ..][0..s.w];
        if (dx >= w or dx <= -w) {
            @memset(dst, if (dx > 0) src[0] else src[s.w - 1]);
        } else if (dx > 0) {
            const k: usize = @intCast(dx);
            @memcpy(dst[k..], src[0 .. s.w - k]);
            @memset(dst[0..k], src[0]);
        } else if (dx < 0) {
            const k: usize = @intCast(-dx);
            @memcpy(dst[0 .. s.w - k], src[k..]);
            @memset(dst[s.w - k ..], src[s.w - 1]);
        } else {
            @memcpy(dst, src);
        }
    }
}

/// Additive full-screen flash.
pub fn flash(s: *Surface, c: Rgb, amount: f32) void {
    if (!(amount > 0.004)) return;
    const k = c.scale(amount);
    const ar = canvas.to8(k.r);
    const ag = canvas.to8(k.g);
    const ab = canvas.to8(k.b);
    if (ar == 0 and ag == 0 and ab == 0) return;
    for (s.pixels) |*p| {
        p.r +|= ar;
        p.g +|= ag;
        p.b +|= ab;
    }
}

/// Darken (mix toward `c`) toward the corners. `strength` 0..1.
pub fn vignette(s: *Surface, strength: f32, c: Rgb) void {
    if (!(strength > 0.004)) return;
    const hw = @as(f32, @floatFromInt(s.w)) * 0.5;
    const hh = @as(f32, @floatFromInt(s.h)) * 0.5;
    var y: u32 = 0;
    while (y < s.h) : (y += 1) {
        const dy = (@as(f32, @floatFromInt(y)) + 0.5 - hh) / hh;
        const row = s.pixels[@as(usize, y) * s.w ..][0..s.w];
        const cr: u32 = canvas.to8(c.r);
        const cg: u32 = canvas.to8(c.g);
        const cb: u32 = canvas.to8(c.b);
        const inv_hw = 1.0 / hw;
        for (row, 0..) |*p, x| {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5 - hw) * inv_hw;
            const q = dx * dx * 0.8 + dy * dy;
            if (q < 0.3) continue;
            const k: u32 = @intFromFloat(@min(strength, 1) * smoothstep(0.3, 1.9, q) * 256);
            const ik = 256 - k;
            p.r = @intCast((p.r * ik + cr * k) >> 8);
            p.g = @intCast((p.g * ik + cg * k) >> 8);
            p.b = @intCast((p.b * ik + cb * k) >> 8);
        }
    }
}

pub const BloomQuality = enum(u8) {
    off,
    /// ¼ resolution, one blur iteration.
    low,
    /// ½ resolution, two blur iterations.
    high,
};

/// Bright-pass → downsample → separable box blur → additive upsample.
pub const Bloom = struct {
    allocator: std.mem.Allocator,
    a: []f32 = &.{},
    b: []f32 = &.{},
    /// Per-output-column taps (x0, tx) cached for the current width.
    col_x: []u32 = &.{},
    col_t: []f32 = &.{},
    row: []f32 = &.{},
    bw: u32 = 0,
    bh: u32 = 0,
    cached_w: u32 = 0,
    cached_fac: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Bloom {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Bloom) void {
        self.freeAll();
        self.* = .{ .allocator = self.allocator };
    }

    fn freeAll(self: *Bloom) void {
        if (self.a.len > 0) self.allocator.free(self.a);
        if (self.b.len > 0) self.allocator.free(self.b);
        if (self.col_x.len > 0) self.allocator.free(self.col_x);
        if (self.col_t.len > 0) self.allocator.free(self.col_t);
        if (self.row.len > 0) self.allocator.free(self.row);
        self.a = &.{};
        self.b = &.{};
        self.col_x = &.{};
        self.col_t = &.{};
        self.row = &.{};
        self.cached_w = 0;
    }

    fn ensure(self: *Bloom, n: usize, w: u32, row_n: usize) !void {
        if (self.a.len >= n and self.col_x.len >= w and self.row.len >= row_n) return;
        self.freeAll();
        errdefer self.freeAll();
        self.a = try self.allocator.alloc(f32, n);
        self.b = try self.allocator.alloc(f32, n);
        self.col_x = try self.allocator.alloc(u32, w);
        self.col_t = try self.allocator.alloc(f32, w);
        self.row = try self.allocator.alloc(f32, row_n);
    }

    /// Add bloom of pixels brighter than `threshold` (0..1 on max channel),
    /// scaled by `strength`. Buffers grow only when the surface grows.
    pub fn apply(self: *Bloom, s: *Surface, quality: BloomQuality, threshold: f32, strength: f32) void {
        if (quality == .off or !(strength > 0.01) or s.w < 8 or s.h < 8) return;
        // Big surfaces bloom at a coarser grid so the cost stays flat.
        const big = s.w > 640;
        const fac: u32 = switch (quality) {
            .high => if (big) 4 else 2,
            else => if (big) 8 else 4,
        };
        const bw = (s.w + fac - 1) / fac;
        const bh = (s.h + fac - 1) / fac;
        self.ensure(@as(usize, bw) * bh * 3, s.w, @as(usize, bw) * 3) catch return;
        self.bw = bw;
        self.bh = bh;
        const a = self.a;
        const b = self.b;

        // Bright pass + box downsample.
        const knee = @max(1 - threshold, 0.05);
        const inv_area = 1.0 / @as(f32, @floatFromInt(fac * fac));
        var by: u32 = 0;
        while (by < bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < bw) : (bx += 1) {
                var r: u32 = 0;
                var g: u32 = 0;
                var bb: u32 = 0;
                const y0 = by * fac;
                const x0 = bx * fac;
                const y1 = @min(y0 + fac, s.h);
                const x1 = @min(x0 + fac, s.w);
                var y = y0;
                while (y < y1) : (y += 1) {
                    const row = s.pixels[@as(usize, y) * s.w ..];
                    var x = x0;
                    while (x < x1) : (x += 1) {
                        const p = row[x];
                        r += p.r;
                        g += p.g;
                        bb += p.b;
                    }
                }
                const scale = canvas.inv255 * inv_area;
                const fr = @as(f32, @floatFromInt(r)) * scale;
                const fg = @as(f32, @floatFromInt(g)) * scale;
                const fb = @as(f32, @floatFromInt(bb)) * scale;
                const v = @max(fr, @max(fg, fb));
                const w_ = sat((v - threshold) / knee);
                const k = w_ * w_;
                const i = (@as(usize, by) * bw + bx) * 3;
                a[i] = fr * k;
                a[i + 1] = fg * k;
                a[i + 2] = fb * k;
            }
        }

        const iters: u32 = if (quality == .high) 2 else 1;
        const radius: u32 = if (quality == .high) 3 else 2;
        var it: u32 = 0;
        while (it < iters) : (it += 1) {
            boxH(a, b, bw, bh, radius);
            boxV(b, a, bw, bh, radius);
        }

        // Additive bilinear upsample: interpolate the bloom row vertically
        // once per output row, then two horizontal taps per pixel.
        const ffac: f32 = @floatFromInt(fac);
        const maxx: f32 = @floatFromInt(bw - 1);
        const maxy: f32 = @floatFromInt(bh - 1);
        if (self.cached_w != s.w or self.cached_fac != fac) {
            for (0..s.w) |x| {
                const sx = @min(@max((@as(f32, @floatFromInt(x)) + 0.5) / ffac - 0.5, 0), maxx);
                const x0: u32 = @intFromFloat(sx);
                self.col_x[x] = x0;
                self.col_t[x] = sx - @as(f32, @floatFromInt(x0));
            }
            self.cached_w = s.w;
            self.cached_fac = fac;
        }
        const gain = strength * 255.0;
        const rowv = self.row[0 .. @as(usize, bw) * 3];
        var y: u32 = 0;
        while (y < s.h) : (y += 1) {
            const sy = @min(@max((@as(f32, @floatFromInt(y)) + 0.5) / ffac - 0.5, 0), maxy);
            const y0: u32 = @intFromFloat(sy);
            const yy1 = @min(y0 + 1, bh - 1);
            const ty = sy - @as(f32, @floatFromInt(y0));
            const r0 = a[@as(usize, y0) * bw * 3 ..][0 .. @as(usize, bw) * 3];
            const r1 = a[@as(usize, yy1) * bw * 3 ..][0 .. @as(usize, bw) * 3];
            var any: f32 = 0;
            for (rowv, r0, r1) |*o, v0, v1| {
                o.* = (v0 + (v1 - v0) * ty) * gain;
                any = @max(any, o.*);
            }
            if (any < 0.5) continue;
            const row = s.pixels[@as(usize, y) * s.w ..][0..s.w];
            for (row, self.col_x[0..s.w], self.col_t[0..s.w]) |*p, x0, tx| {
                const j0 = x0 * 3;
                const j1 = @min(x0 + 1, bw - 1) * 3;
                const vr = rowv[j0] + (rowv[j1] - rowv[j0]) * tx;
                const vg = rowv[j0 + 1] + (rowv[j1 + 1] - rowv[j0 + 1]) * tx;
                const vb = rowv[j0 + 2] + (rowv[j1 + 2] - rowv[j0 + 2]) * tx;
                p.r +|= @intFromFloat(@min(vr, 255));
                p.g +|= @intFromFloat(@min(vg, 255));
                p.b +|= @intFromFloat(@min(vb, 255));
            }
        }
    }
};

/// Horizontal box blur (RGB interleaved), src → dst, clamped edges.
fn boxH(src: []const f32, dst: []f32, w: u32, h: u32, r: u32) void {
    const inv = 1.0 / @as(f32, @floatFromInt(2 * r + 1));
    const wi: i32 = @intCast(w);
    const ri: i32 = @intCast(r);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const base = @as(usize, y) * w * 3;
        inline for (0..3) |ch| {
            var acc: f32 = 0;
            var k: i32 = -ri;
            while (k <= ri) : (k += 1) {
                const xi: usize = @intCast(std.math.clamp(k, 0, wi - 1));
                acc += src[base + xi * 3 + ch];
            }
            var x: i32 = 0;
            while (x < wi) : (x += 1) {
                dst[base + @as(usize, @intCast(x)) * 3 + ch] = acc * inv;
                const add_i: usize = @intCast(std.math.clamp(x + ri + 1, 0, wi - 1));
                const sub_i: usize = @intCast(std.math.clamp(x - ri, 0, wi - 1));
                acc += src[base + add_i * 3 + ch] - src[base + sub_i * 3 + ch];
            }
        }
    }
}

/// Vertical box blur (RGB interleaved), src → dst, clamped edges.
fn boxV(src: []const f32, dst: []f32, w: u32, h: u32, r: u32) void {
    const inv = 1.0 / @as(f32, @floatFromInt(2 * r + 1));
    const hi: i32 = @intCast(h);
    const ri: i32 = @intCast(r);
    const stride = @as(usize, w) * 3;
    var x: usize = 0;
    while (x < @as(usize, w) * 3) : (x += 1) {
        var acc: f32 = 0;
        var k: i32 = -ri;
        while (k <= ri) : (k += 1) {
            const yi: usize = @intCast(std.math.clamp(k, 0, hi - 1));
            acc += src[yi * stride + x];
        }
        var y: i32 = 0;
        while (y < hi) : (y += 1) {
            dst[@as(usize, @intCast(y)) * stride + x] = acc * inv;
            const add_i: usize = @intCast(std.math.clamp(y + ri + 1, 0, hi - 1));
            const sub_i: usize = @intCast(std.math.clamp(y - ri, 0, hi - 1));
            acc += src[add_i * stride + x] - src[sub_i * stride + x];
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mk(w: u32, h: u32) !Surface {
    return Surface.init(testing.allocator, @intCast(@max(w / 4, 1)), @intCast(@max(h / 4, 1)), w, h);
}

test "shift repeats edges" {
    var s = try mk(4, 4);
    defer s.deinit();
    const scratch = try testing.allocator.alloc(Px, 16);
    defer testing.allocator.free(scratch);
    for (s.pixels, 0..) |*p, i| p.* = .{ .r = @intCast(i), .g = 0, .b = 0 };
    shift(&s, scratch, 1, 0);
    try testing.expectEqual(@as(u8, 0), s.pixels[0].r);
    try testing.expectEqual(@as(u8, 0), s.pixels[1].r);
    try testing.expectEqual(@as(u8, 2), s.pixels[3].r);
    shift(&s, scratch, 0, -1);
    try testing.expectEqual(@as(u8, 4), s.pixels[0].r); // row 1 moved up
    shift(&s, scratch, 100, 100); // huge offsets don't crash
}

test "lens blackens horizon and leaves far pixels alone" {
    var s = try mk(64, 64);
    defer s.deinit();
    const scratch = try testing.allocator.alloc(Px, s.pixels.len);
    defer testing.allocator.free(scratch);
    // checkerboard-ish gradient
    for (s.pixels, 0..) |*p, i| p.* = .{ .r = @intCast((i * 7) % 256), .g = 128, .b = @intCast(i % 64 * 4) };
    const far_before = s.pixels[2 * 64 + 2];
    displace(&s, scratch, &.{}, &.{.{ .cx = 32, .cy = 32, .horizon = 5, .einstein = 8, .reach = 20 }});
    const center = s.pixels[32 * 64 + 32];
    try testing.expectEqual(@as(u8, 0), center.r);
    try testing.expectEqual(@as(u8, 0), center.g);
    try testing.expectEqual(far_before, s.pixels[2 * 64 + 2]);
    // photon ring is bright
    const ring_px = s.pixels[32 * 64 + 32 + 6];
    try testing.expect(ring_px.r > 150);
}

test "shockwave touches only its band" {
    var s = try mk(64, 64);
    defer s.deinit();
    const scratch = try testing.allocator.alloc(Px, s.pixels.len);
    defer testing.allocator.free(scratch);
    for (s.pixels, 0..) |*p, i| p.* = .{ .r = @intCast(i % 64 * 4), .g = 0, .b = 0 };
    const inside = s.pixels[32 * 64 + 32];
    displace(&s, scratch, &.{.{ .cx = 32, .cy = 32, .radius = 20, .width = 4, .amp = 3, .light = 0.5 }}, &.{});
    try testing.expectEqual(inside, s.pixels[32 * 64 + 32]);
    try testing.expect(s.pixels[32 * 64 + 52].b > 0); // ring light tint
}

test "glitch keeps size and stays in region" {
    var s = try mk(64, 32);
    defer s.deinit();
    for (s.pixels, 0..) |*p, i| p.* = .{ .r = @intCast(i % 64 * 4), .g = 50, .b = 50 };
    const outside = s.pixels[1 * 64 + 1];
    glitch(&s, .{ .x = 10, .y = 10, .w = 40, .h = 12, .amount = 1, .unit = 12, .seed = 5, .t = 0.3 });
    try testing.expectEqual(outside, s.pixels[1 * 64 + 1]);
    try testing.expectEqual(s.pixels[31 * 64 + 60], Px{ .r = 240, .g = 50, .b = 50 });
}

test "bloom adds light around bright pixels only" {
    var s = try mk(64, 64);
    defer s.deinit();
    canvas.clear(&s, Rgb.black);
    canvas.fillRect(&s, 30, 30, 4, 4, Rgb.white, 1, .over);
    var bloom = Bloom.init(testing.allocator);
    defer bloom.deinit();
    bloom.apply(&s, .high, 0.6, 1.0);
    try testing.expect(s.pixels[32 * 64 + 37].r > 0); // halo
    try testing.expectEqual(@as(u8, 0), s.pixels[2 * 64 + 2].r); // far corner dark
    bloom.apply(&s, .low, 0.6, 1.0);
    bloom.apply(&s, .off, 0.6, 1.0);
    // dark frame: nothing added
    canvas.clear(&s, Rgb.init(0.2, 0.2, 0.2));
    bloom.apply(&s, .low, 0.6, 1.0);
    try testing.expectEqual(@as(u8, 51), s.pixels[100].r);
}

test "flash and vignette" {
    var s = try mk(32, 32);
    defer s.deinit();
    canvas.clear(&s, Rgb.init(0.5, 0.5, 0.5));
    vignette(&s, 1, Rgb.black);
    try testing.expect(s.pixels[0].r < s.pixels[16 * 32 + 16].r);
    flash(&s, Rgb.white, 0.5);
    try testing.expect(s.pixels[16 * 32 + 16].r > 200);
}
