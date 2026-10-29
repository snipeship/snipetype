//! `Fx`: the effect manager. Owns a particle pool, a fixed pool of active
//! effect instances, up to 4 shockwaves, screen flash and shake, and the
//! post passes (displacement / lensing / glitch / bloom).
//!
//! Frame usage (scene):
//!   fx.update(dt);
//!   backdrop → fx.drawUnder(s) → live caps → fx.drawOver(s) → fx.post(s) → HUD
//!
//! Spawning: `spawn(effect, cx, cy, cap_w, cap_h, hue, intensity)` with the
//! cap's center and size in surface pixels (sizes, speeds and particle counts
//! all scale with the cap height, so the same call looks right on a half-block
//! surface and on a 4–8 px/cell kitty/web surface). After a hit the scene
//! should stop drawing that cap: effects that need the cap's look (pop, dust,
//! glitch, lightning, frost, melt, supernova, blackhole, derez, plus the
//! shards/voxels of shatter/voxel) redraw or break up a cap built from
//! `CapLook` (top/side/legend colors + optional legend text, drawn with the
//! pixel font when large enough). `spawnEx` takes a `Spawn` with a look; the
//! plain `spawn` uses the cream letter skin.

const std = @import("std");
const model = @import("../game/model.zig");
const canvas = @import("canvas.zig");
const color = @import("color.zig");
const font = @import("font.zig");
const particles = @import("particles.zig");
const post_mod = @import("post.zig");
const rng_mod = @import("rng.zig");

const Surface = canvas.Surface;
const Px = canvas.Px;
const Rgb = color.Rgb;
const Particle = particles.Particle;
const Rng = rng_mod.Rng;
const sat = canvas.sat;
const smoothstep = canvas.smoothstep;
const pal = color.palette;
const pi = std.math.pi;

pub const Effect = model.Effect;
pub const BloomQuality = post_mod.BloomQuality;

pub const max_instances = 48;
pub const max_waves = 4;
const max_pts = 128;
const max_lenses = 4;
const max_attractors = 4;

/// What the hit cap looked like (for effects that break it up or redraw it).
pub const CapLook = struct {
    top: Rgb = pal.cap_letter[0],
    side: Rgb = pal.cap_letter[2],
    legend: Rgb = pal.cap_letter[1],
    /// Optional legend (≤ 15 bytes are copied) drawn with the pixel font
    /// when the cap is at least ~10 px tall.
    text: []const u8 = "",
    /// Rarity / accent glow around the cap.
    glow: ?Rgb = null,
};

/// Keycap skin for a model role / rarity (DESIGN.md palette), for `Spawn.look`.
pub fn lookFor(role: model.CapRole, rarity: model.Rarity) CapLook {
    return switch (rarity) {
        .rare => .{ .top = Rgb.hex(0x1f5fd6), .side = Rgb.hex(0x143f94), .legend = Rgb.hex(0xeef4ff), .glow = Rgb.hex(0x4f8dff) },
        .epic => .{ .top = Rgb.hex(0x2a1660), .side = Rgb.hex(0x120a2e), .legend = Rgb.hex(0xe8dcff), .glow = Rgb.hex(0x9a6bff) },
        .legendary => .{ .top = Rgb.hex(0xf0c25a), .side = Rgb.hex(0xb8862c), .legend = Rgb.hex(0x2a1a05), .glow = Rgb.hex(0xffd27a) },
        .common => switch (role) {
            .letter, .digit, .symbol => .{ .top = pal.cap_letter[0], .side = pal.cap_letter[2], .legend = pal.cap_letter[1] },
            .modifier => .{ .top = pal.cap_modifier[0], .side = pal.cap_modifier[2], .legend = pal.cap_modifier[1] },
            .named => .{ .top = pal.cap_named[0], .side = pal.cap_named[2], .legend = pal.cap_named[1] },
            .arrow => .{ .top = pal.cap_arrow[0], .side = pal.cap_arrow[2], .legend = pal.cap_arrow[1] },
        },
    };
}

pub const Spawn = struct {
    /// Cap center and size in surface pixels.
    cx: f32,
    cy: f32,
    w: f32,
    h: f32,
    /// Accent hue 0..1.
    hue: f32 = 0.08,
    /// 0..1 — particle counts, glow, shake.
    intensity: f32 = 0.5,
    look: CapLook = .{},
};

const Kind = enum(u8) {
    shatter,
    confetti,
    voxel,
    pop,
    dust,
    glitch,
    lightning,
    frost,
    melt,
    fireworks,
    supernova,
    blackhole,
    derez,
    miss,

    /// Effects whose size reaches well beyond the cap (limited by
    /// `Fx.big_unit_max`).
    fn screenScale(self: Kind) bool {
        return switch (self) {
            .supernova, .blackhole, .derez, .miss => true,
            else => false,
        };
    }

    fn fromEffect(e: Effect) Kind {
        return @fromBackingInt(@intCast(@backingInt(e)));
    }
};

comptime {
    // Kind mirrors model.Effect order for the first 13 entries.
    const info = @typeInfo(Effect).@"enum";
    for (info.field_names, info.field_values) |name, value| {
        if (!std.mem.eql(u8, name, @tagName(@as(Kind, @fromBackingInt(value))))) @compileError("Kind/Effect mismatch");
    }
}

/// Seconds each effect instance stays active (its particles may outlive it).
pub fn duration(e: Effect) f32 {
    return kindDuration(Kind.fromEffect(e));
}

fn kindDuration(k: Kind) f32 {
    return switch (k) {
        .shatter => 0.14,
        .confetti => 0.12,
        .voxel => 0.12,
        .pop => 0.38,
        .dust => 0.3,
        .glitch => 0.9,
        .lightning => 0.75,
        .frost => 1.0,
        .melt => 1.1,
        .fireworks => 0.95,
        .supernova => 1.4,
        .blackhole => 1.45,
        .derez => 1.25,
        .miss => 0.6,
    };
}

const Inst = struct {
    kind: Kind = .pop,
    active: bool = false,
    t: f32 = 0,
    dur: f32 = 1,
    cx: f32 = 0,
    cy: f32 = 0,
    w: f32 = 1,
    h: f32 = 1,
    /// Size unit: the cap height (px).
    u: f32 = 1,
    hue: f32 = 0,
    intensity: f32 = 0,
    look: CapLook = .{},
    text_buf: [15]u8 = undefined,
    text_len: u8 = 0,
    rng: Rng = .{ .s = 1 },
    seed: u32 = 0,
    /// One-shot event flags.
    done: u32 = 0,
    timer: f32 = 0,
    dir: f32 = 1,
    /// Generic accumulators (emission carry, seed points, ...).
    aux: [6]f32 = @splat(0),
    pts: [max_pts][2]f32 = undefined,
    npts: u16 = 0,
    /// Polyline boundaries inside `pts` (lightning / cracks).
    seg: [10]u16 = @splat(0),
    nseg: u8 = 0,

    fn text(self: *const Inst) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn once(self: *Inst, bit: u5) bool {
        const m = @as(u32, 1) << bit;
        if (self.done & m != 0) return false;
        self.done |= m;
        return true;
    }

    fn accent(self: *const Inst) Rgb {
        return color.accent(self.hue);
    }
};

const Wave = struct {
    active: bool = false,
    cx: f32 = 0,
    cy: f32 = 0,
    t: f32 = 0,
    dur: f32 = 0.95,
    max_r: f32 = 0,
    strength: f32 = 0,
    u: f32 = 1,
};

