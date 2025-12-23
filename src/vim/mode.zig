pub const VimMode = enum {
    normal,
    insert,
    visual,
    visual_line,

    pub fn name(self: VimMode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
        };
    }
};
