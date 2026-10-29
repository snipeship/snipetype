//! Gameplay tests for arcade.zig: flow, hit rules, scoring in play, levels,
//! the word stage, rates, determinism and headless bot runs. Tests above the
//! "Words game" section play the Keys game.

const std = @import("std");
const keys = @import("../platform/keys.zig");
const model = @import("model.zig");
const levels = @import("levels.zig");
const scoring = @import("scoring.zig");
const arcade = @import("arcade.zig");

const Arcade = arcade.Arcade;
const Cap = model.Cap;
const Step = model.Step;
const KeyEvent = keys.KeyEvent;
const testing = std.testing;

const TICKS_PER_LEVEL = arcade.LEVEL_SECONDS * arcade.TICK_HZ;

fn mk(seed: u64, opts: arcade.Options) !Arcade {
    return Arcade.init(testing.allocator, seed, opts);
}

fn ch(c: u8) KeyEvent {
    return levels.eventForStep(.{ .code = levels.unshifted(c), .text = c, .legend = "", .role = .letter });
}

const enter: KeyEvent = .{ .code = keys.code.enter };
const esc: KeyEvent = .{ .code = keys.code.escape };

fn press(a: *Arcade, ev: KeyEvent) void {
    a.handleKey(ev, 0);
}

fn steps(a: *Arcade, n: usize) void {
    for (0..n) |_| a.step();
}

fn countEvents(a: *const Arcade, tag: std.meta.Tag(model.Event)) usize {
    var n: usize = 0;
    for (a.events()) |e| {
        if (e == tag) n += 1;
    }
    return n;
}

fn lastHit(a: *const Arcade) ?@FieldType(model.Event, "hit") {
    var out: ?@FieldType(model.Event, "hit") = null;
    for (a.events()) |e| switch (e) {
        .hit => |h| out = h,
        else => {},
    };
    return out;
}

/// Start a shift and remove whatever spawned, with health that never runs out.
fn playing(a: *Arcade) void {
    a.startGame();
    a.cap_len = 0;
    a.clearEvents();
    a.stats.health = 1e9;
}

fn charSteps(comptime s: []const u8) [s.len]Step {
    var out: [s.len]Step = undefined;
    inline for (s, 0..) |c, i| out[i] = .{ .code = levels.unshifted(c), .text = c, .legend = "", .role = .letter };
    return out;
}

/// Put a cap on screen directly.
fn inject(a: *Arcade, kind: model.TargetKind, st: []const Step, progress: f32) *Cap {
    var c: Cap = .{ .id = 1000 + @as(u32, @intCast(a.cap_len)), .kind = kind, .len = @intCast(st.len), .x = 0.5, .hue = 0.3, .progress = progress, .family = .letters, .item = 999 };
    @memcpy(c.steps[0..st.len], st);
    a.cap_buf[a.cap_len] = c;
    a.cap_len += 1;
    return &a.cap_buf[a.cap_len - 1];
}

fn findCap(a: *const Arcade, id: u32) ?*const Cap {
    for (a.caps()) |*c| {
        if (c.id == id) return c;
    }
    return null;
}

// ---------------------------------------------------------------------------

test "title -> playing -> paused -> title -> results flow" {
    var a = try mk(1, .{ .game = .keys });
    defer a.deinit();
    try testing.expectEqual(model.Phase.title, a.phase);

    press(&a, .{ .code = keys.code.right });
    try testing.expectEqual(model.Pace.staff, a.selectedPace());
    press(&a, .{ .code = keys.code.left });
    press(&a, .{ .code = keys.code.left });
    try testing.expectEqual(model.Pace.junior, a.selectedPace());
    press(&a, .{ .code = keys.code.left });
    try testing.expectEqual(model.Pace.tenx, a.selectedPace());
    press(&a, .{ .code = keys.code.up });
    press(&a, .{ .code = keys.code.up });
    try testing.expectEqual(@as(u8, 4), a.selectedSpeed());
    try testing.expectEqual(@as(u8, 4), a.hud.pace_mult);
    press(&a, .{ .code = keys.code.down });
    press(&a, .{ .code = keys.code.down });
    press(&a, .{ .code = keys.code.down });
    try testing.expectEqual(@as(u8, 16), a.selectedSpeed());
    press(&a, .{ .code = keys.code.up });
    try testing.expectEqual(@as(u8, 1), a.selectedSpeed());
    press(&a, .{ .code = keys.code.right });
    press(&a, .{ .code = keys.code.right });
    try testing.expectEqual(model.Pace.senior, a.selectedPace());

    // Esc and q do nothing on the title.
    press(&a, esc);
    press(&a, ch('q'));
    try testing.expectEqual(model.Phase.title, a.phase);

    a.clearEvents();
    press(&a, enter);
    try testing.expectEqual(model.Phase.playing, a.phase);
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .start));
    try testing.expectEqualStrings("HOME ROW", a.hud.level_name);
    try testing.expectEqual(@as(f32, 0), a.hud.banner_t);

    steps(&a, 60);
    press(&a, esc);
    try testing.expectEqual(model.Phase.paused, a.phase);
    const t = a.tick;
    a.update(10_000);
    a.update(10_200);
    try testing.expectEqual(t, a.tick);
    a.handleKey(esc, 20_000);
    try testing.expectEqual(model.Phase.playing, a.phase);
    a.update(20_100); // 100 ms -> 12 ticks, the pause is not counted
    try testing.expectEqual(t + 12, a.tick);

    press(&a, esc);
    press(&a, ch('q'));
    try testing.expectEqual(model.Phase.title, a.phase);
    try testing.expectEqual(@as(usize, 0), a.caps().len);

    // Game over -> results -> again -> title.
    press(&a, enter);
    a.cap_len = 0;
    a.stats.health = 2;
    a.clearEvents();
    press(&a, ch('z')); // nothing on screen: wrong, -2
    try testing.expectEqual(model.Phase.results, a.phase);
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .game_over));
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .wrong));
    a.clearEvents();
    // Keys typed as the shift ends do not skip the results card.
    press(&a, enter);
    press(&a, ch('q'));
    try testing.expectEqual(model.Phase.results, a.phase);
    steps(&a, arcade.RESULTS_LOCK_TICKS);
    press(&a, enter);
    try testing.expectEqual(model.Phase.playing, a.phase);
    try testing.expectEqual(@as(f32, 100), a.stats.health);
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .start));
    a.stats.health = 1;
    press(&a, ch('z'));
    try testing.expectEqual(model.Phase.results, a.phase);
    steps(&a, arcade.RESULTS_LOCK_TICKS);
    press(&a, ch('q'));
    try testing.expectEqual(model.Phase.title, a.phase);
}

