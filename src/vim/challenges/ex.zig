//! Drills for the "ex" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "ex/sub-01",
        .lesson = .ex,
        .title = "Dashes",
        .prompt = "Replace every '_' on the line",
        .start = "|a_b a_b a_b",
        .goal = "a-b a-b a-b",
        .par = 9,
        .solutions = &.{":s/_/-/g<CR>"},
        .why = ":s replaces on the line; g replaces every match, not just the first",
    },
    .{
        .id = "ex/sub-all-01",
        .lesson = .ex,
        .title = "No more var",
        .prompt = "var becomes let on every line",
        .start = "|var a = 1;\nvar b = 2;\nvar c = 3;",
        .goal = "let a = 1;\nlet b = 2;\nlet c = 3;",
        .par = 13,
        .solutions = &.{":%s/var/let/<CR>"},
        .why = "% is the range 'every line'",
    },
    .{
        .id = "ex/sub-range-01",
        .lesson = .ex,
        .title = "Lines 2 and 3",
        .prompt = "Replace old with new on lines 2-3 only",
        .start = "|x = old\ny = old\nz = old",
        .goal = "x = old\ny = new\nz = new",
        .par = 15,
        .solutions = &.{":2,3s/old/new/<CR>"},
        .why = "a range a,b limits :s to those lines",
    },
    .{
        .id = "ex/move-01",
        .lesson = .ex,
        .title = "Imports first",
        .prompt = "Move the use line to the top",
        .start = "fn main() {}\n|use std::io;",
        .goal = "use std::io;\nfn main() {}",
        .par = 4,
        .solutions = &.{":m0<CR>"},
        .why = ":m0 moves the line below line 0, i.e. to the top",
    },
};
