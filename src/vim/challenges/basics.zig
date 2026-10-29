//! Drills for the "basics" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "basics/x-01",
        .lesson = .basics,
        .title = "Stray char",
        .prompt = "Delete the extra 'x' (count + l, then x)",
        .start = "|let xa = 1;",
        .goal = "let a = 1;",
        .par = 3,
        .solutions = &.{"4lx"},
        .why = "a count before l moves several columns at once",
    },
    .{
        .id = "basics/j-01",
        .lesson = .basics,
        .title = "Extra semicolon",
        .prompt = "Go doesn't need that ';' on line 2",
        .start = "|x := 1\ny := 2;\nz := 3",
        .goal = "x := 1\ny := 2\nz := 3",
        .par = 4,
        .solutions = &.{"j6lx"},
        .why = "j moves down a line; 6l jumps six columns",
    },
    .{
        .id = "basics/k-01",
        .lesson = .basics,
        .title = "Wrong value",
        .prompt = "Make b equal 1",
        .start = "int a = 1;\nint b = 2;\nint |c = 3;",
        .goal = "int a = 1;\nint b = 1;\nint c = 3;",
        .par = 5,
        .solutions = &.{"k4lr1"},
        .why = "k keeps the column; r replaces one char without leaving NORMAL",
    },
    .{
        .id = "basics/count-01",
        .lesson = .basics,
        .title = "Garbage prefix",
        .prompt = "Delete the three x's",
        .start = "|xxxreturn 0;",
        .goal = "return 0;",
        .par = 2,
        .solutions = &.{"3x"},
        .why = "a count works on commands too: 3x deletes three chars",
    },
};
