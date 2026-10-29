//! Arcade rules as pure functions: pace curves, points, combo multiplier,
//! effect tiers and intensity, milestones, ranks and the results flavor line.

const std = @import("std");
const model = @import("model.zig");
const layout = @import("layout.zig");

const Cap = model.Cap;
const Pace = model.Pace;
const Rarity = model.Rarity;
const Effect = model.Effect;

// ---------------------------------------------------------------------------
// Pace

pub const PaceParams = struct {
    fall_start: f64,
    fall_end: f64,
    gap_start: f64,
    gap_end: f64,
    miss_damage: f32,
    /// Share of the curve reached by the end of the scripted day.
    day: f64,
};

pub fn paceParams(p: Pace) PaceParams {
    return switch (p) {
        .junior => .{ .fall_start = 7, .fall_end = 2.8, .gap_start = 1.5, .gap_end = 0.36, .miss_damage = 5, .day = 0.71 },
        .senior => .{ .fall_start = 5.6, .fall_end = 2, .gap_start = 1.1, .gap_end = 0.25, .miss_damage = 8, .day = 0.75 },
        .staff => .{ .fall_start = 4.4, .fall_end = 1.6, .gap_start = 0.85, .gap_end = 0.21, .miss_damage = 10, .day = 0.645 },
        .tenx => .{ .fall_start = 3.4, .fall_end = 1.2, .gap_start = 0.6, .gap_end = 0.17, .miss_damage = 12, .day = 0.45 },
    };
}

/// Per-tick decay of the remaining overtime ramp (half-life ~79 s at 120 Hz).
pub const OVERTIME_Q: f64 = 0.999927;

/// Extra curve per overtime second once the eased ramp has run out, so
/// overtime never plateaus (+0.1 per minute).
pub const OVERTIME_CREEP_PER_S: f64 = 0.1 / 60.0;

/// Curve position: `day*level/9` during the day, then easing toward 1 in
/// overtime (`overtime_ticks` since overtime began) plus a slow creep past 1.
pub fn curveS(p: Pace, level: u8, overtime_ticks: u64) f64 {
    return curveDay(paceParams(p).day, level, overtime_ticks);
}

/// Words game curve: the day ramps further than in the Keys game, so lines
/// fall noticeably faster by the afternoon.
pub fn wordsCurveS(p: Pace, level: u8, overtime_ticks: u64) f64 {
    return curveDay(@min(1.0, paceParams(p).day * WORDS_DAY_MULT), level, overtime_ticks);
}

fn curveDay(day: f64, level: u8, overtime_ticks: u64) f64 {
    if (level < 10) return day * @as(f64, @floatFromInt(@min(level, 9))) / 9.0;
    const t: f64 = @floatFromInt(overtime_ticks);
    const secs = t / 120.0;
    return day + (1 - day) * (1 - @exp(t * @log(OVERTIME_Q))) + secs * OVERTIME_CREEP_PER_S;
}

/// Harmonic interpolation `1/(1/a + (1/b - 1/a)*s)`.
pub fn harmonic(a: f64, b: f64, s: f64) f64 {
    return 1.0 / (1.0 / a + (1.0 / b - 1.0 / a) * s);
}

/// Seconds a cap takes to fall, at curve position `s` and speed multiplier.
pub fn fallTime(p: Pace, s: f64, speed: u8) f64 {
    const pp = paceParams(p);
    return harmonic(pp.fall_start, pp.fall_end, s) / @as(f64, @floatFromInt(@max(speed, 1)));
}

/// Base seconds between spawns.
pub fn spawnGap(p: Pace, s: f64, speed: u8) f64 {
    const pp = paceParams(p);
    return harmonic(pp.gap_start, pp.gap_end, s) / @as(f64, @floatFromInt(@max(speed, 1)));
}

/// Fall-time multiplier for a word cap of `len` letters.
pub fn wordFallScale(len: usize) f32 {
    return 0.9 + 0.12 * @as(f32, @floatFromInt(len));
}

/// Words game: share of the level fall time a 4-letter word gets. The
/// reference uses 0.72 with 2 words on screen; that let a perfect 60 WPM bot
/// work past 20:00 on senior, so ours falls faster (60 WPM now clocks out
/// around 14:00, 30 WPM around 12:00).
pub const WORDS_FALL: f32 = 0.42;
/// Code identifiers (Shift, punctuation) fall this much slower.
pub const CODE_FALL_SCALE: f32 = 1.3;
/// The Words game's day ramps this much further than the Keys game's.
pub const WORDS_DAY_MULT: f64 = 1.1;