test "update runs fixed steps and clamps long gaps" {
    var a = try mk(2, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.update(1000);
    try testing.expectEqual(@as(u64, 0), a.tick);
    for (1..6) |i| a.update(1000 + @as(i64, @intCast(i)) * 200);
    try testing.expectEqual(@as(u64, 120), a.tick);
    a.update(2004);
    a.update(2009); // 9 ms -> 1 tick (8.33 ms each), remainder carried
    try testing.expectEqual(@as(u64, 121), a.tick);
    a.update(60_000); // clamped to 250 ms
    try testing.expectEqual(@as(u64, 121 + 30), a.tick);
}

test "key events: releases and modifiers are never wrong" {
    var a = try mk(3, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    press(&a, .{ .code = keys.code.left_shift });
    press(&a, .{ .code = keys.code.left_control, .mods = .{ .ctrl = true } });
    press(&a, .{ .code = 'a', .kind = .release });
    press(&a, .{ .code = keys.code.f1 + 4 });
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
    try testing.expectEqual(@as(usize, 0), countEvents(&a, .wrong));
    try testing.expectEqual(@as(usize, 3), countEvents(&a, .key_press));
}

test "first spawn at 0.8 s and spawns are deterministic per seed" {
    var a = try mk(42, .{ .game = .keys });
    defer a.deinit();
    var b = try mk(42, .{ .game = .keys });
    defer b.deinit();
    var c = try mk(43, .{ .game = .keys });
    defer c.deinit();
    for ([_]*Arcade{ &a, &b, &c }) |x| {
        x.startGame();
        x.stats.health = 1e9;
    }
    steps(&a, 95);
    try testing.expectEqual(@as(usize, 0), a.caps().len);
    steps(&a, 2);
    try testing.expectEqual(@as(usize, 1), a.caps().len);

    steps(&a, 3000 - 97);
    steps(&b, 3000);
    steps(&c, 3000);
    try testing.expectEqual(a.caps().len, b.caps().len);
    var differs = a.caps().len != c.caps().len;
    for (a.caps(), b.caps(), 0..) |x, y, i| {
        try testing.expectEqual(x.id, y.id);
        try testing.expectEqual(x.item, y.item);
        try testing.expectEqual(x.family, y.family);
        try testing.expectEqual(x.x, y.x);
        try testing.expectEqual(x.progress, y.progress);
        if (i < c.caps().len and (c.caps()[i].x != x.x or c.caps()[i].item != x.item)) differs = true;
    }
    try testing.expect(differs);
    try testing.expectEqual(a.stats.misses, b.stats.misses);
}

test "level 0 only spawns the home row and never duplicates on screen" {
    var a = try mk(7, .{ .game = .keys });
    defer a.deinit();
    a.startGame();
    a.stats.health = 1e9;
    for (0..TICKS_PER_LEVEL - 1) |_| {
        a.step();
        for (a.caps(), 0..) |x, i| {
            try testing.expectEqual(model.Family.home_row, x.family);
            if (x.state != .falling) continue;
            for (a.caps()[i + 1 ..]) |y| {
                if (y.state == .falling) try testing.expect(y.item != x.item);
            }
        }
    }
}

test "hit picks the lowest of duplicate caps; typed progress wins" {
    var a = try mk(4, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    const s = charSteps("a");
    const high = inject(&a, .key, &s, 0.2).id;
    const low = inject(&a, .key, &s, 0.6).id;
    press(&a, ch('a'));
    try testing.expectEqual(low, lastHit(&a).?.cap_id);
    try testing.expectEqual(model.CapState.hit, findCap(&a, low).?.state);
    try testing.expectEqual(model.CapState.falling, findCap(&a, high).?.state);

    // A partially typed sequence beats a lower single key.
    playing(&a);
    const dd = inject(&a, .sequence, &charSteps("dd"), 0.1);
    dd.typed = 1;
    const dd_id = dd.id;
    _ = inject(&a, .key, &charSteps("d"), 0.8);
    press(&a, ch('d'));
    try testing.expectEqual(dd_id, lastHit(&a).?.cap_id);
}

test "sequence progress, wrong key resets it" {
    var a = try mk(5, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.stats.health = 100;
    const id = inject(&a, .sequence, &charSteps("ciw"), 0.4).id;
    a.stats.combo = 5;
    press(&a, ch('c'));
    press(&a, ch('i'));
    try testing.expectEqual(@as(u8, 2), findCap(&a, id).?.typed);
    try testing.expectEqual(@as(usize, 2), countEvents(&a, .step));
    press(&a, ch('z'));
    try testing.expectEqual(@as(u8, 0), findCap(&a, id).?.typed);
    try testing.expectEqual(@as(u32, 0), a.stats.combo);
    try testing.expectEqual(@as(f32, 98), a.stats.health);
    try testing.expectEqual(@as(u32, 1), a.stats.wrongs);
    press(&a, ch('c'));
    press(&a, ch('i'));
    press(&a, ch('w'));
    const h = lastHit(&a).?;
    try testing.expectEqual(id, h.cap_id);
    // sequence of 3: 30 + 10*3 = 60, not quick, combo 1 -> x1
    try testing.expectEqual(@as(u32, 60), h.points);
    try testing.expectEqual(@as(f32, 100), a.stats.health); // +3 heal, capped
}

test "shifted sequences need the shifted characters" {
    var a = try mk(6, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    const id = inject(&a, .sequence, &charSteps("gUiw"), 0.4).id;
    press(&a, ch('g'));
    press(&a, .{ .code = 'u', .text = 'u' }); // lowercase u is wrong
    try testing.expectEqual(@as(u8, 0), findCap(&a, id).?.typed);
    press(&a, ch('g'));
    press(&a, .{ .code = 'u', .mods = .{ .shift = true }, .text = 'U' });
    press(&a, ch('i'));
    press(&a, ch('w'));
    try testing.expectEqual(id, lastHit(&a).?.cap_id);
}

test "typed prefix reroutes to a sibling sequence" {
    var a = try mk(8, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    const dd = inject(&a, .sequence, &charSteps("dd"), 0.5).id;
    const dw = inject(&a, .sequence, &charSteps("dw"), 0.3).id;
    press(&a, ch('d'));
    try testing.expectEqual(@as(u8, 1), findCap(&a, dd).?.typed);
    press(&a, ch('w'));
    try testing.expectEqual(dw, lastHit(&a).?.cap_id);
    try testing.expectEqual(@as(u8, 0), findCap(&a, dd).?.typed);
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
}

test "typed prefix beats a fresh single key" {
    var a = try mk(8, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    const dd = inject(&a, .sequence, &charSteps("dd"), 0.5).id;
    const dw = inject(&a, .sequence, &charSteps("dw"), 0.3).id;
    const w = inject(&a, .key, &charSteps("w"), 0.1).id;
    press(&a, ch('d'));
    press(&a, ch('w'));
    try testing.expectEqual(dw, lastHit(&a).?.cap_id);
    try testing.expectEqual(@as(u8, 0), findCap(&a, dd).?.typed);
    try testing.expectEqual(model.CapState.falling, findCap(&a, w).?.state);
}

test "keypad keys that type text count, other high codes are neutral" {
    var a = try mk(8, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    const one = inject(&a, .key, &charSteps("1"), 0.5).id;
    press(&a, .{ .code = 57400, .text = '1' }); // kitty KP_1
    try testing.expectEqual(one, lastHit(&a).?.cap_id);
    press(&a, .{ .code = keys.code.f(5) });
    press(&a, .{ .code = keys.code.left_shift, .mods = .{ .shift = true } });
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
}

test "ex command ends with Enter and scores 60" {
    var a = try mk(9, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    const ex = levels.pool(.ex)[2]; // :wq
    const c = inject(&a, .sequence, ex.steps, 0.5);
    c.family = .ex;
    for (ex.steps) |s| press(&a, levels.eventForStep(s));
    try testing.expectEqual(@as(u32, 60), lastHit(&a).?.points);
}

test "in-game scoring: senior x2 combo 70 chord3 = 1440, quick and rarity" {
    var a = try mk(10, .{ .game = .keys, .speed = 2 });
    defer a.deinit();
    playing(&a);
    a.stats.combo = 70;
    const item = levels.pool(.three)[1]; // Ctrl+Shift+F
    _ = inject(&a, .chord3, item.steps, 0.5);
    press(&a, .{ .code = 'f', .mods = .{ .ctrl = true, .shift = true } });
    const h = lastHit(&a).?;
    try testing.expectEqual(@as(u32, 1440), h.points);
    try testing.expectEqual(@as(u2, 3), h.effect.tier());
    try testing.expectEqual(@as(u64, 1440), a.stats.score);

    var b = try mk(11, .{ .game = .keys });
    defer b.deinit();
    playing(&b);
    _ = inject(&b, .key, &charSteps("j"), 0.1);
    press(&b, ch('j'));
    try testing.expect(lastHit(&b).?.quick);
    try testing.expectEqual(@as(u32, 15), lastHit(&b).?.points);
    const r = inject(&b, .key, &charSteps("k"), 0.5);
    r.rarity = .rare;
    press(&b, ch('k'));
    try testing.expectEqual(@as(u32, 20), lastHit(&b).?.points);
    try testing.expectEqual(@as(u2, 2), lastHit(&b).?.effect.tier());
}

test "combo multiplier and milestones in play" {
    var a = try mk(12, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.stats.combo = 9;
    _ = inject(&a, .key, &charSteps("a"), 0.5);
    press(&a, ch('a'));
    try testing.expectEqual(@as(u32, 10), a.stats.combo);
    try testing.expectEqual(@as(u8, 2), a.stats.mult);
    try testing.expectEqual(@as(u32, 20), lastHit(&a).?.points);
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .milestone));
    try testing.expectEqualStrings("the linter is impressed", a.hud.callout);
    try testing.expectEqual(@as(f32, 0), a.hud.callout_t);
}

test "effects never repeat back to back" {
    var a = try mk(13, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    var last: ?model.Effect = null;
    for (0..60) |_| {
        _ = inject(&a, .key, &charSteps("a"), 0.5);
        press(&a, ch('a'));
        const e = lastHit(&a).?.effect;
        if (last) |l| try testing.expect(e != l);
        last = e;
        a.cap_len = 0;
        a.clearEvents();
    }
}

test "miss damage by pace and game over" {
    var a = try mk(14, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.stats.health = 100;
    a.stats.combo = 12;
    const c = inject(&a, .key, &charSteps("a"), 0.9999);
    c.speed = 1;
    a.step();
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .miss));
    try testing.expectEqual(@as(f32, 92), a.stats.health);
    try testing.expectEqual(@as(u32, 0), a.stats.combo);
    try testing.expectEqual(@as(u32, 1), a.stats.misses);
    // The missed cap lingers ~1 s for its animation, then disappears.
    try testing.expectEqual(model.CapState.missed, a.caps()[0].state);
    for (0..130) |_| {
        a.step();
        a.cap_len = @min(a.cap_len, 1); // ignore new spawns
    }
    try testing.expectEqual(@as(usize, 0), a.caps().len);

    var t = try mk(15, .{ .game = .keys, .pace = .tenx });
    defer t.deinit();
    playing(&t);
    t.stats.health = 10;
    const d = inject(&t, .key, &charSteps("a"), 0.9999);
    d.speed = 1;
    t.step();
    try testing.expectEqual(model.Phase.results, t.phase);
    try testing.expectEqual(@as(f32, 0), t.stats.health);
    try testing.expectEqual(@as(usize, 1), countEvents(&t, .game_over));
}

test "level advances every 30 s with banner and level_up" {
    var a = try mk(16, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    steps(&a, TICKS_PER_LEVEL - 1);
    try testing.expectEqual(@as(u8, 0), a.hud.level);
    try testing.expectEqual(@as(u16, 9 * 60 + 59), a.hud.clock_minutes);
    try testing.expectEqual(@as(usize, 0), countEvents(&a, .level_up));
    a.clearEvents();
    a.step();
    try testing.expectEqual(@as(u8, 1), a.hud.level);
    try testing.expectEqual(@as(u16, 10 * 60), a.hud.clock_minutes);
    try testing.expectEqualStrings("EVERY LETTER", a.hud.level_name);
    try testing.expectEqualStrings("10:00  EVERY LETTER · the rest of a to z", a.hud.banner);
    try testing.expect(a.hud.banner_t < 0.01);
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .level_up));
    // Overtime after 10 levels, and it keeps speeding up.
    steps(&a, TICKS_PER_LEVEL * 9);
    try testing.expectEqual(@as(u8, 10), a.hud.level);
    try testing.expectEqualStrings("OVERTIME", a.hud.level_name);
    const f0 = a.fallTime();
    steps(&a, TICKS_PER_LEVEL);
    try testing.expect(a.fallTime() < f0);
    try testing.expectEqual(@as(u16, 20 * 60), a.hud.clock_minutes);
}

test "shift hard-stops after 60 minutes" {
    var a = try mk(17, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.tick = arcade.SHIFT_SECONDS * arcade.TICK_HZ - 2;
    a.level = 119;
    a.step();
    try testing.expectEqual(model.Phase.playing, a.phase);
    a.step();
    try testing.expectEqual(model.Phase.results, a.phase);
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .game_over));
}

test "no-chords mode spawns macros instead of three-key chords" {
    var a = try mk(18, .{ .game = .keys, .chords = false });
    defer a.deinit();
    playing(&a);
    a.tick = 8 * TICKS_PER_LEVEL - 1;
    a.level = 7;
    a.step();
    try testing.expectEqualStrings("MACROS", a.hud.level_name);
    var macros: usize = 0;
    for (0..TICKS_PER_LEVEL - 10) |_| {
        a.step();
        for (a.caps()) |c| {
            try testing.expect(c.family != .three);
            if (c.family == .macros and c.age == arcade.DT) macros += 1;
        }
    }
    try testing.expect(macros >= 5);
}

/// Index of the next cap a perfect player would press.
fn botTarget(a: *const Arcade, min_progress: f32) ?usize {
    var active_word: ?usize = null;
    var best: ?usize = null;
    for (a.caps(), 0..) |*c, i| {
        if (c.state != .falling) continue;
        if (c.kind == .word) {
            if (active_word == null or c.word < a.caps()[active_word.?].word) active_word = i;
            continue;
        }
        if (c.progress < min_progress and c.typed == 0) continue;
        if (best == null) {
            best = i;
            continue;
        }
        const b = &a.caps()[best.?];
        if (c.typed > b.typed or (c.typed == b.typed and c.progress > b.progress)) best = i;
    }
    if (best) |b| {
        if (active_word == null or a.caps()[b].typed > 0 or a.caps()[b].progress > a.caps()[active_word.?].progress) return b;
    }
    return active_word;
}

fn botPress(a: *Arcade, now: i64, min_progress: f32) bool {
    const i = botTarget(a, min_progress) orelse return false;
    const c = &a.caps()[i];
    a.handleKey(levels.eventForStep(c.steps[c.typed]), now);
    return true;
}

test "word stage: phrase flow, progress and phrase_done" {
    var a = try mk(19, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.tick = 9 * TICKS_PER_LEVEL - 1;
    a.level = 8;
    a.step();
    try testing.expectEqualStrings("DEEP WORK", a.hud.level_name);
    try testing.expect(a.hud.word_stage);
    const p0 = a.hud.phrase.?;
    try testing.expect(p0.word_count >= 2);
    try testing.expectEqual(@as(u8, 0), p0.word_index);
    // The first word is on screen right away; no key caps spawn now.
    var words: usize = 0;
    for (a.caps()) |c| {
        try testing.expectEqual(model.TargetKind.word, c.kind);
        words += 1;
    }
    try testing.expectEqual(@as(usize, 1), words);
    const first = a.caps()[0];
    const span = p0.wordSpan(0).?;
    try testing.expectEqual(span.start, p0.word_start);
    try testing.expectEqual(span.end, p0.word_end);

    // Type the first letter: done_upto moves, combo and score grow.
    press(&a, levels.eventForStep(first.steps[0]));
    try testing.expect(a.hud.phrase.?.done_upto > span.start);
    try testing.expectEqual(@as(u32, 1), a.stats.combo);
    try testing.expectEqual(@as(u64, 10), a.stats.score);
    try testing.expect(a.stats.wpm > 0);

    // Never more than 2 words on screen; play the whole line perfectly.
    var done = false;
    var now: i64 = 0;
    var guard: usize = 0;
    while (!done and guard < 20_000) : (guard += 1) {
        a.step();
        var live: usize = 0;
        for (a.caps()) |c| live += @intFromBool(c.kind == .word and c.state == .falling);
        try testing.expect(live <= 2);
        if (guard % 6 == 0) _ = botPress(&a, now, 0);
        now += 8;
        if (countEvents(&a, .phrase_done) > 0) done = true;
    }
    try testing.expect(done);
    const p = a.hud.phrase.?;
    try testing.expect(p.complete);
    try testing.expectEqual(@as(u64, 0), p.missed);
    try testing.expectEqual(@as(u32, 0), a.stats.misses);
    // Hold, then the next line begins.
    a.clearEvents();
    steps(&a, @intFromFloat(arcade.PHRASE_HOLD_SECONDS * 120 + 2));
    try testing.expect(!a.hud.phrase.?.complete);
    try testing.expectEqual(@as(u8, 0), a.hud.phrase.?.word_index);
}

test "word stage: a missed word is struck, stage ends into overtime" {
    var a = try mk(20, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.tick = 9 * TICKS_PER_LEVEL - 1;
    a.level = 8;
    a.step();
    // Let the first word land.
    var guard: usize = 0;
    while (a.stats.misses == 0 and guard < 5000) : (guard += 1) a.step();
    try testing.expect(a.hud.phrase.?.isMissed(0));
    // After 30 s the stage hands over to overtime and keys come back.
    steps(&a, TICKS_PER_LEVEL + 10 * arcade.TICK_HZ);
    try testing.expectEqual(@as(u8, 10), a.hud.level);
    try testing.expect(!a.hud.word_stage);
    try testing.expect(a.hud.phrase == null);
    var key_caps: usize = 0;
    for (a.caps()) |c| key_caps += @intFromBool(c.kind != .word);
    try testing.expect(key_caps > 0);
}

test "kpm uses a sliding 10 s window" {
    var a = try mk(21, .{ .game = .keys });
    defer a.deinit();
    playing(&a);
    a.next_spawn = 1e9; // only injected caps
    for (0..15) |_| {
        steps(&a, 120);
        _ = inject(&a, .key, &charSteps("a"), 0.5);
        press(&a, ch('a'));
    }
    // One key per second: 10 in the window -> 60/min.
    try testing.expectApproxEqAbs(@as(f32, 60), a.stats.kpm, 0.01);
    try testing.expect(a.stats.peak_kpm >= 60);
    steps(&a, 11 * 120);
    try testing.expectEqual(@as(f32, 0), a.stats.kpm);
    try testing.expect(a.stats.peak_kpm >= 60);
    // Chords count their modifiers.
    _ = inject(&a, .chord2, levels.pool(.ctrl)[0].steps, 0.5);
    press(&a, .{ .code = 's', .mods = .{ .ctrl = true } });
    a.step();
    try testing.expectApproxEqAbs(@as(f32, 12), a.stats.kpm, 0.01);
}

test "title attract demo spawns and auto-hits caps" {
    var a = try mk(22, .{ .game = .keys });
    defer a.deinit();
    steps(&a, 10 * 120);
    try testing.expectEqual(model.Phase.title, a.phase);
    try testing.expect(countEvents(&a, .hit) >= 3);
    try testing.expect(countEvents(&a, .miss) == 0);
    try testing.expect(a.caps().len > 0);
    try testing.expectEqual(@as(u64, 0), a.stats.score);
}

test "overlap avoidance places caps apart" {
    var a = try mk(23, .{ .game = .keys, .play_cols = 120 });
    defer a.deinit();
    playing(&a);
    var overlaps: usize = 0;
    var pairs: usize = 0;
    for (0..TICKS_PER_LEVEL * 2) |_| {
        a.step();
        const cs = a.caps();
        if (cs.len == 0) continue;
        const n = cs[cs.len - 1];
        if (n.age != arcade.DT) continue;
        for (cs[0 .. cs.len - 1]) |o| {
            if (o.state != .falling or o.progress > 0.2) continue;
            pairs += 1;
            const dx = @abs(n.x - o.x) * 120;
            const need = @as(f32, @floatFromInt(arcade.capWidthCells(&n) + arcade.capWidthCells(&o))) / 2;
            if (dx < need) overlaps += 1;
        }
    }
    try testing.expect(pairs > 0);
    try testing.expectEqual(@as(usize, 0), overlaps);
}

test "perfect bot plays 5 minutes" {
    var a = try mk(0xC0FFEE, .{ .game = .keys });
    defer a.deinit();
    a.startGame();
    var now: i64 = 0;
    var frame: usize = 0;
    // 60 fps frames, at most one key every other frame (30 keys/s).
    while (now < 300_000) : (frame += 1) {
        now += 16;
        a.update(now);
        if (frame % 2 == 0) _ = botPress(&a, now, 0.1);
        a.clearEvents();
        if (a.phase != .playing) break;
    }
    try testing.expectEqual(model.Phase.playing, a.phase);
    try testing.expect(a.hud.level >= 9);
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
    try testing.expect(a.stats.misses <= 3);
    try testing.expect(a.stats.best_combo >= 200);
    try testing.expect(a.stats.score > 200_000);
    try testing.expect(a.stats.peak_kpm > 100);
    try testing.expectEqualStrings(":wq wizard", a.rank().name);
    try testing.expect(a.avgKpm() > 120);
    try testing.expect(std.mem.startsWith(u8, a.heardLine(), "audible from"));
}

test "doing nothing ends the shift within a minute" {
    var a = try mk(99, .{ .game = .keys });
    defer a.deinit();
    a.startGame();
    var now: i64 = 0;
    while (a.phase == .playing and now < 120_000) {
        now += 16;
        a.update(now);
        a.clearEvents();
    }
    try testing.expectEqual(model.Phase.results, a.phase);
    try testing.expect(now < 60_000);
    try testing.expect(now > 10_000);
    try testing.expectEqualStrings("hunt & peck", a.rank().name);
}

/// Plays with perfect accuracy at a fixed key rate (one press every `every`
/// 16 ms frames, reacting once a cap has fallen 15%) for up to 10 minutes.
fn humanBot(pace: model.Pace, every: usize) !Arcade {
    var a = try mk(0xBEEF, .{ .game = .keys, .pace = pace });
    a.startGame();
    var now: i64 = 0;
    var frame: usize = 0;
    while (now < 600_000 and a.phase == .playing) : (frame += 1) {
        now += 16;
        a.update(now);
        if (frame % every == 0) _ = botPress(&a, now, 0.15);
        a.clearEvents();
    }
    return a;
}

test "difficulty ramps: slow typists fall behind, fast ones reach overtime" {
    // 150 keys/min on senior: survives the morning, drowns in the evening.
    var slow = try humanBot(.senior, 24);
    defer slow.deinit();
    try testing.expectEqual(model.Phase.results, slow.phase);
    try testing.expect(slow.hud.level >= 6 and slow.hud.level <= 14);
    // 400 keys/min on senior: deep into overtime without trouble.
    var fast = try humanBot(.senior, 9);
    defer fast.deinit();
    try testing.expect(fast.hud.level >= 15);
    try testing.expect(fast.stats.misses <= 5);
    // 10X punishes 150 keys/min early.
    var tenx = try humanBot(.tenx, 24);
    defer tenx.deinit();
    try testing.expectEqual(model.Phase.results, tenx.phase);
    try testing.expect(tenx.hud.level < 8);
}

// ---------------------------------------------------------------------------
// Words game

const words_mod = @import("words.zig");

/// Start a Words shift without touching the first line.
fn wordsPlaying(a: *Arcade) void {
    a.startGame();
    a.clearEvents();
    a.stats.health = 1e9;
}

/// Freeze the line machinery so injected word caps are the only targets.
fn freezeLines(a: *Arcade) void {
    a.cap_len = 0;
    a.word.active = false;
    a.word.holding = true;
    a.word.hold_until = std.math.maxInt(u64);
    a.hud.phrase = null;
    a.clearEvents();
}

fn injectWord(a: *Arcade, text: []const u8, code_word: bool, progress: f32) *Cap {
    var c: Cap = .{ .id = 2000 + @as(u32, @intCast(a.cap_len)), .kind = .word, .len = 0, .x = 0.5, .hue = 0.4, .progress = progress, .family = .words };
    if (code_word) {
        c.len = levels.identSteps(text, &c.steps);
        c.exact = words_mod.hasUpper(text);
    } else {
        c.len = levels.wordSteps(text, &c.steps);
    }
    a.cap_buf[a.cap_len] = c;
    a.cap_len += 1;
    return &a.cap_buf[a.cap_len - 1];
}

/// Jump to the start of Words level `lvl` (fires its level-up).
fn enterWordsLevel(a: *Arcade, lvl: u8) void {
    a.cap_len = 0;
    a.word.holding = true;
    a.word.hold_until = 0;
    a.tick = @as(u64, lvl) * TICKS_PER_LEVEL - 1;
    a.level = lvl - 1;
    a.step();
}

/// Force the next line of the current level right away.
fn nextLine(a: *Arcade) void {
    a.cap_len = 0;
    a.word.holding = true;
    a.word.hold_until = a.tick;
    a.step();
}

test "words is the default game; Tab and g toggle it on the title" {
    var a = try mk(30, .{});
    defer a.deinit();
    try testing.expectEqual(model.Game.words, a.selectedGame());
    press(&a, .{ .code = keys.code.tab });
    try testing.expectEqual(model.Game.keys, a.selectedGame());
    press(&a, ch('g'));
    try testing.expectEqual(model.Game.words, a.selectedGame());
    // releases, repeats and G do not toggle; arrows still pick pace and speed
    press(&a, .{ .code = keys.code.tab, .kind = .release });
    press(&a, .{ .code = keys.code.tab, .kind = .repeat });
    press(&a, ch('G'));
    try testing.expectEqual(model.Game.words, a.selectedGame());
    press(&a, .{ .code = keys.code.right });
    press(&a, .{ .code = keys.code.up });
    try testing.expectEqual(model.Pace.staff, a.selectedPace());
    try testing.expectEqual(@as(u8, 2), a.selectedSpeed());
    try testing.expectEqual(model.Game.words, a.selectedGame());

    press(&a, enter);
    try testing.expectEqual(model.Phase.playing, a.phase);
    try testing.expectEqualStrings("WARM-UP", a.hud.level_name);
    try testing.expectEqualStrings("09:00  WARM-UP · short words, no spaces", a.hud.banner);
    try testing.expect(a.hud.word_stage);
    const p = a.hud.phrase.?;
    try testing.expect(p.word_count >= 1 and p.word_count <= 2);
    try testing.expectEqualStrings("", p.attribution);
    // The first word plate drops on the first tick, nothing else.
    try testing.expectEqual(@as(usize, 0), a.caps().len);
    a.step();
    try testing.expectEqual(@as(usize, 1), a.caps().len);
    try testing.expectEqual(model.TargetKind.word, a.caps()[0].kind);

    // Options pick the game for code (the CLI's --game).
    var k = try mk(31, .{ .game = .keys });
    defer k.deinit();
    try testing.expectEqual(model.Game.keys, k.selectedGame());
    k.startGame();
    try testing.expectEqualStrings("HOME ROW", k.hud.level_name);
    try testing.expect(!k.hud.word_stage);
}

test "words game: stage names, words per line and content by level" {
    var a = try mk(32, .{});
    defer a.deinit();
    wordsPlaying(&a);
    const names = [_][]const u8{ "WARM-UP", "INBOX", "STAND-UP", "LUNCH RUSH", "CODE REVIEW", "DEEP WORK", "PAIRING", "DEADLINE", "LAST PUSH", "WRAP-UP", "OVERTIME", "OVERTIME" };
    var prev_text: []const u8 = "";
    for (names, 0..) |name, li| {
        const lvl: u8 = @intCast(li);
        if (lvl > 0) {
            a.clearEvents();
            enterWordsLevel(&a, lvl);
            try testing.expectEqual(@as(usize, 1), countEvents(&a, .level_up));
        }
        prev_text = a.hud.phrase.?.text;
        try testing.expectEqualStrings(name, a.hud.level_name);
        try testing.expect(a.hud.word_stage);
        const st = levels.wordStage(lvl);
        for (0..30) |_| {
            nextLine(&a);
            const p = a.hud.phrase.?;
            const n = p.word_count;
            try testing.expect(n >= 1 and n <= st.max_words);
            if (st.source != .any and st.source != .deadline) try testing.expect(n >= st.min_words);
            // a new line never reuses the buffer the previous line is in
            try testing.expect(p.text.ptr != prev_text.ptr or p.text.len == 0);
            prev_text = p.text;
            var it = std.mem.tokenizeScalar(u8, p.text, ' ');
            while (it.next()) |w| switch (st.source) {
                .short_words => try testing.expect(w.len >= 3 and w.len <= 5),
                .common_words => try testing.expect(w.len <= 6),
                .code => {
                    try testing.expect(a.word.code_line);
                    try testing.expect(containsStr(&words_mod.code, w));
                },
                else => {},
            };
            if (st.source == .quotes) try testing.expect(p.attribution.len > 0);
            if (st.source == .oneliners) try testing.expect(containsStr(&words_mod.oneliners, p.text));
        }
    }
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

test "words game: plain words ignore case, identifiers are exact" {
    var a = try mk(33, .{});
    defer a.deinit();
    wordsPlaying(&a);
    freezeLines(&a);

    // Plain word: either case counts (Caps Lock, stray Shift).
    const w = injectWord(&a, "hello", false, 0.5).id;
    press(&a, .{ .code = 'h', .text = 'H' }); // Caps Lock: code h, text H
    press(&a, .{ .code = 'e', .mods = .{ .shift = true }, .text = 'E' });
    press(&a, ch('l'));
    press(&a, ch('l'));
    press(&a, ch('o'));
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
    const h = lastHit(&a).?;
    try testing.expectEqual(w, h.cap_id);
    try testing.expectEqual(model.TargetKind.word, h.kind);

    // Identifier with uppercase and '.': exact.
    a.cap_len = 0;
    a.clearEvents();
    const id = injectWord(&a, "Math.max", true, 0.5).id;
    try testing.expect(findCap(&a, id).?.exact);
    try testing.expectEqualStrings("M", findCap(&a, id).?.steps[0].legend);
    try testing.expectEqualStrings("a", findCap(&a, id).?.steps[1].legend);
    press(&a, ch('m')); // needs Shift
    try testing.expectEqual(@as(u32, 1), a.stats.wrongs);
    try testing.expectEqual(@as(u8, 0), findCap(&a, id).?.typed);
    for ("Math.max") |c| press(&a, ch(c));
    try testing.expectEqual(id, lastHit(&a).?.cap_id);
    try testing.expectEqual(@as(u32, 1), a.stats.wrongs);

    // snake_case: '_' is Shift+'-', a bare '-' is wrong.
    a.cap_len = 0;
    a.clearEvents();
    const sc = injectWord(&a, "max_len", true, 0.5).id;
    try testing.expect(!findCap(&a, sc).?.exact);
    for ("max") |c| press(&a, ch(c));
    press(&a, .{ .code = '-', .text = '-' });
    try testing.expectEqual(@as(u32, 2), a.stats.wrongs);
    try testing.expectEqual(@as(u8, 3), findCap(&a, sc).?.typed);
    press(&a, .{ .code = '-', .mods = .{ .shift = true } }); // no text: US fallback
    for ("len") |c| press(&a, .{ .code = c, .mods = .{ .shift = true }, .text = std.ascii.toUpper(c) }); // lowercase-only identifier: case is free
    const hit = lastHit(&a).?;
    try testing.expectEqual(sc, hit.cap_id);
    // word points: 15 per character (7), x1
    try testing.expectEqual(@as(u32, 105), hit.points);
}

test "words game: Space between words is ignored, other strays are wrong" {
    var a = try mk(34, .{});
    defer a.deinit();
    wordsPlaying(&a);
    freezeLines(&a);
    _ = injectWord(&a, "cat", false, 0.5);
    const ks = a.stats.keystrokes;
    press(&a, .{ .code = keys.code.space, .text = ' ' });
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
    try testing.expectEqual(ks, a.stats.keystrokes);
    try testing.expectEqual(@as(usize, 0), countEvents(&a, .wrong));
    press(&a, ch('x'));
    try testing.expectEqual(@as(u32, 1), a.stats.wrongs);
    // Keys game: Space with nothing to take it is still a wrong key.
    var k = try mk(35, .{ .game = .keys });
    defer k.deinit();
    playing(&k);
    press(&k, .{ .code = keys.code.space, .text = ' ' });
    try testing.expectEqual(@as(u32, 1), k.stats.wrongs);
}

test "words game: bonus caps share keys with words and cost nothing when missed" {
    var a = try mk(36, .{});
    defer a.deinit();
    wordsPlaying(&a);
    freezeLines(&a);
    const dog = injectWord(&a, "dog", false, 0.3).id;
    const dd_cap = inject(&a, .sequence, levels.pool(.operators)[1].steps, 0.6); // "dd"
    dd_cap.family = .operators;
    const dd = dd_cap.id;
    // Tie at zero typed: the word takes the 'd' even though "dd" is lower.
    press(&a, ch('d'));
    try testing.expectEqual(@as(u8, 1), findCap(&a, dog).?.typed);
    try testing.expectEqual(@as(u8, 0), findCap(&a, dd).?.typed);
    // The word wants 'o': the next 'd' starts the bonus, then finishes it.
    press(&a, ch('d'));
    try testing.expectEqual(@as(u8, 1), findCap(&a, dd).?.typed);
    press(&a, ch('d'));
    const h = lastHit(&a).?;
    try testing.expectEqual(dd, h.cap_id);
    try testing.expectEqual(@as(u2, 2), h.effect.tier());
    try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
    press(&a, ch('o'));
    press(&a, ch('g'));
    try testing.expectEqual(dog, lastHit(&a).?.cap_id);

    // A bonus cap that lands only dissolves.
    a.stats.health = 50;
    a.stats.combo = 12;
    a.clearEvents();
    const ex = inject(&a, .sequence, levels.pool(.ex)[0].steps, 0.9999);
    ex.family = .ex;
    ex.speed = 1;
    a.step();
    try testing.expectEqual(@as(usize, 1), countEvents(&a, .miss));
    try testing.expectEqual(@as(f32, 50), a.stats.health);
    try testing.expectEqual(@as(u32, 12), a.stats.combo);
    try testing.expectEqual(@as(u32, 0), a.stats.misses);
    // A word that lands hurts as usual.
    const lw = injectWord(&a, "late", false, 0.9999);
    lw.speed = 1;
    a.step();
    try testing.expectEqual(@as(f32, 42), a.stats.health);
    try testing.expectEqual(@as(u32, 0), a.stats.combo);
    try testing.expectEqual(@as(u32, 1), a.stats.misses);
}

/// WPM-limited perfect bot for the Words game: one key every `60000 /
/// (wpm * 5)` ms, reacting to bonus caps once they have fallen 15%.
fn wpmBot(seed: u64, opts: arcade.Options, wpm: f32, max_ms: i64) !Arcade {
    var a = try mk(seed, opts);
    a.startGame();
    var now: i64 = 0;
    const interval: f32 = 60_000.0 / (wpm * 5.0);
    var next_key: f32 = 0;
    while (now < max_ms and a.phase == .playing) {
        now += 16;
        a.update(now);
        if (wpm > 0 and @as(f32, @floatFromInt(now)) >= next_key) {
            if (botPress(&a, now, 0.15)) next_key = @as(f32, @floatFromInt(now)) + interval;
        }
        a.clearEvents();
    }
    return a;
}

test "words game: bonus caps arrive from 11:00 with a line's first word" {
    var a = try mk(37, .{ .play_cols = 120 });
    defer a.deinit();
    wordsPlaying(&a);
    var now: i64 = 0;
    var word_spawns: usize = 0;
    var bonus_spawns: usize = 0;
    var rare_words: usize = 0;
    var seen: u32 = 0;
    var frame: usize = 0;
    while (a.hud.level < 9) : (frame += 1) {
        now += 16;
        a.update(now);
        if (frame % 3 == 0) _ = botPress(&a, now, 0.15);
        var top = seen;
        for (a.caps()) |c| {
            if (c.id <= seen) continue;
            top = @max(top, c.id);
            if (c.kind == .word) {
                word_spawns += 1;
                if (c.rarity != .common) rare_words += 1;
                continue;
            }
            bonus_spawns += 1;
            try testing.expect(a.hud.level >= arcade.BONUS_LEVEL);
            try testing.expect(c.family == .operators or c.family == .ex or c.family == .macros);
            // spawned right after word 0 of the line, never mid-line
            var first: ?u32 = null;
            for (a.caps()) |o| {
                if (o.kind == .word and o.word == 0 and o.id == c.id - 1) first = o.id;
            }
            try testing.expect(first != null);
        }
        seen = top;
        a.clearEvents();
        try testing.expectEqual(model.Phase.playing, a.phase);
    }
    const share = @as(f32, @floatFromInt(bonus_spawns)) / @as(f32, @floatFromInt(bonus_spawns + word_spawns));
    try testing.expect(share > 0.06 and share < 0.16);
    try testing.expect(rare_words > 0);
}

test "words game: line completion is tier 3 then phrase_done; long words tier 2" {
    var a = try mk(38, .{});
    defer a.deinit();
    wordsPlaying(&a);
    var now: i64 = 0;
    var seen_line = false;
    var guard: usize = 0;
    while (!seen_line and guard < 20_000) : (guard += 1) {
        now += 16;
        a.update(now);
        if (guard % 4 == 0) _ = botPress(&a, now, 0);
        const evs = a.events();
        for (evs, 0..) |e, i| switch (e) {
            .phrase_done => |pd| {
                // the hit that completed the line comes right before it
                var j = i;
                while (j > 0) {
                    j -= 1;
                    if (evs[j] == .hit) break;
                }
                try testing.expect(evs[j] == .hit);
                try testing.expectEqual(@as(u2, 3), evs[j].hit.effect.tier());
                try testing.expectEqual(model.TargetKind.word, evs[j].hit.kind);
                try testing.expect(pd.points >= 100);
                seen_line = true;
            },
            .hit => |h| {
                if (i + 1 < evs.len and evs[i + 1] == .phrase_done) continue;
                // short common words mid-line: tier 1 unless rare/combo-25
                if (h.rarity == .common and h.combo % 25 != 0) try testing.expectEqual(@as(u2, 1), h.effect.tier());
            },
            else => {},
        };
        a.clearEvents();
    }
    try testing.expect(seen_line);
    try testing.expect(a.hud.phrase.?.complete);

    // A long word mid-line goes out with a tier-2 effect.
    freezeLines(&a);
    a.stats.combo = 3;
    _ = injectWord(&a, "adventure", false, 0.5);
    for ("adventure") |c| press(&a, ch(c));
    try testing.expectEqual(@as(u2, 2), lastHit(&a).?.effect.tier());
    // 15 x 9 letters, combo 12 -> x2
    try testing.expectEqual(@as(u32, 270), lastHit(&a).?.points);
}

test "words game: WPM over the 10 s window, peak_wpm kept" {
    var a = try mk(39, .{});
    defer a.deinit();
    wordsPlaying(&a);
    freezeLines(&a);
    // 5 characters per second for 15 s = 60 WPM.
    var typed: usize = 0;
    for (0..15 * arcade.TICK_HZ) |t| {
        if (a.caps().len == 0 or a.caps()[a.cap_len - 1].state != .falling) _ = injectWord(&a, "abcdefghijklmnopqrst", false, 0.1);
        if (t % 24 == 0) {
            const c = &a.cap_buf[a.cap_len - 1];
            press(&a, levels.eventForStep(c.steps[c.typed]));
            typed += 1;
        }
        a.step();
        for (a.cap_buf[0..a.cap_len]) |*c| {
            if (c.state == .falling) c.progress = 0.1;
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 60), a.stats.wpm, 1.5);
    try testing.expect(a.stats.peak_wpm >= 59);
    try testing.expect(a.stats.kpm > 290);
    steps(&a, 11 * arcade.TICK_HZ);
    try testing.expectEqual(@as(f32, 0), a.stats.wpm);
    try testing.expect(a.stats.peak_wpm >= 59);
}

test "words game: ranks by peak WPM, heard line by average keys" {
    var a = try mk(40, .{});
    defer a.deinit();
    wordsPlaying(&a);
    a.stats.hits = 100;
    a.stats.peak_kpm = 600; // keys/min does not rank the Words game
    a.stats.peak_wpm = 20;
    a.level = 9;
    try testing.expectEqualStrings("hunt & peck", a.rank().name);
    a.stats.peak_wpm = 95;
    try testing.expectEqualStrings("keyboard poet", a.rank().name);
    a.stats.peak_wpm = 55;
    try testing.expectEqualStrings("prose engine", a.rank().name);
    a.tick = 60 * arcade.TICK_HZ;
    a.key_units = 200; // 200 keys/min: a quiet day in the Words game
    try testing.expectEqualStrings("audible from the standup room", a.heardLine());
    a.opts.game = .keys;
    try testing.expectEqualStrings("audible from the data center", a.heardLine());
    try testing.expectEqualStrings(":wq wizard", a.rank().name);
}

test "words game: accuracy counts keystrokes, not whole words" {
    var a = try mk(42, .{});
    defer a.deinit();
    wordsPlaying(&a);
    try testing.expect(a.stats.per_key);
    // 4 words of 5 letters with one typo: 20 good keys out of 21 typed.
    a.stats.hits = 4;
    a.stats.keystrokes = 21;
    a.stats.wrongs = 1;
    try testing.expectApproxEqAbs(@as(f32, 20.0 / 21.0), a.stats.accuracy(), 1e-6);
    a.stats.misses = 1;
    try testing.expectApproxEqAbs(@as(f32, 20.0 / 22.0), a.stats.accuracy(), 1e-6);

    var k = try mk(42, .{ .game = .keys });
    defer k.deinit();
    playing(&k);
    try testing.expect(!k.stats.per_key);
}

test "words game: title attract drops word plates, keys after the toggle" {
    var a = try mk(41, .{});
    defer a.deinit();
    var word_caps: usize = 0;
    for (0..10 * arcade.TICK_HZ) |_| {
        a.step();
        for (a.caps()) |c| {
            if (c.age == arcade.DT and c.kind == .word) word_caps += 1;
        }
    }
    try testing.expect(word_caps >= 4);
    try testing.expect(countEvents(&a, .hit) >= 3);
    try testing.expectEqual(@as(u64, 0), a.stats.score);
    try testing.expect(a.hud.phrase == null);

    press(&a, .{ .code = keys.code.tab });
    a.clearEvents();
    var new_words: usize = 0;
    var new_keys: usize = 0;
    for (0..10 * arcade.TICK_HZ) |_| {
        a.step();
        for (a.caps()) |c| {
            if (c.age != arcade.DT) continue;
            if (c.kind == .word) new_words += 1 else new_keys += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), new_words);
    try testing.expect(new_keys >= 4);
}

test "words game: level clock and banners through overtime" {
    var a = try mk(42, .{});
    defer a.deinit();
    wordsPlaying(&a);
    steps(&a, TICKS_PER_LEVEL);
    try testing.expectEqualStrings("INBOX", a.hud.level_name);
    try testing.expectEqualStrings("10:00  INBOX · everyday words", a.hud.banner);
    try testing.expectEqual(@as(u16, 10 * 60), a.hud.clock_minutes);
    steps(&a, TICKS_PER_LEVEL * 9);
    try testing.expectEqualStrings("OVERTIME", a.hud.level_name);
    try testing.expectEqualStrings("OVERTIME · anything, faster", a.hud.banner);
    try testing.expect(a.hud.word_stage);
    try testing.expect(a.hud.phrase != null);
    // nothing but words (and bonus caps) ever fell
    for (a.caps()) |c| try testing.expect(c.kind == .word or c.kind == .sequence);
    const f0 = a.fallTime();
    steps(&a, TICKS_PER_LEVEL);
    try testing.expect(a.fallTime() < f0);
}

test "words game bots: 60 WPM clocks out mid-afternoon on senior, idle dies fast" {
    var sum: u32 = 0;
    for ([_]u64{ 1234, 1311, 1388 }) |seed| {
        var a = try wpmBot(seed, .{}, 60, 900_000);
        defer a.deinit();
        try testing.expectEqual(model.Phase.results, a.phase);
        try testing.expect(a.hud.level >= 3 and a.hud.level <= 8);
        try testing.expectEqual(@as(u32, 0), a.stats.wrongs);
        try testing.expect(a.stats.peak_wpm > 50 and a.stats.peak_wpm < 70);
        sum += a.hud.level;
    }
    try testing.expect(sum >= 3 * 4 and sum <= 3 * 7);

    var idle = try wpmBot(99, .{}, 0, 300_000);
    defer idle.deinit();
    try testing.expectEqual(model.Phase.results, idle.phase);
    try testing.expect(idle.playSeconds() < 90);
    try testing.expectEqualStrings("hunt & peck", idle.rank().name);

    // 30 WPM falls behind before CODE REVIEW; 100 WPM reaches overtime.
    var slow = try wpmBot(7, .{}, 30, 900_000);
    defer slow.deinit();
    try testing.expect(slow.hud.level >= 2 and slow.hud.level <= 4);
    var fast = try wpmBot(7, .{}, 100, 900_000);
    defer fast.deinit();
    try testing.expect(fast.hud.level >= 10);
}
