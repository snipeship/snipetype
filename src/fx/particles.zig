//! Fixed-capacity particle pool: sparks, dots, voxel squares, tumbling
//! shards, two-tone confetti, streaks and smoke puffs, with gravity, drag,
//! spin, flutter, attractors (black holes), floor bounce and color ramps.
//! Storage is allocated once in `init`; emitting into a full pool drops the
//! particle (returns null).

const std = @import("std");
const canvas = @import("canvas.zig");
const color = @import("color.zig");

const Surface = canvas.Surface;
const Rgb = color.Rgb;
const Blend = canvas.Blend;
const sat = canvas.sat;

pub const default_capacity = 4096;

pub const Kind = enum(u8) {
    /// Glowing point (additive halo + hot core); `stretch` > 0 makes it a streak.
    spark,
    /// Solid anti-aliased disc.
    dot,
    /// Soft radial glow only.
    glow,
    /// Rotating square with a bevel (voxel bits, pixel blocks).
    square,
    /// Flat-shaded rotating triangle with a fake 3D tumble (`shape` vertices).
    shard,
    /// Paper bit: thin rect, front `c0` / back `c1`, flipping and fluttering.
    confetti,
    /// Line from (pos − v·stretch) to pos.
    streak,
    /// Growing soft puff, alpha-blended.
    smoke,
};

pub const Layer = enum(u8) { under, over };

pub const Particle = struct {
    x: f32,
    y: f32,
    vx: f32 = 0,
    vy: f32 = 0,
    /// Total lifetime (s) and time lived so far.
    life: f32 = 1,
    age: f32 = 0,
    /// Size in px (radius for round kinds, edge for squares/confetti,
    /// vertex scale for shards, width for streaks).
    size: f32 = 1,
    /// Size multiplier reached at the end of life.
    size_end: f32 = 1,
    rot: f32 = 0,
    spin: f32 = 0,
    /// Fake 3D flip angle and rate (shards, confetti).
    tumble: f32 = 0,
    tumble_rate: f32 = 0,
    /// Downward acceleration px/s² (negative floats up).
    gravity: f32 = 0,
    /// Linear drag per second.
    drag: f32 = 0,
    /// Sideways sway acceleration (px/s²) for confetti / embers.
    flutter: f32 = 0,
    /// Start → end color (confetti: front / back).
    c0: Rgb = Rgb.white,
    c1: Rgb = Rgb.white,
    alpha: f32 = 1,
    /// Seconds to fade in.
    fade_in: f32 = 0,
    /// Fraction of life spent fading out at the end.
    fade_out: f32 = 0.35,
    /// Streak / stretched spark length in seconds of velocity.
    stretch: f32 = 0,
    kind: Kind = .spark,
    blend: Blend = .add,
    layer: Layer = .over,
    twinkle: bool = false,
    bounce: bool = false,
    /// Pulled by attractors (black holes).
    attract: bool = true,
    seed: u16 = 0,
    /// Shard vertex offsets (x0,y0,x1,y1,x2,y2) in units of size/127.
    shape: [6]i8 = .{ 0, -127, 110, 63, -110, 63 },

    pub fn progress(self: *const Particle) f32 {
        return sat(self.age / @max(self.life, 1e-4));
    }
};

/// Point that pulls particles (and swallows them inside `kill_radius`).
pub const Attractor = struct {
    x: f32,
    y: f32,
    /// Acceleration (px/s²) at distance `radius`; grows as 1/d inside.
    strength: f32,
    radius: f32,
    kill_radius: f32 = 0,
    /// Tangential share of the pull (spiral in).
    swirl: f32 = 0.6,
};