/// Fall-time multiplier for a Words-game word of `len` characters:
/// `WORDS_FALL * (1 + 0.035 * max(0, len - 4))`.
pub fn wordsGameFallScale(len: usize) f32 {
    const extra: f32 = @floatFromInt(len -| 4);
    return WORDS_FALL * (1 + 0.035 * extra);
}

/// Words game: a word this long (or longer) gets a tier-2 effect.
pub const LONG_WORD: u8 = 8;

// ---------------------------------------------------------------------------
// Points

pub fn rarityMult(r: Rarity) u32 {
    return switch (r) {
        .common => 1,
        .rare => 2,
        .epic => 3,
        .legendary => 5,
    };
}

/// Combo multiplier: x2 at 10, x3 at 20, ... x8 from 70.
pub fn comboMult(combo: u32) u8 {
    return @intCast(@min(8, 1 + combo / 10));
}

/// A hit is quick while the cap is in the top 35% of its fall.
pub const QUICK_PROGRESS: f32 = 0.35;

/// Base points of a completed cap before multipliers.
pub fn basePoints(cap: *const Cap) u32 {
    const len: u32 = cap.len;
    return switch (cap.kind) {
        .word => 15 * len,
        .chord3 => 90,
        .chord2 => 40,
        .sequence => if (cap.family == .ex) 60 else 30 + 10 * len,
        .key => switch (cap.steps[0].role) {
            .letter => 10,
            .digit, .symbol => 12,
            .named, .arrow, .modifier => 15,
        },
    };
}

/// `round(base * rarity * quick * mult) * speed`.
pub fn points(base: u32, rarity: Rarity, quick: bool, mult: u8, speed: u8) u32 {
    const raw = @as(f64, @floatFromInt(base * rarityMult(rarity))) * (if (quick) @as(f64, 1.5) else 1.0) * @as(f64, @floatFromInt(mult));
    return @as(u32, @intFromFloat(@round(raw))) * @max(speed, 1);
}

/// Health restored by completing a cap.
pub fn heal(cap: *const Cap) f32 {
    if (cap.rarity != .common) return 5;
    return switch (cap.kind) {
        .key, .word => 1,
        else => 3,
    };
}

pub const WRONG_DAMAGE: f32 = 2;

// ---------------------------------------------------------------------------
// Effects

/// Effect tier for a hit (`combo` is the combo after the hit).
pub fn effectTier(cap: *const Cap, combo: u32) u2 {
    if (combo > 0 and combo % 25 == 0) return 3;
    if (cap.kind == .chord3) return 3;
    if (cap.rarity == .epic or cap.rarity == .legendary) return 3;
    if (cap.kind == .word) return if (cap.len >= LONG_WORD or cap.rarity == .rare) 2 else 1;
    if (cap.kind == .key) switch (cap.steps[0].role) {
        .letter, .digit, .symbol => return if (cap.rarity == .rare) 2 else 1,
        else => {},
    };
    return 2;
}

pub fn tierEffects(tier: u2) []const Effect {
    return switch (tier) {
        0, 1 => &.{ .shatter, .confetti, .voxel, .pop, .dust },
        2 => &.{ .glitch, .lightning, .frost, .melt, .fireworks },
        3 => &.{ .supernova, .blackhole, .derez },
    };
}

/// Pick an effect of `tier`, never repeating `last`. `roll` is any random
/// number.
pub fn pickEffect(tier: u2, last: ?Effect, roll: u64) Effect {
    const list = tierEffects(tier);
    var n: usize = list.len;
    var skip: ?usize = null;
    if (last) |l| {
        for (list, 0..) |e, i| {
            if (e == l) {
                skip = i;
                n -= 1;
            }
        }
    }
    var k: usize = @intCast(roll % n);
    if (skip) |s| {
        if (k >= s) k += 1;
    }
    return list[k];
}

