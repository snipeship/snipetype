//! Endless content stream for the word-by-word engine. Each `next()` call
//! yields one chunk: a word (words mode, with punctuation/numbers applied),
//! a sentence or quote (sentences mode) or a whole multi-line snippet (code
//! mode). Deterministic for a seed, allocation-free.
//!
//! Custom mode yields the user's text (once, or repeated when timed); with
//! weak-key weights, words mode favours words full of weak keys.

const std = @import("std");

const content = @import("content.zig");
const types = @import("types.zig");
const Config = types.Config;
const Lang = types.Lang;
const Rng = @import("rng.zig").Rng;
const stats = @import("stats.zig");

const quotes = @import("../game/quotes.zig").all;

pub const Chunk = struct {
    /// Static data or the source's scratch buffer (valid until next call).
    text: []const u8,
    /// Attribution of a quote (sentences mode).
    by: ?[]const u8 = null,
};

/// How consecutive chunks are joined in the target text: a space, a line
/// break (multi-line custom text repeating) or a blank line (code).
pub const Join = enum { space, newline, blank_line };

/// Words that are never picked twice within this many picks.
const RECENT = 10;
/// Pools (sentences + quotes, a code bank) are tracked in one bitset.
const MAX_POOL = 256;
/// Weak-key words: candidates drawn per pick, one chosen by weight.
const WEAK_POOL = 24;

const contractions = [_][]const u8{
    "don't",  "can't",  "won't",  "it's",    "that's",  "you're", "we're",  "they're",
    "isn't",  "didn't", "let's",  "there's", "doesn't", "aren't", "wasn't", "we'll",
    "you'll", "what's", "here's",
};

