/// Editor mode. Operator-pending is not a mode of its own: it is NORMAL with
/// `VimEditor.isPending()` true.
pub const Mode = enum {
    normal,
    insert,
    replace,
    visual,
    visual_line,
    cmdline,
    /// Ctrl+V: a rectangle of display columns.
    visual_block,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .replace => "REPLACE",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .cmdline => "COMMAND",
            .visual_block => "V-BLOCK",
        };
    }

    /// Legacy name of `label`.
    pub fn name(self: Mode) []const u8 {
        return self.label();
    }

    pub fn isVisual(self: Mode) bool {
        return self == .visual or self == .visual_line or self == .visual_block;
    }
};

/// Legacy alias.
pub const VimMode = Mode;