/// Effect intensity 0..1.
pub fn intensity(combo: u32, key_count: u8, rarity: Rarity, quick: bool) f32 {
    const c: f32 = @min(1.0, @as(f32, @floatFromInt(combo)) / 80.0);
    const extra: f32 = @floatFromInt(@min(3, @max(key_count, 1) - 1));
    const r: f32 = switch (rarity) {
        .common => 0,
        .rare => 0.12,
        .epic => 0.22,
        .legendary => 0.32,
    };
    return @min(1.0, 0.2 + 0.45 * c + 0.12 * extra + r + (if (quick) @as(f32, 0.05) else 0));
}

/// Rarity from a uniform roll in [0,1): legendary 0.5%, epic 1.5%, rare 4%.
pub fn rarityFromRoll(u: f64) Rarity {
    if (u < 0.005) return .legendary;
    if (u < 0.02) return .epic;
    if (u < 0.06) return .rare;
    return .common;
}

// ---------------------------------------------------------------------------
// Milestones

pub const Milestone = struct { combo: u32, text: []const u8 };

pub const milestones = [_]Milestone{
    .{ .combo = 10, .text = "the linter is impressed" },
    .{ .combo = 20, .text = "tests passing locally" },
    .{ .combo = 35, .text = "PR approved without comments" },
    .{ .combo = 50, .text = "senior dev glances over" },
    .{ .combo = 75, .text = "CI is green on first try" },
    .{ .combo = 100, .text = "someone opened your profile on GitHub" },
    .{ .combo = 150, .text = "the build is faster than you" },
    .{ .combo = 200, .text = "promoted to principal (unpaid)" },
};

