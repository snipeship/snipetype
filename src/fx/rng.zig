//! Tiny deterministic PRNG and hash helpers for effects (wasm-safe).

const std = @import("std");

/// xorshift32* — fast, good enough for particles, never zero state.
pub const Rng = struct {
    s: u32,

    pub fn init(seed: u32) Rng {
        return .{ .s = mix32(seed) | 1 };
    }

    pub fn next(self: *Rng) u32 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.s = x;
        return x *% 0x9E3779BB;
    }

    /// Uniform float in [0, 1).
    pub fn float(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 8)) * (1.0 / 16777216.0);
    }

    /// Uniform float in [lo, hi).
    pub fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.float();
    }

    /// Uniform float in [-1, 1).
    pub fn signed(self: *Rng) f32 {
        return self.float() * 2 - 1;
    }

    /// Uniform integer in [0, n).
    pub fn int(self: *Rng, n: u32) u32 {
        if (n == 0) return 0;
        return @intCast((@as(u64, self.next()) * n) >> 32);
    }

    /// -1 or +1.
    pub fn sign(self: *Rng) f32 {
        return if (self.next() & 0x10000 != 0) 1 else -1;
    }

    pub fn chance(self: *Rng, p: f32) bool {
        return self.float() < p;
    }
};

/// Integer finalizer (murmur3 fmix32).
pub fn mix32(v: u32) u32 {
    var h = v;
    h ^= h >> 16;
    h *%= 0x85eb_ca6b;
    h ^= h >> 13;
    h *%= 0xc2b2_ae35;
    h ^= h >> 16;
    return h;
}

/// Stateless hash of (a, b) → [0, 1).
pub fn hash01(a: u32, b: u32) f32 {
    const h = mix32(a *% 0x27d4_eb2d ^ mix32(b +% 0x1656_67b1));
    return @as(f32, @floatFromInt(h >> 8)) * (1.0 / 16777216.0);
}

test "rng ranges" {
    var r = Rng.init(42);
    var lo: f32 = 1;
    var hi: f32 = 0;
    for (0..10000) |_| {
        const f = r.float();
        try std.testing.expect(f >= 0 and f < 1);
        lo = @min(lo, f);
        hi = @max(hi, f);
        try std.testing.expect(r.int(7) < 7);
    }
    try std.testing.expect(lo < 0.01 and hi > 0.99);
    try std.testing.expectEqual(@as(u32, 0), r.int(0));
}

test "rng deterministic and hash stable" {
    var a = Rng.init(7);
    var b = Rng.init(7);
    for (0..10) |_| try std.testing.expectEqual(a.next(), b.next());
    try std.testing.expectEqual(hash01(3, 4), hash01(3, 4));
    try std.testing.expect(hash01(3, 4) != hash01(4, 3));
}
