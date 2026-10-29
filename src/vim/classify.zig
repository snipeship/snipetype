//! Vim word classes: blank (space, tab, end of line), keyword
//! ([A-Za-z0-9_] and non-ASCII bytes) and punctuation (any other
//! non-blank). WORD motions (W B E gE iW aW) treat every non-blank alike.

pub const blank: u8 = 0;
pub const punct: u8 = 1;
pub const keyword: u8 = 2;

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn isKeyword(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c >= 0x80;
}

/// Class of a char; 0 (NUL) is the end of a line and counts as blank.
pub fn cls(c: u8, big: bool) u8 {
    if (c == ' ' or c == '\t' or c == 0) return blank;
    if (big) return punct;
    return if (isKeyword(c)) keyword else punct;
}

test "classes" {
    const t = @import("std").testing;
    try t.expectEqual(keyword, cls('a', false));
    try t.expectEqual(keyword, cls('_', false));
    try t.expectEqual(punct, cls('(', false));
    try t.expectEqual(punct, cls('!', false));
    try t.expectEqual(blank, cls('\t', false));
    try t.expectEqual(punct, cls('a', true));
}
