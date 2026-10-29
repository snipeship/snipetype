//! Headless preview of the arcade scene: drives an `Arcade` with scripted
//! keys and time, renders scenario frames with `Scene`, and writes PPM (P6)
//! images with the text layer rasterized over the pixels (pixel font scaled
//! to the cell size), the way a terminal would show them.
//!
//!   arcade-preview <outdir> [--cols N] [--rows N] [--mode kitty|half|both]
//!                  [--cell WxH] [--game words|keys|both] [--bench]
//!
//! kitty mode renders the surface at `gfx.pixelSize` for a WxH px terminal
//! cell (default 8x16 → 4×8 surface px per cell; the web at 1280×720 is
//! about 8x17), bilinear-upscaled like the kitty/web presenters. half mode
//! renders cols × rows*2 (one cell = two stacked pixels; text cells take the
//! averaged background, like the half-block presenter). Output cells are
//! 12×24 px. Frames: `<k|h>_0xx` Words game (the default), `_1xx` Keys
//! game, `_2xx` forced effects.
//!
//! Lives at src/ so it can import src/game, src/fx and src/platform by path.

const std = @import("std");
const fx = @import("fx/fx.zig");
const arcade_mod = @import("game/arcade.zig");
const scene_mod = @import("game/scene.zig");
const model = @import("game/model.zig");
const levels = @import("game/levels.zig");
const keys = @import("platform/keys.zig");
const presenter = @import("gfx/presenter.zig");

const Arcade = arcade_mod.Arcade;
const Scene = scene_mod.Scene;
const Surface = fx.Surface;
const Px = fx.Px;

const CELL_W = 12;
const CELL_H = 24;

const Mode = enum { kitty, half };

const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    out_dir: []const u8,
    cols: u16,
    rows: u16,
    mode: Mode,
    arc: Arcade,
    scene: Scene,
    surf: Surface,
    now: i64 = 1000,
    /// Perfect bot types caps once they have fallen this far.
    bot_at: f32 = 0.3,
    bot: bool = true,
    /// Cap the bot leaves alone (to force a miss).
    spare: u32 = 0,
    frames: usize = 0,

    fn quality(self: *const Ctx) scene_mod.Quality {
        return if (self.mode == .half) .{ .halfblock = true, .bloom = .off } else .{ .bloom = .low };
    }

    /// What the app does every frame before rendering.
    fn syncPlayWidth(self: *Ctx) void {
        self.arc.setPlayWidth(scene_mod.simPlayCols(&self.surf, self.quality()));
    }

    /// Advance time by `ms` in 1/60 s frames, optionally rendering each.
    fn run(self: *Ctx, ms: i64, render: bool) void {
        var left = ms;
        while (left > 0) : (left -= 16) {
            self.now += 16;
            if (self.bot and self.arc.phase == .playing) self.botStep();
            self.syncPlayWidth();
            self.arc.update(self.now);
            if (render) self.scene.render(&self.surf, &self.arc, self.now, self.quality());
            self.arc.clearEvents();
        }
    }

    /// Fast-forward without rendering, then render the last `tail_ms`.
    fn skip(self: *Ctx, ms: i64, tail_ms: i64) void {
        self.run(@max(ms - tail_ms, 0), false);
        self.run(tail_ms, true);
    }

    fn botStep(self: *Ctx) void {
        // type at most two keys per frame (≈ 7200 kpm cap, plenty)
        var n: usize = 0;
        while (n < 2) : (n += 1) {
            var best: ?usize = null;
            for (self.arc.caps(), 0..) |c, i| {
                if (c.state != .falling or c.id == self.spare) continue;
                if (c.progress < self.bot_at and c.typed == 0) continue;
                if (best == null or c.progress > self.arc.caps()[best.?].progress) best = i;
            }
            const i = best orelse return;
            const c = self.arc.caps()[i];
            self.arc.handleKey(levels.eventForStep(c.steps[c.typed]), self.now);
        }
    }

    fn snap(self: *Ctx, name: []const u8) !void {
        self.scene.render(&self.surf, &self.arc, self.now, self.quality());
        self.arc.clearEvents();
        try writeFrame(self, name);
        self.frames += 1;
    }
};

