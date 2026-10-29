//! Arcade content: the stages of a shift, the item pools each stage unlocks,
//! family weights, and key matching between `keys.KeyEvent`s and cap steps.
//!
//! All tables are comptime data; nothing here allocates.

const std = @import("std");
const keys = @import("../platform/keys.zig");
const model = @import("model.zig");

const Step = model.Step;
const Family = model.Family;
const TargetKind = model.TargetKind;
const CapRole = model.CapRole;
const Mods = model.Mods;
const code = keys.code;

/// One spawnable target.
pub const Item = struct {
    kind: TargetKind,
    steps: []const Step,
    caption: []const u8 = "",
};

/// A stage ("hour") of the shift.
pub const Stage = struct {
    name: []const u8,
    /// Short description of what the stage adds.
    adds: []const u8,
    /// Family unlocked by this stage (null for overtime).
    family: ?Family,
    /// "HH:00 NAME · adds" shown in the level-up banner.
    banner: []const u8,
};

/// Number of scripted stages before overtime.
pub const STAGE_COUNT = 10;
/// Level index of the word stage.
pub const WORD_LEVEL = 9;
/// First overtime level.
pub const OVERTIME_LEVEL = 10;

// ---------------------------------------------------------------------------
// Characters and legends

const legend_lower: [128][1]u8 = blk: {
    var t: [128][1]u8 = undefined;
    for (0..128) |i| t[i] = .{@intCast(i)};
    break :blk t;
};

const legend_upper: [128][1]u8 = blk: {
    var t: [128][1]u8 = undefined;
    for (0..128) |i| t[i] = .{std.ascii.toUpper(@intCast(i))};
    break :blk t;
};

/// US-layout shifted symbols and their unshifted key.
const shift_pairs = [_][2]u8{
    .{ '!', '1' }, .{ '@', '2' },  .{ '#', '3' }, .{ '$', '4' }, .{ '%', '5' },
    .{ '^', '6' }, .{ '&', '7' },  .{ '*', '8' }, .{ '(', '9' }, .{ ')', '0' },
    .{ '_', '-' }, .{ '+', '=' },  .{ '{', '[' }, .{ '}', ']' }, .{ '|', '\\' },
    .{ ':', ';' }, .{ '"', '\'' }, .{ '<', ',' }, .{ '>', '.' }, .{ '?', '/' },
    .{ '~', '`' },
};

/// The unshifted key that produces `c` on a US layout ('$' -> '4', 'G' -> 'g').
pub fn unshifted(c: u21) u21 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    for (shift_pairs) |p| {
        if (p[0] == c) return p[1];
    }
    return c;
}

/// The character shift+`c` produces on a US layout ('4' -> '$', 'g' -> 'G').
pub fn shifted(c: u21) u21 {
    if (c >= 'a' and c <= 'z') return c - 32;
    for (shift_pairs) |p| {
        if (p[1] == c) return p[0];
    }
    return c;
}

fn roleOf(c: u8) CapRole {
    if (std.ascii.isAlphabetic(c)) return .letter;
    if (std.ascii.isDigit(c)) return .digit;
    return .symbol;
}

/// A step matched by the character it produces (shift-aware).
fn charStep(comptime c: u8) Step {
    if (c == ' ') return space_step;
    return .{ .code = unshifted(c), .text = c, .legend = legend_lower[c][0..], .role = roleOf(c) };
}

fn named(comptime c: u21, comptime legend: []const u8, comptime role: CapRole) Step {
    return .{ .code = c, .legend = legend, .role = role };
}

const space_step = named(code.space, "Space", .named);
const enter_step = named(code.enter, "Enter", .named);
const tab_step = named(code.tab, "Tab", .named);
const bksp_step = named(code.backspace, "Bksp", .named);
const up_step = named(code.up, "↑", .arrow);
const down_step = named(code.down, "↓", .arrow);
const left_step = named(code.left, "←", .arrow);
const right_step = named(code.right, "→", .arrow);

