//! Drills for the "words" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "words/dw-01",
        .lesson = .words,
        .title = "Not mutable",
        .prompt = "Drop the 'mut '",
        .start = "|let mut x = 5;",
        .goal = "let x = 5;",
        .par = 3,
        .solutions = &.{"wdw"},
        .why = "dw deletes to the start of the next word, including the space",
    },
    .{
        .id = "words/e-01",
        .lesson = .words,
        .title = "Longer name",
        .prompt = "Rename count to counter",
        .start = "|let count = 0;",
        .goal = "let counter = 0;",
        .par = 6,
        .solutions = &.{"2eaer<Esc>"},
        .why = "e lands on a word's last char; a appends after it",
    },
    .{
        .id = "words/b-01",
        .lesson = .words,
        .title = "Drop an argument",
        .prompt = "Remove the b argument",
        .start = "x = compute(a, b, |c)",
        .goal = "x = compute(a, c)",
        .par = 5,
        .solutions = &.{"2bd2w"},
        .why = "b walks back by words; punctuation like ',' is a word of its own",
    },
    .{
        .id = "words/W-01",
        .lesson = .words,
        .title = "Short import",
        .prompt = "Keep only the alias",
        .start = "|import foo.bar.baz as qux",
        .goal = "import qux",
        .par = 4,
        .solutions = &.{"wd2W"},
        .why = "W treats foo.bar.baz as one WORD: anything between spaces",
    },
};