const Args = struct {
    out: []const u8,
    cols: u16,
    rows: u16,
    modes: []const Mode,
    bench: bool,
    cell_w: u16 = 8,
    cell_h: u16 = 16,
    games: []const model.Game = &.{ .words, .keys },
};

fn parseArgs(args: []const [:0]const u8) !Args {
    if (args.len < 2) {
        std.debug.print("usage: arcade-preview <outdir> [--cols N] [--rows N] [--mode kitty|half|both] [--cell WxH] [--game words|keys|both] [--bench]\n", .{});
        return error.Usage;
    }
    var cols: u16 = 120;
    var rows: u16 = 35;
    var modes: []const Mode = &.{ .kitty, .half };
    var do_bench = false;
    var cell_w: u16 = 8;
    var cell_h: u16 = 16;
    var games: []const model.Game = &.{ .words, .keys };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--cols") and i + 1 < args.len) {
            i += 1;
            cols = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rows") and i + 1 < args.len) {
            i += 1;
            rows = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--mode") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "kitty")) modes = &.{.kitty} else if (std.mem.eql(u8, args[i], "half")) modes = &.{.half} else modes = &.{ .kitty, .half };
        } else if (std.mem.eql(u8, a, "--cell") and i + 1 < args.len) {
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], 'x');
            cell_w = try std.fmt.parseInt(u16, it.next() orelse "8", 10);
            cell_h = try std.fmt.parseInt(u16, it.next() orelse "16", 10);
        } else if (std.mem.eql(u8, a, "--game") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "words")) games = &.{.words} else if (std.mem.eql(u8, args[i], "keys")) games = &.{.keys} else games = &.{ .words, .keys };
        } else if (std.mem.eql(u8, a, "--bench")) {
            do_bench = true;
        }
    }
    return .{ .out = args[1], .cols = cols, .rows = rows, .modes = modes, .bench = do_bench, .cell_w = cell_w, .cell_h = cell_h, .games = games };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parseArgs(args) catch std.process.exit(2);
    try std.Io.Dir.cwd().createDirPath(io, opts.out);

    if (opts.bench) {
        try bench(io, gpa, opts);
        return;
    }
    for (opts.modes) |mode| {
        for (opts.games) |game| switch (game) {
            .words => try wordsScenarios(io, gpa, opts, mode),
            .keys => try keysScenarios(io, gpa, opts, mode),
        };
    }
}

fn newCtx(io: std.Io, gpa: std.mem.Allocator, a: Args, mode: Mode, game: model.Game) !Ctx {
    const cols = a.cols;
    const rows = a.rows;
    const out = a.out;
    const px = presenter.pixelSize(if (mode == .half) .halfblock else .kitty, cols, rows, a.cell_w, a.cell_h);
    const w: u32 = px.w;
    const h: u32 = px.h;
    var arc = try Arcade.init(gpa, 0xA4CADE, .{ .pace = .senior, .speed = 1, .play_cols = cols, .game = game });
    errdefer arc.deinit();
    var sc = try Scene.init(gpa, 0xA4CADE);
    errdefer sc.deinit();
    const surf = try Surface.init(gpa, cols, rows, w, h);
    return .{ .io = io, .gpa = gpa, .out_dir = out, .cols = cols, .rows = rows, .mode = mode, .arc = arc, .scene = sc, .surf = surf };
}

fn freeCtx(c: *Ctx) void {
    c.surf.deinit();
    c.scene.deinit();
    c.arc.deinit();
}

fn press(c: *Ctx, code: u21) void {
    c.arc.handleKey(.{ .code = code }, c.now);
}

/// Jump to `level` with the perfect bot (no rendering), then render a tail.
fn jumpToLevel(c: *Ctx, level: u8, into_ms: i64) void {
    const target: i64 = @as(i64, level) * arcade_mod.LEVEL_SECONDS * 1000 + into_ms;
    const elapsed: i64 = @intFromFloat(c.arc.playSeconds() * 1000);
    if (target > elapsed) c.skip(target - elapsed, 1500);
}

/// Let the current line of the Words game finish (attribution showing).
fn finishLine(c: *Ctx) void {
    var guard: usize = 0;
    while (guard < 2500) : (guard += 1) {
        c.run(16, guard % 4 == 0);
        if (c.arc.hud.phrase) |ph| if (ph.complete) break;
    }
    c.run(700, true);
}