pub const Fx = struct {
    allocator: std.mem.Allocator,
    particles: particles.Pool,
    insts: []Inst,
    waves: [max_waves]Wave = @splat(.{}),
    rng: Rng,
    time: f32 = 0,
    /// Premultiplied additive flash color, decays quickly.
    flash_rgb: Rgb = Rgb.black,
    /// Shake amplitude in px, decays.
    shake_amp: f32 = 0,
    shake_dx: i32 = 0,
    shake_dy: i32 = 0,
    scratch: []Px = &.{},
    bloom: post_mod.Bloom,
    /// Bloom settings; scenes on tiny (half-block) surfaces should use .off/.low.
    bloom_quality: BloomQuality = .low,
    bloom_threshold: f32 = 0.7,
    bloom_strength: f32 = 0.65,
    /// Vignette strength applied in `post` (0 = none).
    vignette: f32 = 0,
    /// Deck top in px: voxels / shards bounce on it when set.
    floor_y: ?f32 = null,
    /// Default size unit (cap height, px) for effects spawned without a cap
    /// (missBurst, shockwave, shake). Set with `setCellPx`.
    unit: f32 = 16,
    /// Upper bound on the size unit of screen-scale effects (tier 3, miss
    /// burst, shockwaves): keeps them from swamping tiny surfaces. Set with
    /// `setSurfacePx`; infinite = no limit.
    big_unit_max: f32 = std.math.inf(f32),

    pub fn init(allocator: std.mem.Allocator) !Fx {
        return initCapacity(allocator, particles.default_capacity);
    }

    pub fn initCapacity(allocator: std.mem.Allocator, particle_capacity: usize) !Fx {
        var pool = try particles.Pool.init(allocator, particle_capacity);
        errdefer pool.deinit();
        const insts = try allocator.alloc(Inst, max_instances);
        @memset(insts, .{});
        return .{
            .allocator = allocator,
            .particles = pool,
            .insts = insts,
            .rng = Rng.init(0x5eed),
            .bloom = post_mod.Bloom.init(allocator),
        };
    }

    pub fn deinit(self: *Fx) void {
        self.particles.deinit();
        self.allocator.free(self.insts);
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.bloom.deinit();
    }

    /// Drop every effect, particle, wave, flash and shake.
    pub fn reset(self: *Fx) void {
        self.particles.clear();
        for (self.insts) |*i| i.active = false;
        for (&self.waves) |*w| w.active = false;
        self.flash_rgb = Rgb.black;
        self.shake_amp = 0;
        self.shake_dx = 0;
        self.shake_dy = 0;
    }

    /// Tell the engine the surface's pixels per terminal cell; the default
    /// unit becomes a 2-row cap height.
    pub fn setCellPx(self: *Fx, px_w: f32, px_h: f32) void {
        _ = px_w;
        self.unit = @max(px_h * 2, 2);
    }

    /// Tell the engine the surface size in px: screen-scale effects (tier 3,
    /// miss burst, shockwaves) are limited to a unit of 6.5% of the smaller
    /// dimension (never below 3 px).
    pub fn setSurfacePx(self: *Fx, w: f32, h: f32) void {
        self.big_unit_max = @max(3, @min(w, h) * 0.065);
    }

    /// Reseed (deterministic previews / tests).
    pub fn seed(self: *Fx, s: u32) void {
        self.rng = Rng.init(s);
    }

    /// True while anything is still animating.
    pub fn busy(self: *const Fx) bool {
        if (self.particles.len > 0) return true;
        for (self.insts) |i| if (i.active) return true;
        for (self.waves) |w| if (w.active) return true;
        return self.shake_amp > 0.3 or self.flash_rgb.luma() > 0.004;
    }

    pub fn activeEffects(self: *const Fx) usize {
        var n: usize = 0;
        for (self.insts) |i| n += @intFromBool(i.active);
        return n;
    }

    /// Spawn a hit effect for a cap with the default (letter) look.
    pub fn spawn(self: *Fx, effect: Effect, cx: f32, cy: f32, cap_w: f32, cap_h: f32, hue: f32, intensity: f32) void {
        self.spawnEx(effect, .{ .cx = cx, .cy = cy, .w = cap_w, .h = cap_h, .hue = hue, .intensity = intensity });
    }

    /// Spawn a hit effect with full parameters (cap look).
    pub fn spawnEx(self: *Fx, effect: Effect, sp: Spawn) void {
        self.start(Kind.fromEffect(effect), sp);
    }

    /// Red crack + sparks where a cap landed (miss). Uses `unit`.
    pub fn missBurst(self: *Fx, cx: f32, cy: f32) void {
        self.start(.miss, .{ .cx = cx, .cy = cy, .w = self.unit, .h = self.unit, .hue = 0.0, .intensity = 0.6 });
    }

    /// Radial displacement ring (max 4 alive; the oldest is replaced).
    /// `strength` 0..1 scales radius, displacement and ring light.
    pub fn shockwave(self: *Fx, cx: f32, cy: f32, strength: f32) void {
        self.shockwaveUnit(cx, cy, strength, boostUnit(self.unit));
    }

    fn shockwaveUnit(self: *Fx, cx: f32, cy: f32, strength: f32, u_in: f32) void {
        const u = @min(u_in, self.big_unit_max);
        var slot: *Wave = &self.waves[0];
        for (&self.waves) |*w| {
            if (!w.active) {
                slot = w;
                break;
            }
            if (w.t > slot.t) slot = w;
        }
        const st = sat(strength);
        slot.* = .{
            .active = true,
            .cx = cx,
            .cy = cy,
            .t = 0,
            .dur = 0.95,
            .max_r = u * (4.5 + 4.5 * st),
            .strength = st,
            .u = u,
        };
    }

    /// Additive full-screen flash of `c` (amount 0..1, decays in ~0.25 s).
    pub fn flash(self: *Fx, c: Rgb, amount: f32) void {
        self.flash_rgb = self.flash_rgb.add(c.scale(sat(amount))).clamp01();
    }

    /// Screen shake; amount 0..1 (≈ up to half a cap height), decays.
    pub fn shake(self: *Fx, amount: f32) void {
        self.shake_amp = @max(self.shake_amp, sat(amount) * self.unit * 0.45);
    }

    fn shakeUnit(self: *Fx, amount: f32, u: f32) void {
        self.shake_amp = @max(self.shake_amp, sat(amount) * u * 0.45);
    }

    /// Current shake offset in pixels (applied by `post`).
    pub fn shakeOffset(self: *const Fx) [2]i32 {
        return .{ self.shake_dx, self.shake_dy };
    }

    fn start(self: *Fx, kind: Kind, sp: Spawn) void {
        if (!(sp.w > 0 and sp.h > 0)) return;
        if (!(std.math.isFinite(sp.cx) and std.math.isFinite(sp.cy))) return;
        if (!(std.math.isFinite(sp.w) and std.math.isFinite(sp.h))) return;
        // free slot, else recycle the oldest
        var slot: *Inst = &self.insts[0];
        var found = false;
        for (self.insts) |*i| {
            if (!i.active) {
                slot = i;
                found = true;
                break;
            }
        }
        if (!found) {
            for (self.insts) |*i| {
                if (i.t / i.dur > slot.t / slot.dur) slot = i;
            }
        }
        const sd = self.rng.next();
        slot.* = .{
            .kind = kind,
            .active = true,
            .t = 0,
            .dur = kindDuration(kind),
            .cx = sp.cx,
            .cy = sp.cy,
            .w = sp.w,
            .h = sp.h,
            // Effects on tiny (half-block) caps get a bigger unit so they stay
            // readable: travel, rings and glows relative to the cap grow.
            .u = if (kind.screenScale()) @min(boostUnit(sp.h), self.big_unit_max) else boostUnit(sp.h),
            .hue = if (std.math.isFinite(sp.hue)) sp.hue else 0,
            .intensity = sat(sp.intensity),
            .look = sp.look,
            .rng = Rng.init(sd),
            .seed = sd,
        };
        var n = @min(sp.look.text.len, slot.text_buf.len);
        // don't cut a multi-byte codepoint (invalid UTF-8 draws nothing)
        if (n < sp.look.text.len) {
            while (n > 0 and sp.look.text[n] & 0xC0 == 0x80) n -= 1;
        }
        @memcpy(slot.text_buf[0..n], sp.look.text[0..n]);
        slot.text_len = @intCast(n);
        slot.look.text = "";
        self.begin(slot);
    }

    // -----------------------------------------------------------------------
    // Update
    // -----------------------------------------------------------------------

    pub fn update(self: *Fx, dt_in: f32) void {
        const dt = std.math.clamp(dt_in, 0, 0.1);
        if (dt == 0) return;
        self.time += dt;
        var attractors: [max_attractors]particles.Attractor = undefined;
        var na: usize = 0;
        for (self.insts) |*inst| {
            if (!inst.active) continue;
            const prev = inst.t;
            inst.t += dt;
            self.tick(inst, prev, dt);
            if (inst.kind == .blackhole and na < max_attractors) {
                const rh = blackholeRadius(inst);
                if (rh > 0.3) {
                    attractors[na] = .{
                        .x = inst.cx,
                        .y = inst.cy,
                        .strength = inst.u * 28 * (1 + inst.intensity),
                        .radius = rh * 4,
                        .kill_radius = rh * 0.85,
                        .swirl = 0.75,
                    };
                    na += 1;
                }
            }
            if (inst.t >= inst.dur) inst.active = false;
        }
        self.particles.update(dt, .{ .floor_y = self.floor_y, .attractors = attractors[0..na] });
        for (&self.waves) |*w| {
            if (!w.active) continue;
            w.t += dt;
            if (w.t >= w.dur) w.active = false;
        }
        const decay = @exp(-dt * 9.0);
        self.flash_rgb = self.flash_rgb.scale(decay);
        self.shake_amp *= @exp(-dt * 7.0);
        if (self.shake_amp < 0.35) self.shake_amp = 0;
        const step: u32 = @intFromFloat(@mod(self.time * 45, 1e6));
        const amp = @min(self.shake_amp, 4096); // keep the i32 conversion in range
        self.shake_dx = @intFromFloat(@round(amp * (rng_mod.hash01(step, 11) * 2 - 1)));
        self.shake_dy = @intFromFloat(@round(amp * 0.8 * (rng_mod.hash01(step, 23) * 2 - 1)));
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    /// Layer behind live caps: soft halos, smoke, under-particles.
    pub fn drawUnder(self: *Fx, s: *Surface) void {
        for (self.insts) |*inst| if (inst.active) drawInstUnder(s, inst);
        self.particles.draw(s, .under);
    }

    /// Layer above caps: effect cap renderings, bolts, particles.
    pub fn drawOver(self: *Fx, s: *Surface) void {
        for (self.insts) |*inst| if (inst.active) drawInstOver(s, inst);
        self.particles.draw(s, .over);
    }

    /// Post passes: shockwaves + lensing, glitch slices, bloom, vignette,
    /// shake, flash. Grows its scratch buffer only when the surface grows.
    pub fn post(self: *Fx, s: *Surface) void {
        if (s.w == 0 or s.h == 0) return;
        const need = s.pixels.len;
        if (self.scratch.len < need) {
            if (self.scratch.len > 0) self.allocator.free(self.scratch);
            self.scratch = self.allocator.alloc(Px, need) catch &.{};
        }
        const have_scratch = self.scratch.len >= need;

        var waves: [max_waves]post_mod.Shockwave = undefined;
        var nw: usize = 0;
        for (self.waves) |w| {
            if (!w.active) continue;
            const q = sat(w.t / w.dur);
            const e = 1 - (1 - q) * (1 - q) * (1 - q);
            const fade = (1 - q) * (1 - q);
            waves[nw] = .{
                .cx = w.cx,
                .cy = w.cy,
                .radius = w.max_r * e,
                .width = w.u * (0.7 + 0.5 * w.strength) * (1 - 0.4 * q) + 1,
                .amp = w.u * (0.25 + 0.35 * w.strength) * fade,
                .light = (0.12 + 0.6 * w.strength) * fade,
            };
            nw += 1;
        }
        var lenses: [max_lenses]post_mod.Lens = undefined;
        var nl: usize = 0;
        for (self.insts) |*inst| {
            if (!inst.active or inst.kind != .blackhole or nl >= max_lenses) continue;
            const rh = blackholeRadius(inst);
            if (rh < 0.4) continue;
            lenses[nl] = .{
                .cx = inst.cx,
                .cy = inst.cy,
                .horizon = rh,
                .einstein = rh * 1.7,
                .reach = rh * 5.5,
                .k = 1,
                .photon = 0.8 + 0.4 * inst.intensity,
            };
            nl += 1;
        }
        if (have_scratch) post_mod.displace(s, self.scratch, waves[0..nw], lenses[0..nl]);

        for (self.insts) |*inst| {
            if (!inst.active) continue;
            const amt = glitchAmount(inst);
            if (amt <= 0.01) continue;
            const pad_x = inst.u * 0.7;
            const pad_y = inst.u * 0.3;
            post_mod.glitch(s, .{
                .x = inst.cx - inst.w * 0.5 - pad_x,
                .y = inst.cy - inst.h * 0.5 - pad_y,
                .w = inst.w + pad_x * 2,
                .h = inst.h + pad_y * 2,
                .amount = amt,
                .unit = inst.u,
                .seed = inst.seed,
                .t = inst.t,
            });
        }

        self.bloom.apply(s, self.bloom_quality, self.bloom_threshold, self.bloom_strength);
        post_mod.vignette(s, self.vignette, pal.night.scale(0.4));
        if (have_scratch) post_mod.shift(s, self.scratch, self.shake_dx, self.shake_dy);
        if (self.flash_rgb.luma() > 0.003) post_mod.flash(s, self.flash_rgb, 1);
    }

    // -----------------------------------------------------------------------
    // Effect logic
    // -----------------------------------------------------------------------

    fn emit(self: *Fx, inst: *Inst, p: Particle) void {
        var q = p;
        q.seed = @truncate(inst.rng.next());
        _ = self.particles.emit(q);
    }

    /// Particle budget: base count scaled by intensity and resolution.
    fn count(self: *Fx, inst: *const Inst, base: f32) usize {
        const density = std.math.clamp(inst.u / 16.0, 0.35, 1.4);
        const n = base * density * (0.55 + 0.9 * inst.intensity);
        // Clamp before converting: extreme cap aspect ratios make `base` huge.
        const free: f32 = @floatFromInt(self.particles.free());
        return @intFromFloat(@min(@max(@round(n), 1), free));
    }

    fn begin(self: *Fx, inst: *Inst) void {
        switch (inst.kind) {
            .shatter => self.shatterBurst(inst, inst.look.top, inst.look.side, false),
            .confetti => self.beginConfetti(inst),
            .voxel => self.beginVoxel(inst),
            .pop => self.beginPop(inst),
            .dust => inst.dir = inst.rng.sign(),
            .glitch => {},
            .lightning => {
                genLightning(inst);
                self.flash(Rgb.init(0.65, 0.75, 1.0), 0.1 + 0.16 * inst.intensity);
                self.sparkBurst(inst, inst.cx, inst.cy, 26, 4, 12, Rgb.init(0.75, 0.85, 1), Rgb.init(0.3, 0.4, 1), true);
                self.shakeUnit(0.15 + 0.2 * inst.intensity, inst.u);
            },
            .frost => {
                genFrost(inst);
            },
            .melt => {},
            .fireworks => {
                self.sparkBurst(inst, inst.cx, inst.cy, 10, 2, 5, pal.amber, pal.coral, false);
            },
            .supernova => self.beginSupernova(inst),
            .blackhole => self.beginBlackhole(inst),
            .derez => {
                self.shakeUnit(0.25 + 0.2 * inst.intensity, inst.u);
                self.shockwaveUnit(inst.cx, inst.cy, 0.25, inst.u);
                self.flash(pal.derez, 0.06);
            },
            .miss => {
                genMiss(inst);
                self.flash(pal.miss, 0.12);
                self.shakeUnit(0.35, inst.u);
                self.sparkBurst(inst, inst.cx, inst.cy, 18, 3, 8, Rgb.init(1, 0.45, 0.35), pal.miss, true);
            },
        }
    }

    fn tick(self: *Fx, inst: *Inst, prev: f32, dt: f32) void {
        const t = inst.t;
        const u = inst.u;
        switch (inst.kind) {
            .dust => {
                if (t < 0.24) {
                    const rate = (260 + 420 * inst.intensity) * std.math.clamp(u / 16, 0.3, 1.3) * @max(inst.w / inst.h, 1) * 0.6;
                    inst.aux[0] += rate * dt;
                    while (inst.aux[0] >= 1) : (inst.aux[0] -= 1) self.dustSpeck(inst);
                }
            },
            .glitch => {
                if (t < 0.55) {
                    inst.aux[0] += (50 + 90 * inst.intensity) * dt;
                    while (inst.aux[0] >= 1) : (inst.aux[0] -= 1) {
                        if (self.particles.free() == 0) break;
                        const r = &inst.rng;
                        const c = switch (r.int(3)) {
                            0 => pal.glitch_cyan,
                            1 => pal.glitch_red,
                            else => Rgb.white,
                        };
                        const dir = r.sign();
                        const streak = r.chance(0.35);
                        self.emit(inst, .{
                            .x = inst.cx + r.signed() * inst.w * 0.6,
                            .y = inst.cy + r.signed() * inst.h * 0.6,
                            .vx = dir * u * r.range(4, 14),
                            .life = r.range(0.12, 0.32),
                            .size = @max(u * r.range(0.07, 0.18), 0.8),
                            .kind = if (streak) .streak else .square,
                            .stretch = 0.03,
                            .drag = 3,
                            .c0 = c,
                            .c1 = c,
                            .alpha = 0.9,
                            .blend = .add,
                        });
                    }
                }
            },
            .lightning => {
                if (t < 0.42) {
                    inst.timer += dt;
                    if (inst.timer >= 0.055) {
                        inst.timer = 0;
                        genLightning(inst);
                        if (inst.rng.chance(0.4)) self.flash(Rgb.init(0.6, 0.7, 1.0), 0.04 + 0.05 * inst.intensity);
                    }
                }
            },
            .frost => {
                if (t < 0.48) {
                    inst.aux[2] += (40 + 60 * inst.intensity) * dt * std.math.clamp(u / 16, 0.4, 1.3);
                    while (inst.aux[2] >= 1) : (inst.aux[2] -= 1) {
                        const r = &inst.rng;
                        const rf = frostFront(inst);
                        const a = r.range(0, 2 * pi);
                        const d = r.float() * rf;
                        const x = inst.aux[0] + @cos(a) * d;
                        const y = inst.aux[1] + @sin(a) * d;
                        if (@abs(x - inst.cx) > inst.w * 0.5 or @abs(y - inst.cy) > inst.h * 0.5) continue;
                        self.emit(inst, .{ .x = x, .y = y, .life = r.range(0.15, 0.35), .size = @max(u * 0.06, 0.5), .kind = .spark, .c0 = Rgb.white, .c1 = pal.ice_light, .twinkle = true, .attract = false });
                    }
                }
                if (t >= 0.48 and inst.once(0)) self.frostCrack(inst);
            },
            .melt => {
                if (t < 0.45) {
                    inst.aux[0] += (14 + 24 * inst.intensity) * dt * std.math.clamp(u / 16, 0.4, 1.3) * @max(inst.w / inst.h, 1);
                    while (inst.aux[0] >= 1) : (inst.aux[0] -= 1) {
                        const r = &inst.rng;
                        self.emit(inst, .{
                            .x = inst.cx + r.signed() * inst.w * 0.45,
                            .y = inst.cy + inst.h * 0.5,
                            .vy = u * r.range(0.5, 2),
                            .gravity = u * 14,
                            .life = r.range(0.35, 0.7),
                            .size = @max(u * r.range(0.05, 0.09), 0.5),
                            .kind = .spark,
                            .c0 = Rgb.hex(0xffb347),
                            .c1 = Rgb.hex(0xa0200c),
                            .bounce = true,
                        });
                    }
                }
                if (t >= 0.45 and inst.once(0)) {
                    const n = self.count(inst, 22 * @max(inst.w / inst.h, 1));
                    const r = &inst.rng;
                    for (0..n) |_| {
                        self.emit(inst, .{
                            .x = inst.cx + r.signed() * inst.w * 0.55,
                            .y = inst.cy + inst.h * 0.4,
                            .vx = r.signed() * u * 0.8,
                            .vy = -u * r.range(1, 3),
                            .gravity = -u * 1.5,
                            .drag = 1.2,
                            .flutter = u * 6,
                            .life = r.range(0.5, 1.1),
                            .size = @max(u * r.range(0.04, 0.08), 0.5),
                            .kind = .spark,
                            .c0 = pal.amber,
                            .c1 = Rgb.hex(0xff3a10),
                            .twinkle = r.chance(0.5),
                        });
                    }
                    for (0..@min(@as(usize, 5), self.particles.free())) |_| {
                        self.emit(inst, .{
                            .x = inst.cx + r.signed() * inst.w * 0.4,
                            .y = inst.cy + inst.h * 0.3,
                            .vy = -u * r.range(0.8, 1.6),
                            .drag = 1,
                            .life = r.range(0.6, 1.0),
                            .size = u * 0.35,
                            .size_end = 3,
                            .kind = .smoke,
                            .c0 = Rgb.hex(0x3a2a2a),
                            .c1 = Rgb.hex(0x1a1420),
                            .alpha = 0.35,
                            .blend = .over,
                            .layer = .under,
                        });
                    }
                }
            },
            .fireworks => {
                const rise_t: f32 = 0.34;
                if (t < rise_t) {
                    const pos = fireworksRocket(inst);
                    inst.aux[0] += 150 * dt * std.math.clamp(u / 16, 0.4, 1.2);
                    while (inst.aux[0] >= 1) : (inst.aux[0] -= 1) {
                        const r = &inst.rng;
                        self.emit(inst, .{
                            .x = pos[0] + r.signed() * u * 0.08,
                            .y = pos[1] + r.float() * u * 0.3,
                            .vx = r.signed() * u * 0.6,
                            .vy = u * r.range(0.2, 1.5),
                            .gravity = u * 5,
                            .life = r.range(0.18, 0.4),
                            .size = @max(u * 0.05, 0.5),
                            .kind = .spark,
                            .c0 = pal.amber,
                            .c1 = Rgb.hex(0xff4a1a),
                            .twinkle = r.chance(0.3),
                        });
                    }
                }
                if (t >= rise_t and inst.once(0)) self.fireworksBurst(inst);
            },
            .supernova => {
                if (t < 0.42) {
                    self.shake_amp = @max(self.shake_amp, u * 0.08 * (0.5 + inst.intensity) * (t / 0.42));
                }
                if (t >= 0.42 and inst.once(0)) self.supernovaBurst(inst);
            },
            .blackhole => {
                const rh = blackholeRadius(inst);
                if (t > 0.15 and t < 1.0 and rh > 0.3) {
                    inst.aux[0] += (30 + 50 * inst.intensity) * dt * std.math.clamp(u / 16, 0.35, 1.2);
                    while (inst.aux[0] >= 1) : (inst.aux[0] -= 1) {
                        const r = &inst.rng;
                        const a = r.range(0, 2 * pi);
                        const d = rh * r.range(3.5, 5.5);
                        const sp = u * r.range(1.5, 3);
                        self.emit(inst, .{
                            .x = inst.cx + @cos(a) * d,
                            .y = inst.cy + @sin(a) * d,
                            .vx = -@sin(a) * sp,
                            .vy = @cos(a) * sp,
                            .life = r.range(0.6, 1.0),
                            .size = @max(u * r.range(0.04, 0.08), 0.5),
                            .kind = .spark,
                            .stretch = 0.03,
                            .c0 = if (r.chance(0.6)) pal.amber else Rgb.white,
                            .c1 = Rgb.hex(0xff5a1a),
                            .fade_in = 0.1,
                        });
                    }
                }
                if (t >= 1.12 and inst.once(0)) {
                    self.flash(Rgb.init(1, 0.85, 0.6), 0.14 + 0.1 * inst.intensity);
                    self.shockwaveUnit(inst.cx, inst.cy, 0.35 + 0.3 * inst.intensity, u);
                    self.shakeUnit(0.35 + 0.3 * inst.intensity, u);
                }
                if (t >= 1.3 and inst.once(1)) {
                    self.sparkBurst(inst, inst.cx, inst.cy, 40, 4, 11, pal.amber, Rgb.hex(0xff4a1a), true);
                }
            },
            .derez => {
                const d0 = derezProgress(prev);
                const d1 = derezProgress(t);
                if (d1 > d0) self.derezDetach(inst, d0, d1);
            },
            else => {},
        }
    }

    fn sparkBurst(self: *Fx, inst: *Inst, x: f32, y: f32, base: f32, smin: f32, smax: f32, c0: Rgb, c1: Rgb, streak: bool) void {
        const n = self.count(inst, base);
        const r = &inst.rng;
        const u = inst.u;
        for (0..n) |_| {
            const a = r.range(0, 2 * pi);
            const sp = u * r.range(smin, smax);
            self.emit(inst, .{
                .x = x,
                .y = y,
                .vx = @cos(a) * sp,
                .vy = @sin(a) * sp,
                .gravity = u * 6,
                .drag = 2.5,
                .life = r.range(0.25, 0.5),
                .size = @max(u * r.range(0.04, 0.08), 0.5),
                .kind = .spark,
                .stretch = if (streak) 0.035 else 0,
                .c0 = c0,
                .c1 = c1,
            });
        }
    }

    /// Break the cap rectangle into jittered triangles flying apart.
    fn shatterBurst(self: *Fx, inst: *Inst, top: Rgb, side: Rgb, ice: bool) void {
        const u = inst.u;
        const r = &inst.rng;
        const extra: f32 = @round(inst.intensity * 2);
        const nx: usize = @intFromFloat(std.math.clamp(@round(inst.w / (u * 0.42)) + extra, 2, 14));
        const ny: usize = @intFromFloat(std.math.clamp(@round(inst.h / (u * 0.5)) + @round(extra * 0.5), 2, 5));
        var grid: [15 * 6][2]f32 = undefined;
        const x0 = inst.cx - inst.w * 0.5;
        const y0 = inst.cy - inst.h * 0.5;
        const cw = inst.w / @as(f32, @floatFromInt(nx));
        const ch = inst.h / @as(f32, @floatFromInt(ny));
        for (0..ny + 1) |j| for (0..nx + 1) |i| {
            var px = x0 + @as(f32, @floatFromInt(i)) * cw;
            var py = y0 + @as(f32, @floatFromInt(j)) * ch;
            if (i > 0 and i < nx) px += r.signed() * cw * 0.35;
            if (j > 0 and j < ny) py += r.signed() * ch * 0.35;
            grid[j * (nx + 1) + i] = .{ px, py };
        };
        const side_y = inst.cy + inst.h * 0.5 - inst.h * 0.2;
        const k = 0.55 + 0.5 * inst.intensity;
        for (0..ny) |j| for (0..nx) |i| {
            const a = grid[j * (nx + 1) + i];
            const b = grid[j * (nx + 1) + i + 1];
            const c = grid[(j + 1) * (nx + 1) + i];
            const d = grid[(j + 1) * (nx + 1) + i + 1];
            const flip = (i + j) % 2 == 0;
            const tris = if (flip) [2][3][2]f32{ .{ a, b, d }, .{ a, d, c } } else [2][3][2]f32{ .{ a, b, c }, .{ b, d, c } };
            for (tris) |tri| {
                if (self.particles.free() == 0) return;
                const gx = (tri[0][0] + tri[1][0] + tri[2][0]) / 3;
                const gy = (tri[0][1] + tri[1][1] + tri[2][1]) / 3;
                var ext: f32 = 0.01;
                for (tri) |p| ext = @max(ext, @max(@abs(p[0] - gx), @abs(p[1] - gy)));
                var shape: [6]i8 = undefined;
                for (tri, 0..) |p, vi| {
                    shape[vi * 2] = @intFromFloat(std.math.clamp((p[0] - gx) / ext * 127, -127, 127));
                    shape[vi * 2 + 1] = @intFromFloat(std.math.clamp((p[1] - gy) / ext * 127, -127, 127));
                }
                const nxr = (gx - inst.cx) / (inst.w * 0.5);
                const nyr = (gy - inst.cy) / (inst.h * 0.5);
                var col = if (gy > side_y) side else top.lighten(r.range(0, 0.12));
                if (!ice and r.chance(0.28)) col = inst.accent().lighten(r.range(0.1, 0.4));
                if (ice) col = switch (r.int(3)) {
                    0 => pal.ice_light,
                    1 => pal.ice,
                    else => Rgb.white,
                };
                self.emit(inst, .{
                    .x = gx,
                    .y = gy,
                    .vx = (nxr * r.range(2, 5) + r.signed()) * u * k,
                    .vy = (nyr * r.range(1, 2.5) - r.range(2, 5)) * u * k,
                    .gravity = u * 16,
                    .drag = 0.6,
                    .spin = r.signed() * 12,
                    .tumble = 0,
                    .tumble_rate = r.signed() * 14,
                    .life = r.range(0.55, 0.95) + 0.2 * inst.intensity,
                    .size = ext,
                    .size_end = 0.7,
                    .kind = .shard,
                    .blend = .over,
                    .c0 = col,
                    .c1 = if (ice) pal.ice else col.scale(0.8),
                    .alpha = if (ice) 0.9 else 1,
                    .fade_out = 0.3,
                    .bounce = true,
                    .shape = shape,
                });
            }
        };
        self.sparkBurst(inst, inst.cx, inst.cy, 10, 4, 9, if (ice) pal.ice_light else inst.accent().lighten(0.3), if (ice) pal.ice else inst.accent(), true);
    }

    fn beginConfetti(self: *Fx, inst: *Inst) void {
        const colors = [_]Rgb{ pal.coral, pal.amber, pal.teal, Rgb.hex(0x4f8dff), Rgb.hex(0x9a6bff), Rgb.hex(0xff5fa2), Rgb.hex(0xb8f35a), pal.cream };
        const aspect = std.math.clamp(inst.w / inst.h, 1, 4);
        const n = self.count(inst, (26 + 24 * inst.intensity) * @sqrt(aspect) * 1.4);
        const r = &inst.rng;
        const u = inst.u;
        for (0..n) |_| {
            const fx = r.signed();
            const c0 = colors[r.int(colors.len)];
            const c1 = if (r.chance(0.5)) c0.scale(0.6) else colors[r.int(colors.len)].scale(0.85);
            self.emit(inst, .{
                .x = inst.cx + fx * inst.w * 0.45,
                .y = inst.cy + r.signed() * inst.h * 0.4,
                .vx = (r.signed() * 3.5 + fx * 1.5) * u,
                .vy = -u * r.range(8, 14) * (0.8 + 0.4 * inst.intensity),
                .gravity = u * 10,
                .drag = 1.9,
                .flutter = u * 30,
                .rot = r.range(0, pi),
                .spin = r.signed() * 6,
                .tumble = r.range(0, 2 * pi),
                .tumble_rate = r.sign() * r.range(6, 14),
                .life = r.range(1.1, 1.7),
                .size = @max(u * r.range(0.16, 0.26), 0.9),
                .kind = .confetti,
                .blend = .over,
                .c0 = c0,
                .c1 = c1,
                .fade_out = 0.25,
            });
        }
        self.emit(inst, .{ .x = inst.cx, .y = inst.cy, .life = 0.16, .size = u * 1.2, .size_end = 1.4, .kind = .glow, .c0 = Rgb.white, .c1 = inst.accent(), .alpha = 0.35 });
    }

    fn beginVoxel(self: *Fx, inst: *Inst) void {
        const u = inst.u;
        var bs = @max(u * 0.26, 1);
        // keep the grid ≤ ~240 blocks
        while ((inst.w / bs) * (inst.h / bs) > 240) bs *= 1.2;
        const nx: usize = @intFromFloat(@max(@ceil(inst.w / bs), 1));
        const ny: usize = @intFromFloat(@max(@ceil(inst.h / bs), 1));
        const r = &inst.rng;
        const x0 = inst.cx - inst.w * 0.5;
        const y0 = inst.cy - inst.h * 0.5;
        const k = 0.7 + 0.6 * inst.intensity;
        const side_row = @as(f32, @floatFromInt(ny)) * 0.8;
        for (0..ny) |j| for (0..nx) |i| {
            if (self.particles.free() == 0) return;
            const fx = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(nx));
            const fy = (@as(f32, @floatFromInt(j)) + 0.5) / @as(f32, @floatFromInt(ny));
            // skip the rounded corners
            const ex = @abs(fx - 0.5) * 2;
            const ey = @abs(fy - 0.5) * 2;
            if (ex > 0.8 and ey > 0.8 and (ex - 0.8) * (ex - 0.8) + (ey - 0.8) * (ey - 0.8) > 0.04) continue;
            const px = x0 + (@as(f32, @floatFromInt(i)) + 0.5) * bs;
            const py = y0 + (@as(f32, @floatFromInt(j)) + 0.5) * bs;
            var c = if (@as(f32, @floatFromInt(j)) >= side_row) inst.look.side else inst.look.top.lighten(0.1 * (1 - fy));
            if (r.chance(0.12)) c = c.scale(0.85);
            const nxr = (px - inst.cx) / (inst.w * 0.5);
            const nyr = (py - inst.cy) / (inst.h * 0.5);
            self.emit(inst, .{
                .x = px,
                .y = py,
                .vx = (nxr * r.range(0.5, 2.5) + r.signed() * 0.5) * u * k,
                .vy = (nyr * 0.8 - r.range(1, 4)) * u * k,
                .gravity = u * 18,
                .drag = 0.5,
                .spin = if (bs >= 5) r.signed() * 8 else 0,
                .rot = 0,
                .life = r.range(0.6, 1.1),
                .size = bs * 0.92,
                .size_end = 0.6,
                .kind = .square,
                .blend = .over,
                .c0 = c,
                .c1 = c.scale(0.7),
                .bounce = true,
                .fade_out = 0.3,
            });
        };
        self.emit(inst, .{ .x = inst.cx, .y = inst.cy, .life = 0.12, .size = u * 1.1, .kind = .glow, .c0 = Rgb.white, .c1 = inst.accent(), .alpha = 0.25 });
    }

    fn beginPop(self: *Fx, inst: *Inst) void {
        const u = inst.u;
        const r = &inst.rng;
        const n = self.count(inst, 12 + 6 * @max(inst.w / inst.h, 1));
        const pale = inst.accent().lighten(0.6);
        for (0..n) |i| {
            const a = (@as(f32, @floatFromInt(i)) + r.float() * 0.6) / @as(f32, @floatFromInt(n)) * 2 * pi;
            const ex = @cos(a) * inst.w * 0.55;
            const ey = @sin(a) * inst.h * 0.55;
            self.emit(inst, .{
                .x = inst.cx + ex,
                .y = inst.cy + ey,
                .vx = @cos(a) * u * r.range(2, 4.5),
                .vy = @sin(a) * u * r.range(2, 4.5) - u * 0.5,
                .drag = 4.5,
                .life = r.range(0.4, 0.65),
                .size = @max(u * 0.28, 0.8),
                .size_end = 2.6,
                .kind = .smoke,
                .c0 = pale,
                .c1 = inst.accent(),
                .alpha = 0.3,
                .blend = .add,
                .fade_out = 0.6,
            });
        }
        self.sparkBurst(inst, inst.cx, inst.cy, 10, 3, 7, inst.accent().lighten(0.4), inst.accent(), false);
    }

    fn dustSpeck(self: *Fx, inst: *Inst) void {
        if (self.particles.free() == 0) return;
        const r = &inst.rng;
        const u = inst.u;
        const p = sat(inst.t / 0.22);
        // the wipe travels from the trailing edge to the leading edge
        const lead = inst.dir;
        const fx = std.math.clamp(-lead * (1 - 2 * p) + r.signed() * 0.35, -1, 1);
        const glowy = r.chance(0.7);
        const c = if (glowy) (if (r.chance(0.5)) inst.accent().lighten(0.35) else Rgb.white) else inst.look.top;
        self.emit(inst, .{
            .x = inst.cx + fx * inst.w * 0.5,
            .y = inst.cy + r.signed() * inst.h * 0.45,
            .vx = lead * u * r.range(4, 16),
            .vy = r.range(-1.8, 0.5) * u,
            .gravity = -u * 0.8,
            .drag = 1.8,
            .flutter = u * 3,
            .life = r.range(0.6, 1.3),
            .size = @max(u * r.range(0.035, 0.085), 0.45),
            .kind = if (glowy) .spark else .dot,
            .blend = if (glowy) .add else .over,
            .c0 = c,
            .c1 = if (glowy) inst.accent() else c.scale(0.7),
            .twinkle = r.chance(0.4),
        });
    }

    fn frostCrack(self: *Fx, inst: *Inst) void {
        self.shatterBurst(inst, pal.ice_light, pal.ice, true);
        const r = &inst.rng;
        const u = inst.u;
        const n = self.count(inst, 26);
        for (0..n) |_| {
            const a = r.range(0, 2 * pi);
            const sp = u * r.range(1, 5);
            self.emit(inst, .{
                .x = inst.cx + r.signed() * inst.w * 0.4,
                .y = inst.cy + r.signed() * inst.h * 0.4,
                .vx = @cos(a) * sp,
                .vy = @sin(a) * sp - u,
                .gravity = u * 3,
                .drag = 2.5,
                .life = r.range(0.4, 0.9),
                .size = @max(u * 0.05, 0.5),
                .kind = .spark,
                .c0 = Rgb.white,
                .c1 = pal.ice,
                .twinkle = true,
            });
        }
        for (0..@min(@as(usize, 6), self.particles.free())) |_| {
            self.emit(inst, .{
                .x = inst.cx + r.signed() * inst.w * 0.4,
                .y = inst.cy + r.signed() * inst.h * 0.3,
                .vx = r.signed() * u,
                .vy = -u * r.range(0.3, 1),
                .drag = 1.5,
                .life = r.range(0.6, 1.0),
                .size = u * 0.4,
                .size_end = 3,
                .kind = .smoke,
                .c0 = pal.ice_light,
                .c1 = pal.ice,
                .alpha = 0.22,
                .blend = .over,
            });
        }
        self.emit(inst, .{ .x = inst.cx, .y = inst.cy, .life = 0.2, .size = u * 1.6, .kind = .glow, .c0 = Rgb.white, .c1 = pal.ice, .alpha = 0.6 });
    }

    fn fireworksBurst(self: *Fx, inst: *Inst) void {
        const pos = fireworksRocket(inst);
        const r = &inst.rng;
        const u = inst.u;
        const n = self.count(inst, 90 + 70 * inst.intensity);
        const main_c = color.hsv(inst.hue, 0.7, 1);
        const second = if (r.chance(0.5)) color.hsv(inst.hue + 0.5, 0.6, 1) else pal.amber.lighten(0.3);
        const speed = u * (5.5 + 2.5 * inst.intensity);
        for (0..n) |_| {
            const a = r.range(0, 2 * pi);
            // shell: most particles near full speed
            const sp = speed * (1 - r.float() * r.float() * 0.6);
            const alt = r.chance(0.3);
            self.emit(inst, .{
                .x = pos[0],
                .y = pos[1],
                .vx = @cos(a) * sp,
                .vy = @sin(a) * sp,
                .gravity = u * 3.5,
                .drag = 1.6,
                .life = r.range(0.8, 1.3),
                .size = @max(u * 0.06, 0.5),
                .kind = .spark,
                .stretch = 0.035,
                .c0 = if (alt) second else main_c.lighten(0.25),
                .c1 = if (alt) second.scale(0.6) else color.hsv(inst.hue + 0.05, 0.9, 0.7),
                .twinkle = r.chance(0.35),
                .fade_out = 0.5,
            });
        }
        self.emit(inst, .{ .x = pos[0], .y = pos[1], .life = 0.22, .size = u * 2, .size_end = 1.4, .kind = .glow, .c0 = Rgb.white, .c1 = main_c, .alpha = 0.5 });
        self.flash(main_c, 0.05 + 0.06 * inst.intensity);
    }

    fn beginSupernova(self: *Fx, inst: *Inst) void {
        const r = &inst.rng;
        const u = inst.u;
        const n = @min(@as(usize, @intFromFloat(46 * std.math.clamp(u / 16 + 0.3, 0.5, 1.2))), self.particles.free());
        for (0..n) |_| {
            const a = r.range(0, 2 * pi);
            const d = u * r.range(2.2, 3.8);
            const v = d / 0.42 * r.range(0.9, 1.05);
            self.emit(inst, .{
                .x = inst.cx + @cos(a) * d,
                .y = inst.cy + @sin(a) * d,
                .vx = -@cos(a) * v,
                .vy = -@sin(a) * v,
                .life = 0.42,
                .size = @max(u * 0.05, 0.5),
                .kind = .spark,
                .stretch = 0.05,
                .c0 = inst.accent().lighten(0.3),
                .c1 = Rgb.white,
                .fade_in = 0.08,
                .fade_out = 0.1,
                .attract = false,
            });
        }
    }

    fn supernovaBurst(self: *Fx, inst: *Inst) void {
        const r = &inst.rng;
        const u = inst.u;
        self.shockwaveUnit(inst.cx, inst.cy, 0.6 + 0.4 * inst.intensity, u);
        self.flash(Rgb.init(1, 0.93, 0.85), 0.07 + 0.1 * inst.intensity);
        self.shakeUnit(0.6 + 0.4 * inst.intensity, u);
        const n = self.count(inst, 150);
        const acc = inst.accent();
        const comp = color.accent(inst.hue + 0.5);
        for (0..n) |i| {
            const a = r.range(0, 2 * pi);
            const kind_roll = r.float();
            const fast = kind_roll < 0.15;
            const sp = u * (if (fast) r.range(10, 16) else r.range(3, 11));
            self.emit(inst, .{
                .x = inst.cx,
                .y = inst.cy,
                .vx = @cos(a) * sp,
                .vy = @sin(a) * sp,
                .gravity = u * 1.5,
                .drag = 2,
                .life = r.range(0.6, 1.25),
                .size = @max(u * (if (kind_roll > 0.75) r.range(0.08, 0.13) else r.range(0.04, 0.07)), 0.5),
                .kind = .spark,
                .stretch = if (kind_roll > 0.75) 0 else 0.04,
                .c0 = if (fast) Rgb.white else if (i % 3 == 0) comp.lighten(0.2) else acc.lighten(0.3),
                .c1 = if (i % 3 == 0) comp else acc.scale(0.7),
                .twinkle = kind_roll > 0.85,
                .fade_out = 0.5,
            });
        }
    }

    fn beginBlackhole(self: *Fx, inst: *Inst) void {
        const r = &inst.rng;
        const u = inst.u;
        const n = self.count(inst, 36);
        const rh_max = blackholeMax(inst);
        for (0..n) |_| {
            const a = r.range(0, 2 * pi);
            const d = rh_max * r.range(1.8, 4.5);
            const sp = u * r.range(2, 4);
            self.emit(inst, .{
                .x = inst.cx + @cos(a) * d,
                .y = inst.cy + @sin(a) * d,
                .vx = -@sin(a) * sp,
                .vy = @cos(a) * sp,
                .life = r.range(0.9, 1.4),
                .size = @max(u * r.range(0.04, 0.09), 0.5),
                .kind = .spark,
                .stretch = 0.03,
                .c0 = if (r.chance(0.5)) pal.amber else inst.look.top,
                .c1 = Rgb.hex(0xff4a1a),
                .fade_in = 0.05,
            });
        }
        self.shakeUnit(0.3 + 0.2 * inst.intensity, u);
    }

    fn derezDetach(self: *Fx, inst: *Inst, d0: f32, d1: f32) void {
        const g = derezGrid(inst);
        const r = &inst.rng;
        const u = inst.u;
        var j: u32 = 0;
        while (j < g.ny) : (j += 1) {
            var i: u32 = 0;
            while (i < g.nx) : (i += 1) {
                const th = derezThreshold(inst, i, j, g.ny);
                if (th <= d0 or th > d1) continue;
                if (!derezInside(inst, g, i, j)) continue;
                if (self.particles.free() == 0) return;
                const bx = g.x0 + (@as(f32, @floatFromInt(i)) + 0.5) * g.bs;
                const by = g.y0 + (@as(f32, @floatFromInt(j)) + 0.5) * g.bs;
                self.emit(inst, .{
                    .x = bx,
                    .y = by,
                    .vx = r.signed() * u * 0.6,
                    .vy = -u * r.range(1.2, 3.5),
                    .gravity = -u * 2,
                    .drag = 0.8,
                    .life = r.range(0.4, 0.85),
                    .size = g.bs * 0.9,
                    .size_end = 0.5,
                    .kind = .square,
                    .blend = .add,
                    .c0 = pal.derez.lighten(0.35),
                    .c1 = Rgb.init(0.0, 0.35, 0.6),
                    .twinkle = r.chance(0.3),
                    .attract = false,
                });
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Per-effect geometry helpers (pure functions of the instance)
// ---------------------------------------------------------------------------

/// Size unit for a cap of height h: the cap height, enlarged for tiny caps.
fn boostUnit(h: f32) f32 {
    return @max(h, @min(9, h * 2.2));
}

fn easeOut(t: f32) f32 {
    const q = 1 - sat(t);
    return 1 - q * q * q;
}

fn easeIn(t: f32) f32 {
    const q = sat(t);
    return q * q * q;
}

fn easeOutBack(t: f32) f32 {
    const q = sat(t) - 1;
    const c = 1.7;
    return 1 + (c + 1) * q * q * q + c * q * q;
}

fn blackholeMax(inst: *const Inst) f32 {
    return inst.u * 0.55 * (1 + 0.35 * inst.intensity);
}

fn blackholeRadius(inst: *const Inst) f32 {
    const t = inst.t;
    const m = blackholeMax(inst);
    if (t < 0.25) return m * @max(easeOutBack(t / 0.25), 0);
    if (t < 1.12) return m * (1 + 0.04 * @sin(t * 18));
    return m * (1 - easeIn((t - 1.12) / 0.18));
}

fn glitchAmount(inst: *const Inst) f32 {
    const t = inst.t;
    return switch (inst.kind) {
        .glitch => if (t < 0.26) 0.45 + 0.55 * t / 0.26 else 1 - smoothstep(0.26, 0.85, t),
        .derez => if (t > 0.08 and t < 0.5) 0.35 * (1 - smoothstep(0.3, 0.5, t)) else 0,
        else => 0,
    };
}

fn fireworksRocket(inst: *const Inst) [2]f32 {
    const rise = @max(@min(inst.u * 3.4 * (0.8 + 0.4 * inst.intensity), inst.cy - inst.u), inst.u * 0.5);
    const p = easeOut(inst.t / 0.34);
    return .{ inst.cx + @sin(inst.t * 30) * inst.u * 0.05, inst.cy - rise * p };
}

fn frostFront(inst: *const Inst) f32 {
    return inst.aux[3] * easeOut(inst.t / 0.44);
}

fn derezProgress(t: f32) f32 {
    return sat((t - 0.15) / 0.57);
}

const DerezGrid = struct { x0: f32, y0: f32, bs: f32, nx: u32, ny: u32 };

fn derezGrid(inst: *const Inst) DerezGrid {
    // Smallest whole block size ≥ the unit-based one that keeps the grid
    // within 64 × 24 (closed form; a += 1 loop never ends for huge caps).
    const bs = @max(@max(@round(inst.u * 0.16), 1), @max(@ceil(inst.w / 64), @ceil(inst.h / 24)));
    const nx: u32 = @intFromFloat(@max(@ceil(inst.w / bs), 1));
    const ny: u32 = @intFromFloat(@max(@ceil(inst.h / bs), 1));
    return .{
        .x0 = inst.cx - @as(f32, @floatFromInt(nx)) * bs * 0.5,
        .y0 = inst.cy - @as(f32, @floatFromInt(ny)) * bs * 0.5,
        .bs = bs,
        .nx = nx,
        .ny = ny,
    };
}

fn derezThreshold(inst: *const Inst, i: u32, j: u32, ny: u32) f32 {
    // top rows dissolve first, with noise
    const row = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(@max(ny, 1)));
    return 0.02 + 0.55 * rng_mod.hash01(inst.seed +% i, j) + 0.42 * row;
}

fn derezInside(inst: *const Inst, g: DerezGrid, i: u32, j: u32) bool {
    const bx = g.x0 + (@as(f32, @floatFromInt(i)) + 0.5) * g.bs;
    const by = g.y0 + (@as(f32, @floatFromInt(j)) + 0.5) * g.bs;
    const r = @min(inst.w, inst.h) * 0.18;
    return canvas.sdRoundBox(bx - inst.cx, by - inst.cy, inst.w * 0.5, inst.h * 0.5, r) < g.bs * 0.3;
}

/// Midpoint-displacement jagged polyline a→b with 2^levels segments,
/// written to `out`; returns the point count.
fn bolt(r: *Rng, out: [][2]f32, a: [2]f32, b: [2]f32, levels: u3, rough: f32) usize {
    const n: usize = @as(usize, 1) << levels;
    if (out.len < n + 1) return 0;
    out[0] = a;
    out[n] = b;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    var disp = @sqrt(dx * dx + dy * dy) * rough;
    var stepw = n;
    while (stepw > 1) : (stepw /= 2) {
        var i: usize = 0;
        while (i < n) : (i += stepw) {
            const p = out[i];
            const q = out[i + stepw];
            const vx = q[0] - p[0];
            const vy = q[1] - p[1];
            const l = @sqrt(vx * vx + vy * vy) + 1e-6;
            const off = r.signed() * disp;
            out[i + stepw / 2] = .{ (p[0] + q[0]) * 0.5 - vy / l * off, (p[1] + q[1]) * 0.5 + vx / l * off };
        }
        disp *= 0.55;
    }
    return n + 1;
}

fn genLightning(inst: *Inst) void {
    const r = &inst.rng;
    const u = inst.u;
    const top: [2]f32 = .{ inst.cx + r.signed() * u * 2.5, -2 };
    const target: [2]f32 = .{ inst.cx + r.signed() * inst.w * 0.15, inst.cy };
    var n: usize = 0;
    inst.nseg = 0;
    const len = @max(target[1] - top[1], u);
    const levels: u3 = if (len > u * 8) 6 else if (len > u * 3) 5 else 4;
    n += bolt(r, inst.pts[n..], top, target, levels, 0.11);
    inst.seg[0] = 0;
    inst.seg[1] = @intCast(n);
    inst.nseg = 1;
    const main_n = n;
    // two side branches
    for (0..2) |_| {
        const k = @as(usize, @intFromFloat(r.range(0.25, 0.75) * @as(f32, @floatFromInt(main_n - 1))));
        const p = inst.pts[k];
        const q = inst.pts[@min(k + 1, main_n - 1)];
        const ang = std.math.atan2(q[1] - p[1], q[0] - p[0]) + r.sign() * r.range(0.4, 0.9);
        const bl = (target[1] - p[1]) * r.range(0.25, 0.45) + u;
        const end: [2]f32 = .{ p[0] + @cos(ang) * bl, p[1] + @sin(ang) * bl };
        const m = bolt(r, inst.pts[n..], p, end, 4, 0.14);
        if (m == 0) break;
        n += m;
        inst.nseg += 1;
        inst.seg[inst.nseg] = @intCast(n);
    }
    // short fork below the cap
    const tail_end: [2]f32 = .{ target[0] + r.signed() * u, target[1] + u * r.range(1.0, 1.8) };
    const m = bolt(r, inst.pts[n..], target, tail_end, 3, 0.2);
    if (m > 0) {
        n += m;
        inst.nseg += 1;
        inst.seg[inst.nseg] = @intCast(n);
    }
    inst.npts = @intCast(n);
}

fn genFrost(inst: *Inst) void {
    const r = &inst.rng;
    const sx = inst.cx + r.signed() * inst.w * 0.15;
    const sy = inst.cy + r.signed() * inst.h * 0.15;
    inst.aux[0] = sx;
    inst.aux[1] = sy;
    // front must reach the farthest corner
    var far: f32 = 0;
    for ([_]f32{ -1, 1 }) |ax| for ([_]f32{ -1, 1 }) |ay| {
        const dx = inst.cx + ax * inst.w * 0.5 - sx;
        const dy = inst.cy + ay * inst.h * 0.5 - sy;
        far = @max(far, @sqrt(dx * dx + dy * dy));
    };
    inst.aux[3] = far * 1.05;
    // crystal segments (pairs of points)
    var n: usize = 0;
    const rays: usize = 7;
    const reach = @max(inst.w, inst.h) * 0.6;
    for (0..rays) |k| {
        var a = (@as(f32, @floatFromInt(k)) + r.range(-0.3, 0.3)) / @as(f32, @floatFromInt(rays)) * 2 * pi;
        var p: [2]f32 = .{ sx, sy };
        const seg_len = reach * r.range(0.22, 0.32);
        for (0..4) |si| {
            a += r.signed() * 0.25;
            const q: [2]f32 = .{ p[0] + @cos(a) * seg_len, p[1] + @sin(a) * seg_len };
            if (n + 2 > max_pts) break;
            inst.pts[n] = p;
            inst.pts[n + 1] = q;
            n += 2;
            if (si == 1 or si == 2) {
                for ([_]f32{ -1, 1 }) |side| {
                    const ba = a + side * r.range(0.6, 1.0);
                    const bl = seg_len * r.range(0.4, 0.7);
                    if (n + 2 > max_pts) break;
                    inst.pts[n] = q;
                    inst.pts[n + 1] = .{ q[0] + @cos(ba) * bl, q[1] + @sin(ba) * bl };
                    n += 2;
                }
            }
            p = q;
        }
    }
    inst.npts = @intCast(n);
}

fn genMiss(inst: *Inst) void {
    const r = &inst.rng;
    const u = inst.u;
    var n: usize = 0;
    inst.nseg = 0;
    inst.seg[0] = 0;
    const rays: usize = 7;
    for (0..rays) |k| {
        // mostly upward (deck surface), a couple sideways/down
        const base = -pi + (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(rays)) * pi;
        const a = if (k == 0) r.range(0.2, 0.6) else if (k == rays - 1) pi - r.range(0.2, 0.6) else base + r.signed() * 0.2;
        const l = u * r.range(1.0, 2.2);
        const end: [2]f32 = .{ inst.cx + @cos(a) * l, inst.cy + @sin(a) * l * 0.7 };
        const m = bolt(r, inst.pts[n..], .{ inst.cx, inst.cy }, end, 3, 0.18);
        if (m == 0) break;
        n += m;
        inst.nseg += 1;
        inst.seg[inst.nseg] = @intCast(n);
    }
    inst.npts = @intCast(n);
}

// ---------------------------------------------------------------------------
// Instance drawing
// ---------------------------------------------------------------------------

fn drawCap(s: *Surface, inst: *const Inst, cx: f32, cy: f32, w: f32, h: f32, alpha: f32, tint: ?Rgb, tint_amt: f32) void {
    if (!(w > 0.3 and h > 0.3) or !(alpha > 0.01)) return;
    canvas.keycap(s, cx - w * 0.5, cy - h * 0.5, w, h, inst.look.top, inst.look.side, .{
        .alpha = alpha,
        .glow = inst.look.glow,
        .tint = tint,
        .tint_amount = tint_amt,
    });
    const txt = inst.text();
    if (txt.len == 0) return;
    var scale = h * 0.42 / font.cap_h;
    if (scale < 0.7) return;
    const tw = font.measure(txt, scale, .{});
    if (tw > w * 0.8) scale *= w * 0.8 / tw;
    var lc = inst.look.legend;
    if (tint) |tc| lc = lc.lerp(tc, tint_amt * 0.6);
    _ = font.drawTextCentered(s, cx, cy - h * 0.08 - font.height(scale) * 0.5, scale, txt, lc, .{ .alpha = alpha });
}

fn drawInstUnder(s: *Surface, inst: *const Inst) void {
    const u = inst.u;
    const t = inst.t;
    switch (inst.kind) {
        .supernova => {
            if (t >= 0.42) {
                const q = (t - 0.42) / 0.98;
                canvas.glow(s, inst.cx, inst.cy, u * 4 * (1 + q), inst.accent(), 0.35 * (1 - q) * (1 - q), .add);
            }
        },
        .blackhole => {
            const rh = blackholeRadius(inst);
            if (rh > 0.3) canvas.glow(s, inst.cx, inst.cy, rh * 3.5, Rgb.hex(0xff8a2a), 0.12, .add);
        },
        .frost => {
            if (t < 0.6) canvas.roundRectGlow(s, inst.cx - inst.w * 0.5, inst.cy - inst.h * 0.5, inst.w, inst.h, inst.h * 0.18, u * 0.6, pal.ice, 0.35 * sat(t / 0.3) * (1 - smoothstep(0.45, 0.6, t)), .add);
        },
        .derez => {
            const d = derezProgress(t);
            canvas.roundRectGlow(s, inst.cx - inst.w * 0.5, inst.cy - inst.h * 0.5, inst.w, inst.h, inst.h * 0.18, u * 0.7, pal.derez, 0.4 * (1 - d) * sat(t / 0.1), .add);
        },
        else => {},
    }
}

fn drawInstOver(s: *Surface, inst: *const Inst) void {
    const u = inst.u;
    const t = inst.t;
    const acc = inst.accent();
    switch (inst.kind) {
        .shatter, .confetti, .voxel => {
            // brief hot flash where the cap was
            const q = t / inst.dur;
            canvas.glow(s, inst.cx, inst.cy, u * 1.3, Rgb.white.lerp(acc, 0.4), 0.55 * (1 - q), .add);
        },
        .pop => {
            const grow = easeOut(t / 0.16);
            const sc = 1 + 0.4 * grow;
            const a = 1 - sat(t / 0.2);
            drawCap(s, inst, inst.cx, inst.cy, inst.w * sc, inst.h * sc, a, Rgb.white, 0.6 * grow);
            const q = sat(t / 0.32);
            const rr = u * (0.55 + 1.5 * easeOut(q)) + inst.w * 0.25;
            canvas.ring(s, inst.cx, inst.cy, rr, @max(u * 0.14 * (1 - q), 0.6), acc.lighten(0.3), 0.9 * (1 - q), .add);
            canvas.softRing(s, inst.cx, inst.cy, rr, u * 0.3, acc, 0.35 * (1 - q), .add);
        },
        .dust => {
            const a = 1 - smoothstep(0.02, 0.22, t);
            drawCap(s, inst, inst.cx + inst.dir * u * 0.15 * (1 - a), inst.cy, inst.w, inst.h, a, acc.lighten(0.5), 0.5 * (1 - a));
        },
        .glitch => drawGlitch(s, inst),
        .lightning => drawLightning(s, inst),
        .frost => drawFrost(s, inst),
        .melt => drawMelt(s, inst),
        .fireworks => {
            if (t < 0.1) drawCap(s, inst, inst.cx, inst.cy, inst.w, inst.h, 1 - t / 0.1, Rgb.white, 0.7);
            if (t < 0.34) {
                const p = fireworksRocket(inst);
                canvas.glow(s, p[0], p[1], u * 0.7, pal.amber, 0.7, .add);
                canvas.disc(s, p[0], p[1], @max(u * 0.08, 0.6), Rgb.white, 1, .add);
            }
        },
        .supernova => drawSupernova(s, inst),
        .blackhole => drawBlackhole(s, inst),
        .derez => drawDerez(s, inst),
        .miss => {
            const q = sat(t / inst.dur);
            const grow = easeOut(t / 0.08);
            var k: usize = 0;
            while (k < inst.nseg) : (k += 1) {
                const a: usize = inst.seg[k];
                const b: usize = inst.seg[k + 1];
                const cnt = a + @max(@as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(b - a)) * grow))), 2);
                const pts = inst.pts[a..@min(cnt, b)];
                canvas.glowPolyline(s, pts, u * 0.35, pal.miss, 0.45 * (1 - q), .add);
                canvas.polyline(s, pts, @max(u * 0.07, 0.8), Rgb.init(1, 0.75, 0.7), 1 - q, .add);
            }
            canvas.glow(s, inst.cx, inst.cy, u * 1.4, pal.miss, 0.6 * (1 - q), .add);
        },
    }
}

