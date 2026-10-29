//! Stream B test entry point: `zig test src/core_tests.zig` runs the typing
//! core (session, keystroke log, stats, content, history) test blocks, plus
//! the randomized property tests below.

const std = @import("std");
const testing = std.testing;

const types = @import("core/types.zig");
const Config = types.Config;
const constants = @import("core/constants.zig");
const Rng = @import("core/rng.zig").Rng;
const session_mod = @import("core/session.zig");
const Session = session_mod.Session;
const Edit = session_mod.Edit;
const stats = @import("core/stats.zig");
const history = @import("core/history.zig");
const typing_test = @import("core/typing_test.zig");
const TypingTest = typing_test.TypingTest;

test {
    _ = @import("core/session.zig");
    _ = @import("core/keylog.zig");
    _ = @import("core/stats.zig");
    _ = @import("core/source.zig");
    _ = @import("core/history.zig");
    _ = @import("core/snippets.zig");
    _ = @import("core/content.zig");
    _ = @import("core/metrics.zig");
    _ = @import("core/constants.zig");
    _ = @import("core/typing_test.zig");
    _ = @import("core/syntax.zig");
    _ = @import("core/daily.zig");
    _ = @import("core/layout.zig");
}

// ---- property tests ----

/// A random edit, biased towards typing the right next letter so tests
/// actually progress (and finish).
fn randomEdit(rng: *Rng, s: *const Session) Edit {
    const roll = rng.range(100);
    const i = s.activeIndex();
    const target = s.targetOf(i);
    const typed = s.typedOf(i);
    if (roll < 55) {
        if (typed.len < target.len) return .{ .char = target[typed.len] };
        return if (s.word(i).sep == .newline and rng.range(2) == 0) .newline else .{ .char = ' ' };
    }
    if (roll < 63) return .{ .char = @intCast(0x21 + rng.range(0x7e - 0x21 + 1)) };
    if (roll < 70) return .{ .char = ' ' };
    if (roll < 73) return .newline;
    if (roll < 82) return .backspace;
    return switch (rng.range(8)) {
        0 => .delete_word,
        1 => .delete_line,
        2 => .delete_forward,
        3 => .delete_word_forward,
        4 => .left,
        5 => .right,
        6 => .word_left,
        else => .word_right,
    };
}

/// Structural invariants of a session after any edit.
fn checkSession(s: *const Session) !void {
    const n = s.wordCount();
    try testing.expect(s.activeIndex() < n);
    try testing.expect(s.caret() <= s.typedOf(s.activeIndex()).len);
    var correct_chars: u32 = 0;
    for (0..n) |i| {
        const typed = s.typedOf(i);
        const target = s.targetOf(i);
        try testing.expect(target.len > 0);
        try testing.expect(typed.len <= target.len + constants.MAX_EXTRA_LETTERS);
        // Words after the active one are never touched.
        if (i > s.activeIndex()) try testing.expectEqual(@as(usize, 0), typed.len);
        if (i < s.activeIndex() and std.mem.eql(u8, typed, target)) correct_chars += @intCast(target.len + 1);
    }
    if (!s.isComplete()) try testing.expectEqual(correct_chars, s.correct_chars);
    // Only an exact last word ends the test without a Space.
    if (s.isComplete() and !s.last_committed) {
        try testing.expectEqualStrings(s.targetOf(s.activeIndex()), s.typedOf(s.activeIndex()));
    }
    try testing.expect(s.log.correct <= s.log.typed);
}

/// Result invariants (simple modes).
fn checkResult(t: *const TypingTest) !void {
    const r = t.result().?;
    const s = &t.session;
    try testing.expect(std.math.isFinite(r.wpm) and r.wpm >= 0);
    try testing.expect(std.math.isFinite(r.raw) and r.raw >= 0);
    try testing.expect(r.acc >= 0 and r.acc <= 100);
    // Every counted letter of a correct word was typed at least once.
    try testing.expect(r.raw + 0.001 >= r.wpm);
    if (r.consistency) |c| try testing.expect(c >= 0 and c <= 100);
    try testing.expect(r.missed_words.len <= stats.MAX_MISSED_WORDS);
    try testing.expect(r.slow_words.len <= stats.MAX_SLOW_WORDS);
    try testing.expectEqual(@as(usize, (r.duration_ms + 999) / 1000), r.series.len);
    if (r.series.len > 0) try testing.expectApproxEqAbs(r.wpm, r.series[r.series.len - 1].wpm, 0.01);
    for (r.series) |p| try testing.expect(std.math.isFinite(p.raw) and std.math.isFinite(p.wpm));
    if (t.config.time_limit > 0) {
        try testing.expect(r.duration_ms <= t.config.time_limit * 1000);
    }

    // Letter breakdown, recomputed independently.
    var c: stats.CharCounts = .{};
    const last = s.activeIndex() + 1;
    for (0..last) |i| {
        const typed = s.typedOf(i);
        const target = s.targetOf(i);
        const m = @min(typed.len, target.len);
        for (0..m) |k| {
            if (typed[k] == target[k]) c.correct += 1 else c.incorrect += 1;
        }
        if (typed.len > target.len) c.extra += @intCast(typed.len - target.len);
        const committed = i < s.activeIndex() or s.isComplete();
        if (committed and target.len > typed.len) c.missed += @intCast(target.len - typed.len);
    }
    try testing.expectEqual(c, r.chars);
}

