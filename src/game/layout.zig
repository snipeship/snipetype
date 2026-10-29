//! Cell layout of a falling cap, shared by the simulation (overlap-free
//! spawn placement) and the scene (drawing keys and legends on cell centers).
//!
//! A cap is a row of keys: the held modifiers of a chord (Ctrl, Alt, Shift,
//! Super) followed by one key per step. Chords, sequences, words and any cap
//! with a caption sit on a plate that adds one cell of padding on each side
//! and is at least as wide as the caption.

const std = @import("std");
const model = @import("model.zig");

const Cap = model.Cap;
const CapRole = model.CapRole;
const Mods = model.Mods;

pub const MAX_KEYS = model.MAX_STEPS + 4;

/// One keycap of a cap, in cells relative to the cap's left edge.
pub const KeyBox = struct {
    x: u16,
    w: u16,
    legend: []const u8,
    role: CapRole,
    /// Step this key belongs to (modifier keys belong to the chord step).
    step: u8,
    is_mod: bool,
};

pub const Layout = struct {
    boxes: [MAX_KEYS]KeyBox = undefined,
    n: u8 = 0,
    /// Total width in cells (plate included).
    width: u16 = 0,
    /// Draw a plate behind the keys (and the caption below it).
    plate: bool = false,

    pub fn keys(self: *const Layout) []const KeyBox {
        return self.boxes[0..self.n];
    }
};

/// Display width of a legend in cells (one per codepoint).
pub fn legendCols(s: []const u8) u16 {
    return @intCast(std.unicode.utf8CountCodepoints(s) catch s.len);
}

/// Width of one key in cells.
pub fn keyWidth(legend: []const u8, compact: bool) u16 {
    if (compact) return 3;
    return @max(4, legendCols(legend) + 2);
}

/// Modifier legends of `mods` in display order.
pub fn modLegends(mods: Mods, buf: *[4][]const u8) []const []const u8 {
    var n: usize = 0;
    if (mods.ctrl) {
        buf[n] = "Ctrl";
        n += 1;
    }
    if (mods.alt) {
        buf[n] = "Alt";
        n += 1;
    }
    if (mods.shift) {
        buf[n] = "Shift";
        n += 1;
    }
    if (mods.super) {
        buf[n] = "Super";
        n += 1;
    }
    return buf[0..n];
}

pub fn hasPlate(cap: *const Cap) bool {
    return cap.kind != .key or cap.caption.len > 0;
}

/// Lay out `cap`'s keys left to right.
pub fn layout(cap: *const Cap) Layout {
    var out: Layout = .{};
    const compact = cap.kind == .word;
    const gap: u16 = if (compact) 0 else 1;
    out.plate = hasPlate(cap);
    const pad: u16 = if (out.plate) 1 else 0;
    var x: u16 = 0;
    for (cap.stepSlice(), 0..) |step, i| {
        var mbuf: [4][]const u8 = undefined;
        for (modLegends(step.mods, &mbuf)) |m| {
            if (out.n >= MAX_KEYS) break;
            if (out.n > 0) x += gap;
            const w = keyWidth(m, false);
            out.boxes[out.n] = .{ .x = x, .w = w, .legend = m, .role = .modifier, .step = @intCast(i), .is_mod = true };
            out.n += 1;
            x += w;
        }
        if (out.n >= MAX_KEYS) break;
        if (out.n > 0) x += gap;
        const w = keyWidth(step.legend, compact);
        out.boxes[out.n] = .{ .x = x, .w = w, .legend = step.legend, .role = step.role, .step = @intCast(i), .is_mod = false };
        out.n += 1;
        x += w;
    }
    const keys_w = x;
    var width = keys_w + 2 * pad;
    if (out.plate) width = @max(width, legendCols(cap.caption) + 2);
    // Center the keys on the plate.
    const shift = (width - keys_w) / 2;
    for (out.boxes[0..out.n]) |*b| b.x += shift;
    out.width = width;
    return out;
}

/// Approximate width of a cap in terminal cells.
pub fn capWidthCells(cap: *const Cap) u16 {
    return layout(cap).width;
}

/// Number of physical keys a cap needs (modifiers + steps).
pub fn keyCount(cap: *const Cap) u8 {
    var n: u8 = 0;
    for (cap.stepSlice()) |s| {
        const m = s.mods;
        n += 1 + @as(u8, @intFromBool(m.ctrl)) + @intFromBool(m.alt) + @intFromBool(m.shift) + @intFromBool(m.super);
    }
    return n;
}

const testing = std.testing;

fn testCap(kind: model.TargetKind, steps: []const model.Step, caption: []const u8) Cap {
    var c: Cap = .{ .id = 1, .kind = kind, .len = @intCast(steps.len), .x = 0.5, .hue = 0, .caption = caption };
    @memcpy(c.steps[0..steps.len], steps);
    return c;
}

test "single key is four cells" {
    const c = testCap(.key, &.{.{ .code = 'a', .text = 'a', .legend = "a", .role = .letter }}, "");
    const l = layout(&c);
    try testing.expectEqual(@as(u16, 4), l.width);
    try testing.expect(!l.plate);
    try testing.expectEqual(@as(u8, 1), keyCount(&c));
}

test "chord layout has modifier keys and plate" {
    const c = testCap(.chord3, &.{.{ .code = 'z', .mods = .{ .ctrl = true, .shift = true }, .legend = "Z", .role = .letter }}, "redo");
    const l = layout(&c);
    // [Ctrl 6] [Shift 7] [Z 4] + 2 gaps + 2 pad = 21
    try testing.expectEqual(@as(u8, 3), l.n);
    try testing.expectEqual(@as(u16, 21), l.width);
    try testing.expectEqualStrings("Ctrl", l.keys()[0].legend);
    try testing.expect(l.keys()[1].is_mod);
    try testing.expectEqual(@as(u16, 1), l.keys()[0].x);
    try testing.expectEqual(@as(u8, 3), keyCount(&c));
}

test "caption widens the plate and keys are centered" {
    const c = testCap(.key, &.{.{ .code = 'x', .text = 'x', .legend = "x", .role = .letter }}, "delete char");
    const l = layout(&c);
    try testing.expectEqual(@as(u16, 13), l.width);
    try testing.expectEqual(@as(u16, 4), l.keys()[0].x);
}