pub const Source = struct {
    rng: Rng,
    config: Config,
    /// Practice lists (missed words) replace the generator; the list is
    /// owned by the caller and yielded in order.
    custom: ?[]const []const u8 = null,
    custom_pos: usize = 0,
    /// Untimed words mode: words still to produce (the last one gets a
    /// sentence mark when punctuation is on).
    remaining: ?usize = null,
    code_lang: Lang = .mixed,
    /// Custom mode: the sanitized text (empty → content.custom_sample);
    /// owned by the caller. Untimed tests yield it once.
    text: []const u8 = "",
    text_done: bool = false,
    /// Words mode: weak-key weights (owned by the caller); null = uniform.
    weights: ?*const stats.KeyWeights = null,

    recent: [RECENT]u32 = undefined,
    recent_len: usize = 0,
    recent_pos: usize = 0,
    used: std.StaticBitSet(MAX_POOL) = .empty,
    used_count: usize = 0,

    /// Punctuation: words left in the current sentence, capitalise next.
    sentence_left: usize = 0,
    cap_next: bool = true,
    scratch: [96]u8 = undefined,

    pub fn init(seed: u64, config: Config, custom: ?[]const []const u8) Source {
        var s: Source = .{ .rng = Rng.init(seed), .config = config, .custom = custom };
        if (custom == null and config.mode == .words and config.time_limit == 0)
            s.remaining = std.math.clamp(config.word_count, types.MIN_WORDS, types.MAX_WORDS);
        if (config.mode == .code) {
            s.code_lang = config.lang;
            // "mixed" picks one language per test, like the old generator.
            if (config.lang == .mixed) s.code_lang = content.pickLang(&s.rng);
        }
        return s;
    }

    pub fn join(self: *const Source) Join {
        if (self.custom != null) return .space;
        return switch (self.config.mode) {
            .code => .blank_line,
            .custom => if (std.mem.indexOfScalar(u8, self.customText(), '\n') != null) .newline else .space,
            else => .space,
        };
    }

    /// The custom text, or the built-in sample when there is none.
    pub fn customText(self: *const Source) []const u8 {
        return if (self.text.len > 0) self.text else content.custom_sample;
    }

    /// The next chunk, or null when a finite source (practice list, untimed
    /// words count) is exhausted.
    pub fn next(self: *Source) ?Chunk {
        if (self.custom) |list| {
            if (self.custom_pos >= list.len) return null;
            self.custom_pos += 1;
            return .{ .text = list[self.custom_pos - 1] };
        }
        return switch (self.config.mode) {
            .sentences => self.nextSentence(),
            .code => .{ .text = self.pickFromPool(content.codeSnippets(self.code_lang)) },
            .custom => self.nextCustom(),
            else => self.nextWord(),
        };
    }

    fn nextCustom(self: *Source) ?Chunk {
        if (self.config.time_limit == 0) {
            if (self.text_done) return null;
            self.text_done = true;
        }
        return .{ .text = self.customText() };
    }

    fn nextSentence(self: *Source) Chunk {
        const builtin = content.sentenceList();
        const total = builtin.len + quotes.len;
        const idx = self.pickIndex(total);
        if (idx < builtin.len) return .{ .text = builtin[idx] };
        const q = quotes[idx - builtin.len];
        return .{ .text = q.text, .by = q.by };
    }

    fn pickFromPool(self: *Source, pool: []const []const u8) []const u8 {
        if (pool.len == 0) return "";
        return pool[self.pickIndex(pool.len)];
    }

    /// Random index in 0..n without repeats until all n were used.
    fn pickIndex(self: *Source, n_total: usize) usize {
        const n = @min(n_total, MAX_POOL);
        if (self.used_count >= n) {
            self.used = .empty;
            self.used_count = 0;
        }
        var k = self.rng.range(n - self.used_count);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.used.isSet(i)) continue;
            if (k == 0) break;
            k -= 1;
        }
        self.used.set(i);
        self.used_count += 1;
        return i;
    }

    fn nextWord(self: *Source) ?Chunk {
        if (self.remaining) |r| {
            if (r == 0) return null;
            self.remaining = r - 1;
        }
        const list = content.wordList(self.config.tier) catch return null;
        if (list.len == 0) return null;
        const base = if (self.weights) |w| list[self.pickWeighted(list, w)] else list[self.pickWord(list.len)];
        if (!self.config.punctuation and !self.config.numbers) return .{ .text = base };
        return .{ .text = self.decorate(base, list) };
    }

    /// A word index not among the last RECENT picks (when the list allows).
    fn pickWord(self: *Source, n: usize) usize {
        var idx: u32 = 0;
        var tries: usize = 0;
        while (true) : (tries += 1) {
            idx = @intCast(self.rng.range(n));
            if (n <= RECENT or tries > 32) break;
            const recent = self.recent[0..self.recent_len];
            if (std.mem.indexOfScalar(u32, recent, idx) == null) break;
        }
        self.recent[self.recent_pos] = idx;
        self.recent_pos = (self.recent_pos + 1) % RECENT;
        self.recent_len = @min(self.recent_len + 1, RECENT);
        return idx;
    }

    /// Weak keys: WEAK_POOL random candidates, one picked with probability
    /// proportional to the cube of its weakest letter's weight. Using the
    /// weakest letter keeps long words from winning on length alone, and
    /// the cube lets a clearly weak key beat its rarity in the list (q, z
    /// and x are in 2% of the common words).
    fn pickWeighted(self: *Source, list: []const []const u8, w: *const stats.KeyWeights) usize {
        var idx: [WEAK_POOL]usize = undefined;
        var score: [WEAK_POOL]f32 = undefined;
        var total: f32 = 0;
        for (&idx, &score) |*i, *sc| {
            i.* = self.pickWord(list.len);
            var top: f32 = 0;
            for (list[i.*]) |c| {
                if (stats.keyIndex(c)) |k| top = @max(top, w[k]);
            }
            sc.* = 0.05 + top * top * top;
            total += sc.*;
        }
        var r = @as(f32, @floatFromInt(self.rng.range(1 << 24))) / (1 << 24) * total;
        for (idx, score) |i, sc| {
            if (r < sc) return i;
            r -= sc;
        }
        return idx[WEAK_POOL - 1];
    }

    fn chance(self: *Source, percent: usize) bool {
        return self.rng.range(100) < percent;
    }

    /// Punctuation/numbers applied to one word, written to `scratch`.
    fn decorate(self: *Source, base: []const u8, list: []const []const u8) []const u8 {
        var buf: [96]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const punct = self.config.punctuation;
        if (punct and self.sentence_left == 0) {
            self.sentence_left = 6 + self.rng.range(7);
            self.cap_next = true;
        }
        const starts = self.cap_next;
        const ends = punct and (self.sentence_left == 1 or (self.remaining != null and self.remaining.? == 0));

        // Numbers never replace a sentence start (it stays a capital).
        if (self.config.numbers and !(punct and starts) and self.chance(10)) {
            self.writeNumber(&w);
        } else {
            var word = base;
            if (punct and self.chance(3)) word = contractions[self.rng.range(contractions.len)];
            const wrap: u8 = if (punct and !ends and self.chance(3)) (if (self.chance(50)) '"' else '(') else 0;
            if (wrap != 0) w.writeByte(wrap) catch {};
            if (starts and punct) {
                w.writeByte(std.ascii.toUpper(word[0])) catch {};
                w.writeAll(word[1..]) catch {};
            } else w.writeAll(word) catch {};
            if (punct and self.chance(2)) {
                w.writeByte('-') catch {};
                w.writeAll(list[self.rng.range(list.len)]) catch {};
            }
            if (wrap != 0) w.writeByte(if (wrap == '(') ')' else '"') catch {};
        }

        if (punct) {
            self.cap_next = false;
            if (ends) {
                const r = self.rng.range(100);
                w.writeByte(if (r < 70) '.' else if (r < 85) '?' else '!') catch {};
                self.cap_next = true;
                self.sentence_left = 0;
            } else {
                self.sentence_left -= 1;
                if (self.chance(10)) {
                    w.writeByte(',') catch {};
                } else if (self.chance(2)) {
                    w.writeByte(if (self.chance(50)) ';' else ':') catch {};
                }
            }
        }
        const out = w.buffered();
        @memcpy(self.scratch[0..out.len], out);
        return self.scratch[0..out.len];
    }

    fn writeNumber(self: *Source, w: *std.Io.Writer) void {
        switch (self.rng.range(5)) {
            0 => {
                const digits = 1 + self.rng.range(4);
                const max: usize = std.math.pow(usize, 10, digits);
                w.print("{d}", .{self.rng.range(max)}) catch {};
            },
            1 => w.print("{d}", .{1900 + self.rng.range(131)}) catch {},
            2 => w.print("{d}.{d:0>2}", .{ self.rng.range(100), self.rng.range(100) }) catch {},
            3 => w.print("{d}%", .{1 + self.rng.range(100)}) catch {},
            else => w.print("v{d}.{d}", .{ 1 + self.rng.range(9), self.rng.range(20) }) catch {},
        }
    }
};