/// A chord step: modifiers held, then `base` pressed.
fn chordStep(comptime mods: Mods, comptime base: Step) Step {
    var s = base;
    s.mods = mods;
    s.text = 0;
    if (base.code < 128 and std.ascii.isAlphabetic(@intCast(base.code))) {
        s.legend = legend_upper[base.code][0..];
    }
    return s;
}

fn steps1(comptime s: Step) []const Step {
    const arr = [1]Step{s};
    return &arr;
}

fn seqSteps(comptime s: []const u8, comptime enter: bool) []const Step {
    comptime {
        var arr: [s.len + @intFromBool(enter)]Step = undefined;
        for (s, 0..) |c, i| arr[i] = charStep(c);
        if (enter) arr[s.len] = enter_step;
        const final = arr;
        return &final;
    }
}

fn keyItem(comptime c: u8, comptime caption: []const u8) Item {
    return .{ .kind = .key, .steps = steps1(charStep(c)), .caption = caption };
}

fn keyItems(comptime chars: []const u8) [chars.len]Item {
    var out: [chars.len]Item = undefined;
    for (chars, 0..) |c, i| out[i] = keyItem(c, "");
    return out;
}

fn seqItem(comptime s: []const u8, comptime caption: []const u8) Item {
    return .{ .kind = .sequence, .steps = seqSteps(s, false), .caption = caption };
}

fn exItem(comptime s: []const u8, comptime caption: []const u8) Item {
    return .{ .kind = .sequence, .steps = seqSteps(s, true), .caption = caption };
}

fn chordItem(comptime mods: Mods, comptime base: Step, comptime caption: []const u8) Item {
    var n: u8 = 0;
    if (mods.ctrl) n += 1;
    if (mods.alt) n += 1;
    if (mods.shift) n += 1;
    if (mods.super) n += 1;
    return .{ .kind = if (n >= 2) .chord3 else .chord2, .steps = steps1(chordStep(mods, base)), .caption = caption };
}

const ctrl: Mods = .{ .ctrl = true };
const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };
const alt: Mods = .{ .alt = true };
const alt_shift: Mods = .{ .alt = true, .shift = true };
const ctrl_alt: Mods = .{ .ctrl = true, .alt = true };

fn ctrlItem(comptime c: u8, comptime caption: []const u8) Item {
    return chordItem(ctrl, charStep(c), caption);
}

// ---------------------------------------------------------------------------
// Pools

const home_row_items = keyItems("asdfjkl;");
const letters_items = keyItems("bceghimnopqrtuvwxyz");
const digits_items = keyItems("0123456789-=[]',./");

const named_items = [_]Item{
    .{ .kind = .key, .steps = steps1(space_step) },
    .{ .kind = .key, .steps = steps1(enter_step) },
    .{ .kind = .key, .steps = steps1(tab_step) },
    .{ .kind = .key, .steps = steps1(bksp_step) },
    .{ .kind = .key, .steps = steps1(up_step) },
    .{ .kind = .key, .steps = steps1(down_step) },
    .{ .kind = .key, .steps = steps1(left_step) },
    .{ .kind = .key, .steps = steps1(right_step) },
};

const motions_items = [_]Item{
    keyItem('h', "left"),     keyItem('j', "down"),        keyItem('k', "up"),
    keyItem('l', "right"),    keyItem('w', "next word"),   keyItem('b', "back word"),
    keyItem('e', "word end"), keyItem('0', "line start"),  keyItem('$', "line end"),
    keyItem('G', "bottom"),   keyItem('x', "delete char"), keyItem('p', "paste"),
    keyItem('u', "undo"),     keyItem('%', "match pair"),  keyItem('.', "repeat"),
};

