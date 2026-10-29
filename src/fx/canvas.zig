//! Drawing primitives on a Surface's pixel layer.
//!
//! All coordinates are floating pixel space: pixel (x, y) covers
//! [x, x+1) × [y, y+1) and its center is (x+0.5, y+0.5). Shapes are
//! anti-aliased by signed distance (coverage = clamp(0.5 - d)), so sub-pixel
//! sizes fade in smoothly — important on tiny half-block surfaces.
//! Every primitive clips to the surface and never allocates.

const std = @import("std");
const surface_mod = @import("surface.zig");
const color = @import("color.zig");

pub const Surface = surface_mod.Surface;
pub const Px = surface_mod.Px;
pub const Rgb = color.Rgb;

/// How a color is composited onto the existing pixel.
pub const Blend = enum(u8) {
    /// Alpha over: dst = mix(dst, c, a).
    over,
    /// Additive light: dst += c * a.
    add,
    /// Screen: dst = 1 - (1 - dst)(1 - c a). Brightens without clipping hard.
    screen,
    /// Multiply toward c: dst = mix(dst, dst * c, a).
    multiply,
};

pub const inv255: f32 = 1.0 / 255.0;

pub inline fn f(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) * inv255;
}

pub inline fn sat(v: f32) f32 {
    return @min(@max(v, 0), 1);
}

pub inline fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = sat((x - e0) / (e1 - e0));
    return t * t * (3 - 2 * t);
}

inline fn b8(v: f32) u8 {
    return @intFromFloat(sat(v) * 255.0 + 0.5);
}

/// 0..1 float → byte (clamped, rounded).
pub fn to8(v: f32) u8 {
    return b8(v);
}

/// Composite `c` with opacity `a` (0..1) onto one pixel.
pub inline fn blendPx(p: *Px, c: Rgb, a: f32, mode: Blend) void {
    if (!(a > 0.002)) return;
    switch (mode) {
        // Integer fast paths for the two hot modes.
        .over => {
            const k: u32 = @intFromFloat(@min(a, 1) * 256 + 0.5);
            const ik = 256 - k;
            p.r = @intCast((@as(u32, p.r) * ik + @as(u32, b8(c.r)) * k + 128) >> 8);
            p.g = @intCast((@as(u32, p.g) * ik + @as(u32, b8(c.g)) * k + 128) >> 8);
            p.b = @intCast((@as(u32, p.b) * ik + @as(u32, b8(c.b)) * k + 128) >> 8);
            return;
        },
        .add => {
            p.r +|= b8(c.r * a);
            p.g +|= b8(c.g * a);
            p.b +|= b8(c.b * a);
            return;
        },
        else => {},
    }
    const dr = f(p.r);
    const dg = f(p.g);
    const db = f(p.b);
    switch (mode) {
        .over, .add => unreachable,
        .screen => {
            p.r = b8(1 - (1 - dr) * (1 - sat(c.r * a)));
            p.g = b8(1 - (1 - dg) * (1 - sat(c.g * a)));
            p.b = b8(1 - (1 - db) * (1 - sat(c.b * a)));
        },
        .multiply => {
            const k = @min(a, 1);
            p.r = b8(dr + (dr * c.r - dr) * k);
            p.g = b8(dg + (dg * c.g - dg) * k);
            p.b = b8(db + (db * c.b - db) * k);
        },
    }
}

/// Pixel at integer coordinates, or null when outside.
pub inline fn pixelAt(s: *Surface, x: i32, y: i32) ?*Px {
    if (x < 0 or y < 0) return null;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= s.w or uy >= s.h) return null;
    return &s.pixels[@as(usize, uy) * s.w + ux];
}

/// Blend one integer pixel (clipped).
pub inline fn plot(s: *Surface, x: i32, y: i32, c: Rgb, a: f32, mode: Blend) void {
    if (pixelAt(s, x, y)) |p| blendPx(p, c, a, mode);
}

pub fn getRgb(s: *const Surface, x: u32, y: u32) Rgb {
    const p = s.pixels[@as(usize, y) * s.w + x];
    return .{ .r = f(p.r), .g = f(p.g), .b = f(p.b) };
}

/// Integer pixel span [x0, x1) × [y0, y1), clipped to the surface.
pub const Span = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn empty(self: Span) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }
};

