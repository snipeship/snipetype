//! Result and live numbers of a test, derived from the session's words and
//! keystroke log (Monkeytype definitions):
//! - wpm: characters of correctly committed words plus their separators,
//!   plus the correct prefix of the active word, / 5 / minutes;
//! - raw: every typed character (corrected ones too) / 5 / minutes;
//! - acc: correct char keystrokes / all char keystrokes.

const std = @import("std");

const constants = @import("constants.zig");
const Session = @import("session.zig").Session;

pub const CharCounts = struct { correct: u32 = 0, incorrect: u32 = 0, extra: u32 = 0, missed: u32 = 0 };
pub const Sample = struct { t_s: u16, wpm: f32, raw: f32, errors: u16 };
/// A word and the time spent on it (from the previous commit to its own).
pub const WordTime = struct { word: []const u8, ms: u32 };

pub const Live = struct {
    elapsed_ms: i64 = 0,
    remaining_ms: ?i64 = null,
    wpm: f32 = 0,
    raw: f32 = 0,
    acc: f32 = 100,
    words_done: u32 = 0,
    words_total: ?u32 = null,
    corrected: u32 = 0,
    keystrokes: u32 = 0,
};

pub const ResultKind = enum { typing, vim_type, vim_drill };

pub const Result = struct {
    kind: ResultKind,
    wpm: f32,
    raw: f32,
    acc: f32,
    consistency: ?f32,
    chars: CharCounts,
    corrected: u32,
    keystrokes: u32,
    duration_ms: u32,
    /// Per second; owned by TypingTest; valid until next reset.
    series: []const Sample,
    /// ≤ 12 distinct.
    missed_words: []const []const u8,
    /// ≤ 5, slowest first.
    slow_words: []const WordTime,
    /// ≥ 1 s, no paste.
    valid: bool,
    strokes: u32 = 0,
    par: u16 = 0,
    stars: u2 = 0,
    efficiency: f32 = 0,
    hinted: bool = false,
    drill_id: ?[]const u8 = null,
    /// Sentences mode: attribution of a quote.
    quote_by: ?[]const u8 = null,
    /// Typing modes (not zen): per-key stats of this run; owned by
    /// TypingTest, valid until the next reset.
    per_key: ?*const PerKey = null,
};

// ---- per-key stats ----

/// Keys the per-key stats track: unshifted US keys; a shifted char counts
/// for its base key. Space and Enter are not tracked.
pub const KEYSET = "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./";

/// US shift map: the shifted symbol of each KEYSET entry (0 for none).
pub const SHIFTED = "ABCDEFGHIJKLMNOPQRSTUVWXYZ)!@#$%^&*(~_+{}|:\"<>?";

/// Index of the key that types `c` in KEYSET ('A' → 'a', '!' → '1',
/// '"' → '\'', '?' → '/'); null for space and everything else.
pub fn keyIndex(c: u8) ?usize {
    const table = comptime blk: {
        var t: [128]u8 = @splat(0xff);
        for (KEYSET, 0..) |k, i| t[k] = i;
        for (SHIFTED, 0..) |k, i| t[k] = i;
        break :blk t;
    };
    if (c >= 128) return null;
    const i = table[c];
    return if (i == 0xff) null else i;
}

pub const KeyStat = struct {
    /// Keystrokes where this key was expected (right or wrong).
    hits: u32 = 0,
    /// ... that were wrong.
    misses: u32 = 0,
    /// Sum of time-since-previous-keystroke for correct hits (each capped
    /// at KEY_MS_CAP).
    ms_sum: u32 = 0,
    /// Number of correct hits in `ms_sum`.
    timed: u32 = 0,

    /// Percent right; null when the key was never expected.
    pub fn accuracy(self: KeyStat) ?f32 {
        if (self.hits == 0) return null;
        const right: f32 = @floatFromInt(self.hits -| self.misses);
        return right / @as(f32, @floatFromInt(self.hits)) * 100;
    }

    /// Average ms per correct hit; null when none was timed.
    pub fn avgMs(self: KeyStat) ?f32 {
        if (self.timed == 0) return null;
        return @as(f32, @floatFromInt(self.ms_sum)) / @as(f32, @floatFromInt(self.timed));
    }

    pub fn add(self: *KeyStat, o: KeyStat) void {
        self.hits +|= o.hits;
        self.misses +|= o.misses;
        self.ms_sum +|= o.ms_sum;
        self.timed +|= o.timed;
    }
};

