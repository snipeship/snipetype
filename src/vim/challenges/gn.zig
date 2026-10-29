//! Drills for the "gn" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "gn/cgn-01",
        .lesson = .gn,
        .title = "Rename a variable",
        .prompt = "Rename tmp to val (three places)",
        .start = "|let tmp = load();\nlet out = tmp + tmp;",
        .goal = "let val = load();\nlet out = val + val;",
        .par = 14,
        .solutions = &.{ "/tmp<CR>cgnval<Esc>..", ":%s/tmp/val/g<CR>" },
        .why = "cgn changes the next match; . repeats it on the following one",
    },
    .{
        .id = "gn/dgn-01",
        .lesson = .gn,
        .title = "Unsafe no more",
        .prompt = "Remove every \"unsafe \"",
        .start = "|unsafe fn a() {}\nunsafe fn b() {}\nfn c() { unsafe { d() } }",
        .goal = "fn a() {}\nfn b() {}\nfn c() { { d() } }",
        .par = 14,
        .solutions = &.{ "/unsafe <CR>dgn..", "/unsafe.<CR>dgn.." },
        .why = "dgn deletes the next match; . deletes the one after it",
    },
    .{
        .id = "gn/star-01",
        .lesson = .gn,
        .title = "Rename from the cursor",
        .prompt = "Rename tmp to ast everywhere, starting where you are",
        .start = "let |tmp = parse(src);\ncheck(tmp);\nreturn tmp;",
        .goal = "let ast = parse(src);\ncheck(ast);\nreturn ast;",
        .par = 11,
        .solutions = &.{ "*Ncgnast<Esc>..", "#Ncgnast<Esc>.." },
        .why = "* searches the word under the cursor, N comes back, cgn changes it, . does the rest",
    },
    .{
        .id = "gn/lower-01",
        .lesson = .gn,
        .title = "Quiet the warnings",
        .prompt = "Lowercase every WARN",
        .start = "|log(WARN, 1)\nif x: WARN()\nreturn WARN",
        .goal = "log(warn, 1)\nif x: warn()\nreturn warn",
        .par = 12,
        .solutions = &.{ "/WARN<CR>gugn..", "?WARN<CR>gugN.." },
        .why = "gugn lowercases the match; with an uppercase pattern (smartcase) the lowered word no longer matches, so . moves on",
    },
};