fn fuzzConfig(rng: *Rng) Config {
    const modes = [_]types.Mode{ .words, .words, .sentences, .code };
    const tiers = [_]types.WordTier{ .easy, .common, .full };
    const langs = [_]types.Lang{ .zig, .rust, .go, .typescript, .python, .c, .mixed };
    const times = [_]usize{ 0, 0, 15, 30 };
    return .{
        .mode = modes[rng.range(modes.len)],
        .word_count = 1 + rng.range(60),
        .time_limit = times[rng.range(times.len)],
        .tier = tiers[rng.range(tiers.len)],
        .lang = langs[rng.range(langs.len)],
        .punctuation = rng.range(2) == 0,
        .numbers = rng.range(2) == 0,
    };
}

test "property: random keystroke streams keep session and stats invariants" {
    var rng = Rng.init(0x5eed);
    for (0..300) |round| {
        const cfg = fuzzConfig(&rng);
        var t = try TypingTest.init(testing.allocator, round, cfg);
        defer t.deinit();
        var now: i64 = 1_000_000;
        var steps: usize = 0;
        while (t.state != .finished and steps < 4000) : (steps += 1) {
            now += @intCast(rng.range(260));
            t.handleEdit(randomEdit(&rng, &t.session), now);
            try checkSession(&t.session);
            if (t.state == .typing and cfg.time_limit > 0) {
                // Timed tests never run out of words.
                try testing.expect(t.session.wordCount() - t.session.activeIndex() > constants.ENDLESS_LOOKAHEAD_WORDS);
            }
            const l = t.live(now);
            try testing.expect(l.acc >= 0 and l.acc <= 100);
            try testing.expect(l.raw + 0.001 >= l.wpm);
            if (l.remaining_ms) |rem| try testing.expect(rem >= 0);
            if (rng.range(50) == 0) t.tick(now);
        }
        if (t.state != .finished) {
            t.tick(now + 10_000_000);
            if (t.state != .finished) continue; // untimed and still going
        }
        try checkResult(&t);
        if (cfg.time_limit > 0) {
            try testing.expectEqual(@as(i64, @intCast(cfg.time_limit * 1000)), t.end_time.? - t.start_time.?);
        }
        // Practice: each missed word three times, nothing else.
        const missed = t.result().?.missed_words.len;
        if (try t.practiceMissed()) {
            try testing.expect(missed > 0);
            // Timed runs pull the list lazily (lookahead), untimed all at once.
            if (cfg.time_limit == 0) {
                try testing.expectEqual(missed * 3, t.session.wordCount());
            } else try testing.expect(t.session.wordCount() <= missed * 3);
            try testing.expect(t.isPractice());
            try t.reset(round + 1);
        } else try testing.expectEqual(@as(usize, 0), missed);
        // restartSame keeps the target.
        const first = t.session.targetOf(0);
        var copy: [128]u8 = undefined;
        const n = @min(first.len, copy.len);
        @memcpy(copy[0..n], first[0..n]);
        try t.restartSame();
        try testing.expectEqualStrings(copy[0..n], t.session.targetOf(0)[0..n]);
    }
}

test "property: a correct last word committed with Space is counted once" {
    const list = [_][]const u8{ "ab", "cd" };
    var s = try Session.init(testing.allocator, @import("core/source.zig").Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10 });
    defer s.deinit();
    var t: u32 = 0;
    // "cxd", then remove the 'x': exact, but not by typing a letter.
    for ("ab cxd") |ch| {
        t += 100;
        s.apply(.{ .char = ch }, t);
    }
    s.apply(.left, t + 50);
    s.apply(.backspace, t + 100);
    try testing.expect(!s.isComplete());
    s.apply(.{ .char = ' ' }, t + 200);
    try testing.expect(s.isComplete());
    var bufs: stats.Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = stats.typingResult(&s, t + 200, false, &bufs, testing.allocator);
    // "ab " + "cd " = 6 chars (each word plus its separator), not 8.
    try testing.expectApproxEqAbs(stats.perMinute(6, t + 200), r.wpm, 0.01);
    try testing.expect(r.raw >= r.wpm);
}

