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
};