fn drawGlitch(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    const u = inst.u;
    if (t > 0.62) return;
    const step: u32 = @intFromFloat(t * 30);
    const vis = rng_mod.hash01(inst.seed, step) > 0.22;
    if (!vis) return;
    const a = 1 - smoothstep(0.32, 0.62, t);
    const jx = (rng_mod.hash01(inst.seed +% 1, step) * 2 - 1) * u * 0.25 * a;
    const tint_roll = rng_mod.hash01(inst.seed +% 2, step);
    const tint: ?Rgb = if (tint_roll < 0.2) pal.glitch_cyan else if (tint_roll < 0.35) pal.glitch_red else null;
    drawCap(s, inst, inst.cx + jx, inst.cy, inst.w, inst.h, a, tint, 0.5);
    // RGB ghosts (visible even where post slices are a pixel tall)
    const off = u * (0.12 + 0.25 * rng_mod.hash01(inst.seed +% 3, step));
    canvas.roundRect(s, inst.cx - inst.w * 0.5 + jx + off, inst.cy - inst.h * 0.5, inst.w, inst.h, inst.h * 0.18, pal.glitch_red, 0.28 * a, .add);
    canvas.roundRect(s, inst.cx - inst.w * 0.5 + jx - off, inst.cy - inst.h * 0.5, inst.w, inst.h, inst.h * 0.18, pal.glitch_cyan, 0.28 * a, .add);
}