test "property: an incorrect committed last word adds nothing to wpm" {
    const list = [_][]const u8{ "ab", "cde" };
    var s = try Session.init(testing.allocator, @import("core/source.zig").Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10 });
    defer s.deinit();
    var t: u32 = 0;
    for ("ab cd ") |ch| {
        t += 100;
        s.apply(.{ .char = ch }, t);
    }
    try testing.expect(s.isComplete());
    var bufs: stats.Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = stats.typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectApproxEqAbs(stats.perMinute(3, t), r.wpm, 0.01);
}

test "property: a short partial last second doesn't wreck consistency" {
    // Ten words at a steady pace, the last key landing 1 ms into a new
    // second: that sliver must not count as a 12000-wpm burst.
    const list = [_][]const u8{ "aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff", "gggg", "hhhh", "iiii", "jjjj" };
    var s = try Session.init(testing.allocator, @import("core/source.zig").Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10 });
    defer s.deinit();
    var t: u32 = 201;
    var keys: u32 = 0;
    for (list, 0..) |w, i| {
        for (w) |ch| {
            s.apply(.{ .char = ch }, t);
            keys += 1;
            t += 100;
        }
        if (i + 1 < list.len) {
            s.apply(.{ .char = ' ' }, t);
            keys += 1;
            t += 100;
        }
    }
    try testing.expect(s.isComplete());
    // 49 keys, the last one (and the end) at 5001 ms.
    try testing.expectEqual(@as(u32, 49), keys);
    const duration: u32 = 5001;
    var bufs: stats.Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = stats.typingResult(&s, duration, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(usize, 6), r.series.len);
    for (r.series) |p| try testing.expect(p.raw <= 200);
    try testing.expect(r.consistency.? > 50);
}

