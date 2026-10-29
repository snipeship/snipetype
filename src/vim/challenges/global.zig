//! Drills for the "global" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "global/delete-01",
        .lesson = .global,
        .title = "Strip the logging",
        .prompt = "Delete every console.log line",
        .start = "|const a = load();\nconsole.log(a);\nconst b = parse(a);\nconsole.log(b);\nconst c = run(b);\nconsole.log(c);\nreturn c;",
        .goal = "const a = load();\nconst b = parse(a);\nconst c = run(b);\nreturn c;",
        .par = 9,
        .solutions = &.{ ":g/log/d<CR>", ":g/g(/d<CR>" },
        .why = ":g/pat/d deletes each line that matches, wherever it is",
    },
    .{
        .id = "global/vglobal-01",
        .lesson = .global,
        .title = "Only the TODOs",
        .prompt = "Keep the TODO lines, delete the rest",
        .start = "|// TODO: cache results\nfn a() {}\n// TODO: handle errors\nfn b() {}\n// TODO: add tests",
        .goal = "// TODO: cache results\n// TODO: handle errors\n// TODO: add tests",
        .par = 10,
        .solutions = &.{ ":v/TODO/d<CR>", ":v/TO/d<CR>" },
        .why = ":v (or :g!) runs the command on the lines that do NOT match",
    },
    .{
        .id = "global/norm-01",
        .lesson = .global,
        .title = "Shout the names",
        .prompt = "Uppercase the name at the start of every line",
        .start = "|red = warm\ngreen = cool\nblue = cold\ncyan = cool\nmagenta = warm\nyellow = warm",
        .goal = "RED = warm\nGREEN = cool\nBLUE = cold\nCYAN = cool\nMAGENTA = warm\nYELLOW = warm",
        .par = 11,
        .solutions = &.{ ":%norm gUe<CR>", ":%norm gUw<CR>" },
        .why = ":%norm runs NORMAL keys on each line, starting at column 0",
    },
    .{
        .id = "global/reverse-01",
        .lesson = .global,
        .title = "Upside down",
        .prompt = "Reverse the order of the lines",
        .start = "|first\nsecond\nthird\nfourth",
        .goal = "fourth\nthird\nsecond\nfirst",
        .par = 8,
        .solutions = &.{ ":g/^/m0<CR>", ":g/$/m0<CR>" },
        .why = ":g/^/m0 moves each line, in turn, to the top",
    },
};
