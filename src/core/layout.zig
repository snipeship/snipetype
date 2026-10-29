//! Layout emulation: a QWERTY keyboard typing as dvorak, colemak or
//! colemak-dh (ANSI). The App remaps each typed char of the simple modes
//! through `remap`; the heatmap draws `rows`.

const std = @import("std");

const types = @import("types.zig");
const Layout = types.Layout;
const stats = @import("stats.zig");

/// Unshifted rows top to bottom: number row, top, home, bottom.
const qwerty_rows = [4][]const u8{ "`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./" };
const dvorak_rows = [4][]const u8{ "`1234567890[]", "',.pyfgcrl/=\\", "aoeuidhtns-", ";qjkxbmwvz" };
const colemak_rows = [4][]const u8{ "`1234567890-=", "qwfpgjluy;[]\\", "arstdhneio'", "zxcvbkm,./" };
const colemak_dh_rows = [4][]const u8{ "`1234567890-=", "qwfpbjluy;[]\\", "arstgmneio'", "zxcdvkh,./" };

/// Unshifted rows of `l`, top to bottom (for the heatmap).
pub fn rows(l: Layout) [4][]const u8 {
    return switch (l) {
        .qwerty => qwerty_rows,
        .dvorak => dvorak_rows,
        .colemak => colemak_rows,
        .colemak_dh => colemak_dh_rows,
    };
}

/// Per layout: KEYSET index of a QWERTY key → the char `l` types there.
const tables = blk: {
    @setEvalBranchQuota(100_000);
    var t: [std.meta.tags(Layout).len][stats.KEYSET.len]u8 = undefined;
    for (std.meta.tags(Layout)) |l| {
        const to = rows(l);
        for (stats.KEYSET, 0..) |k, ki| {
            t[@backingInt(l)][ki] = k;
            for (qwerty_rows, 0..) |row, r| {
                if (std.mem.indexOfScalar(u8, row, k)) |c| t[@backingInt(l)][ki] = to[r][c];
            }
        }
    }
    break :blk t;
};

/// A char typed at a QWERTY key position → the char of `l` at that
/// position, shift-aware ('S' → 'O' in dvorak). Identity for qwerty and
/// for chars outside the main block (space, control bytes, non-ASCII).
pub fn remap(l: Layout, c: u8) u8 {
    if (l == .qwerty) return c;
    const ki = stats.keyIndex(c) orelse return c;
    const shifted = stats.KEYSET[ki] != c;
    const out = tables[@backingInt(l)][ki];
    if (!shifted) return out;
    const oi = stats.keyIndex(out) orelse return out;
    return stats.SHIFTED[oi];
}

const testing = std.testing;

fn remapStr(l: Layout, s: []const u8, buf: []u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = remap(l, c);
    return buf[0..s.len];
}

test "home rows and shift awareness" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aoeu", remapStr(.dvorak, "asdf", &buf));
    try testing.expectEqualStrings("arst", remapStr(.colemak, "asdf", &buf));
    try testing.expectEqualStrings("arstgmneio", remapStr(.colemak_dh, "asdfghjkl;", &buf));
    try testing.expectEqualStrings("asdf", remapStr(.qwerty, "asdf", &buf));
    // Shifted: uppercase stays uppercase, symbols follow their key.
    try testing.expectEqualStrings("AOEU", remapStr(.dvorak, "ASDF", &buf));
    try testing.expectEqual(@as(u8, 's'), remap(.dvorak, ';'));
    try testing.expectEqual(@as(u8, 'S'), remap(.dvorak, ':'));
    try testing.expectEqual(@as(u8, '"'), remap(.dvorak, 'Q'));
    try testing.expectEqual(@as(u8, ':'), remap(.dvorak, 'Z'));
    try testing.expectEqual(@as(u8, 'O'), remap(.colemak, ':'));
    try testing.expectEqual(@as(u8, '{'), remap(.dvorak, '_'));
    // Outside the block: unchanged.
    for ([_]u8{ ' ', '\n', 0x1b, 0xc3, '1', '!' }) |c| try testing.expectEqual(c, remap(.colemak, c));
}

test "every layout is a permutation of the QWERTY block" {
    for (std.meta.tags(Layout)) |l| {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        var n: usize = 0;
        for (rows(l), qwerty_rows) |r, q| {
            try testing.expectEqual(q.len, r.len);
            @memcpy(a[n..][0..r.len], r);
            @memcpy(b[n..][0..q.len], q);
            n += r.len;
        }
        std.mem.sort(u8, a[0..n], {}, std.sort.asc(u8));
        std.mem.sort(u8, b[0..n], {}, std.sort.asc(u8));
        try testing.expectEqualStrings(b[0..n], a[0..n]);
        // remap is a bijection on printable ASCII.
        var seen: [128]bool = @splat(false);
        for (0x20..0x7f) |c| {
            const o = remap(l, @intCast(c));
            try testing.expect(o >= 0x20 and o < 0x7f);
            try testing.expect(!seen[o]);
            seen[o] = true;
        }
    }
}