test "property: history lines round-trip through the PB table" {
    var rng = Rng.init(77);
    var pb = history.PbTable.init(testing.allocator);
    defer pb.deinit();
    var jsonl: std.ArrayList(u8) = .empty;
    defer jsonl.deinit(testing.allocator);
    var buf: [512]u8 = undefined;
    var best: f32 = 0;
    const cfg: Config = .{ .mode = .code, .lang = .rust, .time_limit = 30 };
    for (0..200) |i| {
        const wpm: f32 = @as(f32, @floatFromInt(rng.range(20000))) / 100.0;
        const res: stats.Result = .{
            .kind = .typing,
            .wpm = wpm,
            .raw = wpm + 1,
            .acc = 90,
            .consistency = if (i % 3 == 0) null else 70,
            .chars = .{},
            .corrected = 0,
            .keystrokes = 0,
            .duration_ms = 30_000,
            .series = &.{},
            .missed_words = &.{},
            .slow_words = &.{},
            .valid = true,
        };
        const line = history.recordLine(&res, cfg, @intCast(i), i, &buf);
        try testing.expect(line.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
        try jsonl.appendSlice(testing.allocator, line);
        try jsonl.append(testing.allocator, '\n');
        // Inject garbage now and then.
        if (i % 17 == 0) try jsonl.appendSlice(testing.allocator, "{\"v\":1,\"key\":\n");
        const rounded = @round(wpm * 10) / 10;
        best = @max(best, rounded);
    }
    pb.loadJsonl(jsonl.items);
    var key_buf: [64]u8 = undefined;
    try testing.expectApproxEqAbs(best, pb.bestWpm(history.pbKey(cfg, &key_buf)).?, 0.051);
}

test "property: invalid drill results never become a PB" {
    var pb = history.PbTable.init(testing.allocator);
    defer pb.deinit();
    const res: stats.Result = .{
        .kind = .vim_drill,
        .wpm = 0,
        .raw = 0,
        .acc = 100,
        .consistency = null,
        .chars = .{},
        .corrected = 0,
        .keystrokes = 1,
        .duration_ms = 500,
        .series = &.{},
        .missed_words = &.{},
        .slow_words = &.{},
        .valid = false,
        .strokes = 1,
        .drill_id = "a/b",
    };
    try testing.expectEqual(history.PbOutcome.none, pb.submit(.{ .mode = .vim }, &res));
    try testing.expect(pb.bestDrill("a/b") == null);
}

test "property: config JSON round-trips for every combination" {
    var rng = Rng.init(3);
    var buf: [512]u8 = undefined;
    for (0..200) |_| {
        var cfg = fuzzConfig(&rng);
        cfg.vim_kind = if (rng.range(2) == 0) .type else .drills;
        if (rng.range(3) == 0) cfg.mode = .vim;
        const json = history.configToJson(cfg, "tokyo-night", &buf);
        var back: Config = .{};
        var theme: [32]u8 = undefined;
        try testing.expectEqualStrings("tokyo-night", history.configFromJson(json, &back, &theme).?);
        try testing.expectEqual(cfg.mode, back.mode);
        try testing.expectEqual(cfg.word_count, back.word_count);
        try testing.expectEqual(cfg.time_limit, back.time_limit);
        try testing.expectEqual(cfg.lang, back.lang);
        try testing.expectEqual(cfg.tier, back.tier);
        try testing.expectEqual(cfg.punctuation, back.punctuation);
        try testing.expectEqual(cfg.numbers, back.numbers);
        try testing.expectEqual(cfg.vim_kind, back.vim_kind);
    }
}

test "property: generated words are typable tokens; punctuation keeps sentence shape" {
    var rng = Rng.init(11);
    for (0..400) |seed| {
        var cfg = fuzzConfig(&rng);
        cfg.mode = .words;
        var src = Source.init(seed, cfg, null);
        var n: usize = 0;
        var cap_next = true;
        var last: []const u8 = "";
        while (src.next()) |chunk| : (n += 1) {
            if (n >= 300) break;
            const w = chunk.text;
            try testing.expect(w.len > 0);
            for (w) |ch| try testing.expect(ch >= 0x21 and ch <= 0x7e);
            if (cfg.punctuation) {
                const c0 = if (w[0] == '"' or w[0] == '(') w[1] else w[0];
                if (cap_next) try testing.expect(std.ascii.isUpper(c0));
                if (!cap_next and std.ascii.isAlphabetic(c0)) try testing.expect(std.ascii.isLower(c0));
                const e = w[w.len - 1];
                cap_next = e == '.' or e == '?' or e == '!';
            } else if (!cfg.numbers) {
                for (w) |ch| try testing.expect(ch >= 'a' and ch <= 'z');
            }
            last = w;
        }
        if (cfg.time_limit == 0) {
            try testing.expectEqual(@min(cfg.word_count, 300), n);
            if (cfg.punctuation) try testing.expect(cap_next); // ends a sentence
        }
    }
}

// ---- round 2: policies, Enter-skip, zen, custom, daily, per-key ----

const Source = @import("core/source.zig").Source;
const daily = @import("core/daily.zig");
const layout = @import("core/layout.zig");

fn sumTyped(s: *const Session) usize {
    var n: usize = 0;
    for (0..s.wordCount()) |i| n += s.typedOf(i).len;
    return n;
}

test "property: strict policies, custom and daily texts keep the invariants" {
    var rng = Rng.init(0xbeef);
    const custom_texts = [_][]const u8{
        "one two three four five",
        "fn main() {\n    let x = 1;\n\n    return x;\n}",
        "  indented first\nsecond line here\n\tthird",
    };
    for (0..240) |round| {
        var cfg = fuzzConfig(&rng);
        const modes = [_]types.Mode{ .words, .code, .custom, .daily, .sentences };
        cfg.mode = modes[rng.range(modes.len)];
        const stops = [_]types.StopOnError{ .off, .letter, .word };
        cfg.stop_on_error = stops[rng.range(stops.len)];
        cfg.no_backspace = rng.range(3) == 0;
        cfg.day = @intCast(rng.range(30000));
        var t = try TypingTest.init(testing.allocator, round, cfg);
        defer t.deinit();
        if (cfg.mode == .custom and rng.range(4) != 0) {
            try t.setCustomText(custom_texts[rng.range(custom_texts.len)]);
            try t.restartSame();
        }
        var now: i64 = 1_000_000;
        var steps: usize = 0;
        while (t.state != .finished and steps < 3000) : (steps += 1) {
            now += @intCast(rng.range(260));
            const s = &t.session;
            const before_typed = sumTyped(s);
            const before_active = s.activeIndex();
            const edit = randomEdit(&rng, s);
            t.handleEdit(edit, now);
            try checkSession(s);
            if (cfg.no_backspace) {
                try testing.expect(sumTyped(s) >= before_typed);
                try testing.expect(s.activeIndex() >= before_active);
            }
            // Word plus no-backspace stops on the letter (TypingTest.policy).
            const stop: types.StopOnError = if (cfg.stop_on_error == .word and cfg.no_backspace) .letter else cfg.stop_on_error;
            if (stop == .letter and edit == .char and sumTyped(s) > before_typed) {
                const c = s.caret();
                const target = s.targetOf(s.activeIndex());
                const typed = s.typedOf(s.activeIndex());
                if (!s.isComplete()) try testing.expect(c - 1 < target.len and typed[c - 1] == target[c - 1]);
            }
            if (stop == .word) {
                for (0..s.activeIndex()) |i| try testing.expectEqualStrings(s.targetOf(i), s.typedOf(i));
            }
            const pk = s.per_key.total();
            try testing.expect(pk.misses <= s.log.typed - s.log.correct);
            try testing.expect(pk.hits <= s.log.typed);
            try testing.expect(pk.timed <= pk.hits - pk.misses);
        }
        if (t.state != .finished) {
            t.tick(now + 10_000_000);
            if (t.state != .finished) try testing.expect(t.submit(now));
        }
        const r = t.result().?;
        try testing.expect(r.acc >= 0 and r.acc <= 100);
        try testing.expect(r.raw + 0.001 >= r.wpm);
        if (r.series.len > 0) try testing.expectApproxEqAbs(r.wpm, r.series[r.series.len - 1].wpm, 0.01);
        try testing.expect(r.per_key != null);
        if (cfg.mode == .daily) try testing.expectEqual(types.DAILY_WORDS, t.session.wordCount());
        var buf: [history.MAX_RECORD_LEN]u8 = undefined;
        const line = history.recordLine(r, t.config, 1, 1, &buf);
        try testing.expect(line.len > 0);
        var log = history.Log.init(testing.allocator);
        defer log.deinit();
        log.addLine(line);
        try testing.expectEqualDeep(r.per_key.?.*, log.perKey().*);
    }
}

test "property: random Enter presses keep correct_chars equal to a recount" {
    var rng = Rng.init(42);
    for (0..150) |round| {
        const langs = [_]types.Lang{ .zig, .python, .yaml, .sql, .bash, .mixed };
        var t = try TypingTest.init(testing.allocator, round, .{ .mode = .code, .lang = langs[round % langs.len], .word_count = 1 + rng.range(40), .time_limit = if (round % 3 == 0) 15 else 0 });
        defer t.deinit();
        var now: i64 = 0;
        var steps: usize = 0;
        while (t.state != .finished and steps < 2000) : (steps += 1) {
            now += 50;
            const s = &t.session;
            const edit: Edit = switch (rng.range(10)) {
                0, 1 => .newline,
                2 => .backspace,
                3 => .{ .char = ' ' },
                else => blk: {
                    const target = s.targetOf(s.activeIndex());
                    const typed = s.typedOf(s.activeIndex());
                    break :blk .{ .char = if (typed.len < target.len and rng.range(5) != 0) target[typed.len] else 'x' };
                },
            };
            const typed_before = s.log.typed;
            const line_before = s.activeIndex();
            t.handleEdit(edit, now);
            try checkSession(s);
            // Enter adds at most one keystroke and never moves backwards.
            if (edit == .newline) {
                try testing.expect(s.log.typed - typed_before <= 1);
                try testing.expect(s.activeIndex() >= line_before);
                // After a skip the caret sits at the start of a line.
                if (s.log.typed > typed_before and !s.isComplete()) {
                    try testing.expectEqual(@as(usize, 0), s.caret());
                    try testing.expect(s.activeIndex() == 0 or s.word(s.activeIndex() - 1).sep == .newline);
                }
            }
        }
        if (t.state != .finished) t.tick(now + 1_000_000);
        if (t.state != .finished) _ = t.submit(now);
        try checkResult(&t);
    }
}

test "property: zen sessions keep their own invariants" {
    var rng = Rng.init(9);
    for (0..100) |round| {
        var t = try TypingTest.init(testing.allocator, round, .{ .mode = .zen, .time_limit = 15 });
        defer t.deinit();
        var now: i64 = 0;
        for (0..600) |_| {
            now += @intCast(1 + rng.range(300));
            const s = &t.session;
            const edit: Edit = switch (rng.range(12)) {
                0, 1 => .{ .char = ' ' },
                2 => .newline,
                3 => .backspace,
                4 => .delete_word,
                5 => .left,
                6 => .delete_line,
                else => .{ .char = @intCast('a' + rng.range(26)) },
            };
            t.handleEdit(edit, now);
            try testing.expect(s.activeIndex() < s.wordCount());
            try testing.expect(s.caret() <= s.typedOf(s.activeIndex()).len);
            var cc: u32 = 0;
            for (0..s.activeIndex()) |i| {
                try testing.expect(s.typedOf(i).len > 0);
                try testing.expectEqual(session_mod.WordStatus.correct, s.word(i).status);
                cc += @intCast(s.typedOf(i).len + 1);
            }
            for (s.activeIndex() + 1..s.wordCount()) |i| try testing.expectEqual(@as(usize, 0), s.typedOf(i).len);
            try testing.expectEqual(cc, s.correct_chars);
            try testing.expectEqual(s.log.typed, s.log.correct);
        }
        t.tick(now + 100_000);
        if (t.state == .waiting) continue;
        try testing.expect(t.submit(now));
        const r = t.result().?;
        try testing.expect(r.per_key == null);
        try testing.expect(r.acc >= 0 and r.acc <= 100);
        try testing.expect(r.raw + 0.001 >= r.wpm);
        try testing.expectEqual(@as(u32, 0), r.chars.incorrect + r.chars.missed + r.chars.extra);
        if (r.series.len > 0) try testing.expectApproxEqAbs(r.wpm, r.series[r.series.len - 1].wpm, 0.01);
    }
}

test "property: custom text sanitizing is clean and idempotent" {
    var rng = Rng.init(123);
    for (0..300) |_| {
        var raw: [400]u8 = undefined;
        const n = rng.range(raw.len);
        const alphabet = "ab \t\r\n\x00\x7f\xc3\xa9.,;{}";
        for (raw[0..n]) |*c| c.* = if (rng.range(4) == 0) @intCast(rng.range(256)) else alphabet[rng.range(alphabet.len)];
        const once = try typing_test.sanitizeCustom(testing.allocator, raw[0..n]);
        defer testing.allocator.free(once);
        const twice = try typing_test.sanitizeCustom(testing.allocator, once);
        defer testing.allocator.free(twice);
        try testing.expectEqualStrings(once, twice);
        for (once) |c| try testing.expect(c == '\n' or (c >= 0x20 and c <= 0x7e));
        try testing.expect(std.mem.indexOf(u8, once, " \n") == null);
        if (once.len > 0) {
            try testing.expect(once[once.len - 1] != ' ' and once[once.len - 1] != '\n');
            try testing.expect(once[0] != '\n');
        }
        // Typing it exactly gives a perfect run (or nothing to type).
        var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .custom });
        defer t.deinit();
        try t.setCustomText(raw[0..n]);
        try t.restartSame();
        var now: i64 = 0;
        var guard: usize = 0;
        while (t.state != .finished and guard < 2000) : (guard += 1) {
            const s = &t.session;
            const i = s.activeIndex();
            for (s.targetOf(i)[s.typedOf(i).len..]) |c| {
                now += 40;
                t.handleEdit(.{ .char = c }, now);
            }
            if (t.state == .finished) break;
            now += 40;
            t.handleEdit(if (s.word(i).sep == .newline) .newline else .{ .char = ' ' }, now);
        }
        try testing.expectEqual(typing_test.TestState.finished, t.state);
        try testing.expectEqual(@as(f32, 100), t.result().?.acc);
    }
}