/// Pixels touched by the float box [fx0, fx1] × [fy0, fy1], or null.
pub fn span(s: *const Surface, fx0: f32, fy0: f32, fx1: f32, fy1: f32) ?Span {
    if (!(fx0 <= fx1 and fy0 <= fy1)) return null;
    const w: f32 = @floatFromInt(s.w);
    const h: f32 = @floatFromInt(s.h);
    const x0 = @max(@floor(fx0), 0);
    const y0 = @max(@floor(fy0), 0);
    const x1 = @min(@ceil(fx1), w);
    const y1 = @min(@ceil(fy1), h);
    if (!(x0 < x1 and y0 < y1)) return null;
    return .{
        .x0 = @intFromFloat(x0),
        .y0 = @intFromFloat(y0),
        .x1 = @intFromFloat(x1),
        .y1 = @intFromFloat(y1),
    };
}

// ---------------------------------------------------------------------------
// Fills
// ---------------------------------------------------------------------------

/// Fill the whole pixel layer with an opaque color.
pub fn clear(s: *Surface, c: Rgb) void {
    @memset(s.pixels, .{ .r = b8(c.r), .g = b8(c.g), .b = b8(c.b), .a = 255 });
}

/// Blend a color over the whole layer (e.g. a pause dim).
pub fn fill(s: *Surface, c: Rgb, a: f32, mode: Blend) void {
    for (s.pixels) |*p| blendPx(p, c, a, mode);
}

/// Axis-aligned rectangle with exact area coverage on fractional edges.
pub fn fillRect(s: *Surface, x: f32, y: f32, w: f32, h: f32, c: Rgb, a: f32, mode: Blend) void {
    const sp = span(s, x, y, x + w, y + h) orelse return;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy: f32 = @floatFromInt(py);
        const cy = sat(@min(fy + 1, y + h) - @max(fy, y));
        if (cy <= 0) continue;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx: f32 = @floatFromInt(px);
            const cx = sat(@min(fx + 1, x + w) - @max(fx, x));
            blendPx(&row[px], c, a * cx * cy, mode);
        }
    }
}

/// Signed distance from (px, py) to a rounded box centered at the origin
/// with half extents (hx, hy) and corner radius r. Negative inside.
pub fn sdRoundBox(px: f32, py: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(px) - hx + r;
    const qy = @abs(py) - hy + r;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
}

/// Anti-aliased rounded rectangle filled with a vertical gradient top→bottom.
pub fn roundRectV(s: *Surface, x: f32, y: f32, w: f32, h: f32, radius: f32, top: Rgb, bottom: Rgb, a: f32, mode: Blend) void {
    if (!(w > 0 and h > 0)) return;
    const sp = span(s, x - 1, y - 1, x + w + 1, y + h + 1) orelse return;
    const hx = w * 0.5;
    const hy = h * 0.5;
    const cx = x + hx;
    const cy = y + hy;
    const r = @min(@max(radius, 0), @min(hx, hy));
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const c = top.lerp(bottom, sat((fy - y) / h));
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const d = sdRoundBox(fx - cx, fy - cy, hx, hy, r);
            const cov = sat(0.5 - d);
            if (cov > 0) blendPx(&row[px], c, a * cov, mode);
        }
    }
}

/// Anti-aliased rounded rectangle, flat color.
pub fn roundRect(s: *Surface, x: f32, y: f32, w: f32, h: f32, radius: f32, c: Rgb, a: f32, mode: Blend) void {
    roundRectV(s, x, y, w, h, radius, c, c, a, mode);
}

/// Rounded rectangle outline of the given stroke thickness (centered on the edge).
pub fn roundRectOutline(s: *Surface, x: f32, y: f32, w: f32, h: f32, radius: f32, thickness: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(w > 0 and h > 0)) return;
    const t = @max(thickness, 0.01);
    const sp = span(s, x - t - 1, y - t - 1, x + w + t + 1, y + h + t + 1) orelse return;
    const hx = w * 0.5;
    const hy = h * 0.5;
    const cx = x + hx;
    const cy = y + hy;
    const r = @min(@max(radius, 0), @min(hx, hy));
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const d = @abs(sdRoundBox(fx - cx, fy - cy, hx, hy, r));
            const cov = sat(t * 0.5 - d + 0.5);
            if (cov > 0) blendPx(&row[px], c, a * cov, mode);
        }
    }
}

/// Soft glow around a rounded rectangle: light falls off over `spread` px
/// outside the edge (and is full inside). Default use: additive halo.
pub fn roundRectGlow(s: *Surface, x: f32, y: f32, w: f32, h: f32, radius: f32, spread: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(w > 0 and h > 0 and spread > 0)) return;
    const sp = span(s, x - spread, y - spread, x + w + spread, y + h + spread) orelse return;
    const hx = w * 0.5;
    const hy = h * 0.5;
    const cx = x + hx;
    const cy = y + hy;
    const r = @min(@max(radius, 0), @min(hx, hy));
    const inv = 1.0 / spread;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const d = sdRoundBox(fx - cx, fy - cy, hx, hy, r);
            const q = 1 - sat(d * inv);
            if (q > 0) blendPx(&row[px], c, a * q * q, mode);
        }
    }
}

