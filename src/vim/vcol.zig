//! Display (virtual) columns: a tab spans up to the next multiple of
//! `tabstop`; every other byte is one cell. Lines are short, so these walk
//! the line each time.

const std = @import("std");

/// Width of byte `c` drawn at display column `vc`.
pub fn charWidth(c: u8, vc: usize, ts: u8) usize {
    if (c != '\t') return 1;
    const t: usize = @max(ts, 1);
    return t - vc % t;
}

/// Display column where byte `col` starts (past the end: one cell per byte).
pub fn displayCol(line: []const u8, col: usize, ts: u8) usize {
    var vc: usize = 0;
    for (line[0..@min(col, line.len)]) |c| vc += charWidth(c, vc, ts);
    return vc + (col -| line.len);
}

/// Last display column covered by byte `col` (a tab covers several).
pub fn displayEnd(line: []const u8, col: usize, ts: u8) usize {
    const vc = displayCol(line, col, ts);
    if (col >= line.len) return vc;
    return vc + charWidth(line[col], vc, ts) - 1;
}

/// Total display width of a line.
pub fn width(line: []const u8, ts: u8) usize {
    return displayCol(line, line.len, ts);
}

/// The byte whose cells contain display column `want` (Vim's coladvance):
/// the last char when `want` is past the end, `line.len` for an empty line.
pub fn byteAt(line: []const u8, want: usize, ts: u8) usize {
    var vc: usize = 0;
    for (line, 0..) |c, i| {
        const w = charWidth(c, vc, ts);
        if (want < vc + w) return i;
        vc += w;
    }
    return line.len -| 1;
}

/// Like `byteAt`, but a column past the end gives `line.len` (visual
/// mode and block edges may sit on the end of line).
pub fn byteAtOrEnd(line: []const u8, want: usize, ts: u8) usize {
    var vc: usize = 0;
    for (line, 0..) |c, i| {
        const w = charWidth(c, vc, ts);
        if (want < vc + w) return i;
        vc += w;
    }
    return line.len;
}

const testing = std.testing;

test "display columns with tabs" {
    try testing.expectEqual(@as(usize, 0), displayCol("\tx", 0, 8));
    try testing.expectEqual(@as(usize, 8), displayCol("\tx", 1, 8));
    try testing.expectEqual(@as(usize, 8), displayCol("ab\tx", 3, 8));
    try testing.expectEqual(@as(usize, 7), displayEnd("ab\tx", 2, 8));
    try testing.expectEqual(@as(usize, 2), byteAt("ab\tx", 5, 8));
    try testing.expectEqual(@as(usize, 3), byteAt("ab\tx", 8, 8));
    try testing.expectEqual(@as(usize, 3), byteAt("ab\tx", 20, 8));
    try testing.expectEqual(@as(usize, 4), byteAtOrEnd("ab\tx", 20, 8));
    try testing.expectEqual(@as(usize, 9), width("ab\tx", 8));
    try testing.expectEqual(@as(usize, 6), displayCol("ab", 6, 8));
}
