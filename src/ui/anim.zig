//! Results animations as pure functions of the clock: the numbers count up
//! with an ease-out, the graph draws in left to right, and a new personal
//! best twinkles a few sparkles around the banner.
//!
//! Everything is keyed on `UiState.finished_ms` (when the results appeared)
//! and the frame's `now_ms`. With `finished_ms == null`, a clock before it,
//! or once the window has passed, every function returns its final value,
//! so the last frame is exactly the static card.

const std = @import("std");

/// Count-up of the big WPM and the stats.
pub const COUNT_MS: i64 = 600;
/// Graph draw-in.
pub const GRAPH_MS: i64 = 500;
/// PB sparkle around the banner.
pub const SPARKLE_MS: i64 = 1500;

/// Linear progress 0..1 of an animation lasting `dur_ms`; 1 when there is
/// no animation (no start, a clock before the start, or past the end).
pub fn progress(finished_ms: ?i64, now_ms: i64, dur_ms: i64) f32 {
    const start = finished_ms orelse return 1;
    const dt = now_ms - start;
    if (dt < 0 or dt >= dur_ms) return 1;
    return @as(f32, @floatFromInt(dt)) / @as(f32, @floatFromInt(dur_ms));
}

/// Cubic ease-out: fast start, gentle landing; exact at 0 and 1.
pub fn easeOut(p: f32) f32 {
    const q = 1 - std.math.clamp(p, 0, 1);
    return 1 - q * q * q;
}

/// `value` counted up at progress `p` (exactly `value` at p = 1).
pub fn countUp(value: f32, p: f32) f32 {
    if (p >= 1) return value;
    return value * easeOut(p);
}

/// Integer version of `countUp`.
pub fn countUpInt(value: u32, p: f32) u32 {
    if (p >= 1) return value;
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * easeOut(p)));
}

/// Progress of every results animation at `now_ms`.
pub const Frame = struct {
    count: f32 = 1,
    graph: f32 = 1,
    /// Milliseconds into the sparkle, or null when it isn't running.
    sparkle_ms: ?i64 = null,

    pub fn at(finished_ms: ?i64, now_ms: i64, sparkle: bool) Frame {
        var f: Frame = .{
            .count = progress(finished_ms, now_ms, COUNT_MS),
            .graph = progress(finished_ms, now_ms, GRAPH_MS),
        };
        if (sparkle and progress(finished_ms, now_ms, SPARKLE_MS) < 1) f.sparkle_ms = now_ms - finished_ms.?;
        return f;
    }

    /// The final (static) frame.
    pub const final: Frame = .{};

    pub fn isFinal(self: Frame) bool {
        return self.count >= 1 and self.graph >= 1 and self.sparkle_ms == null;
    }
};

/// True while any animation started at `finished_ms` is mid-way.
pub fn active(finished_ms: ?i64, now_ms: i64, sparkle: bool) bool {
    return !Frame.at(finished_ms, now_ms, sparkle).isFinal();
}

/// A sparkle cell: offset from the banner (dx < 0: left of the text,
/// dx >= 0: columns past its end), and whether it shows as `✦` or `·`.
pub const Spark = struct { dx: i32, big: bool };

/// Offsets around the banner, nearest first.
const SPARK_SLOTS = [_]i32{ -2, 1, -4, 3, -6, 5 };

/// The sparkle cells visible `ms` into the sparkle (each twinkles on its
/// own phase and fades out over the last third).
pub fn sparks(ms: i64, out: *[SPARK_SLOTS.len]Spark) []const Spark {
    var n: usize = 0;
    const fade = SPARKLE_MS * 2 / 3;
    for (SPARK_SLOTS, 0..) |dx, k| {
        const phase = @divTrunc(ms, 90) + @as(i64, @intCast(k)) * 3;
        const on = @mod(phase, 5) < 3;
        // Outer sparkles go out first while fading.
        if (ms > fade and k >= SPARK_SLOTS.len - @as(usize, @intCast(@divTrunc((ms - fade) * (SPARK_SLOTS.len + 1), SPARKLE_MS - fade)))) continue;
        if (!on) continue;
        out[n] = .{ .dx = dx, .big = @mod(phase, 5) == 1 };
        n += 1;
    }
    return out[0..n];
}

test "progress and easing" {
    try std.testing.expectEqual(@as(f32, 1), progress(null, 5, 600));
    try std.testing.expectEqual(@as(f32, 0), progress(1000, 1000, 600));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), progress(1000, 1300, 600), 1e-6);
    try std.testing.expectEqual(@as(f32, 1), progress(1000, 1600, 600));
    try std.testing.expectEqual(@as(f32, 1), progress(1000, 900, 600));
    try std.testing.expectEqual(@as(f32, 0), easeOut(0));
    try std.testing.expectEqual(@as(f32, 1), easeOut(1));
    try std.testing.expect(easeOut(0.5) > 0.5);
}

test "count-up at start, middle and end" {
    try std.testing.expectEqual(@as(f32, 0), countUp(87.4, 0));
    const mid = countUp(87.4, 0.5);
    try std.testing.expect(mid > 43.7 and mid < 87.4);
    try std.testing.expectEqual(@as(f32, 87.4), countUp(87.4, 1));
    try std.testing.expectEqual(@as(u32, 130), countUpInt(130, 1));
    try std.testing.expectEqual(@as(u32, 0), countUpInt(130, 0));
}

test "active boundaries" {
    try std.testing.expect(!active(null, 0, true));
    try std.testing.expect(active(1000, 1000, false));
    try std.testing.expect(active(1000, 1000 + COUNT_MS - 1, false));
    try std.testing.expect(!active(1000, 1000 + COUNT_MS, false));
    try std.testing.expect(active(1000, 1000 + COUNT_MS, true));
    try std.testing.expect(active(1000, 1000 + SPARKLE_MS - 1, true));
    try std.testing.expect(!active(1000, 1000 + SPARKLE_MS, true));
    try std.testing.expect(!active(1000, 999, true));
}

test "sparkles twinkle and fade out" {
    var buf: [SPARK_SLOTS.len]Spark = undefined;
    var seen: usize = 0;
    var t: i64 = 0;
    while (t < SPARKLE_MS) : (t += 33) seen += sparks(t, &buf).len;
    try std.testing.expect(seen > 0);
    try std.testing.expect(sparks(0, &buf).len < SPARK_SLOTS.len);
    try std.testing.expectEqual(@as(usize, 0), sparks(SPARKLE_MS - 1, &buf).len);
}