pub const Env = struct {
    /// Particles with `bounce` bounce off this y (e.g. the deck top).
    floor_y: ?f32 = null,
    attractors: []const Attractor = &.{},
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    items: []Particle,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Pool {
        return .{ .allocator = allocator, .items = try allocator.alloc(Particle, capacity) };
    }

    pub fn deinit(self: *Pool) void {
        self.allocator.free(self.items);
        self.items = &.{};
        self.len = 0;
    }

    pub fn clear(self: *Pool) void {
        self.len = 0;
    }

    pub fn alive(self: *const Pool) []const Particle {
        return self.items[0..self.len];
    }

    pub fn free(self: *const Pool) usize {
        return self.items.len - self.len;
    }

    /// Add a particle; returns a pointer for tweaks, or null if full.
    pub fn emit(self: *Pool, p: Particle) ?*Particle {
        if (self.len >= self.items.len) return null;
        self.items[self.len] = p;
        self.len += 1;
        return &self.items[self.len - 1];
    }

    pub fn update(self: *Pool, dt: f32, env: Env) void {
        if (!(dt > 0)) return;
        var i: usize = 0;
        while (i < self.len) {
            const p = &self.items[i];
            p.age += dt;
            var dead = p.age >= p.life;
            if (!dead) {
                step(p, dt, env);
                if (p.attract) {
                    for (env.attractors) |a| {
                        const dx = a.x - p.x;
                        const dy = a.y - p.y;
                        const d = @sqrt(dx * dx + dy * dy);
                        if (d < a.kill_radius) {
                            dead = true;
                            break;
                        }
                        if (d >= a.radius * 3 or d < 1e-3) continue;
                        const acc = a.strength * a.radius / @max(d, a.radius * 0.15);
                        const ux = dx / d;
                        const uy = dy / d;
                        const radial = acc * (1 - a.swirl * 0.5);
                        const tang = acc * a.swirl;
                        p.vx += (ux * radial - uy * tang) * dt;
                        p.vy += (uy * radial + ux * tang) * dt;
                    }
                }
                if (!(std.math.isFinite(p.x) and std.math.isFinite(p.y))) dead = true;
            }
            if (dead) {
                self.len -= 1;
                self.items[i] = self.items[self.len];
            } else i += 1;
        }
    }

    pub fn draw(self: *const Pool, s: *Surface, layer: Layer) void {
        for (self.items[0..self.len]) |*p| {
            if (p.layer == layer) drawParticle(s, p);
        }
    }
};

fn step(p: *Particle, dt: f32, env: Env) void {
    p.vy += p.gravity * dt;
    if (p.flutter != 0) {
        const ph = p.age * 6.5 + @as(f32, @floatFromInt(p.seed)) * 0.37;
        p.vx += @sin(ph) * p.flutter * dt;
    }
    if (p.drag > 0) {
        const k = 1.0 / (1.0 + p.drag * dt);
        p.vx *= k;
        p.vy *= k;
    }
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    p.rot += p.spin * dt;
    p.tumble += p.tumble_rate * dt;
    if (p.bounce) {
        if (env.floor_y) |fy| {
            if (p.y > fy and p.vy > 0) {
                p.y = fy;
                p.vy *= -0.35;
                p.vx *= 0.7;
                p.spin *= 0.6;
                p.tumble_rate *= 0.6;
            }
        }
    }
}

/// Draw one particle (exposed for effects that render particles manually).
pub fn drawParticle(s: *Surface, p: *const Particle) void {
    const t = p.progress();
    var a = p.alpha;
    if (p.fade_in > 0) a *= sat(p.age / p.fade_in);
    if (p.fade_out > 0) a *= sat((1 - t) / p.fade_out);
    if (p.twinkle) a *= 0.5 + 0.5 * @sin(p.age * 38 + @as(f32, @floatFromInt(p.seed)));
    if (!(a > 0.004)) return;
    const size = p.size * (1 + (p.size_end - 1) * t);
    if (!(size > 0.01)) return;
    const c = if (p.kind == .confetti) p.c0 else p.c0.lerp(p.c1, t);
    // Pixel-sized solids snap to whole pixels so they stay crisp on tiny
    // (half-block) surfaces instead of smearing into dim 2×2 blurs.
    if (size < 1.4 and (p.kind == .square or p.kind == .shard or p.kind == .confetti)) {
        const shade = if (p.kind == .confetti and @cos(p.tumble) < 0) p.c1 else c;
        canvas.fillRect(s, @floor(p.x), @floor(p.y), 1, 1, shade, a, p.blend);
        return;
    }
    switch (p.kind) {
        .spark => {
            if (p.stretch > 0) return drawStreak(s, p, c, a, size);
            canvas.glow(s, p.x, p.y, size * 2.4, c, a * 0.55, p.blend);
            canvas.disc(s, p.x, p.y, size * 0.55, c.lighten(0.55), a, p.blend);
        },
        .dot => canvas.disc(s, p.x, p.y, size, c, a, p.blend),
        .glow => canvas.glow(s, p.x, p.y, size, c, a, p.blend),
        .smoke => canvas.glow(s, p.x, p.y, size, c, a, p.blend),
        .streak => drawStreak(s, p, c, a, size),
        .square => {
            if (size < 1.6) {
                canvas.fillRect(s, p.x - size * 0.5, p.y - size * 0.5, size, size, c, a, p.blend);
            } else {
                canvas.rotRect(s, p.x, p.y, size, size, p.rot, c.scale(0.78), a, p.blend);
                const inner = size * 0.62;
                const ox = -size * 0.08;
                canvas.rotRect(s, p.x + ox, p.y + ox, inner, inner, p.rot, c.lighten(0.12), a, p.blend);
            }
        },
        .shard => {
            const ct = @cos(p.tumble);
            const ca = @cos(p.rot);
            const sa = @sin(p.rot);
            const k = size / 127.0;
            var pts: [3][2]f32 = undefined;
            for (0..3) |i| {
                const lx = @as(f32, @floatFromInt(p.shape[i * 2])) * k;
                const ly = @as(f32, @floatFromInt(p.shape[i * 2 + 1])) * k * ct;
                pts[i] = .{ p.x + lx * ca - ly * sa, p.y + lx * sa + ly * ca };
            }
            const facing = @abs(ct);
            var shade = c.scale(0.5 + 0.5 * facing);
            if (ct < 0) shade = shade.scale(0.8); // back face a bit darker
            if (facing > 0.93) shade = shade.lighten((facing - 0.93) * 6);
            canvas.triangle(s, pts[0], pts[1], pts[2], shade, a, p.blend);
        },
        .confetti => {
            const ct = @cos(p.tumble);
            const face = if (ct >= 0) p.c0 else p.c1;
            const lit = face.scale(0.6 + 0.4 * @abs(ct));
            const h = @max(size * 0.55 * @abs(ct), 0.35);
            canvas.rotRect(s, p.x, p.y, size, h, p.rot, lit, a, p.blend);
        },
    }
}

