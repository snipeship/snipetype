//! Arcade mode data model: the read-only view the scene renders from and the
//! events the simulation emits. Pure data, no platform dependencies.

const std = @import("std");
const keys = @import("../platform/keys.zig");

pub const Mods = keys.Mods;

pub const MAX_STEPS = 24;

/// Difficulty: fall speed, spawn gap, miss damage.
pub const Pace = enum(u8) {
    junior,
    senior,
    staff,
    tenx,

    pub fn label(self: Pace) []const u8 {
        return switch (self) {
            .junior => "JUNIOR",
            .senior => "SENIOR",
            .staff => "STAFF",
            .tenx => "10X",
        };
    }
};

/// Which game the shift plays: falling words (default) or the key/chord stages.
pub const Game = enum(u8) {
    words,
    keys,

    pub fn label(self: Game) []const u8 {
        return switch (self) {
            .words => "WORDS",
            .keys => "KEYS",
        };
    }
};

pub const Rarity = enum(u8) { common, rare, epic, legendary };

/// Keycap skin family (drives colors in the scene).
pub const CapRole = enum(u8) { letter, digit, symbol, named, arrow, modifier };

/// Content family a cap was drawn from (stage unlocks, weights, scoring).
pub const Family = enum(u8) {
    home_row,
    letters,
    digits,
    named, // Space/Enter/Tab/Bksp and arrows
    motions, // vim single-key motions
    operators, // vim sequences
    ctrl, // Ctrl+key chords
    ex, // ":w<Enter>" style commands
    three, // three-key chords (needs kitty keyboard)
    macros, // extra sequences used instead of `three` without chord support
    words, // deep work stage
};

pub const TargetKind = enum(u8) {
    key, // single key, e.g. "j"
    chord2, // modifier + key, e.g. Ctrl+S
    chord3, // two modifiers + key, e.g. Ctrl+Shift+V
    sequence, // keys typed in order, e.g. "dd", "ciw", ":wq<Enter>"
    word, // letters of a word (deep work stage)
};

/// One key to press. For chords the modifiers live in `mods`.
pub const Step = struct {
    code: u21,
    mods: Mods = .{},
    /// Legend printed on the cap for the non-modifier key ("A", "↑", "Enter").
    legend: []const u8,
    role: CapRole,
    /// Produced character to match instead of `code`+shift (shift-aware,
    /// e.g. '$', 'G', ':'); 0 = match by `code` and exact `mods`.
    text: u21 = 0,
};

pub const CapState = enum(u8) { falling, hit, missed };

pub const Cap = struct {
    id: u32,
    kind: TargetKind,
    steps: [MAX_STEPS]Step = undefined,
    len: u8,
    /// Steps already typed (sequence/word progress).
    typed: u8 = 0,
    /// Short human caption ("save", "paste plain", "delete line"); "" if none.
    caption: []const u8 = "",
    /// Horizontal center in the play area, 0 (left) .. 1 (right).
    x: f32,
    /// Fall progress: 0 = spawned at top, 1 = landed on the deck (miss).
    progress: f32 = 0,
    rarity: Rarity = .common,
    /// Accent hue 0..1 for glow/popup colors.
    hue: f32,
    state: CapState = .falling,
    /// Seconds since the last state change (for hit/miss animations).
    state_t: f32 = 0,
    /// Seconds since spawn.
    age: f32 = 0,
    family: Family = .letters,
    /// Index of the item in its family pool (duplicate suppression).
    item: u16 = 0,
    /// Current fall speed in progress units per second.
    speed: f32 = 0,
    /// Multiplier on the level fall time (word caps fall slower).
    fall_scale: f32 = 1,
    /// Word index in the current phrase (word caps only).
    word: u8 = 0,
    /// Word cap typed case-sensitively (code identifiers with uppercase).
    /// Plain word caps accept either case.
    exact: bool = false,

    pub fn stepSlice(self: *const Cap) []const Step {
        return self.steps[0..self.len];
    }
};

/// Visual effect for a hit, chosen by the simulation (tiered like the
/// reference game: tier 1 small, tier 2 medium, tier 3 screen-shaking).
pub const Effect = enum(u8) {
    // tier 1
    shatter,
    confetti,
    voxel,
    pop,
    dust,
    // tier 2
    glitch,
    lightning,
    frost,
    melt,
    fireworks,
    // tier 3
    supernova,
    blackhole,
    derez,

    pub fn tier(self: Effect) u2 {
        return switch (self) {
            .shatter, .confetti, .voxel, .pop, .dust => 1,
            .glitch, .lightning, .frost, .melt, .fireworks => 2,
            .supernova, .blackhole, .derez => 3,
        };
    }
};

