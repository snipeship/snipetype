/// Operators that take a motion or text object (`d{motion}`, `g~iw`, ...).
pub const Operator = enum {
    delete, // d
    change, // c
    yank, // y
    indent, // >
    outdent, // <
    lower, // gu
    upper, // gU
    toggle, // g~
    format, // gq
    reindent, // =
    format_keep, // gw (cursor stays)

    /// The key that doubles the operator to act on lines (dd, g~~, gUU).
    pub fn lineKey(self: Operator) u8 {
        return switch (self) {
            .delete => 'd',
            .change => 'c',
            .yank => 'y',
            .indent => '>',
            .outdent => '<',
            .lower => 'u',
            .upper => 'U',
            .toggle => '~',
            .format => 'q',
            .reindent => '=',
            .format_keep => 'w',
        };
    }

    pub fn isChange(self: Operator) bool {
        return self != .yank;
    }
};
