//! Test entry for the pixel effects engine (src/fx/). Run with
//! `zig test src/fx_tests.zig`; wasm-safety check (forces analysis of every
//! public fx function via `refAll` and the `fx_smoke` export below):
//! `zig build-obj -target wasm32-freestanding -O ReleaseSmall -fno-emit-bin src/fx_tests.zig`.

const std = @import("std");
const builtin = @import("builtin");

pub const surface = @import("fx/surface.zig");
pub const color = @import("fx/color.zig");
pub const rng = @import("fx/rng.zig");
pub const canvas = @import("fx/canvas.zig");
pub const post = @import("fx/post.zig");
pub const font = @import("fx/font.zig");
pub const particles = @import("fx/particles.zig");
pub const effects = @import("fx/effects.zig");
pub const popup = @import("fx/popup.zig");
pub const fx_ns = @import("fx/fx.zig");

test {
    _ = color;
    _ = rng;
    _ = canvas;
    _ = post;
    _ = font;
    _ = particles;
    _ = effects;
    _ = popup;
    _ = fx_ns;
}

/// Reference every public, non-inline, non-generic function (recursing into
/// public container types) so the compiler analyzes them for this target.
fn refAll(comptime T: type) void {
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.declarations(T)) |name| {
        const v = @field(T, name);
        const V = @TypeOf(v);
        switch (@typeInfo(V)) {
            .@"fn" => |fi| {
                if (comptime fi.attrs.@"callconv" != .@"inline" and !fi.is_generic) _ = &v;
            },
            .type => switch (@typeInfo(v)) {
                .@"struct", .@"enum", .@"union" => refAll(v),
                else => {},
            },
            else => {},
        }
    }
}

comptime {
    refAll(color);
    refAll(rng);
    refAll(canvas);
    refAll(post);
    refAll(font);
    refAll(particles);
    refAll(effects);
    refAll(popup);
    if (builtin.target.cpu.arch.isWasm()) @export(&smoke, .{ .name = "fx_smoke" });
}

var smoke_mem: [512 << 10]u8 = undefined;

/// Exercise the whole engine once (wasm analysis target; also run natively
/// by the test below).
fn smoke() callconv(.c) u32 {
    var fba = std.heap.FixedBufferAllocator.init(&smoke_mem);
    const a = fba.allocator();
    var s = surface.Surface.init(a, 40, 12, 160, 48) catch return 1;
    defer s.deinit();
    var fx = effects.Fx.initCapacity(a, 512) catch return 2;
    defer fx.deinit();
    inline for (comptime std.meta.tags(effects.Effect)) |e| {
        fx.spawn(e, 80, 24, 8, 6, 0.3, 0.8);
    }
    fx.missBurst(20, 40);
    fx.shockwave(80, 24, 1);
    fx.flash(color.palette.coral, 0.2);
    fx.shake(0.5);
    var frame: u32 = 0;
    while (frame < 30) : (frame += 1) {
        canvas.clear(&s, color.palette.night);
        fx.update(1.0 / 30.0);
        fx.drawUnder(&s);
        fx.drawOver(&s);
        fx.post(&s);
        _ = font.drawText(&s, 2, 2, 1, "+1,440 ×8", color.palette.ink, .{ .glow = 0.5, .bold = true });
        font.drawFlipDigit(&s, 120, 4, 12, 18, '1', '2', 0.5, .{});
        popup.draw(&s, .{ .style = @fromBackingInt(@intCast(frame % popup.style_count)), .text = "redo", .sub = "+90", .x = 80, .y = 20, .t = 0.2, .scale = 1 });
    }
    return @as(u32, s.pixels[0].r) + 100;
}

test "smoke run" {
    try std.testing.expect(smoke() >= 100);
}