fn drawLightning(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    const u = inst.u;
    const step: u32 = @intFromFloat(t * 18);
    const flick = 0.6 + 0.4 * rng_mod.hash01(inst.seed, step);
    const b = (1 - smoothstep(0.22, 0.6, t)) * flick;
    if (t < 0.12) drawCap(s, inst, inst.cx, inst.cy, inst.w, inst.h, 1 - t / 0.12, Rgb.white, 0.85);
    if (b <= 0.01) return;
    const outer = Rgb.init(0.35, 0.45, 1.0);
    const mid = Rgb.init(0.65, 0.78, 1.0);
    var k: usize = 0;
    while (k < inst.nseg) : (k += 1) {
        const pts = inst.pts[inst.seg[k]..inst.seg[k + 1]];
        const wk: f32 = if (k == 0) 1 else 0.6;
        canvas.glowPolyline(s, pts, u * 0.6 * wk, outer, 0.3 * b, .add);
        canvas.glowPolyline(s, pts, u * 0.22 * wk, mid, 0.6 * b, .add);
        canvas.polyline(s, pts, @max(u * 0.07 * wk, 0.7), Rgb.white, b, .add);
    }
    canvas.glow(s, inst.cx, inst.cy, u * 1.8, mid, 0.7 * b, .add);
}