test "property: daily texts depend only on the date" {
    for (0..40) |k| {
        const day: u32 = @intCast(18000 + k * 37);
        var a = try TypingTest.init(testing.allocator, k, .{ .mode = .daily, .day = day });
        defer a.deinit();
        var b = try TypingTest.init(testing.allocator, k * 7919 + 1, .{ .mode = .daily, .day = day, .tier = .full, .punctuation = false, .numbers = true, .word_count = 3, .time_limit = 60 });
        defer b.deinit();
        try testing.expectEqual(types.DAILY_WORDS, a.session.wordCount());
        for (0..types.DAILY_WORDS) |i| try testing.expectEqualStrings(a.session.targetOf(i), b.session.targetOf(i));
        var ds: [10]u8 = undefined;
        const date = daily.format(day, &ds);
        try testing.expectEqual(@as(usize, 10), date.len);
    }
}

test "property: weak-key sources are deterministic and draw from the tier" {
    var rng = Rng.init(77);
    for (0..40) |seed| {
        var w: stats.KeyWeights = undefined;
        for (&w) |*x| x.* = @as(f32, @floatFromInt(rng.range(100))) / 10;
        const tiers = [_]types.WordTier{ .easy, .common, .k5 };
        const cfg: Config = .{ .mode = .words, .time_limit = 30, .tier = tiers[seed % tiers.len] };
        var a = Source.init(seed, cfg, null);
        var b = Source.init(seed, cfg, null);
        a.weights = &w;
        b.weights = &w;
        const list = try @import("core/content.zig").wordList(cfg.tier);
        for (0..100) |_| {
            const x = a.next().?.text;
            try testing.expectEqualStrings(x, b.next().?.text);
            var found = false;
            for (list) |l| found = found or std.mem.eql(u8, l, x);
            try testing.expect(found);
        }
    }
}