pub const Event = union(enum) {
    /// A cap was completed. Position is the cap center in play-area
    /// coordinates (x 0..1, y = progress 0..1 at hit time).
    hit: struct {
        cap_id: u32,
        x: f32,
        y: f32,
        effect: Effect,
        points: u32,
        quick: bool,
        /// 0..1, drives particle counts / glow / shake.
        intensity: f32,
        hue: f32,
        rarity: Rarity,
        caption: []const u8,
        kind: TargetKind,
        combo: u32,
    },
    /// Partial progress on a sequence/word cap.
    step: struct { cap_id: u32, index: u8 },
    /// Key pressed that matched nothing (combo reset).
    wrong: struct { code: u21 },
    /// A cap reached the deck.
    miss: struct { cap_id: u32, x: f32, hue: f32 },
    /// Every physical key press (for the backdrop keyboard ripple).
    key_press: struct { code: u21, mods: Mods },
    level_up: struct { level: u8 },
    milestone: struct { combo: u32, text: []const u8 },
    phrase_done: struct { points: u32 },
    game_over,
    /// A shift started (title -> playing, or "again" from results).
    start,
};

pub const Phase = enum(u8) { title, playing, paused, results };

pub const Stats = struct {
    score: u64 = 0,
    combo: u32 = 0,
    best_combo: u32 = 0,
    /// Combo multiplier 1..8.
    mult: u8 = 1,
    /// 0..100; game over at 0.
    health: f32 = 100,
    hits: u32 = 0,
    misses: u32 = 0,
    wrongs: u32 = 0,
    keystrokes: u32 = 0,
    /// Keys per minute over a sliding 10 s window.
    kpm: f32 = 0,
    peak_kpm: f32 = 0,
    /// Words per minute (characters / 5) over the same window, counted on
    /// word caps (the Words game and the deep work stage).
    wpm: f32 = 0,
    peak_wpm: f32 = 0,
    /// Accuracy counts keystrokes rather than caps (set for the Words game,
    /// where one hit is a whole word but each wrong key counts on its own).
    per_key: bool = false,

    pub fn accuracy(self: Stats) f32 {
        if (self.per_key) {
            // Correct keys over all keys typed, each missed cap one error.
            const all = self.keystrokes + self.misses;
            if (all == 0) return 1;
            return @as(f32, @floatFromInt(self.keystrokes -| self.wrongs)) / @as(f32, @floatFromInt(all));
        }
        const total = self.hits + self.wrongs + self.misses;
        if (total == 0) return 1;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total));
    }
};

/// Sentence shown under the HUD during word stages.
pub const Phrase = struct {
    text: []const u8,
    /// Byte range of the active word in `text`.
    word_start: u16,
    word_end: u16,
    /// Bytes of `text` already completed.
    done_upto: u16,
    attribution: []const u8 = "",
    /// Index of the active word and the number of words in `text`.
    word_index: u8 = 0,
    word_count: u8 = 0,
    /// Bit i set = word i was missed (draw struck through).
    missed: u64 = 0,
    /// All words resolved; the line is holding (fade in the attribution).
    complete: bool = false,

    pub const Span = struct { start: u16, end: u16 };

    /// Byte range of word `i` (words are separated by spaces).
    pub fn wordSpan(self: *const Phrase, i: usize) ?Span {
        var n: usize = 0;
        var pos: usize = 0;
        const t = self.text;
        while (pos < t.len) {
            while (pos < t.len and t[pos] == ' ') pos += 1;
            if (pos >= t.len) break;
            const start = pos;
            while (pos < t.len and t[pos] != ' ') pos += 1;
            if (n == i) return .{ .start = @intCast(start), .end = @intCast(pos) };
            n += 1;
        }
        return null;
    }

    pub fn isMissed(self: *const Phrase, i: usize) bool {
        return i < 64 and (self.missed >> @intCast(i)) & 1 == 1;
    }
};

pub const Hud = struct {
    level: u8 = 0,
    /// Stage name of the current level (Keys or Words stage names).
    level_name: []const u8 = "",
    /// Minutes since midnight shown on the flip clock (09:00 = 540).
    clock_minutes: u16 = 9 * 60,
    pace: Pace = .senior,
    /// Speed multiplier 1, 2, 4, 8, 16.
    pace_mult: u8 = 1,
    phrase: ?Phrase = null,
    /// Level-change banner, shown while banner_t < ~2.5 s.
    banner: []const u8 = "",
    banner_t: f32 = 99,
    /// Combo milestone callout.
    callout: []const u8 = "",
    callout_t: f32 = 99,
    /// Whether the level uses words/WPM instead of keys/min (true for the
    /// whole of a Words game, and during the Keys game's deep work stage).
    word_stage: bool = false,
};

/// End-of-shift rank (our own names).
pub const Rank = struct {
    name: []const u8,
    blurb: []const u8,
    hue: f32,
};