fn drawFrost(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    const u = inst.u;
    if (t >= 0.48) {
        // lingering cold glow after the crack
        const q = sat((t - 0.48) / 0.4);
        canvas.glow(s, inst.cx, inst.cy, u * 1.6, pal.ice, 0.3 * (1 - q), .add);
        return;
    }
    drawCap(s, inst, inst.cx, inst.cy, inst.w, inst.h, 1, null, 0);
    // ice front: per pixel inside the cap
    const rf = frostFront(inst);
    const sx = inst.aux[0];
    const sy = inst.aux[1];
    const x0 = inst.cx - inst.w * 0.5;
    const y0 = inst.cy - inst.h * 0.5;
    const sp = canvas.span(s, x0, y0, x0 + inst.w, y0 + inst.h) orelse return;
    const r = @min(inst.w, inst.h) * 0.18;
    const band = @max(u * 0.08, 0.8);
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const vy = (fy - y0) / inst.h;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const cov = sat(0.5 - canvas.sdRoundBox(fx - inst.cx, fy - inst.cy, inst.w * 0.5, inst.h * 0.5, r));
            if (cov <= 0) continue;
            const dx = fx - sx;
            const dy = fy - sy;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > rf + band) continue;
            const n = rng_mod.hash01(@as(u32, @intCast(px)) *% 3 +% inst.seed, py);
            var c = pal.ice_deep.lerp(pal.ice, 0.35 + 0.4 * (1 - vy) + 0.15 * n);
            var a: f32 = 0.92 * sat((rf - d) / band + 1);
            const edge = 1 - @abs(d - rf) / band;
            if (edge > 0) {
                c = c.lerp(pal.ice_light, edge);
                a = @max(a, edge);
            }
            canvas.blendPx(&row[px], c, a * cov, .over);
        }
    }
    // crystal lines revealed up to the front
    const crack = smoothstep(0.38, 0.47, t);
    const lc = pal.ice_light.lerp(Rgb.white, crack);
    var k: usize = 0;
    while (k + 1 < inst.npts) : (k += 2) {
        const a = inst.pts[k];
        const b = inst.pts[k + 1];
        const da = @sqrt((a[0] - sx) * (a[0] - sx) + (a[1] - sy) * (a[1] - sy));
        const db = @sqrt((b[0] - sx) * (b[0] - sx) + (b[1] - sy) * (b[1] - sy));
        if (rf <= da) continue;
        var e = b;
        if (rf < db and db > da) {
            const f = (rf - da) / (db - da);
            e = .{ a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f };
        }
        // keep crystals on the cap (plus a little halo spill)
        const cx0 = std.math.clamp(a[0], x0 - u * 0.2, x0 + inst.w + u * 0.2);
        const cy0 = std.math.clamp(a[1], y0 - u * 0.2, y0 + inst.h + u * 0.2);
        const cx1 = std.math.clamp(e[0], x0 - u * 0.2, x0 + inst.w + u * 0.2);
        const cy1 = std.math.clamp(e[1], y0 - u * 0.2, y0 + inst.h + u * 0.2);
        canvas.line(s, cx0, cy0, cx1, cy1, @max(u * 0.045, 0.5) * (1 + crack), lc, 0.75 + 0.25 * crack, .add);
    }
}