/// Spare the lowest cap until it lands, then render the miss.
fn forceMiss(c: *Ctx, name: []const u8) !void {
    var low: ?model.Cap = null;
    for (c.arc.caps()) |cap| {
        if (cap.state == .falling and (low == null or cap.progress > low.?.progress)) low = cap;
    }
    const l = low orelse return;
    c.spare = l.id;
    var guard: usize = 0;
    while (guard < 1000) : (guard += 1) {
        c.run(16, true);
        var landed = true;
        for (c.arc.caps()) |cap| {
            if (cap.id == l.id and cap.state == .falling) landed = false;
        }
        if (landed) break;
    }
    c.run(120, true);
    try c.snap(name);
    c.spare = 0;
}

/// Pause, then run the health out and capture the results card.
fn pauseAndResults(c: *Ctx, pause_name: []const u8, in_name: []const u8, name: []const u8) !void {
    press(c, keys.code.escape);
    c.run(100, true);
    try c.snap(pause_name);
    press(c, keys.code.escape);
    c.run(200, true);
    c.bot = false;
    var guard: usize = 0;
    while (c.arc.phase == .playing and guard < 20000) : (guard += 1) c.run(16, false);
    c.run(400, true);
    try c.snap(in_name);
    c.run(1600, true);
    try c.snap(name);
}

fn wordsScenarios(io: std.Io, gpa: std.mem.Allocator, a: Args, mode: Mode) !void {
    var c = try newCtx(io, gpa, a, mode, .words);
    defer freeCtx(&c);

    // title (Words selected) + attract demo
    c.run(2600, true);
    try c.snap("001_title_words");
    press(&c, keys.code.enter);
    c.bot_at = 0.5;
    c.run(5200, true);
    try c.snap("002_w_level0");
    c.run(2600, true);
    try c.snap("003_w_level0b");
    try forceMiss(&c, "004_w_miss");
    press(&c, '`');
    c.run(80, true);
    try c.snap("005_w_wrong");
    jumpToLevel(&c, 2, 12000);
    try c.snap("006_w_level2");
    jumpToLevel(&c, 4, 14000);
    try c.snap("007_w_level4_identifiers");
    jumpToLevel(&c, 6, 9000);
    try c.snap("008_w_level6");
    jumpToLevel(&c, 8, 6000);
    try c.snap("009_w_level8_quote");
    finishLine(&c);
    try c.snap("010_w_level8_line_done");
    jumpToLevel(&c, 11, 6000);
    try c.snap("011_w_overtime");
    try pauseAndResults(&c, "012_w_paused", "013_w_results_in", "014_w_results");
}

fn keysScenarios(io: std.Io, gpa: std.mem.Allocator, a: Args, mode: Mode) !void {
    var c = try newCtx(io, gpa, a, mode, .words);
    defer freeCtx(&c);

    // title + attract demo; Tab switches to the Keys game
    c.run(1200, true);
    press(&c, keys.code.tab);
    c.run(1400, true);
    try c.snap("101_title_keys");
    press(&c, keys.code.right);
    press(&c, keys.code.up);
    c.run(900, true);
    try c.snap("102_title_staff_x2");
    press(&c, keys.code.left);
    press(&c, keys.code.down);

    // clock in
    press(&c, keys.code.enter);
    c.run(4200, true);
    try c.snap("103_level0");
    try forceMiss(&c, "104_miss");
    // wrong key flash
    press(&c, '`');
    c.run(80, true);
    try c.snap("105_wrong");

    // later levels with the perfect bot
    c.bot_at = 0.45;
    jumpToLevel(&c, 3, 9000);
    try c.snap("106_level3_named");
    jumpToLevel(&c, 4, 12000);
    try c.snap("107_level4_motions");
    jumpToLevel(&c, 5, 14000);
    c.bot_at = 0.55;
    c.run(300, true);
    try c.snap("108_level5_operators");
    c.bot_at = 0.45;
    jumpToLevel(&c, 6, 15000);
    try c.snap("109_level6_ctrl");
    jumpToLevel(&c, 7, 12000);
    try c.snap("110_level7_ex");
    jumpToLevel(&c, 8, 600);
    try c.snap("111_level8_banner");
    jumpToLevel(&c, 8, 16000);
    try c.snap("112_level8_chords");
    c.bot_at = 0.55;
    jumpToLevel(&c, 9, 9000);
    try c.snap("113_level9_words");
    finishLine(&c);
    try c.snap("114_phrase_done");
    c.bot_at = 0.45;
    jumpToLevel(&c, 11, 10000);
    try c.snap("115_overtime");

    // force each effect on live caps (one per frame, captured near its peak)
    try forceEffects(&c);

    try pauseAndResults(&c, "130_paused", "131_results_in", "132_results");
}

