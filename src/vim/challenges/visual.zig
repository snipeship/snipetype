//! Drills for the "visual" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "visual/V-indent-01",
        .lesson = .visual,
        .title = "Indent the body",
        .prompt = "Indent both statements",
        .start = "fn f() {\n|let a = 1;\nlet b = 2;\n}",
        .goal = "fn f() {\n    let a = 1;\n    let b = 2;\n}",
        .par = 3,
        .solutions = &.{"Vj>"},
        .why = "V selects lines; > shifts them right",
    },
    .{
        .id = "visual/v-args-01",
        .lesson = .visual,
        .title = "Keep the last",
        .prompt = "Leave only \"c\"",
        .start = "print(|\"a\", \"b\", \"c\")",
        .goal = "print(\"c\")",
        .par = 6,
        .solutions = &.{"v2f,ld"},
        .why = "v selects characters; any motion (2f,) extends it",
    },
    .{
        .id = "visual/V-delete-01",
        .lesson = .visual,
        .title = "Debug lines",
        .prompt = "Delete the three debug comments",
        .start = "int main() {\n|  // debug\n  // debug\n  // debug\n  return 0;\n}",
        .goal = "int main() {\n  return 0;\n}",
        .par = 4,
        .solutions = &.{"Vjjd"},
        .why = "V then j extends by whole lines",
    },
    .{
        .id = "visual/viwU-01",
        .lesson = .visual,
        .title = "Constant case",
        .prompt = "Upper-case the name",
        .start = "const |max_size = 10;",
        .goal = "const MAX_SIZE = 10;",
        .par = 4,
        .solutions = &.{"viwU"},
        .why = "text objects work in visual mode; U upper-cases the selection",
    },
};
