//! Drills for the "macros" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "macros/list-01",
        .lesson = .macros,
        .title = "Bullet list",
        .prompt = "Make each line '- x,'",
        .start = "|a\nb\nc",
        .goal = "- a,\n- b,\n- c,",
        .par = 14,
        .solutions = &.{"qqI- <Esc>A,<Esc>jq2@q"},
        .why = "record one line's edit ending with j, then replay it with a count",
    },
    .{
        .id = "macros/quote-01",
        .lesson = .macros,
        .title = "String list",
        .prompt = "Quote each fruit and add a comma",
        .start = "|apple\nbanana\ncherry",
        .goal = "\"apple\",\n\"banana\",\n\"cherry\",",
        .par = 14,
        .solutions = &.{"qqI\"<Esc>A\",<Esc>jq2@q"},
        .why = "a macro replays exactly the keys you typed",
    },
    .{
        .id = "macros/num-01",
        .lesson = .macros,
        .title = "Numbered items",
        .prompt = "Make item0..item3",
        .start = "|item0",
        .goal = "item0\nitem1\nitem2\nitem3",
        .par = 10,
        .solutions = &.{"qqyyp<C-a>q2@q"},
        .why = "<C-a> adds 1 to the number on the line; inside a macro it counts up",
    },
};