/// Vertical gradient over a rectangle (anti-aliased edges).
pub fn gradientV(s: *Surface, x: f32, y: f32, w: f32, h: f32, top: Rgb, bottom: Rgb, a: f32, mode: Blend) void {
    const sp = span(s, x, y, x + w, y + h) orelse return;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy: f32 = @floatFromInt(py);
        const cy = sat(@min(fy + 1, y + h) - @max(fy, y));
        const c = top.lerp(bottom, sat((fy + 0.5 - y) / h));
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx: f32 = @floatFromInt(px);
            const cx = sat(@min(fx + 1, x + w) - @max(fx, x));
            blendPx(&row[px], c, a * cx * cy, mode);
        }
    }
}

pub const Stop = struct { at: f32, c: Rgb };

/// Color of a multi-stop gradient at t (stops sorted by `at`).
pub fn stopsAt(stops: []const Stop, t: f32) Rgb {
    if (stops.len == 0) return Rgb.black;
    if (t <= stops[0].at) return stops[0].c;
    for (stops[1..], 1..) |st, i| {
        if (t <= st.at) {
            const prev = stops[i - 1];
            const k = (t - prev.at) / @max(st.at - prev.at, 1e-6);
            return prev.c.lerp(st.c, k);
        }
    }
    return stops[stops.len - 1].c;
}

/// Opaque full-surface vertical gradient through `stops` (t: 0 top .. 1 bottom).
pub fn backgroundV(s: *Surface, stops: []const Stop) void {
    const h: f32 = @floatFromInt(@max(s.h, 1));
    var py: u32 = 0;
    while (py < s.h) : (py += 1) {
        const c = stopsAt(stops, (@as(f32, @floatFromInt(py)) + 0.5) / h);
        const px_val: Px = .{ .r = b8(c.r), .g = b8(c.g), .b = b8(c.b) };
        @memset(s.pixels[@as(usize, py) * s.w ..][0..s.w], px_val);
    }
}

/// Radial gradient disc: `inner` at the center fading to `outer` at radius r,
/// alpha a_in → a_out (outside r nothing is drawn).
pub fn radialGradient(s: *Surface, cx: f32, cy: f32, r: f32, inner: Rgb, outer: Rgb, a_in: f32, a_out: f32, mode: Blend) void {
    if (!(r > 0)) return;
    const sp = span(s, cx - r, cy - r, cx + r, cy + r) orelse return;
    const inv = 1.0 / r;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = @as(f32, @floatFromInt(py)) + 0.5 - cy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
            const d = @sqrt(dx * dx + dy * dy);
            if (d >= r) continue;
            const t = d * inv;
            const edge = sat(r - d);
            blendPx(&row[px], inner.lerp(outer, t), (a_in + (a_out - a_in) * t) * edge, mode);
        }
    }
}

// ---------------------------------------------------------------------------
// Round shapes and lines
// ---------------------------------------------------------------------------

/// Solid anti-aliased disc.
pub fn disc(s: *Surface, cx: f32, cy: f32, r: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(r > 0)) return;
    if (r < 0.5) {
        // Sub-pixel: spread area-weighted over the nearest pixels.
        dot(s, cx, cy, c, a * r * r * std.math.pi, mode);
        return;
    }
    const sp = span(s, cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1) orelse return;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = @as(f32, @floatFromInt(py)) + 0.5 - cy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
            const cov = sat(r - @sqrt(dx * dx + dy * dy) + 0.5);
            if (cov > 0) blendPx(&row[px], c, a * cov, mode);
        }
    }
}

/// A point of light spread bilinearly over the 4 nearest pixels.
pub fn dot(s: *Surface, x: f32, y: f32, c: Rgb, a: f32, mode: Blend) void {
    const fx = x - 0.5;
    const fy = y - 0.5;
    if (!(fx > -2 and fy > -2 and fx < @as(f32, @floatFromInt(s.w)) + 1 and fy < @as(f32, @floatFromInt(s.h)) + 1)) return;
    const ix: i32 = @intFromFloat(@floor(fx));
    const iy: i32 = @intFromFloat(@floor(fy));
    const tx = fx - @floor(fx);
    const ty = fy - @floor(fy);
    plot(s, ix, iy, c, a * (1 - tx) * (1 - ty), mode);
    plot(s, ix + 1, iy, c, a * tx * (1 - ty), mode);
    plot(s, ix, iy + 1, c, a * (1 - tx) * ty, mode);
    plot(s, ix + 1, iy + 1, c, a * tx * ty, mode);
}