fn heatRamp(h: f32) Rgb {
    const stops = [_]canvas.Stop{
        .{ .at = 0, .c = Rgb.hex(0x4a0805) },
        .{ .at = 0.35, .c = Rgb.hex(0xc0260c) },
        .{ .at = 0.65, .c = Rgb.hex(0xff7a1a) },
        .{ .at = 1, .c = Rgb.hex(0xfff1c2) },
    };
    return canvas.stopsAt(&stops, h);
}

fn drawMelt(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    const u = inst.u;
    const hw = inst.w * 0.5;
    const hh = inst.h * 0.5;
    if (t < 0.45) {
        const p = t / 0.45;
        const spread = 1 + 0.18 * p * p;
        const left = inst.cx - hw * spread;
        const right = inst.cx + hw * spread;
        const sp = canvas.span(s, left, inst.cy - hh, right, inst.cy + hh + u * 1.4) orelse return;
        const bottom = inst.cy + hh;
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            const nx = (fx - inst.cx) / (hw * spread);
            if (@abs(nx) >= 1) continue;
            const edge_cov = sat((1 - @abs(nx)) * hw * spread);
            const col_noise = rng_mod.hash01(inst.seed, @as(u32, @intCast(px)) / 2);
            const shoulder = (1 - @sqrt(@max(1 - nx * nx, 0))) * inst.h * 0.5;
            const sag = inst.h * p * @sqrt(p) * (0.28 + 0.2 * col_noise) + shoulder * (0.4 + 0.6 * p);
            const top = inst.cy - hh + sag;
            const drip_n = rng_mod.hash01(inst.seed +% 7, @as(u32, @intCast(px)) / 2);
            const drip = if (drip_n > 0.62) p * u * 1.3 * (drip_n - 0.62) / 0.38 else 0;
            const bot = bottom + drip;
            if (bot <= top) continue;
            const hf = 0.15 + p * 1.1;
            var py = sp.y0;
            while (py < sp.y1) : (py += 1) {
                const fy = @as(f32, @floatFromInt(py));
                const cy = sat(@min(fy + 1, bot) - @max(fy, top));
                if (cy <= 0) continue;
                const v = (fy + 0.5 - top) / (bot - top);
                var c = if (v > 0.82) inst.look.side else inst.look.top.lighten(0.1 * (1 - v));
                const heat = sat((v - (1 - hf)) / @max(hf, 0.01));
                c = c.lerp(heatRamp(heat), sat(heat * 1.6));
                canvas.blendPx(&s.pixels[@as(usize, py) * s.w + px], c, cy * edge_cov, .over);
            }
        }
        canvas.glowEllipse(s, inst.cx, bottom, hw * 1.3, u * 0.55, Rgb.hex(0xff6a1a), 0.55 * p, .add);
    } else {
        const q = sat((t - 0.45) / 0.65);
        const rx = hw * (1.18 + 0.35 * easeOut(q));
        const ry = @max(inst.h * 0.2 * (1 - q * 0.5), 0.7);
        const cy = inst.cy + hh - ry * 0.6;
        const a = 1 - q * q;
        canvas.ellipse(s, inst.cx, cy, rx, ry, heatRamp(0.85 - 0.75 * q), a, .over);
        canvas.glowEllipse(s, inst.cx, cy, rx * 1.3, ry * 2.5 + u * 0.3, Rgb.hex(0xff6a1a), 0.6 * (1 - q), .add);
    }
}