const operators_items = [_]Item{
    seqItem("gg", "top"),
    seqItem("dd", "delete line"),
    seqItem("yy", "yank line"),
    seqItem("ciw", "change word"),
    seqItem("dw", "delete word"),
    seqItem(">>", "indent"),
    seqItem("zz", "center"),
    seqItem("ZZ", "save & quit"),
    seqItem("di(", "delete inside"),
    seqItem("gUiw", "upper word"),
};

const ctrl_items = [_]Item{
    ctrlItem('s', "save"),      ctrlItem('z', "undo"),         ctrlItem('r', "redo"),
    ctrlItem('f', "find"),      ctrlItem('d', "half down"),    ctrlItem('u', "half up"),
    ctrlItem('o', "jump back"), ctrlItem('v', "block select"), ctrlItem('a', "increment"),
    ctrlItem('x', "decrement"), ctrlItem('e', "scroll down"),  ctrlItem('y', "scroll up"),
};

const ex_items = [_]Item{
    exItem(":w", "write"),
    exItem(":q!", "abandon ship"),
    exItem(":wq", "save & quit"),
    exItem(":noh", "clear search"),
    exItem("/todo", "search"),
    exItem(":%s", "replace all"),
    exItem(":sp", "split"),
};

const three_items = [_]Item{
    chordItem(ctrl_shift, charStep('z'), "redo"),
    chordItem(ctrl_shift, charStep('f'), "find in files"),
    chordItem(ctrl_shift, charStep('k'), "delete line"),
    chordItem(ctrl_shift, enter_step, "line above"),
    chordItem(alt_shift, down_step, "copy line down"),
    chordItem(alt, up_step, "move line up"),
    chordItem(alt, down_step, "move line down"),
    chordItem(ctrl_alt, down_step, "add cursor"),
};

/// Replacement for `three_items` when the terminal cannot report chords.
const macros_items = [_]Item{
    seqItem("yiw", "yank word"),
    seqItem("dap", "delete paragraph"),
    seqItem("ci\"", "change quote"),
    seqItem("xp", "swap chars"),
    seqItem("ddp", "swap lines"),
    seqItem("ggVG", "select all"),
    seqItem("A;", "append semicolon"),
    exItem(":bn", "next buffer"),
    exItem(":set nu", "line numbers"),
};

/// Item pool of a family (`words` has no static pool).
pub fn pool(f: Family) []const Item {
    return switch (f) {
        .home_row => &home_row_items,
        .letters => &letters_items,
        .digits => &digits_items,
        .named => &named_items,
        .motions => &motions_items,
        .operators => &operators_items,
        .ctrl => &ctrl_items,
        .ex => &ex_items,
        .three => &three_items,
        .macros => &macros_items,
        .words => &.{},
    };
}

/// Relative spawn weight of a family when it is in the mix.
pub fn familyWeight(f: Family) f32 {
    return switch (f) {
        .home_row => 1.2,
        .letters => 1.6,
        .digits => 1.0,
        .named => 1.0,
        .motions => 1.0,
        .operators => 0.9,
        .ctrl => 1.2,
        .ex => 0.8,
        .three => 0.9,
        .macros => 0.9,
        .words => 0,
    };
}

/// Level at which a family first appears.
pub fn unlockLevel(f: Family) u8 {
    return switch (f) {
        .home_row => 0,
        .letters => 1,
        .digits => 2,
        .named => 3,
        .motions => 4,
        .operators => 5,
        .ctrl => 6,
        .ex => 7,
        .three, .macros => 8,
        .words => WORD_LEVEL,
    };
}

/// Share of spawns the newly unlocked family gets at least.
pub const NEW_FAMILY_SHARE: f32 = 0.45;

pub const family_count = @typeInfo(Family).@"enum".field_names.len;