/// Soft radial glow: intensity (1 - d²/r²)³, a cheap gaussian look-alike.
/// Use `.add` for light.
pub fn glow(s: *Surface, cx: f32, cy: f32, r: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(r > 0) or !(a > 0.002)) return;
    if (r < 0.8) {
        dot(s, cx, cy, c, a * @max(r, 0.25) * 1.2, mode);
        return;
    }
    const sp = span(s, cx - r, cy - r, cx + r, cy + r) orelse return;
    const inv = 1.0 / (r * r);
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = @as(f32, @floatFromInt(py)) + 0.5 - cy;
        const dy2 = dy * dy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
            const q = 1 - (dx * dx + dy2) * inv;
            if (q > 0) blendPx(&row[px], c, a * q * q * q, mode);
        }
    }
}

/// Elliptical soft glow (rx, ry radii) — flares, puddles, anamorphic streaks.
pub fn glowEllipse(s: *Surface, cx: f32, cy: f32, rx: f32, ry: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(rx > 0 and ry > 0) or !(a > 0.002)) return;
    const sp = span(s, cx - rx, cy - ry, cx + rx, cy + ry) orelse return;
    const ix = 1.0 / rx;
    const iy = 1.0 / ry;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = (@as(f32, @floatFromInt(py)) + 0.5 - cy) * iy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = (@as(f32, @floatFromInt(px)) + 0.5 - cx) * ix;
            const q = 1 - (dx * dx + dy * dy);
            if (q > 0) blendPx(&row[px], c, a * q * q, mode);
        }
    }
}

/// Solid anti-aliased ellipse.
pub fn ellipse(s: *Surface, cx: f32, cy: f32, rx: f32, ry: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(rx > 0 and ry > 0)) return;
    const sp = span(s, cx - rx - 1, cy - ry - 1, cx + rx + 1, cy + ry + 1) orelse return;
    const m = @min(rx, ry);
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = (@as(f32, @floatFromInt(py)) + 0.5 - cy) / ry;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = (@as(f32, @floatFromInt(px)) + 0.5 - cx) / rx;
            // approximate distance in px using the smaller radius
            const d = (@sqrt(dx * dx + dy * dy) - 1) * m;
            const cov = sat(0.5 - d);
            if (cov > 0) blendPx(&row[px], c, a * cov, mode);
        }
    }
}

/// Anti-aliased ring of radius r (center of stroke) and stroke `thickness`.
pub fn ring(s: *Surface, cx: f32, cy: f32, r: f32, thickness: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(r > 0)) return;
    const t = @max(thickness, 0.3);
    const outer = r + t * 0.5 + 1;
    const sp = span(s, cx - outer, cy - outer, cx + outer, cy + outer) orelse return;
    const inner = @max(r - t * 0.5 - 1, 0);
    const inner2 = inner * inner;
    // thin strokes lose energy to coverage; keep them visible
    const gain: f32 = if (t < 1) t else 1;
    const tw = @max(t, 1);
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = @as(f32, @floatFromInt(py)) + 0.5 - cy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
            const d2 = dx * dx + dy * dy;
            if (d2 < inner2) continue;
            const cov = sat(tw * 0.5 - @abs(@sqrt(d2) - r) + 0.5);
            if (cov > 0) blendPx(&row[px], c, a * cov * gain, mode);
        }
    }
}

/// Soft ring: light falls off as (1 - |d - r| / width)² on both sides.
pub fn softRing(s: *Surface, cx: f32, cy: f32, r: f32, width: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(r > 0 and width > 0)) return;
    const outer = r + width;
    const sp = span(s, cx - outer, cy - outer, cx + outer, cy + outer) orelse return;
    const inner = @max(r - width, 0);
    const inner2 = inner * inner;
    const inv = 1.0 / width;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = @as(f32, @floatFromInt(py)) + 0.5 - cy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
            const d2 = dx * dx + dy * dy;
            if (d2 < inner2) continue;
            const q = 1 - @abs(@sqrt(d2) - r) * inv;
            if (q > 0) blendPx(&row[px], c, a * q * q, mode);
        }
    }
}

/// Distance from p to segment ab.
pub fn segDist(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const wx = px - ax;
    const wy = py - ay;
    const l2 = vx * vx + vy * vy;
    const t = if (l2 > 1e-9) sat((wx * vx + wy * vy) / l2) else 0;
    const dx = wx - vx * t;
    const dy = wy - vy * t;
    return @sqrt(dx * dx + dy * dy);
}