test "property: per-key stats of exact typing count every target letter" {
    var rng = Rng.init(31);
    for (0..60) |round| {
        var t = try TypingTest.init(testing.allocator, round, .{ .mode = if (round % 2 == 0) .words else .code, .word_count = 1 + rng.range(30), .punctuation = round % 3 == 0 });
        defer t.deinit();
        var now: i64 = 0;
        var letters: u32 = 0;
        var keyed: u32 = 0;
        while (t.state != .finished) {
            const s = &t.session;
            const i = s.activeIndex();
            for (s.targetOf(i)) |c| {
                now += 100;
                letters += 1;
                if (stats.keyIndex(c) != null) keyed += 1;
                t.handleEdit(.{ .char = c }, now);
            }
            if (t.state == .finished) break;
            now += 100;
            t.handleEdit(if (s.word(i).sep == .newline) .newline else .{ .char = ' ' }, now);
        }
        const pk = t.result().?.per_key.?;
        const tot = pk.total();
        try testing.expectEqual(keyed, tot.hits);
        try testing.expectEqual(@as(u32, 0), tot.misses);
        try testing.expectEqual(keyed - 1, tot.timed); // all but the first keystroke
        try testing.expectEqual(@as(u32, 100) * (keyed - 1), tot.ms_sum);
        try testing.expect(letters >= keyed);
    }
}