/// Spawn weights per family (indexed by `@backingInt(Family)`) for a key
/// level. The word stage has no key families; callers use level 8's mix if
/// they need keys there. Overtime mixes every key family without a boost.
pub fn familyWeights(level: u8, chords: bool) [family_count]f32 {
    var w: [family_count]f32 = @splat(0);
    const cap_level: u8 = @min(level, 8);
    var sum: f32 = 0;
    for (0..family_count) |i| {
        const f: Family = @fromBackingInt(@intCast(i));
        if (f == .words) continue;
        if (f == .three and !chords) continue;
        if (f == .macros and chords) continue;
        if (unlockLevel(f) > cap_level) continue;
        w[i] = familyWeight(f);
        sum += w[i];
    }
    if (level <= 8) {
        if (stage(level, chords).family) |nf| {
            const i = @backingInt(nf);
            const others = sum - w[i];
            const min_w = NEW_FAMILY_SHARE / (1 - NEW_FAMILY_SHARE) * others;
            if (w[i] < min_w) w[i] = min_w;
        }
    }
    return w;
}

// ---------------------------------------------------------------------------
// Stages

fn mkStage(comptime hour: u8, comptime name: []const u8, comptime adds: []const u8, comptime family: ?Family) Stage {
    const hh = std.fmt.comptimePrint("{d:0>2}:00", .{hour});
    return .{ .name = name, .adds = adds, .family = family, .banner = hh ++ "  " ++ name ++ " · " ++ adds };
}

pub const stages = [STAGE_COUNT]Stage{
    mkStage(9, "HOME ROW", "a s d f j k l ;", .home_row),
    mkStage(10, "EVERY LETTER", "the rest of a to z", .letters),
    mkStage(11, "NUMBERS", "digits and - = [ ] ' , . /", .digits),
    mkStage(12, "LUNCH RUSH", "Space Enter Tab Bksp and arrows", .named),
    mkStage(13, "MOTIONS", "vim keys that move you", .motions),
    mkStage(14, "OPERATORS", "type the whole sequence", .operators),
    mkStage(15, "CTRL", "hold Ctrl, then the key", .ctrl),
    mkStage(16, "EX COMMANDS", "finish with Enter", .ex),
    mkStage(17, "THREE-KEY CHORDS", "two modifiers at once", .three),
    mkStage(18, "DEEP WORK", "type the words, no spaces", .words),
};

/// Level 8 when the terminal cannot report modifier chords.
pub const macros_stage = mkStage(17, "MACROS", "longer vim sequences", .macros);

pub const overtime_stage: Stage = .{
    .name = "OVERTIME",
    .adds = "everything, faster",
    .family = null,
    .banner = "OVERTIME · everything, faster",
};

pub fn stage(level: u8, chords: bool) *const Stage {
    if (level >= STAGE_COUNT) return &overtime_stage;
    if (level == 8 and !chords) return &macros_stage;
    return &stages[level];
}

// ---------------------------------------------------------------------------
// Words game stages

/// Where a Words-game line comes from.
pub const LineSource = enum(u8) {
    /// Random common words of 3 to 5 letters.
    short_words,
    /// Random common words of up to 6 letters.
    common_words,
    /// Random common words of any length.
    mixed_words,
    /// Random common words, about half of them 7 letters or longer.
    long_words,
    /// Code identifiers and keywords, typed exactly.
    code,
    /// Public-domain quotes.
    quotes,
    /// Dev one-liners.
    oneliners,
    /// One-liners, quotes or long word lines.
    deadline,
    /// Anything above (overtime).
    any,
};

/// A stage ("hour") of the Words game.
pub const WordStage = struct {
    name: []const u8,
    adds: []const u8,
    banner: []const u8,
    /// Words per line (word lists) or allowed word counts (quotes, one-liners).
    min_words: u8,
    max_words: u8,
    source: LineSource,
};

fn mkWordStage(comptime hour: u8, comptime name: []const u8, comptime adds: []const u8, comptime lo: u8, comptime hi: u8, comptime source: LineSource) WordStage {
    const hh = std.fmt.comptimePrint("{d:0>2}:00", .{hour});
    return .{ .name = name, .adds = adds, .banner = hh ++ "  " ++ name ++ " · " ++ adds, .min_words = lo, .max_words = hi, .source = source };
}