/// Anti-aliased thick line with round caps (capsule).
pub fn line(s: *Surface, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, c: Rgb, a: f32, mode: Blend) void {
    const hw = @max(width, 0.01) * 0.5;
    // Lines thinner than a pixel are drawn 1 px wide with reduced alpha.
    const eff = @max(hw, 0.5);
    const gain = @min(width, 1);
    const pad = eff + 1;
    const sp = span(s, @min(x0, x1) - pad, @min(y0, y1) - pad, @max(x0, x1) + pad, @max(y0, y1) + pad) orelse return;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const cov = sat(eff - segDist(fx, fy, x0, y0, x1, y1) + 0.5);
            if (cov > 0) blendPx(&row[px], c, a * cov * gain, mode);
        }
    }
}

/// Soft glowing line: intensity (1 - d/radius)² around the segment.
pub fn glowLine(s: *Surface, x0: f32, y0: f32, x1: f32, y1: f32, radius: f32, c: Rgb, a: f32, mode: Blend) void {
    if (!(radius > 0)) return;
    if (radius < 0.75) {
        line(s, x0, y0, x1, y1, radius * 2, c, a, mode);
        return;
    }
    const sp = span(s, @min(x0, x1) - radius, @min(y0, y1) - radius, @max(x0, x1) + radius, @max(y0, y1) + radius) orelse return;
    const inv = 1.0 / radius;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const q = 1 - segDist(fx, fy, x0, y0, x1, y1) * inv;
            if (q > 0) blendPx(&row[px], c, a * q * q, mode);
        }
    }
}

/// Connected thick line through `pts`.
pub fn polyline(s: *Surface, pts: []const [2]f32, width: f32, c: Rgb, a: f32, mode: Blend) void {
    if (pts.len < 2) return;
    // Additive/screen modes would double-light the joints; draw per segment
    // anyway (joints are tiny) to keep the cost linear and allocation-free.
    for (pts[0 .. pts.len - 1], pts[1..]) |p, q| line(s, p[0], p[1], q[0], q[1], width, c, a, mode);
}

/// Soft glow along a polyline.
pub fn glowPolyline(s: *Surface, pts: []const [2]f32, radius: f32, c: Rgb, a: f32, mode: Blend) void {
    if (pts.len < 2) return;
    for (pts[0 .. pts.len - 1], pts[1..]) |p, q| glowLine(s, p[0], p[1], q[0], q[1], radius, c, a, mode);
}

// ---------------------------------------------------------------------------
// Polygons
// ---------------------------------------------------------------------------

/// Anti-aliased convex polygon (≤ 8 points, any winding).
pub fn convex(s: *Surface, pts: []const [2]f32, c: Rgb, a: f32, mode: Blend) void {
    const n = @min(pts.len, 8);
    if (n < 3) return;
    var minx: f32 = pts[0][0];
    var maxx: f32 = pts[0][0];
    var miny: f32 = pts[0][1];
    var maxy: f32 = pts[0][1];
    var area: f32 = 0;
    for (0..n) |i| {
        const p = pts[i];
        const q = pts[(i + 1) % n];
        minx = @min(minx, p[0]);
        maxx = @max(maxx, p[0]);
        miny = @min(miny, p[1]);
        maxy = @max(maxy, p[1]);
        area += p[0] * q[1] - q[0] * p[1];
    }
    if (@abs(area) < 1e-6) return;
    const sgn: f32 = if (area > 0) 1 else -1;
    // Edge equations: n·p + d = signed distance (positive inside).
    var ex: [8]f32 = undefined;
    var ey: [8]f32 = undefined;
    var ed: [8]f32 = undefined;
    for (0..n) |i| {
        const p = pts[i];
        const q = pts[(i + 1) % n];
        var nx = -(q[1] - p[1]) * sgn;
        var ny = (q[0] - p[0]) * sgn;
        const l = @sqrt(nx * nx + ny * ny);
        if (l < 1e-9) {
            ex[i] = 0;
            ey[i] = 0;
            ed[i] = 1e9;
            continue;
        }
        nx /= l;
        ny /= l;
        ex[i] = nx;
        ey[i] = ny;
        ed[i] = -(nx * p[0] + ny * p[1]);
    }
    // Tiny polygons: area-weighted dot so they don't flicker in and out.
    const bw = maxx - minx;
    const bh = maxy - miny;
    if (bw < 1.0 and bh < 1.0) {
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (pts[0..n]) |p| {
            cx += p[0];
            cy += p[1];
        }
        const inv_n = 1.0 / @as(f32, @floatFromInt(n));
        dot(s, cx * inv_n, cy * inv_n, c, a * @abs(area) * 0.5, mode);
        return;
    }
    const sp = span(s, minx - 1, miny - 1, maxx + 1, maxy + 1) orelse return;
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            var d: f32 = 1e9;
            for (0..n) |i| d = @min(d, ex[i] * fx + ey[i] * fy + ed[i]);
            const cov = sat(d + 0.5);
            if (cov > 0) blendPx(&row[px], c, a * cov, mode);
        }
    }
}

