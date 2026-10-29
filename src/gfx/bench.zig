//! Synthetic busy scene + bytes/frame measurements for the presenters.
//!
//! `zig test src/gfx_tests.zig -O ReleaseFast --test-filter bench` prints
//! bytes per frame (and timing) for half-block at 160×45 cells and kitty
//! direct at 640×360 pixels.

const std = @import("std");
const surface_mod = @import("../fx/surface.zig");
const Surface = surface_mod.Surface;
const Px = surface_mod.Px;
const Color = @import("../ui/color.zig").Color;
const presenter = @import("presenter.zig");

/// Fill `s` with frame `t` of a busy synthetic scene: a moving diagonal
/// gradient, a perspective-ish RGB band at the bottom, ~300 drifting glow
/// particles and a few HUD text strings. `busy == false` keeps the
/// background a static vertical gradient (closer to the real backdrop).
pub fn fillScene(s: *Surface, t: u32, busy: bool) void {
    const w = s.w;
    const h = s.h;
    const tf: f32 = @floatFromInt(t);
    for (0..h) |y| {
        const fy: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h, 1)));
        for (0..w) |x| {
            const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(w, 1)));
            const wob: f32 = if (busy) 1 else 0;
            var r: f32 = 11 + 30 * fy + wob * 12 * @sin(fx * 6 + tf * 0.05);
            var g: f32 = 12 + 10 * fy;
            var b: f32 = 34 + 40 * fy + wob * 10 * @cos(fy * 5 - tf * 0.04);
            if (fy > 0.65) { // LED keyboard band with a travelling hue wave
                const k = (fy - 0.65) / 0.35;
                const ph = fx * 9 - tf * 0.09;
                r += 90 * k * (0.5 + 0.5 * @sin(ph));
                g += 90 * k * (0.5 + 0.5 * @sin(ph + 2.1));
                b += 90 * k * (0.5 + 0.5 * @sin(ph + 4.2));
            }
            s.pixels[y * w + x] = .{ .r = clamp8(r), .g = clamp8(g), .b = clamp8(b) };
        }
    }
    // particles
    var prng = std.Random.DefaultPrng.init(1234);
    const rnd = prng.random();
    const scale: f32 = @as(f32, @floatFromInt(w)) / 160.0;
    for (0..300) |_| {
        const x0 = rnd.float(f32) * @as(f32, @floatFromInt(w));
        const y0 = rnd.float(f32) * @as(f32, @floatFromInt(h));
        const vx = (rnd.float(f32) - 0.5) * 2 * scale;
        const vy = (rnd.float(f32) - 0.2) * 1.5 * scale;
        const hue = rnd.float(f32);
        const px = @mod(x0 + vx * tf, @as(f32, @floatFromInt(w)));
        const py = @mod(y0 + vy * tf, @as(f32, @floatFromInt(h)));
        const rad: f32 = @max(1, 1.5 * scale);
        const c: [3]f32 = .{ 255 * (0.5 + 0.5 * @sin(hue * 6.28)), 255 * (0.5 + 0.5 * @sin(hue * 6.28 + 2.1)), 255 };
        const ri: i32 = @intFromFloat(@ceil(rad));
        var dy: i32 = -ri;
        while (dy <= ri) : (dy += 1) {
            var dx: i32 = -ri;
            while (dx <= ri) : (dx += 1) {
                const xx = @as(i32, @intFromFloat(px)) + dx;
                const yy = @as(i32, @intFromFloat(py)) + dy;
                if (xx < 0 or yy < 0 or xx >= w or yy >= h) continue;
                const d = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy))) / (rad + 0.5);
                if (d >= 1) continue;
                const a = 1 - d;
                const p = &s.pixels[@as(usize, @intCast(yy)) * w + @as(usize, @intCast(xx))];
                p.r = clamp8(@as(f32, @floatFromInt(p.r)) + c[0] * a);
                p.g = clamp8(@as(f32, @floatFromInt(p.g)) + c[1] * a);
                p.b = clamp8(@as(f32, @floatFromInt(p.b)) + c[2] * a);
            }
        }
    }
    // HUD text (score changes every frame)
    s.clearText();
    var buf: [32]u8 = undefined;
    const score = std.mem.print(&buf, "{d}", .{t * 37}) catch unreachable;
    s.putText(2, 1, score, Color.rgb(243, 238, 228), null, true);
    s.putText(@divTrunc(@as(i32, s.cols), 2) - 2, 1, "13:42", Color.rgb(20, 20, 20), Color.rgb(239, 230, 210), true);
    s.putText(@as(i32, s.cols) - 10, 1, "312 kpm", Color.rgb(255, 191, 94), null, true);
    // a few keycap legends drifting down
    for (0..12) |i| {
        const col: i32 = @intCast(5 + i * (s.cols / 13));
        const row: i32 = @intCast((t / 4 + i * 3) % @max(s.rows, 1));
        s.putText(col, row, "K", Color.rgb(37, 35, 42), null, true);
    }
}