fn drawSupernova(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    const u = inst.u;
    const acc = inst.accent();
    if (t < 0.42) {
        const p = t / 0.42;
        const sc = 1 - 0.92 * easeIn(p * 1.1);
        const step: u32 = @intFromFloat(t * 40);
        const jx = (rng_mod.hash01(inst.seed, step) * 2 - 1) * u * 0.12 * p;
        const jy = (rng_mod.hash01(inst.seed +% 5, step) * 2 - 1) * u * 0.12 * p;
        drawCap(s, inst, inst.cx + jx, inst.cy + jy, inst.w * sc, inst.h * sc, 1, Rgb.white, p);
        const rr = u * 3.2 * (1 - easeOut(p)) + u * 0.2;
        canvas.softRing(s, inst.cx, inst.cy, rr, u * 0.45, acc, 0.45 * p, .add);
        canvas.ring(s, inst.cx, inst.cy, rr, @max(u * 0.08, 0.7), acc.lighten(0.4), 0.3 + 0.7 * p, .add);
        canvas.glow(s, inst.cx, inst.cy, u * (0.5 + 1.3 * p), Rgb.white, 0.65 * p, .add);
    } else {
        const q = sat((t - 0.42) / 0.98);
        const f = (1 - q) * (1 - q);
        canvas.glowEllipse(s, inst.cx, inst.cy, u * 7 * (1 - q * 0.4), @max(u * 0.22, 0.8) * (1 - q * 0.5), acc.lighten(0.6), 0.9 * f, .add);
        canvas.glowEllipse(s, inst.cx, inst.cy, @max(u * 0.22, 0.8) * (1 - q * 0.5), u * 2.5 * (1 - q * 0.4), acc.lighten(0.6), 0.35 * f, .add);
        canvas.glow(s, inst.cx, inst.cy, u * 2.2 * (1 + q), Rgb.white.lerp(acc, q), f, .add);
        const rr = u * 8 * easeOut(q);
        canvas.softRing(s, inst.cx, inst.cy, rr, u * 0.55, acc, 0.6 * (1 - q), .add);
        canvas.ring(s, inst.cx, inst.cy, rr * 0.92, @max(u * 0.06, 0.6), Rgb.white, 0.5 * (1 - q), .add);
    }
}