test "property: layout remap round-trips through the inverse table" {
    for (std.meta.tags(types.Layout)) |l| {
        var inv: [128]u8 = @splat(0);
        for (0x20..0x7f) |c| inv[layout.remap(l, @intCast(c))] = @intCast(c);
        for (0x20..0x7f) |c| try testing.expectEqual(@as(u8, @intCast(c)), inv[layout.remap(l, @intCast(c))]);
        // Case is preserved for letters.
        for ('a'..'z' + 1) |c| {
            const lo = layout.remap(l, @intCast(c));
            const up = layout.remap(l, std.ascii.toUpper(@intCast(c)));
            if (std.ascii.isAlphabetic(lo)) try testing.expectEqual(std.ascii.toUpper(lo), up);
        }
    }
}

// ---- review regressions ----

const syntax = @import("core/syntax.zig");

/// A code-like session (Enter skips the rest of a line).
fn reviewCode(text: []const u8) !Session {
    var s = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &.{}), .{ .enter_skips_line = true });
    errdefer s.deinit();
    try s.appendText(text, null, .space);
    return s;
}

fn reviewType(s: *Session, str: []const u8, t: *u32) void {
    for (str) |c| {
        t.* += 100;
        s.apply(if (c == '\n') .newline else .{ .char = c }, t.*);
    }
}

test "review: Enter after a Space on a line's last word skips that word" {
    var s = try reviewCode("return foo;\n    bar\nbaz qux");
    defer s.deinit();
    var t: u32 = 0;
    reviewType(&s, "return ", &t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    s.apply(.newline, t);
    // "foo;" is skipped (one wrong Enter) and the caret is on "bar".
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    try testing.expect(s.word(1).skipped);
    try testing.expectEqual(@as(u32, 8), s.log.typed);
    try testing.expectEqual(@as(u32, 7), s.log.correct);
    // A double Enter on the untouched next line still does nothing.
    s.apply(.newline, t);
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    // On the last line, Enter after a Space ends the test.
    reviewType(&s, "bar\nbaz ", &t);
    try testing.expectEqual(@as(usize, 4), s.activeIndex());
    s.apply(.newline, t);
    try testing.expect(s.isComplete());
    try testing.expect(s.word(4).skipped);
}

test "review: Enter on a partly typed last word of the text ends the test" {
    var s = try reviewCode("ab\ncd ef");
    defer s.deinit();
    var t: u32 = 0;
    reviewType(&s, "ab\ncd e", &t);
    s.apply(.newline, t);
    try testing.expect(s.isComplete());
    try testing.expect(s.word(2).skipped);
    try testing.expectEqual(@as(u32, 6), s.correct_chars); // "ab\n" + "cd "
}

test "review: Enter on a long line of timed custom text does not end the test" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "first line\n");
    for (0..constants.ENDLESS_LOOKAHEAD_WORDS + 20) |i| {
        if (i > 0) try text.append(testing.allocator, ' ');
        try text.appendSlice(testing.allocator, "word");
    }
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .custom, .time_limit = 30 });
    defer t.deinit();
    try t.setCustomText(text.items);
    try t.restartSame();
    var now: i64 = 1000;
    for ("first line") |c| {
        now += 100;
        t.handleEdit(.{ .char = c }, now);
    }
    now += 100;
    t.handleEdit(.newline, now);
    now += 100;
    t.handleEdit(.{ .char = 'w' }, now);
    now += 100;
    t.handleEdit(.newline, now);
    // Timed: the text repeats, so the skip lands on "first" again.
    try testing.expectEqual(typing_test.TestState.typing, t.state);
    try testing.expectEqualStrings("first", t.session.targetOf(t.session.activeIndex()));
}

