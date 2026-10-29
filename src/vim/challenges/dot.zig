//! Drills for the "dot" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "dot/semicolons-01",
        .lesson = .dot,
        .title = "Semicolons",
        .prompt = "End every line with ';'",
        .start = "|let a = 1\nlet b = 2\nlet c = 3",
        .goal = "let a = 1;\nlet b = 2;\nlet c = 3;",
        .par = 7,
        .solutions = &.{"A;<Esc>j.j."},
        .why = ". repeats the whole A;<Esc> change",
    },
    .{
        .id = "dot/cw-dot-01",
        .lesson = .dot,
        .title = "Rename twice",
        .prompt = "foo becomes bar both times",
        .start = "|foo(x) + foo(y)",
        .goal = "bar(x) + bar(y)",
        .par = 9,
        .solutions = &.{"cwbar<Esc>ff."},
        .why = "change once, move, and . does it again",
    },
    .{
        .id = "dot/dd-dot-01",
        .lesson = .dot,
        .title = "Comments out",
        .prompt = "Delete the two comment lines",
        .start = "|# a\n# b\ncode\n# c",
        .goal = "code\n# c",
        .par = 3,
        .solutions = &.{"dd."},
        .why = ". repeats a delete too",
    },
    .{
        .id = "dot/indent-dot-01",
        .lesson = .dot,
        .title = "Indent the block",
        .prompt = "Indent both statements",
        .start = "if x:\n|a = 1\nb = 2",
        .goal = "if x:\n    a = 1\n    b = 2",
        .par = 4,
        .solutions = &.{">>j."},
        .why = ">> shifts a line; . shifts the next one",
    },
};
