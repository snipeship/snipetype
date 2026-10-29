/// A buffer position. `col` may equal the line length (the position after
/// the last character, Vim's NUL) while inserting or inside a motion.
pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,

    pub fn lessThan(a: Cursor, b: Cursor) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }

    pub fn equals(a: Cursor, b: Cursor) bool {
        return a.row == b.row and a.col == b.col;
    }

    pub fn min(a: Cursor, b: Cursor) Cursor {
        return if (b.lessThan(a)) b else a;
    }

    pub fn max(a: Cursor, b: Cursor) Cursor {
        return if (b.lessThan(a)) a else b;
    }
};
