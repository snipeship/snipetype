//! Drills for the "block" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "block/insert-01",
        .lesson = .block,
        .title = "Comment out a block",
        .prompt = "Put \"// \" in front of all three lines",
        .start = "|let a = 1;\nlet b = 2;\nlet c = 3;",
        .goal = "// let a = 1;\n// let b = 2;\n// let c = 3;",
        .par = 8,
        .solutions = &.{ "<C-v>2jI// <Esc>", "<C-v>GI// <Esc>" },
        .why = "Ctrl+V selects a column; I types on every row at once (the rows fill in on <Esc>)",
    },
    .{
        .id = "block/append-01",
        .lesson = .block,
        .title = "Ragged semicolons",
        .prompt = "End every line with ';' (the lines have different lengths)",
        .start = "|let a = 1\nlet total = 22\nlet c = 3",
        .goal = "let a = 1;\nlet total = 22;\nlet c = 3;",
        .par = 7,
        .solutions = &.{ "<C-v>2j$A;<Esc>", "<C-v>jj$A;<Esc>" },
        .why = "$ in a block reaches each line's own end, so A appends after the last char of every row",
    },
    .{
        .id = "block/delete-01",
        .lesson = .block,
        .title = "Line numbers pasted in",
        .prompt = "Delete the \"01 \" numbers in front of each import",
        .start = "|01 import os\n02 import sys\n03 import re",
        .goal = "import os\nimport sys\nimport re",
        .par = 6,
        .solutions = &.{ "<C-v>2j2ld", "<C-v>jjlld" },
        .why = "a block is a rectangle: d removes the same columns from every row",
    },
    .{
        .id = "block/change-01",
        .lesson = .block,
        .title = "Rename the prefix",
        .prompt = "Change \"old\" to \"new\" on all three lines",
        .start = "x = |old_width\ny = old_height\nz = old_depth",
        .goal = "x = new_width\ny = new_height\nz = new_depth",
        .par = 10,
        .solutions = &.{ "<C-v>2j2lcnew<Esc>", "<C-v>jjllcnew<Esc>" },
        .why = "c on a block deletes the rectangle and types the text into every row",
    },
};
