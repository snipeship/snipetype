//! Shared config types (mode/lang/config).

const std = @import("std");

pub const Mode = enum {
    words,
    sentences,
    code,
    vim,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .words => "words",
            .sentences => "sentences",
            .code => "code",
            .vim => "vim",
        };
    }

    pub fn fromString(s: []const u8) ?Mode {
        inline for (@typeInfo(Mode).@"enum".fields) |field| {
            if (std.mem.eql(u8, s, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Lang = enum {
    mixed,
    zig,
    rust,
    go,
    typescript,
    python,
    c,

    pub fn name(self: Lang) []const u8 {
        return switch (self) {
            .mixed => "mixed",
            .zig => "zig",
            .rust => "rust",
            .go => "go",
            .typescript => "ts",
            .python => "python",
            .c => "c",
        };
    }

    pub fn fromString(s: []const u8) ?Lang {
        if (std.mem.eql(u8, s, "mixed")) return .mixed;
        if (std.mem.eql(u8, s, "zig")) return .zig;
        if (std.mem.eql(u8, s, "rust") or std.mem.eql(u8, s, "rs")) return .rust;
        if (std.mem.eql(u8, s, "go")) return .go;
        if (std.mem.eql(u8, s, "typescript") or std.mem.eql(u8, s, "ts") or std.mem.eql(u8, s, "js")) return .typescript;
        if (std.mem.eql(u8, s, "python") or std.mem.eql(u8, s, "py")) return .python;
        if (std.mem.eql(u8, s, "c")) return .c;
        return null;
    }
};

pub const Config = struct {
    mode: Mode = .words,
    word_count: usize = 10,
    time_limit: usize = 0,
    lang: Lang = .mixed,
};
