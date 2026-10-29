//! Drills for the "substitute" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "substitute/swap-01",
        .lesson = .substitute,
        .title = "Flip the pairs",
        .prompt = "Swap both sides of every '='",
        .start = "|a=1\nb=2\nc=3\nd=4",
        .goal = "1=a\n2=b\n3=c\n4=d",
        .par = 23,
        .solutions = &.{ ":%s/\\(.\\)=\\(.\\)/\\2=\\1/<CR>", ":%s/\\(.\\)=\\(.\\)/\\2=\\1<CR>" },
        .why = "\\( \\) capture text; \\1 and \\2 put the groups back in any order",
    },
    .{
        .id = "substitute/snake-01",
        .lesson = .substitute,
        .title = "camelCase to snake_case",
        .prompt = "Turn every name into snake_case",
        .start = "|maxSize\nminWidth\nlineHeight",
        .goal = "max_size\nmin_width\nline_height",
        .par = 13,
        .solutions = &.{ ":%s/\\u/_\\l&/<CR>", ":%s/\\u/_\\L&/<CR>" },
        .why = "\\u matches an uppercase letter; \\l lowercases the next char of the replacement, & is the match",
    },
    .{
        .id = "substitute/split-01",
        .lesson = .substitute,
        .title = "One per line",
        .prompt = "Break the import list after every comma",
        .start = "|import { a, b, c, d, e }",
        .goal = "import { a,\nb,\nc,\nd,\ne }",
        .par = 12,
        .solutions = &.{ ":s/, /,\\r/g<CR>", "3f r<CR>;.;.;." },
        .why = "\\r in the replacement starts a new line; g does every match on the line",
    },
    .{
        .id = "substitute/quote-01",
        .lesson = .substitute,
        .title = "Quote the list",
        .prompt = "Turn each word into a quoted, comma-ended string",
        .start = "|red\ngreen\nblue",
        .goal = "\"red\",\n\"green\",\n\"blue\",",
        .par = 13,
        .solutions = &.{ ":%s/.*/\"&\",/<CR>", "<C-v>2jI\"<Esc>gv$A\",<Esc>" },
        .why = "& in the replacement is the whole match, here the whole line",
    },
};