fn collectWords(src: *Source, out: *std.ArrayList(u8), n: usize) !void {
    for (0..n) |i| {
        const chunk = src.next() orelse break;
        if (i > 0) try out.append(std.testing.allocator, ' ');
        try out.appendSlice(std.testing.allocator, chunk.text);
    }
}

test "plain words come from the tier and never repeat within 10" {
    var src = Source.init(42, .{ .mode = .words, .time_limit = 30, .tier = .easy }, null);
    var last: [RECENT][]const u8 = undefined;
    for (0..500) |i| {
        const w = src.next().?.text;
        for (last[0..@min(i, RECENT)]) |p| try std.testing.expect(!std.mem.eql(u8, p, w));
        last[i % RECENT] = w;
    }
}

test "untimed words mode yields exactly word_count words" {
    var src = Source.init(1, .{ .mode = .words, .word_count = 25 }, null);
    var n: usize = 0;
    while (src.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 25), n);
}

test "punctuation starts with a capital and ends with a sentence mark" {
    for (0..20) |seed| {
        var src = Source.init(seed, .{ .mode = .words, .word_count = 3 + seed * 3, .punctuation = true }, null);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try collectWords(&src, &out, 1000);
        const text = out.items;
        const first = if (text[0] == '"' or text[0] == '(') text[1] else text[0];
        try std.testing.expect(std.ascii.isUpper(first));
        const last = text[text.len - 1];
        try std.testing.expect(last == '.' or last == '?' or last == '!');
        // Every sentence mark is followed by a capitalised word.
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        var after_mark = false;
        while (it.next()) |w| {
            if (after_mark) {
                const c = if (w[0] == '"' or w[0] == '(') w[1] else w[0];
                try std.testing.expect(std.ascii.isUpper(c));
            }
            const e = w[w.len - 1];
            after_mark = e == '.' or e == '?' or e == '!';
        }
    }
}

test "numbers replace some words" {
    var src = Source.init(9, .{ .mode = .words, .time_limit = 60, .numbers = true }, null);
    var digits: usize = 0;
    for (0..400) |_| {
        const w = src.next().?.text;
        if (std.mem.indexOfAny(u8, w, "0123456789") != null) digits += 1;
    }
    try std.testing.expect(digits > 15 and digits < 90);
}

test "sentences mode doesn't repeat until the pool is exhausted" {
    var src = Source.init(5, .{ .mode = .sentences, .time_limit = 60 }, null);
    const pool = content.sentenceList().len + quotes.len;
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    var with_by: usize = 0;
    for (0..pool) |_| {
        const c = src.next().?;
        try std.testing.expect(!seen.contains(c.text));
        try seen.put(c.text, {});
        if (c.by != null) with_by += 1;
    }
    try std.testing.expectEqual(quotes.len, with_by);
    // The pool starts over afterwards.
    _ = src.next().?;
}

test "code mode yields whole snippets of one language without repeats" {
    var src = Source.init(3, .{ .mode = .code, .lang = .go, .time_limit = 60 }, null);
    try std.testing.expectEqual(Join.blank_line, src.join());
    const pool = content.codeSnippets(.go);
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (0..pool.len) |_| {
        const c = src.next().?;
        try std.testing.expect(std.mem.indexOfScalar(u8, c.text, '\n') != null);
        try std.testing.expect(!seen.contains(c.text));
        try seen.put(c.text, {});
    }
}

test "a custom list is yielded in order then ends" {
    const list = [_][]const u8{ "one", "two" };
    var src = Source.init(3, .{ .mode = .words, .time_limit = 60 }, &list);
    try std.testing.expectEqualStrings("one", src.next().?.text);
    try std.testing.expectEqualStrings("two", src.next().?.text);
    try std.testing.expect(src.next() == null);
}