/// A correct keystroke's time is capped (a pause is not slowness).
pub const KEY_MS_CAP: u32 = 2000;

pub const PerKey = struct {
    keys: [KEYSET.len]KeyStat = @splat(.{}),

    pub fn get(self: *const PerKey, c: u8) ?KeyStat {
        return self.keys[keyIndex(c) orelse return null];
    }

    pub fn add(self: *PerKey, other: *const PerKey) void {
        for (&self.keys, other.keys) |*a, b| a.add(b);
    }

    pub fn total(self: *const PerKey) KeyStat {
        var t: KeyStat = .{};
        for (self.keys) |k| t.add(k);
        return t;
    }

    /// One keystroke where `expected` was the right key; `ms` is the time
    /// since the previous keystroke (null: not timed).
    pub fn note(self: *PerKey, expected: u8, correct: bool, ms: ?u32) void {
        const k = &self.keys[keyIndex(expected) orelse return];
        k.hits +|= 1;
        if (!correct) {
            k.misses +|= 1;
        } else if (ms) |m| {
            k.ms_sum +|= @min(m, KEY_MS_CAP);
            k.timed +|= 1;
        }
    }
};

/// Higher = weaker key (0 for keys with too little data).
pub const KeyWeights = [KEYSET.len]f32;

/// Keys need this many hits before they get a weight.
pub const WEAK_MIN_HITS: u32 = 5;
/// Weak-key weights need this many timed hits over all keys.
pub const WEAK_MIN_TIMED: u32 = 100;

/// Weak-key weights: 1 + 4·(miss rate / mean miss rate) + 2·(avg ms / mean
/// avg ms) per key with enough data, 0 for the rest. False (all zero)
/// with fewer than WEAK_MIN_TIMED timed hits in total.
pub fn weakWeights(pk: *const PerKey, out: *KeyWeights) bool {
    out.* = @splat(0);
    const tot = pk.total();
    if (tot.timed < WEAK_MIN_TIMED) return false;
    var miss_sum: f32 = 0;
    var ms_sum: f32 = 0;
    var n_miss: f32 = 0;
    var n_ms: f32 = 0;
    for (pk.keys) |k| {
        if (k.hits < WEAK_MIN_HITS) continue;
        miss_sum += @as(f32, @floatFromInt(k.misses)) / @as(f32, @floatFromInt(k.hits));
        n_miss += 1;
        if (k.avgMs()) |m| {
            ms_sum += m;
            n_ms += 1;
        }
    }
    if (n_miss == 0) return false;
    // A small floor keeps an error-free history from dividing by zero.
    const miss_mean = @max(miss_sum / n_miss, 0.01);
    const ms_mean = if (n_ms > 0) @max(ms_sum / n_ms, 1) else 1;
    for (pk.keys, 0..) |k, i| {
        if (k.hits < WEAK_MIN_HITS) continue;
        const rate = @as(f32, @floatFromInt(k.misses)) / @as(f32, @floatFromInt(k.hits));
        const slow = if (k.avgMs()) |m| m / ms_mean else 1;
        out[i] = 1 + 4 * (rate / miss_mean) + 2 * slow;
    }
    return true;
}

pub const MAX_MISSED_WORDS = 12;
pub const MAX_SLOW_WORDS = 5;

/// Storage behind a Result's slices (owned by TypingTest).
pub const Buffers = struct {
    series: std.ArrayList(Sample) = .empty,
    missed: std.ArrayList([]const u8) = .empty,
    slow: std.ArrayList(WordTime) = .empty,

    pub fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        self.series.deinit(allocator);
        self.missed.deinit(allocator);
        self.slow.deinit(allocator);
    }

    pub fn clear(self: *Buffers) void {
        self.series.clearRetainingCapacity();
        self.missed.clearRetainingCapacity();
        self.slow.clearRetainingCapacity();
    }
};

