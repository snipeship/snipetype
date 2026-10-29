//! Drills for the "sentences" lesson.

const Challenge = @import("../drill.zig").Challenge;

pub const list = [_]Challenge{
    .{
        .id = "sentences/das-01",
        .lesson = .sentences,
        .title = "Wrong sentence",
        .prompt = "Delete the sentence the cursor is in",
        .start = "This is fine. This is |wrong. This stays.",
        .goal = "This is fine. This stays.",
        .par = 3,
        .solutions = &.{ "das", "(d)" },
        .why = "das takes the sentence and the space after it, so no gap is left",
    },
    .{
        .id = "sentences/cis-01",
        .lesson = .sentences,
        .title = "Rewrite it",
        .prompt = "Replace the first sentence with \"New text.\"",
        .start = "|Old text here. Keep this.",
        .goal = "New text. Keep this.",
        .par = 13,
        .solutions = &.{ "cisNew text.<Esc>", "c)New text. <Esc>" },
        .why = "cis changes the sentence and keeps the space before the next one",
    },
    .{
        .id = "sentences/fix-01",
        .lesson = .sentences,
        .title = "Third sentence typo",
        .prompt = "Fix \"Thre\" in the third sentence",
        .start = "|One is ok. Two is ok. Thre is bad.",
        .goal = "One is ok. Two is ok. Three is bad.",
        .par = 6,
        .solutions = &.{ "2)eae<Esc>", "2)Eae<Esc>" },
        .why = ") jumps to the start of the next sentence; a count jumps several",
    },
};