fn drawStreak(s: *Surface, p: *const Particle, c: Rgb, a: f32, size: f32) void {
    const st = if (p.stretch > 0) p.stretch else 0.04;
    const tx = p.x - p.vx * st;
    const ty = p.y - p.vy * st;
    canvas.glowLine(s, tx, ty, p.x, p.y, size * 1.6, c, a * 0.5, p.blend);
    canvas.line(s, tx, ty, p.x, p.y, @max(size * 0.6, 0.5), c.lighten(0.5), a, p.blend);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "emit until full, update kills by age (swap remove)" {
    var pool = try Pool.init(testing.allocator, 8);
    defer pool.deinit();
    for (0..8) |i| try testing.expect(pool.emit(.{ .x = 0, .y = 0, .life = @floatFromInt(i + 1) }) != null);
    try testing.expect(pool.emit(.{ .x = 0, .y = 0 }) == null);
    pool.update(2.5, .{}); // lives 1 and 2 die
    try testing.expectEqual(@as(usize, 6), pool.len);
    for (pool.alive()) |p| try testing.expect(p.life > 2.5);
    pool.clear();
    try testing.expectEqual(@as(usize, 0), pool.len);
}

test "gravity, drag and bounce" {
    var pool = try Pool.init(testing.allocator, 4);
    defer pool.deinit();
    _ = pool.emit(.{ .x = 0, .y = 0, .gravity = 100, .life = 10 });
    _ = pool.emit(.{ .x = 0, .y = 0, .vx = 100, .drag = 5, .life = 10 });
    _ = pool.emit(.{ .x = 0, .y = 9, .vy = 50, .bounce = true, .life = 10 });
    for (0..10) |_| pool.update(0.01, .{ .floor_y = 10 });
    try testing.expect(pool.items[0].y > 0.4 and pool.items[0].vy > 9);
    try testing.expect(pool.items[1].vx < 70);
    try testing.expect(pool.items[2].y <= 10.0001);
}

test "attractor pulls and swallows" {
    var pool = try Pool.init(testing.allocator, 4);
    defer pool.deinit();
    _ = pool.emit(.{ .x = 20, .y = 0, .life = 10 });
    _ = pool.emit(.{ .x = 1, .y = 0, .life = 10 });
    _ = pool.emit(.{ .x = 15, .y = 0, .life = 10, .attract = false });
    const at = [_]Attractor{.{ .x = 0, .y = 0, .strength = 500, .radius = 10, .kill_radius = 2 }};
    pool.update(0.05, .{ .attractors = &at });
    try testing.expectEqual(@as(usize, 2), pool.len); // the close one died
    var pulled = false;
    for (pool.alive()) |p| {
        if (p.attract) pulled = p.vx < 0;
        if (!p.attract) try testing.expectEqual(@as(f32, 0), p.vx);
    }
    try testing.expect(pulled);
}

test "every kind draws without crashing, including degenerate sizes" {
    var s = try Surface.init(testing.allocator, 8, 8, 48, 48);
    defer s.deinit();
    canvas.clear(&s, Rgb.black);
    var pool = try Pool.init(testing.allocator, 64);
    defer pool.deinit();
    inline for (comptime std.meta.tags(Kind)) |k| {
        _ = pool.emit(.{ .x = 24, .y = 24, .vx = 30, .vy = -10, .size = 4, .kind = k, .stretch = 0.05, .tumble = 0.3, .life = 1 });
        _ = pool.emit(.{ .x = 2, .y = 47, .size = 0.2, .kind = k, .life = 1 });
        _ = pool.emit(.{ .x = -500, .y = 1e9, .size = 3, .kind = k, .life = 1 });
    }
    pool.update(0.016, .{});
    pool.draw(&s, .over);
    pool.draw(&s, .under);
    var lit = false;
    for (s.pixels) |p| lit = lit or p.r > 0;
    try testing.expect(lit);
}