/// Characters per minute → words per minute over `ms`.
pub fn perMinute(chars: u64, ms: i64) f32 {
    if (ms <= 0) return 0;
    return @as(f32, @floatFromInt(chars)) / 5.0 / (@as(f32, @floatFromInt(ms)) / 60000.0);
}

/// WPM numerator: correct committed words plus the active word's correct
/// prefix (unless the last word was committed: then it is already in).
fn wpmChars(s: *const Session) u64 {
    return @as(u64, s.correct_chars) + s.tailChars();
}

pub fn live(s: *const Session, elapsed_ms: i64, limit_ms: ?i64, untimed_total: bool) Live {
    const ms = @max(elapsed_ms, 0);
    const shown = ms >= constants.MIN_WPM_MS;
    return .{
        .elapsed_ms = ms,
        .remaining_ms = if (limit_ms) |l| @max(0, l - ms) else null,
        .wpm = if (shown) perMinute(wpmChars(s), ms) else 0,
        .raw = if (shown) perMinute(s.log.typed, ms) else 0,
        .acc = s.log.accuracy(),
        .words_done = @intCast(s.doneCount()),
        .words_total = if (untimed_total) @intCast(s.wordCount()) else null,
        .corrected = s.log.corrected,
        .keystrokes = s.log.edits,
    };
}

/// Letter breakdown over the committed words (plus the typed part of the
/// active word: its untyped rest is not "missed" when time runs out).
pub fn charCounts(s: *const Session) CharCounts {
    var c: CharCounts = .{};
    const end = @min(s.activeIndex() + 1, s.wordCount());
    for (0..end) |i| {
        const typed = s.typedOf(i);
        const target = s.targetOf(i);
        const n = @min(typed.len, target.len);
        for (typed[0..n], target[0..n]) |a, b| {
            if (a == b) c.correct += 1 else c.incorrect += 1;
        }
        if (typed.len > target.len) c.extra += @intCast(typed.len - target.len);
        const committed = i < s.activeIndex() or s.isComplete();
        if (committed and target.len > typed.len) c.missed += @intCast(target.len - typed.len);
    }
    return c;
}

/// Coefficient-of-variation consistency of per-second raw, 0..100; null
/// with fewer than 3 samples.
pub fn consistency(series: []const Sample) ?f32 {
    if (series.len < 3) return null;
    var sum: f64 = 0;
    for (series) |p| sum += p.raw;
    const n: f64 = @floatFromInt(series.len);
    const mean = sum / n;
    if (mean <= 0) return 0;
    var sq: f64 = 0;
    for (series) |p| sq += (p.raw - mean) * (p.raw - mean);
    const cv = @sqrt(sq / n) / mean;
    return @floatCast(std.math.clamp(100.0 * (1.0 - cv), 0.0, 100.0));
}

/// One sample per elapsed second (the last one may be partial): cumulative
/// wpm, raw of that second, wrong keystrokes in that second.
pub fn buildSeries(s: *const Session, duration_ms: u32, out: *std.ArrayList(Sample), allocator: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    if (duration_ms == 0) return;
    const n = (duration_ms + 999) / 1000;
    try out.ensureTotalCapacity(allocator, n);
    const recs = s.log.records.items;
    var ri: usize = 0;
    var cum: i64 = 0;
    for (0..n) |k| {
        const lo: u32 = @intCast(k * 1000);
        const hi: u32 = @min(lo + 1000, duration_ms);
        var typed: u32 = 0;
        var errors: u32 = 0;
        // The last window also takes keys stamped exactly at the end.
        while (ri < recs.len and (recs[ri].t_ms < hi or (hi == duration_ms))) : (ri += 1) {
            const r = recs[ri];
            if (r.isTyped()) {
                typed += 1;
                if (!r.correct) errors += 1;
            }
            const len: i64 = @as(i64, @intCast(s.targetOf(r.word).len)) + 1;
            switch (r.kind) {
                .space, .newline, .skip => if (r.correct) {
                    cum += len;
                },
                .uncommit => if (r.correct) {
                    cum -= len;
                },
                else => {},
            }
        }
        var chars: i64 = cum;
        if (k + 1 == n) chars += @intCast(s.tailChars());
        // A partial last second is scaled to a full one only from 500 ms
        // on (Monkeytype): a few ms holding the final key would otherwise
        // read as a huge burst and wreck consistency.
        const window = if (hi - lo < 500) 1000 else hi - lo;
        out.appendAssumeCapacity(.{
            .t_s = @intCast(@min(k + 1, std.math.maxInt(u16))),
            .wpm = perMinute(@intCast(@max(chars, 0)), hi),
            .raw = perMinute(typed, window),
            .errors = @intCast(@min(errors, std.math.maxInt(u16))),
        });
    }
}