test "review: the tokenizer never overruns on random bytes" {
    var rng = Rng.init(0x5eed);
    var line: [600]u8 = undefined;
    var out: [600]syntax.Kind = undefined;
    for (std.meta.tags(types.Lang)) |l| {
        var st: syntax.State = .{};
        for (0..400) |_| {
            const n = rng.range(line.len);
            const alphabet = "\"'`/*#-[]=<>{}()\\ \t0x1_.eE:;abcZ$@!";
            for (line[0..n]) |*c| c.* = if (rng.range(8) == 0) @intCast(0x20 + rng.range(95)) else alphabet[rng.range(alphabet.len)];
            syntax.highlightLine(l, line[0..n], &st, out[0..n]);
        }
        _ = syntax.guessLang(line[0..rng.range(line.len)]);
    }
}

test "review: weak keys with an empty history fall back to normal words" {
    var log = history.Log.init(testing.allocator);
    defer log.deinit();
    var w: stats.KeyWeights = undefined;
    try testing.expect(!log.weakWeights(&w));
    for (w) |x| try testing.expectEqual(@as(f32, 0), x);
    var weak = try TypingTest.init(testing.allocator, 5, .{ .mode = .words, .focus = .weak, .word_count = 30 });
    defer weak.deinit();
    try testing.expect(!(try weak.practiceWeak()));
    try testing.expect(!weak.isPractice());
    var normal = try TypingTest.init(testing.allocator, 5, .{ .mode = .words, .word_count = 30 });
    defer normal.deinit();
    try testing.expectEqual(normal.session.wordCount(), weak.session.wordCount());
    for (0..normal.session.wordCount()) |i| try testing.expectEqualStrings(normal.session.targetOf(i), weak.session.targetOf(i));
}

test "review: Log loads identically at every split point (CRLF too)" {
    const lines =
        "{\"v\":1,\"ts\":100,\"kind\":\"typing\",\"key\":\"words|common|w25|p0n0\",\"mode\":\"words\",\"wpm\":80.5,\"raw\":82,\"acc\":97,\"ms\":20000,\"pk\":\"a:10/1/1500/9 s:5/0/700/5\"}\r\n" ++
        "garbage line\n" ++
        "{\"v\":1,\"ts\":0,\"kind\":\"typing\",\"key\":\"words|common|w25|p0n0\",\"mode\":\"words\",\"wpm\":90,\"pb\":true}\n" ++
        "{\"v\":1,\"ts\":200,\"kind\":\"drill\",\"key\":\"drill|x\",\"id\":\"x\",\"strokes\":7,\"par\":6,\"stars\":2,\"hinted\":false,\"ms\":3000}\n" ++
        "{\"v\":1,\"ts\":300,\"kind\":\"vimtype\",\"key\":\"code|zig|vim\",\"mode\":\"code\",\"wpm\":40,\"raw\":45,\"acc\":99,\"ms\":9000,\"keys\":80}";
    var one = history.Log.init(testing.allocator);
    defer one.deinit();
    one.loadJsonl(lines);
    try testing.expectEqual(@as(u32, 3), one.count());
    for (0..lines.len + 1) |cut| {
        for ([_]usize{ cut, @min(cut + 7, lines.len) }) |cut2| {
            var log = history.Log.init(testing.allocator);
            defer log.deinit();
            log.loadJsonl(lines[0..cut]);
            log.loadJsonl(lines[cut..cut2]);
            log.loadJsonl(lines[cut2..]);
            try testing.expectEqual(one.count(), log.count());
            try testing.expectEqual(one.totalMs(), log.totalMs());
            try testing.expectEqualDeep(one.perKey().*, log.perKey().*);
        }
    }
}