/// Anti-aliased filled triangle.
pub fn triangle(s: *Surface, p0: [2]f32, p1: [2]f32, p2: [2]f32, c: Rgb, a: f32, mode: Blend) void {
    convex(s, &.{ p0, p1, p2 }, c, a, mode);
}

/// Rectangle of size w×h centered at (cx, cy), rotated by `angle` radians.
pub fn rotRect(s: *Surface, cx: f32, cy: f32, w: f32, h: f32, angle: f32, c: Rgb, a: f32, mode: Blend) void {
    const ca = @cos(angle);
    const sa = @sin(angle);
    const hx = w * 0.5;
    const hy = h * 0.5;
    const ux = ca * hx;
    const uy = sa * hx;
    const vx = -sa * hy;
    const vy = ca * hy;
    convex(s, &.{
        .{ cx - ux - vx, cy - uy - vy },
        .{ cx + ux - vx, cy + uy - vy },
        .{ cx + ux + vx, cy + uy + vy },
        .{ cx - ux + vx, cy - uy + vy },
    }, c, a, mode);
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

/// Bilinear sample of an RGBA8 buffer (w×h) at float pixel coords; clamps at edges.
pub fn sampleBuf(buf: []const Px, w: u32, h: u32, x: f32, y: f32) Rgb {
    const maxx: f32 = @floatFromInt(w - 1);
    const maxy: f32 = @floatFromInt(h - 1);
    const fx = @min(@max(x - 0.5, 0), maxx);
    const fy = @min(@max(y - 0.5, 0), maxy);
    const x0: u32 = @intFromFloat(fx);
    const y0: u32 = @intFromFloat(fy);
    const x1 = @min(x0 + 1, w - 1);
    const y1 = @min(y0 + 1, h - 1);
    // 8.8 fixed-point weights: integer math, one float conversion per channel
    const tx: u32 = @intFromFloat((fx - @as(f32, @floatFromInt(x0))) * 256);
    const ty: u32 = @intFromFloat((fy - @as(f32, @floatFromInt(y0))) * 256);
    const r0 = @as(usize, y0) * w;
    const r1 = @as(usize, y1) * w;
    const a = buf[r0 + x0];
    const b = buf[r0 + x1];
    const c = buf[r1 + x0];
    const d = buf[r1 + x1];
    const w00 = (256 - tx) * (256 - ty);
    const w10 = tx * (256 - ty);
    const w01 = (256 - tx) * ty;
    const w11 = tx * ty;
    const k: f32 = 1.0 / (255.0 * 65536.0);
    return .{
        .r = @as(f32, @floatFromInt(a.r * w00 + b.r * w10 + c.r * w01 + d.r * w11)) * k,
        .g = @as(f32, @floatFromInt(a.g * w00 + b.g * w10 + c.g * w01 + d.g * w11)) * k,
        .b = @as(f32, @floatFromInt(a.b * w00 + b.b * w10 + c.b * w01 + d.b * w11)) * k,
    };
}

/// Nearest-pixel sample (clamped).
pub fn sampleNearest(buf: []const Px, w: u32, h: u32, x: f32, y: f32) Px {
    const fx = @min(@max(x, 0), @as(f32, @floatFromInt(w - 1)));
    const fy = @min(@max(y, 0), @as(f32, @floatFromInt(h - 1)));
    return buf[@as(usize, @intFromFloat(fy)) * w + @as(usize, @intFromFloat(fx))];
}

/// Bilinear sample of the surface itself.
pub fn sample(s: *const Surface, x: f32, y: f32) Rgb {
    return sampleBuf(s.pixels, s.w, s.h, x, y);
}

/// Write an opaque color.
pub inline fn store(p: *Px, c: Rgb) void {
    p.* = .{ .r = b8(c.r), .g = b8(c.g), .b = b8(c.b), .a = 255 };
}

// ---------------------------------------------------------------------------
// Keycap
// ---------------------------------------------------------------------------

pub const KeycapOpts = struct {
    /// Overall opacity.
    alpha: f32 = 1,
    /// Corner radius as a fraction of min(w, h); 0.18 looks like a cap.
    radius: f32 = 0.18,
    /// Height of the darker "side" band as a fraction of h.
    side: f32 = 0.16,
    /// Colored outer glow (additive), e.g. for caps near landing / rarity.
    glow: ?Rgb = null,
    glow_amount: f32 = 0.6,
    /// Mix the whole cap toward this color (flash / heat / frost tints).
    tint: ?Rgb = null,
    tint_amount: f32 = 0,
};

/// A 3D-looking keycap: rounded body in the side color, a slightly inset top
/// face with a vertical gradient and a glossy highlight band. (x, y, w, h) is
/// the full cap footprint in pixels. The legend is not drawn.
pub fn keycap(s: *Surface, x: f32, y: f32, w: f32, h: f32, top: Rgb, side: Rgb, o: KeycapOpts) void {
    if (!(w > 0 and h > 0)) return;
    var t = top;
    var sd = side;
    if (o.tint) |tc| {
        t = t.lerp(tc, o.tint_amount);
        sd = sd.lerp(tc, o.tint_amount);
    }
    const m = @min(w, h);
    const r = m * o.radius;
    if (o.glow) |g| {
        const spread = @max(m * 0.45, 1.5);
        roundRectGlow(s, x, y, w, h, r, spread, g, o.glow_amount * o.alpha, .add);
    }
    // body (side color, darker toward bottom)
    roundRectV(s, x, y, w, h, r, sd, sd.scale(0.72), o.alpha, .over);
    // top face
    const band = @max(h * o.side, @min(1.0, h * 0.25));
    const inset = @min(@max(w * 0.06, 0.0), 2.5);
    const fh = h - band - @min(inset, h * 0.08);
    if (fh > 0.5) {
        roundRectV(s, x + inset, y + @min(inset, h * 0.08), w - 2 * inset, fh, r * 0.85, t.lighten(0.12), t.scale(0.93), o.alpha, .over);
        // glossy highlight band near the top of the face
        if (fh > 3) {
            fillRect(s, x + inset + r * 0.6, y + @min(inset, h * 0.08) + fh * 0.1, @max(w - 2 * inset - r * 1.2, 0), @max(fh * 0.12, 0.6), Rgb.white, 0.22 * o.alpha, .over);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testSurface(w: u32, h: u32) !Surface {
    return Surface.init(testing.allocator, @intCast(w / 2), @intCast(h / 2), w, h);
}

test "blend modes" {
    var p: Px = .{ .r = 100, .g = 100, .b = 100 };
    blendPx(&p, Rgb.white, 1, .over);
    try testing.expectEqual(@as(u8, 255), p.r);
    p = .{ .r = 200, .g = 0, .b = 0 };
    blendPx(&p, Rgb.init(1, 0.5, 0), 1, .add);
    try testing.expectEqual(@as(u8, 255), p.r); // clamps
    try testing.expectEqual(@as(u8, 128), p.g);
    p = .{ .r = 128, .g = 128, .b = 128 };
    blendPx(&p, Rgb.white, 0.5, .screen);
    try testing.expect(p.r > 128 and p.r < 255);
    p = .{ .r = 200, .g = 200, .b = 200 };
    blendPx(&p, Rgb.black, 1, .multiply);
    try testing.expectEqual(@as(u8, 0), p.r);
    // zero alpha is a no-op
    p = .{ .r = 1, .g = 2, .b = 3 };
    blendPx(&p, Rgb.white, 0, .over);
    try testing.expectEqual(@as(u8, 1), p.r);
}

test "fillRect area coverage and clipping" {
    var s = try testSurface(8, 8);
    defer s.deinit();
    clear(&s, Rgb.black);
    fillRect(&s, 1.5, 1, 2, 1, Rgb.white, 1, .over);
    try testing.expectEqual(@as(u8, 128), s.pixels[1 * 8 + 1].r); // half covered
    try testing.expectEqual(@as(u8, 255), s.pixels[1 * 8 + 2].r);
    try testing.expectEqual(@as(u8, 128), s.pixels[1 * 8 + 3].r);
    try testing.expectEqual(@as(u8, 0), s.pixels[0].r);
    // off-surface and NaN shapes are ignored, partially visible shapes clip
    fillRect(&s, -100, -100, 10, 10, Rgb.white, 1, .over);
    fillRect(&s, std.math.nan(f32), 0, 4, 4, Rgb.white, 1, .over);
    fillRect(&s, 6, 6, 100, 100, Rgb.white, 1, .over);
    try testing.expectEqual(@as(u8, 255), s.pixels[7 * 8 + 7].r);
    disc(&s, 1e30, 1e30, 5, Rgb.white, 1, .add);
    line(&s, -1e20, 0, 1e20, 0, 1, Rgb.white, 1, .add);
}

test "rounded rect corners are anti-aliased" {
    var s = try testSurface(20, 20);
    defer s.deinit();
    clear(&s, Rgb.black);
    roundRect(&s, 2, 2, 16, 16, 6, Rgb.white, 1, .over);
    try testing.expectEqual(@as(u8, 255), s.pixels[10 * 20 + 10].r); // center
    try testing.expectEqual(@as(u8, 0), s.pixels[2 * 20 + 2].r); // cut corner
    try testing.expectEqual(@as(u8, 255), s.pixels[2 * 20 + 10].r); // top edge middle
    // somewhere on the corner arc there is a partial pixel
    var partial = false;
    for (2..6) |y| for (2..6) |x| {
        const v = s.pixels[y * 20 + x].r;
        if (v > 10 and v < 245) partial = true;
    };
    try testing.expect(partial);
}

test "sdRoundBox signs" {
    try testing.expect(sdRoundBox(0, 0, 5, 5, 1) < 0);
    try testing.expect(sdRoundBox(10, 0, 5, 5, 1) > 0);
    try testing.expectApproxEqAbs(@as(f32, 0), sdRoundBox(5, 0, 5, 5, 1), 1e-5);
}

test "disc glow ring line triangle draw something inside, nothing far away" {
    var s = try testSurface(32, 32);
    defer s.deinit();
    clear(&s, Rgb.black);
    disc(&s, 8, 8, 3, Rgb.white, 1, .over);
    try testing.expectEqual(@as(u8, 255), s.pixels[8 * 32 + 8].r);
    try testing.expectEqual(@as(u8, 0), s.pixels[8 * 32 + 14].r);
    glow(&s, 24, 8, 5, Rgb.init(0, 1, 0), 1, .add);
    try testing.expect(s.pixels[8 * 32 + 24].g > 200);
    try testing.expectEqual(@as(u8, 0), s.pixels[8 * 32 + 30].g);
    ring(&s, 8, 24, 5, 1, Rgb.init(0, 0, 1), 1, .add);
    try testing.expect(s.pixels[24 * 32 + 13].b > 100);
    try testing.expectEqual(@as(u8, 0), s.pixels[24 * 32 + 8].b); // hole
    line(&s, 16, 16, 30, 16, 2, Rgb.init(1, 0, 0), 1, .over);
    try testing.expect(s.pixels[16 * 32 + 22].r > 200);
    triangle(&s, .{ 20, 20 }, .{ 30, 20 }, .{ 20, 30 }, Rgb.white, 1, .over);
    try testing.expectEqual(@as(u8, 255), s.pixels[22 * 32 + 22].g);
    try testing.expectEqual(@as(u8, 0), s.pixels[29 * 32 + 29].g);
    // reversed winding draws the same
    triangle(&s, .{ 20, 30 }, .{ 30, 20 }, .{ 20, 20 }, Rgb.init(0, 0, 0), 1, .over);
    try testing.expectEqual(@as(u8, 0), s.pixels[22 * 32 + 22].g);
}

test "bilinear sampling interpolates" {
    var s = try testSurface(4, 2);
    defer s.deinit();
    clear(&s, Rgb.black);
    s.pixels[1] = .{ .r = 255, .g = 255, .b = 255 };
    const mid = sample(&s, 1.0, 0.5); // halfway between px 0 and 1
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid.r, 0.01);
    const exact = sample(&s, 1.5, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), exact.r, 0.01);
    const clamped = sample(&s, -50, -50);
    try testing.expectApproxEqAbs(@as(f32, 0), clamped.r, 0.01);
}

test "gradient stops" {
    const stops = [_]Stop{ .{ .at = 0, .c = Rgb.black }, .{ .at = 0.5, .c = Rgb.white }, .{ .at = 1, .c = Rgb.black } };
    try testing.expectApproxEqAbs(@as(f32, 1), stopsAt(&stops, 0.5).r, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), stopsAt(&stops, 0.25).r, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), stopsAt(&stops, 2).r, 1e-5);
    var s = try testSurface(4, 4);
    defer s.deinit();
    backgroundV(&s, &stops);
    try testing.expect(s.pixels[1 * 4].r > s.pixels[0].r);
}

test "keycap draws body and face" {
    var s = try testSurface(40, 40);
    defer s.deinit();
    clear(&s, Rgb.black);
    keycap(&s, 4, 4, 32, 32, color.palette.cap_letter[0], color.palette.cap_letter[2], .{ .glow = color.palette.teal });
    const face = s.pixels[15 * 40 + 20];
    const bottom = s.pixels[34 * 40 + 20];
    try testing.expect(face.r > 180);
    try testing.expect(bottom.r < face.r); // darker side band
    try testing.expect(s.pixels[20 * 40 + 1].g > 0); // glow outside
}