pub fn milestoneFor(combo: u32) ?[]const u8 {
    for (milestones) |m| {
        if (m.combo == combo) return m.text;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Ranks

pub const ranks = [_]model.Rank{
    .{ .name = "hunt & peck", .blurb = "every key is a small adventure", .hue = 0.11 },
    .{ .name = "home row hero", .blurb = "your fingers know their way home", .hue = 0.6 },
    .{ .name = "vim adept", .blurb = "hjkl is muscle memory now", .hue = 0.73 },
    .{ .name = "macro machine", .blurb = "the keyboard files for overtime pay", .hue = 0.1 },
    .{ .name = ":wq wizard", .blurb = "exits vim on the first try", .hue = 0.7 },
};

const RankReq = struct { kpm: f32, accuracy: f32, hour_score: f32 };
const rank_reqs = [_]RankReq{
    .{ .kpm = 100, .accuracy = 0.80, .hour_score = 0 },
    .{ .kpm = 160, .accuracy = 0.86, .hour_score = 3 },
    .{ .kpm = 240, .accuracy = 0.92, .hour_score = 5 },
    .{ .kpm = 320, .accuracy = 0.96, .hour_score = 7 },
};

/// `level + 3*log2(speed)`.
pub fn hourScore(level: u8, speed: u8) f32 {
    return @as(f32, @floatFromInt(level)) + 3 * @log2(@as(f32, @floatFromInt(@max(speed, 1))));
}

pub fn rankFor(peak_kpm: f32, accuracy: f32, level: u8, speed: u8) model.Rank {
    const hs = hourScore(level, speed);
    var idx: usize = 0;
    for (rank_reqs, 0..) |r, i| {
        if (peak_kpm >= r.kpm and accuracy >= r.accuracy and hs >= r.hour_score) idx = i + 1;
    }
    return ranks[idx];
}

/// Words game ranks (same tiers, word-flavored names).
pub const word_ranks = [_]model.Rank{
    .{ .name = "hunt & peck", .blurb = "every word is a small adventure", .hue = 0.11 },
    .{ .name = "home row hero", .blurb = "the words arrive, you send them off", .hue = 0.6 },
    .{ .name = "prose engine", .blurb = "sentences fall, you barely blink", .hue = 0.73 },
    .{ .name = "living autocomplete", .blurb = "you finish lines before they land", .hue = 0.1 },
    .{ .name = "keyboard poet", .blurb = "quotes tremble when you clock in", .hue = 0.7 },
};

const word_rank_wpm = [_]f32{ 30, 50, 70, 90 };

/// Words game rank: peak WPM 30/50/70/90 with the same accuracy and
/// hour-score requirements as the Keys game.
pub fn wordRankFor(peak_wpm: f32, accuracy: f32, level: u8, speed: u8) model.Rank {
    const hs = hourScore(level, speed);
    var idx: usize = 0;
    for (rank_reqs, word_rank_wpm, 0..) |r, wpm, i| {
        if (peak_wpm >= wpm and accuracy >= r.accuracy and hs >= r.hour_score) idx = i + 1;
    }
    return word_ranks[idx];
}

/// Words game "heard" line, by average keys per minute (175/250/350/450).
pub fn wordHeardLine(avg_kpm: f32) []const u8 {
    if (avg_kpm >= 450) return "audible from orbit";
    if (avg_kpm >= 350) return "audible from the data center";
    if (avg_kpm >= 250) return "audible from the parking garage";
    if (avg_kpm >= 175) return "audible from the standup room";
    return "audible from the next desk";
}

/// "How far away the typing was audible", by average keys per minute.
pub fn heardLine(avg_kpm: f32) []const u8 {
    if (avg_kpm >= 230) return "audible from orbit";
    if (avg_kpm >= 170) return "audible from the data center";
    if (avg_kpm >= 120) return "audible from the parking garage";
    if (avg_kpm >= 80) return "audible from the standup room";
    return "audible from the next desk";
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn capOf(kind: model.TargetKind, role: model.CapRole, len: u8) Cap {
    var c: Cap = .{ .id = 1, .kind = kind, .len = len, .x = 0.5, .hue = 0 };
    for (0..len) |i| c.steps[i] = .{ .code = 'a', .legend = "a", .role = role };
    return c;
}

test "scoring matches the reference examples" {
    // Senior x2 at combo 70+: three-key chord 90*8*2 = 1440.
    const c3 = capOf(.chord3, .letter, 1);
    try testing.expectEqual(@as(u32, 1440), points(basePoints(&c3), .common, false, comboMult(72), 2));
    const c2 = capOf(.chord2, .letter, 1);
    try testing.expectEqual(@as(u32, 640), points(basePoints(&c2), .common, false, 8, 2));
    const named = capOf(.key, .named, 1);
    try testing.expectEqual(@as(u32, 240), points(basePoints(&named), .common, false, 8, 2));
    try testing.expectEqual(@as(u32, 360), points(basePoints(&named), .common, true, 8, 2));
    const letter = capOf(.key, .letter, 1);
    try testing.expectEqual(@as(u32, 160), points(basePoints(&letter), .common, false, 8, 2));
    const digit = capOf(.key, .digit, 1);
    try testing.expectEqual(@as(u32, 192), points(basePoints(&digit), .common, false, 8, 2));
    try testing.expectEqual(@as(u32, 1280), points(basePoints(&c2), .rare, false, 8, 2));
    try testing.expectEqual(@as(u32, 4320), points(basePoints(&c3), .epic, false, 8, 2));
    try testing.expectEqual(@as(u32, 15), points(10, .common, true, 1, 1));
}

test "base points by kind" {
    var seq = capOf(.sequence, .letter, 3);
    try testing.expectEqual(@as(u32, 60), basePoints(&seq));
    seq.family = .ex;
    try testing.expectEqual(@as(u32, 60), basePoints(&seq));
    const seq2 = capOf(.sequence, .letter, 2);
    try testing.expectEqual(@as(u32, 50), basePoints(&seq2));
    const word = capOf(.word, .letter, 6);
    try testing.expectEqual(@as(u32, 90), basePoints(&word));
}

test "combo multiplier steps" {
    try testing.expectEqual(@as(u8, 1), comboMult(0));
    try testing.expectEqual(@as(u8, 1), comboMult(9));
    try testing.expectEqual(@as(u8, 2), comboMult(10));
    try testing.expectEqual(@as(u8, 3), comboMult(20));
    try testing.expectEqual(@as(u8, 8), comboMult(70));
    try testing.expectEqual(@as(u8, 8), comboMult(500));
}

test "pace curve" {
    // Senior level 0 x1: 5.6 s fall, 1.1 s gap.
    try testing.expectApproxEqAbs(@as(f64, 5.6), fallTime(.senior, curveS(.senior, 0, 0), 1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.1), spawnGap(.senior, curveS(.senior, 0, 0), 1), 1e-9);
    // Senior 17:00 x2 ~ 1.27 s fall.
    try testing.expectApproxEqAbs(@as(f64, 1.27), fallTime(.senior, curveS(.senior, 8, 0), 2), 0.02);
    // Overtime approaches the end value.
    const s_far = curveS(.senior, 12, 120 * 3600);
    try testing.expect(s_far > 0.99);
    try testing.expect(curveS(.senior, 10, 0) == 0.75);
}

test "effect tiers and no repeats" {
    const letter = capOf(.key, .letter, 1);
    try testing.expectEqual(@as(u2, 1), effectTier(&letter, 3));
    try testing.expectEqual(@as(u2, 3), effectTier(&letter, 25));
    var rare = letter;
    rare.rarity = .rare;
    try testing.expectEqual(@as(u2, 2), effectTier(&rare, 3));
    const named = capOf(.key, .named, 1);
    try testing.expectEqual(@as(u2, 2), effectTier(&named, 3));
    const c3 = capOf(.chord3, .letter, 1);
    try testing.expectEqual(@as(u2, 3), effectTier(&c3, 1));
    var last: ?Effect = null;
    for (0..200) |i| {
        const e = pickEffect(3, last, i * 7919);
        try testing.expect(e.tier() == 3);
        if (last) |l| try testing.expect(e != l);
        last = e;
    }
}

test "intensity" {
    try testing.expectApproxEqAbs(@as(f32, 0.2), intensity(0, 1, .common, false), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2 + 0.45 + 0.24 + 0.05), intensity(80, 3, .common, true), 1e-5);
    try testing.expectEqual(@as(f32, 1), intensity(200, 6, .legendary, true));
}

test "rarity roll thresholds" {
    try testing.expectEqual(Rarity.legendary, rarityFromRoll(0.001));
    try testing.expectEqual(Rarity.epic, rarityFromRoll(0.01));
    try testing.expectEqual(Rarity.rare, rarityFromRoll(0.05));
    try testing.expectEqual(Rarity.common, rarityFromRoll(0.5));
}

test "ranks" {
    try testing.expectEqualStrings("hunt & peck", rankFor(50, 1, 9, 1).name);
    try testing.expectEqualStrings("home row hero", rankFor(120, 0.9, 0, 1).name);
    try testing.expectEqualStrings("vim adept", rankFor(170, 0.9, 3, 1).name);
    // x4 speed adds 6 hour points.
    try testing.expectEqualStrings(":wq wizard", rankFor(400, 0.99, 1, 4).name);
    try testing.expectEqualStrings("audible from orbit", heardLine(300));
    try testing.expectEqualStrings("audible from the next desk", heardLine(10));
}

test "words game: fall scale, word tiers, ranks" {
    try testing.expectApproxEqAbs(WORDS_FALL, wordsGameFallScale(3), 1e-6);
    try testing.expectApproxEqAbs(WORDS_FALL, wordsGameFallScale(4), 1e-6);
    try testing.expectApproxEqAbs(WORDS_FALL * 1.21, wordsGameFallScale(10), 1e-5);
    try testing.expect(wordsCurveS(.senior, 5, 0) > curveS(.senior, 5, 0));
    try testing.expectEqual(curveS(.senior, 0, 0), wordsCurveS(.senior, 0, 0));
    const short = capOf(.word, .letter, 5);
    try testing.expectEqual(@as(u2, 1), effectTier(&short, 3));
    const long = capOf(.word, .letter, 8);
    try testing.expectEqual(@as(u2, 2), effectTier(&long, 3));
    var rare = short;
    rare.rarity = .rare;
    try testing.expectEqual(@as(u2, 2), effectTier(&rare, 3));
    var epic = short;
    epic.rarity = .epic;
    try testing.expectEqual(@as(u2, 3), effectTier(&epic, 3));
    try testing.expectEqualStrings("hunt & peck", wordRankFor(25, 1, 9, 1).name);
    try testing.expectEqualStrings("home row hero", wordRankFor(35, 0.9, 0, 1).name);
    try testing.expectEqualStrings("prose engine", wordRankFor(55, 0.9, 3, 1).name);
    try testing.expectEqualStrings("living autocomplete", wordRankFor(75, 0.95, 5, 1).name);
    try testing.expectEqualStrings("keyboard poet", wordRankFor(95, 0.97, 7, 1).name);
    // accuracy still gates the rank
    try testing.expectEqualStrings("home row hero", wordRankFor(95, 0.85, 9, 1).name);
    try testing.expectEqualStrings("audible from the standup room", wordHeardLine(200));
    try testing.expectEqualStrings("audible from orbit", wordHeardLine(500));
    try testing.expectEqualStrings("audible from the next desk", wordHeardLine(100));
}