fn forceEffects(c: *Ctx) !void {
    c.bot_at = 0.62;
    defer c.bot_at = 0.45;
    inline for (comptime std.meta.tags(model.Effect)) |e| {
        // wait for a falling cap in the middle of the play area
        var guard: usize = 0;
        var target: ?usize = null;
        while (guard < 600) : (guard += 1) {
            for (c.arc.caps(), 0..) |cap, i| {
                if (cap.state == .falling and cap.progress > 0.3 and cap.progress < 0.6) target = i;
            }
            if (target != null) break;
            c.run(16, true);
        }
        if (target) |i| {
            const cap = &c.arc.cap_buf[i];
            cap.state = .hit;
            cap.state_t = 0;
            const ev: model.Event = .{ .hit = .{
                .cap_id = cap.id,
                .x = cap.x,
                .y = cap.progress,
                .effect = e,
                .points = 1440,
                .quick = true,
                .intensity = 0.85,
                .hue = cap.hue,
                .rarity = cap.rarity,
                .caption = cap.caption,
                .kind = cap.kind,
                .combo = 77,
            } };
            if (c.arc.event_len < c.arc.event_buf.len) {
                c.arc.event_buf[c.arc.event_len] = ev;
                c.arc.event_len += 1;
            }
            const peak: i64 = switch (e.tier()) {
                1 => 140,
                2 => 300,
                else => 480,
            };
            c.run(peak, true);
            var name: [32]u8 = undefined;
            try c.snap(try std.mem.print(&name, "2{d:0>2}_fx_{s}", .{ @backingInt(e), @tagName(e) }));
        }
    }
}

// ---------------------------------------------------------------------------
// Rasterize surface + text layer → PPM
// ---------------------------------------------------------------------------