test "custom text: once untimed, repeated timed, sample when empty" {
    var once = Source.init(1, .{ .mode = .custom }, null);
    once.text = "hello world";
    try std.testing.expectEqualStrings("hello world", once.next().?.text);
    try std.testing.expect(once.next() == null);
    try std.testing.expectEqual(Join.space, once.join());
    var timed = Source.init(1, .{ .mode = .custom, .time_limit = 30 }, null);
    timed.text = "a\nb";
    for (0..5) |_| try std.testing.expectEqualStrings("a\nb", timed.next().?.text);
    try std.testing.expectEqual(Join.newline, timed.join());
    var empty = Source.init(1, .{ .mode = .custom }, null);
    try std.testing.expectEqualStrings(content.custom_sample, empty.next().?.text);
}

test "weak-key weights favour words with heavy letters" {
    var w: stats.KeyWeights = @splat(1);
    w[stats.keyIndex('z').?] = 50;
    var plain = Source.init(4, .{ .mode = .words, .time_limit = 60, .tier = .common }, null);
    var weak = Source.init(4, .{ .mode = .words, .time_limit = 60, .tier = .common }, null);
    weak.weights = &w;
    var z_plain: usize = 0;
    var z_weak: usize = 0;
    for (0..400) |_| {
        z_plain += std.mem.count(u8, plain.next().?.text, "z");
        z_weak += std.mem.count(u8, weak.next().?.text, "z");
    }
    try std.testing.expect(z_weak > z_plain * 3);
}

test "weak keys from real stats favour those keys, not just long words" {
    // Per-key stats like a real history: every letter typed often, three
    // of them missed more and slower.
    var pk: stats.PerKey = .{};
    for ("abcdefghijklmnopqrstuvwxyz") |c| {
        const weak = std.mem.indexOfScalar(u8, "pkv", c) != null;
        pk.keys[stats.keyIndex(c).?] = .{ .hits = 400, .misses = if (weak) 40 else 8, .ms_sum = 390 * (if (weak) @as(u32, 260) else 160), .timed = 390 };
    }
    var w: stats.KeyWeights = undefined;
    try std.testing.expect(stats.weakWeights(&pk, &w));
    var plain = Source.init(9, .{ .mode = .words, .time_limit = 60, .tier = .common }, null);
    var weak = Source.init(9, .{ .mode = .words, .time_limit = 60, .tier = .common }, null);
    weak.weights = &w;
    var hit_plain: usize = 0;
    var hit_weak: usize = 0;
    var len_plain: usize = 0;
    var len_weak: usize = 0;
    for (0..2000) |_| {
        const a = plain.next().?.text;
        const b = weak.next().?.text;
        len_plain += a.len;
        len_weak += b.len;
        hit_plain += @intFromBool(std.mem.indexOfAny(u8, a, "pkv") != null);
        hit_weak += @intFromBool(std.mem.indexOfAny(u8, b, "pkv") != null);
    }
    try std.testing.expect(hit_weak * 10 > hit_plain * 18);
    try std.testing.expect(len_weak * 10 < len_plain * 13);
}
test "weak rare keys (q z x) still show up often" {
    // Per-key stats like a real history: every letter typed often, three
    // of them missed more and slower.
    var pk: stats.PerKey = .{};
    for ("abcdefghijklmnopqrstuvwxyz") |c| {
        const weak = std.mem.indexOfScalar(u8, "qzx", c) != null;
        pk.keys[stats.keyIndex(c).?] = .{ .hits = 400, .misses = if (weak) 40 else 8, .ms_sum = 390 * (if (weak) @as(u32, 260) else 160), .timed = 390 };
    }
    var w: stats.KeyWeights = undefined;
    try std.testing.expect(stats.weakWeights(&pk, &w));
    var plain = Source.init(9, .{ .mode = .words, .time_limit = 60, .tier = .common }, null);
    var weak = Source.init(9, .{ .mode = .words, .time_limit = 60, .tier = .common }, null);
    weak.weights = &w;
    var hit_plain: usize = 0;
    var hit_weak: usize = 0;
    var len_plain: usize = 0;
    var len_weak: usize = 0;
    for (0..2000) |_| {
        const a = plain.next().?.text;
        const b = weak.next().?.text;
        len_plain += a.len;
        len_weak += b.len;
        hit_plain += @intFromBool(std.mem.indexOfAny(u8, a, "qzx") != null);
        hit_weak += @intFromBool(std.mem.indexOfAny(u8, b, "qzx") != null);
    }
    try std.testing.expect(hit_weak > hit_plain * 3);
    try std.testing.expect(len_weak * 10 < len_plain * 13);
}