/// Distinct committed-wrong target words, in typing order.
fn collectMissed(s: *const Session, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    for (0..s.doneCount()) |i| {
        if (out.items.len >= MAX_MISSED_WORDS) break;
        const target = s.targetOf(i);
        if (std.mem.eql(u8, s.typedOf(i), target)) continue;
        // Words skipped untouched by Enter mid-line were not mistyped.
        if (s.typedOf(i).len == 0) continue;
        var dup = false;
        for (out.items) |w| dup = dup or std.mem.eql(u8, w, target);
        if (!dup) try out.append(allocator, target);
    }
}

fn slowerThan(_: void, a: WordTime, b: WordTime) bool {
    // ms per character, slowest first.
    return @as(u64, a.ms) * b.word.len > @as(u64, b.ms) * a.word.len;
}

/// The slowest correct words (> 2 letters) by ms per character.
fn collectSlow(s: *const Session, out: *std.ArrayList(WordTime), allocator: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    var all: std.ArrayList(WordTime) = .empty;
    defer all.deinit(allocator);
    var prev_end: ?u32 = null;
    for (0..s.doneCount()) |i| {
        const end = s.commitMs(i) orelse continue;
        defer prev_end = end;
        const target = s.targetOf(i);
        if (target.len <= 2 or !std.mem.eql(u8, s.typedOf(i), target)) continue;
        const start = prev_end orelse s.firstMs(i) orelse end;
        var dup = false;
        for (all.items) |*w| {
            if (std.mem.eql(u8, w.word, target)) {
                dup = true;
                w.ms = @max(w.ms, end -| start);
            }
        }
        if (!dup) try all.append(allocator, .{ .word = target, .ms = end -| start });
    }
    std.mem.sort(WordTime, all.items, {}, slowerThan);
    try out.appendSlice(allocator, all.items[0..@min(all.items.len, MAX_SLOW_WORDS)]);
}

/// The result of a words/sentences/code test. Slices point into `bufs`
/// and the session's text.
pub fn typingResult(s: *const Session, duration_ms: u32, pasted: bool, bufs: *Buffers, allocator: std.mem.Allocator) Result {
    buildSeries(s, duration_ms, &bufs.series, allocator) catch bufs.series.clearRetainingCapacity();
    collectMissed(s, &bufs.missed, allocator) catch {};
    collectSlow(s, &bufs.slow, allocator) catch {};
    return .{
        .kind = .typing,
        .wpm = perMinute(wpmChars(s), duration_ms),
        .raw = perMinute(s.log.typed, duration_ms),
        .acc = s.log.accuracy(),
        .consistency = consistency(bufs.series.items),
        .chars = charCounts(s),
        .corrected = s.log.corrected,
        .keystrokes = s.log.edits,
        .duration_ms = duration_ms,
        .series = bufs.series.items,
        .missed_words = bufs.missed.items,
        .slow_words = bufs.slow.items,
        .valid = duration_ms >= 1000 and !pasted,
        .quote_by = s.quoteBy(),
    };
}

// ---- tests ----

const testing = std.testing;
const Source = @import("source.zig").Source;

fn fixed(list: []const []const u8) !Session {
    return Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, list), .{ .min_words = 1000 });
}

/// Types `str` with one key every `step` ms; returns the last timestamp.
fn typeStr(s: *Session, str: []const u8, t: *u32, step: u32) void {
    for (str) |c| {
        t.* += step;
        s.apply(if (c == '\n') .newline else .{ .char = c }, t.*);
    }
}

const ten = [_][]const u8{ "alpha", "beta", "gamma", "delta", "omega", "sigma", "theta", "kappa", "lambda", "zeta" };