fn writeFrame(c: *Ctx, name: []const u8) !void {
    const W: usize = @as(usize, c.cols) * CELL_W;
    const H: usize = @as(usize, c.rows) * CELL_H;
    const img = try c.gpa.alloc(u8, W * H * 3);
    defer c.gpa.free(img);
    const s = &c.surf;

    // pixel layer
    for (0..H) |y| {
        for (0..W) |x| {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            if (c.mode == .half) {
                const col = x / CELL_W;
                const sub: usize = if ((y % CELL_H) < CELL_H / 2) 0 else 1;
                const p = s.pixels[((y / CELL_H) * 2 + sub) * s.w + col];
                r = @floatFromInt(p.r);
                g = @floatFromInt(p.g);
                b = @floatFromInt(p.b);
            } else {
                // bilinear (the presenters scale the image with smoothing)
                const fx_ = (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(s.w)) / @as(f32, @floatFromInt(W)) - 0.5;
                const fy_ = (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(s.h)) / @as(f32, @floatFromInt(H)) - 0.5;
                const rgb = fx.canvas.sampleBuf(s.pixels, s.w, s.h, fx_, fy_);
                r = rgb.r * 255;
                g = rgb.g * 255;
                b = rgb.b * 255;
            }
            const o = (y * W + x) * 3;
            img[o] = @intFromFloat(std.math.clamp(r, 0, 255));
            img[o + 1] = @intFromFloat(std.math.clamp(g, 0, 255));
            img[o + 2] = @intFromFloat(std.math.clamp(b, 0, 255));
        }
    }

    // text layer
    for (0..c.rows) |row| {
        for (0..c.cols) |col| {
            const cell = s.text[row * c.cols + col];
            if (cell.cp == 0) continue;
            const x0 = col * CELL_W;
            const y0 = row * CELL_H;
            var bg: ?[3]u8 = null;
            if (cell.bg) |cb| {
                bg = .{ cb.r, cb.g, cb.b };
            } else if (c.mode == .half) {
                const t = s.pixels[(row * 2) * s.w + col];
                const btm = s.pixels[(row * 2 + 1) * s.w + col];
                bg = .{ avg(t.r, btm.r), avg(t.g, btm.g), avg(t.b, btm.b) };
            }
            if (bg) |bb| {
                for (0..CELL_H) |yy| for (0..CELL_W) |xx| {
                    const o = ((y0 + yy) * W + x0 + xx) * 3;
                    img[o] = bb[0];
                    img[o + 1] = bb[1];
                    img[o + 2] = bb[2];
                };
            }
            if (cell.cp == ' ') continue;
            const cp: u21 = switch (cell.cp) {
                0x2013, 0x2014 => '-',
                else => cell.cp,
            };
            const gl = fx.font.glyph(cp);
            const sc = 2;
            const gx0 = x0 + (CELL_W - 5 * sc) / 2;
            const gy0 = y0 + 3;
            for (0..fx.font.glyph_h) |gr| {
                for (0..5) |gc| {
                    if (!gl.lit(gc, gr)) continue;
                    var dx: usize = 0;
                    const extra: usize = if (cell.bold) 1 else 0;
                    while (dx < sc + extra) : (dx += 1) {
                        for (0..sc) |dy| {
                            const px = gx0 + gc * sc + dx;
                            const py = gy0 + gr * sc + dy;
                            if (px >= W or py >= H) continue;
                            const o = (py * W + px) * 3;
                            img[o] = cell.fg.r;
                            img[o + 1] = cell.fg.g;
                            img[o + 2] = cell.fg.b;
                        }
                    }
                }
            }
        }
    }

    var path_buf: [512]u8 = undefined;
    const tag = if (c.mode == .half) "h" else "k";
    const path = try std.mem.print(&path_buf, "{s}/{s}_{s}.ppm", .{ c.out_dir, tag, name });
    const file = try std.Io.Dir.cwd().createFile(c.io, path, .{});
    defer file.close(c.io);
    var hdr: [64]u8 = undefined;
    try file.writeStreamingAll(c.io, try std.mem.print(&hdr, "P6\n{d} {d}\n255\n", .{ W, H }));
    try file.writeStreamingAll(c.io, img);
}

fn avg(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + b) / 2);
}

// ---------------------------------------------------------------------------
// Benchmark
// ---------------------------------------------------------------------------

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn bench(io: std.Io, gpa: std.mem.Allocator, args: Args) !void {
    inline for (.{ Mode.kitty, Mode.half }) |mode| for (args.games) |game| {
        var c = try newCtx(io, gpa, args, mode, game);
        defer freeCtx(&c);
        press(&c, keys.code.enter);
        c.bot_at = 0.45;
        // a busy mid-game moment: level 8 chords + overtime
        for ([_]u8{ 2, 8, 11 }) |lvl| {
            jumpToLevel(&c, lvl, 5000);
            var total: i96 = 0;
            var worst: i96 = 0;
            const n = 600;
            for (0..n) |_| {
                c.now += 16;
                c.botStep();
                c.syncPlayWidth();
                c.arc.update(c.now);
                const a = nowNs(io);
                c.scene.render(&c.surf, &c.arc, c.now, c.quality());
                const b = nowNs(io);
                c.arc.clearEvents();
                total += b - a;
                worst = @max(worst, b - a);
            }
            std.debug.print("{s} {s} {d}x{d} px level {d}: avg {d:.3} ms  worst {d:.3} ms  (fx particles {d}, effects {d})\n", .{
                @tagName(mode),
                @tagName(game),
                c.surf.w,
                c.surf.h,
                lvl,
                @as(f64, @floatFromInt(total)) / n / 1e6,
                @as(f64, @floatFromInt(worst)) / 1e6,
                c.scene.fx.particles.len,
                c.scene.fx.activeEffects(),
            });
        }
    };
}

test {
    _ = @import("game/scene.zig");
}