fn drawBlackhole(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    // the cap gets swallowed first
    if (t < 0.35) {
        const p = t / 0.35;
        const sc = (1 - p) * (1 - p);
        drawCap(s, inst, inst.cx, inst.cy, inst.w * sc, inst.h * sc, 1, Rgb.hex(0xff8a3a), p);
    }
    const rh = blackholeRadius(inst);
    if (rh < 0.3) return;
    // accretion ring: ember gradient with rotating hot spots
    const r_in = rh * 1.05;
    const r_out = rh * 1.8;
    const sp = canvas.span(s, inst.cx - r_out, inst.cy - r_out, inst.cx + r_out, inst.cy + r_out) orelse return;
    const spin = t * 7;
    // dark core so the lens bends darkness (not backdrop) toward the horizon
    canvas.disc(s, inst.cx, inst.cy, r_in, Rgb.hex(0x050208), 1, .over);
    var py = sp.y0;
    while (py < sp.y1) : (py += 1) {
        const dy = @as(f32, @floatFromInt(py)) + 0.5 - inst.cy;
        const row = s.pixels[@as(usize, py) * s.w ..];
        var px = sp.x0;
        while (px < sp.x1) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) + 0.5 - inst.cx;
            const d = @sqrt(dx * dx + dy * dy);
            if (d < r_in - 1 or d > r_out) continue;
            const v = (d - r_in) / (r_out - r_in); // 0 inner .. 1 outer
            const th = std.math.atan2(dy, dx);
            const swirl = 0.62 + 0.38 * @sin(3 * th - spin + 2.2 * @sin(5 * th + t * 3) + v * 4);
            const prof = sat(1 - v) * sat((d - r_in) + 1) * sat((r_out - d) * 0.7);
            const c = if (v < 0.3) Rgb.hex(0xfff0c8).lerp(Rgb.hex(0xffa040), v / 0.3) else Rgb.hex(0xffa040).lerp(Rgb.hex(0xd8360e), sat((v - 0.3) / 0.7));
            canvas.blendPx(&row[px], c, sat(prof * swirl * 1.4), .over);
            if (v < 0.35) canvas.blendPx(&row[px], Rgb.hex(0xffd9a0), (0.35 - v) * 2 * swirl, .add);
        }
    }
    canvas.softRing(s, inst.cx, inst.cy, rh * 1.85, rh * 0.35, Rgb.hex(0xff6a1a), 0.25, .add);
}

fn drawDerez(s: *Surface, inst: *const Inst) void {
    const t = inst.t;
    const c_in = sat(t / 0.15);
    if (t < 0.2) drawCap(s, inst, inst.cx, inst.cy, inst.w, inst.h, 1 - sat((t - 0.12) / 0.08), pal.derez, c_in * 0.85);
    if (t < 0.08) return;
    const d = derezProgress(t);
    const g = derezGrid(inst);
    const fade_in = sat((t - 0.08) / 0.1);
    const scan_y = g.y0 + @as(f32, @floatFromInt(g.ny)) * g.bs * (1 - @mod(t * 2.2, 1));
    var j: u32 = 0;
    while (j < g.ny) : (j += 1) {
        var i: u32 = 0;
        while (i < g.nx) : (i += 1) {
            if (derezThreshold(inst, i, j, g.ny) <= d) continue;
            if (!derezInside(inst, g, i, j)) continue;
            const bx = g.x0 + @as(f32, @floatFromInt(i)) * g.bs;
            const by = g.y0 + @as(f32, @floatFromInt(j)) * g.bs;
            const n = rng_mod.hash01(inst.seed +% 99, i *% 131 +% j);
            const flick: f32 = if (rng_mod.hash01(i +% j *% 17, @intFromFloat(t * 24)) < 0.08) 1.5 else 1;
            const near_scan = 1 - sat(@abs(by + g.bs * 0.5 - scan_y) / (g.bs * 1.5));
            if (g.bs >= 3) {
                canvas.fillRect(s, bx, by, g.bs, g.bs, pal.derez, 0.75 * fade_in * flick, .add);
                canvas.fillRect(s, bx + 1, by + 1, g.bs - 2, g.bs - 2, Rgb.init(0.02, 0.18 + 0.12 * n, 0.26 + 0.1 * n), 0.9 * fade_in, .over);
            } else {
                canvas.fillRect(s, bx, by, g.bs, g.bs, pal.derez.scale(0.45 + 0.35 * n), 0.9 * fade_in * flick, .over);
            }
            if (near_scan > 0) canvas.fillRect(s, bx, by, g.bs, g.bs, Rgb.white, 0.5 * near_scan * fade_in, .add);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn checksum(s: *const Surface) u64 {
    var h: u64 = 0;
    for (s.pixels) |p| h +%= @as(u64, p.r) * 3 + @as(u64, p.g) * 5 + @as(u64, p.b) * 7;
    return h;
}

fn runAll(w: u32, h: u32, cap_h: f32) !void {
    var s = try Surface.init(testing.allocator, @intCast(@max(w / 4, 1)), @intCast(@max(h / 8, 1)), w, h);
    defer s.deinit();
    var fx = try Fx.init(testing.allocator);
    defer fx.deinit();
    fx.floor_y = @as(f32, @floatFromInt(h)) * 0.8;
    fx.setCellPx(4, cap_h / 2);
    inline for (comptime std.meta.tags(Effect)) |e| {
        fx.reset();
        canvas.clear(&s, pal.night);
        const base = checksum(&s);
        fx.spawnEx(e, .{ .cx = @as(f32, @floatFromInt(w)) * 0.5, .cy = @as(f32, @floatFromInt(h)) * 0.5, .w = cap_h * 1.1, .h = cap_h, .hue = 0.55, .intensity = 0.8, .look = .{ .text = "Q" } });
        try testing.expectEqual(@as(usize, 1), fx.activeEffects());
        var changed = false;
        var t: f32 = 0;
        while (t < 2.0) : (t += 1.0 / 60.0) {
            canvas.clear(&s, pal.night);
            fx.update(1.0 / 60.0);
            fx.drawUnder(&s);
            fx.drawOver(&s);
            fx.post(&s);
            if (checksum(&s) != base) changed = true;
        }
        try testing.expect(changed);
        try testing.expectEqual(@as(usize, 0), fx.activeEffects());
    }
}

test "every effect runs to completion at kitty and half-block scale" {
    try runAll(240, 135, 16);
    try runAll(80, 48, 4);
}

test "spawn ignores degenerate input and recycles when full" {
    var fx = try Fx.initCapacity(testing.allocator, 64);
    defer fx.deinit();
    fx.spawn(.pop, std.math.nan(f32), 0, 10, 10, 0, 1);
    fx.spawn(.pop, 0, 0, 0, 10, 0, 1);
    try testing.expectEqual(@as(usize, 0), fx.activeEffects());
    for (0..max_instances + 10) |_| fx.spawn(.supernova, 50, 50, 20, 16, 0.3, 1);
    try testing.expectEqual(@as(usize, max_instances), fx.activeEffects());
    try testing.expect(fx.particles.len <= 64);
    fx.reset();
    try testing.expect(!fx.busy());
}

test "extreme cap sizes don't hang or overflow; legend cut on a codepoint" {
    var s = try Surface.init(testing.allocator, 40, 12, 160, 96);
    defer s.deinit();
    var fx = try Fx.initCapacity(testing.allocator, 256);
    defer fx.deinit();
    fx.spawn(.derez, 50, 50, 1e30, 10, 0.2, 1); // used to loop forever in derezGrid
    fx.spawn(.pop, 50, 50, 1e30, 1e-30, 0.2, 1); // aspect → inf particle count
    fx.spawn(.supernova, 50, 50, 10, 1e12, std.math.nan(f32), 1); // huge shake, NaN hue
    fx.spawn(.pop, 50, 50, std.math.inf(f32), 10, 0.2, 1); // rejected
    try testing.expectEqual(@as(usize, 3), fx.activeEffects());
    for (0..40) |_| {
        fx.update(1.0 / 60.0);
        fx.drawUnder(&s);
        fx.drawOver(&s);
        fx.post(&s);
    }
    fx.reset();
    // 13 ASCII bytes + a 3-byte arrow = 16: the 15-byte copy must drop the arrow
    fx.spawnEx(.pop, .{ .cx = 80, .cy = 48, .w = 40, .h = 20, .look = .{ .text = "Ctrl+Shift+Al\u{2193}" } });
    for (fx.insts) |*i| if (i.active) {
        try testing.expect(std.unicode.utf8ValidateSlice(i.text()));
        try testing.expectEqual(@as(u8, 13), i.text_len);
    };
}

test "shockwaves cap at four, shake and flash decay" {
    var fx = try Fx.initCapacity(testing.allocator, 16);
    defer fx.deinit();
    for (0..6) |i| fx.shockwave(@floatFromInt(i * 10), 0, 1);
    var n: usize = 0;
    for (fx.waves) |w| n += @intFromBool(w.active);
    try testing.expectEqual(@as(usize, 4), n);
    fx.shake(1);
    fx.flash(Rgb.white, 0.5);
    try testing.expect(fx.busy());
    for (0..120) |_| fx.update(1.0 / 60.0);
    try testing.expect(!fx.busy());
    try testing.expectEqual([2]i32{ 0, 0 }, fx.shakeOffset());
}

test "blackhole lens darkens its center during the hold" {
    var s = try Surface.init(testing.allocator, 30, 17, 120, 68);
    defer s.deinit();
    var fx = try Fx.initCapacity(testing.allocator, 512);
    defer fx.deinit();
    fx.bloom_quality = .off;
    fx.spawn(.blackhole, 60, 34, 16, 16, 0.1, 1);
    var t: f32 = 0;
    while (t < 0.6) : (t += 1.0 / 60.0) fx.update(1.0 / 60.0);
    canvas.clear(&s, Rgb.init(0.5, 0.5, 0.5));
    fx.drawOver(&s);
    fx.post(&s);
    // shake may move the frame by a pixel or two; the horizon is ~5 px wide
    var darkest: u8 = 255;
    for (32..37) |y| for (58..63) |x| {
        darkest = @min(darkest, s.pixels[y * 120 + x].g);
    };
    try testing.expect(darkest < 20);
}

test "lookFor maps skins" {
    const l = lookFor(.named, .common);
    try testing.expectEqual(pal.cap_named[0].r, l.top.r);
    try testing.expect(lookFor(.letter, .legendary).glow != null);
    try testing.expect(lookFor(.arrow, .common).glow == null);
}

test "bolt generator endpoints and count" {
    var r = Rng.init(3);
    var out: [33][2]f32 = undefined;
    const n = bolt(&r, &out, .{ 0, 0 }, .{ 0, 100 }, 5, 0.1);
    try testing.expectEqual(@as(usize, 33), n);
    try testing.expectEqual([2]f32{ 0, 100 }, out[32]);
    var small: [4][2]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), bolt(&r, &small, .{ 0, 0 }, .{ 1, 1 }, 3, 0.1));
}