test "one extra letter: 1 extra, the rest correct, accuracy >= 95%" {
    var s = try fixed(&ten);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "alphax beta gamma delta omega sigma theta kappa lambda zeta", &t, 100);
    try testing.expect(s.isComplete());
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.chars.extra);
    try testing.expectEqual(@as(u32, 0), r.chars.incorrect);
    try testing.expectEqual(@as(u32, 0), r.chars.missed);
    for (1..ten.len) |i| try testing.expect(s.word(i).status == .correct);
    try testing.expect(r.acc >= 95);
    try testing.expect(r.valid);
    try testing.expectEqual(@as(usize, 1), r.missed_words.len);
    try testing.expectEqualStrings("alpha", r.missed_words[0]);
}

test "one missing letter is reported as missed" {
    var s = try fixed(&ten);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "alph beta gamma delta omega sigma theta kappa lambda zeta", &t, 100);
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.chars.missed);
    try testing.expectEqual(@as(u32, 0), r.chars.extra + r.chars.incorrect);
    try testing.expectEqual(WordStatus.incorrect, s.word(0).status);
}

const WordStatus = @import("session.zig").WordStatus;

test "corrected mistakes lower accuracy; raw >= wpm" {
    var s = try fixed(&ten);
    defer s.deinit();
    var t: u32 = 0;
    // Five wrong letters, each fixed right away.
    for (ten, 0..) |w, i| {
        if (i < 5) {
            typeStr(&s, "q", &t, 100);
            s.apply(.backspace, t);
        }
        typeStr(&s, w, &t, 100);
        if (i + 1 < ten.len) typeStr(&s, " ", &t, 100);
    }
    try testing.expect(s.isComplete());
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(u32, 5), r.corrected);
    try testing.expect(r.acc < 100);
    try testing.expectEqual(@as(u32, 0), r.chars.incorrect + r.chars.extra + r.chars.missed);
    try testing.expect(r.raw >= r.wpm);
    try testing.expect(r.wpm > 0);
}

test "series has one sample per started second; consistency needs 3" {
    var s = try fixed(&ten);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "alpha beta gam", &t, 180); // 14 keys → 2520 ms
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(usize, 3), r.series.len);
    try testing.expectEqual(@as(u16, 3), r.series[2].t_s);
    try testing.expect(r.consistency != null);
    // The last sample's wpm equals the result's.
    try testing.expectApproxEqAbs(r.wpm, r.series[2].wpm, 0.01);

    const r2 = typingResult(&s, 1500, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r2.series.len);
    try testing.expect(r2.consistency == null);
    try testing.expect(consistency(&.{}) == null);
    try testing.expect(!typingResult(&s, 900, false, &bufs, testing.allocator).valid);
    try testing.expect(!typingResult(&s, 5000, true, &bufs, testing.allocator).valid);
}

test "slow words: slowest correct words over 2 letters" {
    const list = [_][]const u8{ "abc", "de", "fghij", "klm", "nop" };
    var s = try fixed(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "abc ", &t, 100);
    typeStr(&s, "de ", &t, 900); // short: ignored
    typeStr(&s, "fghij ", &t, 100);
    typeStr(&s, "klm ", &t, 400); // slowest per char
    typeStr(&s, "nop", &t, 100);
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(usize, 4), r.slow_words.len);
    try testing.expectEqualStrings("klm", r.slow_words[0].word);
    try testing.expectEqual(@as(u32, 1600), r.slow_words[0].ms);
    for (r.slow_words) |w| try testing.expect(!std.mem.eql(u8, w.word, "de"));
}

test "live numbers" {
    var s = try fixed(&ten);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "alpha betx", &t, 100);
    const l = live(&s, 1000, 15000, false);
    try testing.expectEqual(@as(?i64, 14000), l.remaining_ms);
    try testing.expectEqual(@as(u32, 1), l.words_done);
    try testing.expect(l.words_total == null);
    // "alpha " + "bet" correct prefix = 9 chars in 1 s.
    try testing.expectApproxEqAbs(perMinute(9, 1000), l.wpm, 0.01);
    try testing.expectApproxEqAbs(perMinute(10, 1000), l.raw, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 90), l.acc, 0.01);
    try testing.expectEqual(@as(f32, 0), live(&s, 100, null, true).wpm);
    try testing.expectEqual(@as(?u32, 10), live(&s, 100, null, true).words_total);
}