fn report(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").optimize != .debug) std.debug.print(fmt, args);
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 255));
}

const testing = std.testing;

fn measure(backend: presenter.Backend, opts: presenter.Options, cols: u16, rows: u16, w: u32, h: u32, frames: u32, busy: bool) !struct { avg: usize, first: usize, ns: i96 } {
    var s = try Surface.init(testing.allocator, cols, rows, w, h);
    defer s.deinit();
    var p = try presenter.Presenter.init(testing.allocator, backend, opts);
    defer p.deinit();
    var total: usize = 0;
    var first: usize = 0;
    var ns: i96 = 0;
    const io = testing.io;
    for (0..frames + 1) |f| {
        fillScene(&s, @intCast(f), busy);
        const t0 = std.Io.Timestamp.now(io, .awake);
        const out = try p.present(&s);
        const dt = t0.untilNow(io, .awake).toNanoseconds();
        if (f == 0) first = out.len else {
            total += out.len;
            ns += dt;
        }
    }
    return .{ .avg = total / frames, .first = first, .ns = @divTrunc(ns, frames) };
}

test "bench: bytes per frame (synthetic scenes)" {
    // Debug (`zig build test`): exercise the code quietly with few frames.
    const quick = @import("builtin").optimize == .debug;
    const hb_frames: u32 = if (quick) 10 else 120;
    const k_frames: u32 = if (quick) 2 else 30;
    inline for (.{ true, false }) |busy| {
        const label = if (busy) "busy" else "calm";
        inline for (.{ 0, 1, 2, 3 }) |q| {
            const r = try measure(.halfblock, .{ .halfblock_quant_bits = q }, 160, 45, 160, 90, hb_frames, busy);
            report("\n[{s}] halfblock 160x45 quant={d}: first={d}B avg={d}B/frame ({d} us)", .{ label, q, r.first, r.avg, @divTrunc(r.ns, 1000) });
            try testing.expect(r.avg > 0);
        }
        inline for (.{ .{ true, false }, .{ false, false }, .{ true, true }, .{ false, true } }) |cfg| {
            const r = try measure(.kitty, .{ .rgb24 = cfg[0], .kitty_png = cfg[1] }, 160, 45, 640, 360, k_frames, busy);
            report("\n[{s}] kitty direct 640x360 {s} {s}: first={d}B avg={d}B/frame ({d} us)", .{
                label, if (cfg[1]) "png  " else "zlib ", if (cfg[0]) "rgb " else "rgba", r.first, r.avg, @divTrunc(r.ns, 1000),
            });
            try testing.expect(r.avg > 0);
        }
    }
    const e = try measure(.external, .{}, 160, 45, 640, 360, hb_frames, true);
    report("\nexternal 160x45: first={d}B avg={d}B/frame\n", .{ e.first, e.avg });
}
