//! Drills for the "search" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "search/slash-01",
        .lesson = .search,
        .title = "Rename target",
        .prompt = "Rename the target function to go",
        .start = "|def a():\n    pass\ndef target():\n    pass",
        .goal = "def a():\n    pass\ndef go():\n    pass",
        .par = 10,
        .solutions = &.{"/tar<CR>cwgo<Esc>"},
        .why = "/ jumps straight to text, wherever it is",
    },
    .{
        .id = "search/star-01",
        .lesson = .search,
        .title = "Third count",
        .prompt = "Rename the count on the last line",
        .start = "|count = 0\nprint(count)\ncount += 1",
        .goal = "count = 0\nprint(count)\ntotal += 1",
        .par = 10,
        .solutions = &.{"*ncwtotal<Esc>"},
        .why = "* searches the word under the cursor; n goes to the next match",
    },
    .{
        .id = "search/n-01",
        .lesson = .search,
        .title = "Done done done",
        .prompt = "Mark every TODO as DONE",
        .start = "|a TODO\nb\nc TODO\nd TODO",
        .goal = "a DONE\nb\nc DONE\nd DONE",
        .par = 17,
        .solutions = &.{"/TODO<CR>cwDONE<Esc>n.n."},
        .why = "n then . is the find-and-replace loop",
    },
};