/// Words game stages; words per line ramp 1-2 up to 5-18.
pub const word_stages = [STAGE_COUNT]WordStage{
    mkWordStage(9, "WARM-UP", "short words, no spaces", 1, 2, .short_words),
    mkWordStage(10, "INBOX", "everyday words", 1, 3, .common_words),
    mkWordStage(11, "STAND-UP", "longer lines, bonus vim keys", 2, 4, .mixed_words),
    mkWordStage(12, "LUNCH RUSH", "long words land harder", 2, 5, .long_words),
    mkWordStage(13, "CODE REVIEW", "identifiers, exactly as written", 2, 5, .code),
    mkWordStage(14, "DEEP WORK", "short quotes", 3, 7, .quotes),
    mkWordStage(15, "PAIRING", "one-liners from the next desk", 4, 9, .oneliners),
    mkWordStage(16, "DEADLINE", "everything, faster", 4, 11, .deadline),
    mkWordStage(17, "LAST PUSH", "longer quotes", 5, 14, .quotes),
    mkWordStage(18, "WRAP-UP", "the long ones", 8, 18, .quotes),
};

pub const word_overtime_stage: WordStage = .{
    .name = "OVERTIME",
    .adds = "anything, faster",
    .banner = "OVERTIME · anything, faster",
    .min_words = 5,
    .max_words = 18,
    .source = .any,
};

pub fn wordStage(level: u8) *const WordStage {
    if (level >= STAGE_COUNT) return &word_overtime_stage;
    return &word_stages[level];
}

// ---------------------------------------------------------------------------
// Key matching

/// The character an event types, shift-aware, with a US-layout fallback for
/// shifted symbols when the terminal did not report the text.
pub fn producedChar(ev: keys.KeyEvent) ?u21 {
    if (ev.mods.ctrl or ev.mods.alt or ev.mods.super) return null;
    if (ev.text != 0) return ev.text;
    const c = ev.code;
    if (c < 32 or c >= 127) return null;
    if (ev.mods.shift) return shifted(c);
    return c;
}

