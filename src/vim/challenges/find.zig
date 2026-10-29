//! Drills for the "find" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "find/dt-01",
        .lesson = .find,
        .title = "Trim arguments",
        .prompt = "Delete up to the c",
        .start = "call(|a, b, c)",
        .goal = "call(c)",
        .par = 3,
        .solutions = &.{"dtc"},
        .why = "dt{c} deletes up to, not including, the char",
    },
    .{
        .id = "find/semi-01",
        .lesson = .find,
        .title = "Second zero",
        .prompt = "Make b's bound 1",
        .start = "|if a > 0 and b > 0 and c > 0:",
        .goal = "if a > 0 and b > 1 and c > 0:",
        .par = 5,
        .solutions = &.{"f0;r1"},
        .why = "; repeats the last f/t search",
    },
    .{
        .id = "find/dt-02",
        .lesson = .find,
        .title = "Middle element",
        .prompt = "Remove b from the tuple",
        .start = "|let (a, b, c) = t;",
        .goal = "let (a, c) = t;",
        .par = 5,
        .solutions = &.{"f,dt,"},
        .why = "jump with f, then delete till the next comma",
    },
    .{
        .id = "find/F-01",
        .lesson = .find,
        .title = "Last element",
        .prompt = "Drop the 30",
        .start = "x = [10, 20, 30|]",
        .goal = "x = [10, 20]",
        .par = 5,
        .solutions = &.{"F,dt]"},
        .why = "F searches backwards on the line",
    },
};