fn lower(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Whether `ev` performs `step`. Character steps compare the produced text
/// (so '$' needs shift+4 and 'G' needs shift+g); other steps compare the key
/// code and the exact Ctrl/Alt/Shift/Super set. `ignore_case` is used by
/// word caps, where only the letter matters.
pub fn stepMatches(step: Step, ev: keys.KeyEvent, ignore_case: bool) bool {
    if (step.text != 0) {
        const c = producedChar(ev) orelse return false;
        if (ignore_case) return lower(c) == lower(step.text);
        return c == step.text;
    }
    var ev_code = ev.code;
    var ev_mods = ev.mods;
    if (ev_code >= 'A' and ev_code <= 'Z') {
        ev_code += 32;
        ev_mods.shift = true;
    }
    if (ev_code != step.code) return false;
    return Mods.eql(ev_mods, step.mods);
}

/// A key event that performs `step` (used by the attract demo and tests).
pub fn eventForStep(step: Step) keys.KeyEvent {
    if (step.text != 0) {
        const base = unshifted(step.text);
        return .{ .code = base, .mods = .{ .shift = base != step.text }, .text = step.text };
    }
    return .{ .code = step.code, .mods = step.mods };
}

/// Builds the steps of a word cap from `word` (letters only, lowercase).
/// Returns the number of steps written.
pub fn wordSteps(word: []const u8, out: []Step) u8 {
    var n: u8 = 0;
    for (word) |c| {
        if (!std.ascii.isAlphabetic(c)) continue;
        if (n >= out.len) break;
        const lc = std.ascii.toLower(c);
        out[n] = .{ .code = lc, .text = lc, .legend = legend_upper[lc][0..], .role = .letter };
        n += 1;
    }
    return n;
}

/// Whether character `c` of a line is typed: every non-space character of a
/// code line, only letters otherwise.
pub fn typesChar(c: u8, code_line: bool) bool {
    if (code_line) return c > ' ' and c < 127;
    return std.ascii.isAlphabetic(c);
}

/// Builds the steps of an identifier cap: every printable character, typed
/// exactly (legends as written, Shift for `_` and uppercase).
pub fn identSteps(word: []const u8, out: []Step) u8 {
    var n: u8 = 0;
    for (word) |c| {
        if (!typesChar(c, true)) continue;
        if (n >= out.len) break;
        out[n] = .{ .code = unshifted(c), .text = c, .legend = legend_lower[c][0..], .role = roleOf(c) };
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "pools are non-empty and steps fit" {
    for (0..family_count) |i| {
        const f: Family = @fromBackingInt(@intCast(i));
        if (f == .words) continue;
        const p = pool(f);
        try testing.expect(p.len > 0);
        for (p) |item| {
            try testing.expect(item.steps.len >= 1 and item.steps.len <= model.MAX_STEPS);
            for (item.steps) |s| try testing.expect(s.legend.len > 0);
        }
    }
}

test "every item is performable by its own events" {
    for (0..family_count) |i| {
        const f: Family = @fromBackingInt(@intCast(i));
        for (pool(f)) |item| {
            for (item.steps) |s| {
                try testing.expect(stepMatches(s, eventForStep(s), false));
            }
        }
    }
}

test "shift-aware matching" {
    const dollar = motions_items[8].steps[0];
    try testing.expectEqualStrings("$", dollar.legend);
    // kitty: code '4', shift, text '$'
    try testing.expect(stepMatches(dollar, .{ .code = '4', .mods = .{ .shift = true }, .text = '$' }, false));
    // no text reported: US fallback
    try testing.expect(stepMatches(dollar, .{ .code = '4', .mods = .{ .shift = true } }, false));
    try testing.expect(!stepMatches(dollar, .{ .code = '4' }, false));

    const big_g = motions_items[9].steps[0];
    try testing.expect(stepMatches(big_g, .{ .code = 'g', .mods = .{ .shift = true }, .text = 'G' }, false));
    try testing.expect(!stepMatches(big_g, .{ .code = 'g', .text = 'g' }, false));
    // lowercase letter must not accept shift
    const a = home_row_items[0].steps[0];
    try testing.expect(stepMatches(a, .{ .code = 'a', .text = 'a' }, false));
    try testing.expect(!stepMatches(a, .{ .code = 'a', .mods = .{ .shift = true }, .text = 'A' }, false));
    try testing.expect(!stepMatches(a, .{ .code = 'a', .mods = .{ .ctrl = true } }, false));
    try testing.expect(stepMatches(a, .{ .code = 'a', .mods = .{ .shift = true }, .text = 'A' }, true));
}

test "chord matching needs exact modifiers" {
    const save = ctrl_items[0].steps[0];
    try testing.expectEqualStrings("S", save.legend);
    try testing.expect(stepMatches(save, .{ .code = 's', .mods = .{ .ctrl = true } }, false));
    try testing.expect(!stepMatches(save, .{ .code = 's', .mods = .{ .ctrl = true, .shift = true } }, false));
    try testing.expect(!stepMatches(save, .{ .code = 's' }, false));
    const redo = three_items[0];
    try testing.expectEqual(TargetKind.chord3, redo.kind);
    try testing.expect(stepMatches(redo.steps[0], .{ .code = 'z', .mods = .{ .ctrl = true, .shift = true } }, false));
    try testing.expect(!stepMatches(redo.steps[0], .{ .code = 'z', .mods = .{ .ctrl = true } }, false));
    // Alt+Up is a two-key chord
    try testing.expectEqual(TargetKind.chord2, three_items[5].kind);
}

test "ex commands end with Enter" {
    for (ex_items) |item| {
        try testing.expectEqual(code.enter, item.steps[item.steps.len - 1].code);
    }
    try testing.expectEqualStrings(":", ex_items[0].steps[0].legend);
}

test "new family gets at least 45 percent" {
    for (1..9) |lvl| {
        const level: u8 = @intCast(lvl);
        const w = familyWeights(level, true);
        var sum: f32 = 0;
        for (w) |x| sum += x;
        const nf = stage(level, true).family.?;
        try testing.expect(w[@backingInt(nf)] / sum >= NEW_FAMILY_SHARE - 0.001);
    }
    const w0 = familyWeights(0, true);
    try testing.expect(w0[@backingInt(Family.home_row)] > 0);
    try testing.expectEqual(@as(f32, 0), w0[@backingInt(Family.letters)]);
}

test "no chords swaps three-key chords for macros" {
    const w = familyWeights(8, false);
    try testing.expectEqual(@as(f32, 0), w[@backingInt(Family.three)]);
    try testing.expect(w[@backingInt(Family.macros)] > 0);
    try testing.expectEqualStrings("MACROS", stage(8, false).name);
    const ot = familyWeights(12, false);
    try testing.expectEqual(@as(f32, 0), ot[@backingInt(Family.three)]);
    try testing.expect(ot[@backingInt(Family.ex)] > 0);
}

test "banners" {
    try testing.expectEqualStrings("09:00  HOME ROW · a s d f j k l ;", stages[0].banner);
    try testing.expectEqualStrings("OVERTIME", stage(13, true).name);
}

test "word steps" {
    var buf: [model.MAX_STEPS]Step = undefined;
    const n = wordSteps("I've", &buf);
    try testing.expectEqual(@as(u8, 3), n);
    try testing.expectEqual(@as(u21, 'i'), buf[0].text);
    try testing.expectEqualStrings("V", buf[1].legend);
}

test "identifier steps keep case and punctuation" {
    var buf: [model.MAX_STEPS]Step = undefined;
    const n = identSteps("std.mem_X-y", &buf);
    try testing.expectEqual(@as(u8, 11), n);
    try testing.expectEqualStrings("s", buf[0].legend);
    try testing.expectEqualStrings(".", buf[3].legend);
    try testing.expectEqual(@as(u21, '_'), buf[7].text);
    try testing.expectEqual(@as(u21, '-'), buf[7].code);
    try testing.expectEqualStrings("X", buf[8].legend);
    // '_' needs shift+'-', 'X' needs shift+'x'.
    try testing.expect(stepMatches(buf[7], eventForStep(buf[7]), false));
    try testing.expect(stepMatches(buf[7], .{ .code = '-', .mods = .{ .shift = true } }, false));
    try testing.expect(!stepMatches(buf[7], .{ .code = '-', .text = '-' }, false));
    try testing.expect(!stepMatches(buf[8], .{ .code = 'x', .text = 'x' }, false));
    try testing.expect(stepMatches(buf[8], .{ .code = 'x', .mods = .{ .shift = true }, .text = 'X' }, false));
}

test "words stages ramp words per line" {
    try testing.expectEqualStrings("WARM-UP", wordStage(0).name);
    try testing.expectEqualStrings("CODE REVIEW", wordStage(4).name);
    try testing.expectEqualStrings("WRAP-UP", wordStage(9).name);
    try testing.expectEqualStrings("OVERTIME", wordStage(10).name);
    try testing.expectEqualStrings("OVERTIME", wordStage(200).name);
    try testing.expectEqualStrings("09:00  WARM-UP · short words, no spaces", word_stages[0].banner);
    var prev: u8 = 0;
    for (word_stages) |st| {
        try testing.expect(st.min_words >= 1 and st.min_words <= st.max_words);
        try testing.expect(st.max_words >= prev);
        prev = st.max_words;
    }
}
