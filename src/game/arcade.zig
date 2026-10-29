//! "snipetype arcade": the deterministic game simulation.
//!
//! Two games share one shift (09:00 to 18:00, then overtime): the Words game
//! (default) drops lines of words one plate at a time; the Keys game drops
//! keys, vim sequences and chords. Either way the player types the caps
//! before they land on the deck. The sim runs at a fixed 120 Hz step fed by
//! `update(now_ms)`, reacts to `handleKey`, and exposes a read-only view
//! (`phase`, `stats`, `hud`, `caps()`) plus a list of `events()` the app maps
//! to effects and sounds. All randomness comes from seeded `Rng`s, nothing
//! here touches the platform, and the only allocations happen in `init`.

const std = @import("std");
const keys = @import("../platform/keys.zig");
const Rng = @import("../core/rng.zig").Rng;
const model = @import("model.zig");
const levels = @import("levels.zig");
const layout = @import("layout.zig");
const scoring = @import("scoring.zig");
const quotes = @import("quotes.zig");
const words = @import("words.zig");

const Cap = model.Cap;
const Event = model.Event;
const Phase = model.Phase;
const Pace = model.Pace;
const Effect = model.Effect;
const Family = model.Family;

/// Width of a cap in terminal cells (shared with the scene).
pub const capWidthCells = layout.capWidthCells;

pub const TICK_HZ: u32 = 120;
pub const DT: f32 = 1.0 / @as(f32, @floatFromInt(TICK_HZ));
/// Live caps (falling + lingering hit/missed ones).
pub const MAX_CAPS = 64;
/// Events buffered between `clearEvents` calls; extras are dropped.
pub const MAX_EVENTS = 256;
pub const LEVEL_SECONDS: u32 = 30;
/// Hard stop for a shift.
pub const SHIFT_SECONDS: u32 = 3600;
/// Hit/missed caps stay listed this long for their animation.
pub const LINGER_SECONDS: f32 = 1.0;
pub const FIRST_SPAWN_SECONDS: f64 = 0.8;
/// Banner and callout display time (the scene fades them out).
pub const BANNER_SECONDS: f32 = 2.5;
/// Largest wall-clock gap one `update` will simulate.
pub const MAX_FRAME_MS: i64 = 250;
/// Rate at which a cap's speed eases toward its target, per tick.
pub const EASE_PER_TICK: f32 = 0.0104;
/// Hold after a deep-work line (a quote) before the next one starts.
pub const PHRASE_HOLD_SECONDS: f64 = 2.6;
/// Words game holds after one-liners and after word-list or code lines.
pub const ONELINER_HOLD_SECONDS: f64 = 1.5;
pub const WORDLINE_HOLD_SECONDS: f64 = 1.0;
/// Words game: first level with bonus vim caps, and the bonus chance per
/// line word (one bonus at most, spawned with the line's first word).
pub const BONUS_LEVEL: u8 = 2;
pub const BONUS_PER_WORD: f64 = 0.14;
pub const BONUS_MAX_CHANCE: f64 = 0.85;
/// Bytes of one generated Words-game line (two are kept, alternating).
pub const LINE_CAP = 256;
/// Keys on the results card are ignored this long, so a key typed as the
/// shift ends (Enter is a cap, so is q) does not skip the results.
pub const RESULTS_LOCK_TICKS: u32 = TICK_HZ * 3 / 4;

/// Speed multipliers selectable on the title screen.
pub const speeds = [_]u8{ 1, 2, 4, 8, 16 };

const KPM_WINDOW_TICKS: u64 = 10 * TICK_HZ;
const RING = 512;

pub const Options = struct {
    /// Game played by the next shift (toggled on the title with Tab or g).
    game: model.Game = .words,
    pace: Pace = .senior,
    /// Speed multiplier: 1, 2, 4, 8 or 16 (other values snap down).
    speed: u8 = 1,
    /// Terminal reports modifier chords (kitty keyboard); otherwise the
    /// three-key stage is replaced by longer sequences.
    chords: bool = true,
    /// Play-area width in cells (spawn placement).
    play_cols: u16 = 80,
};

/// Sliding-window counter of tick stamps.
const Window = struct {
    ticks: [RING]u32 = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Window, tick: u64) void {
        if (self.len == RING) {
            self.head = (self.head + 1) % RING;
            self.len -= 1;
        }
        self.ticks[(self.head + self.len) % RING] = @truncate(tick);
        self.len += 1;
    }

    fn expire(self: *Window, now: u64) void {
        while (self.len > 0 and @as(u64, self.ticks[self.head]) + KPM_WINDOW_TICKS <= now) {
            self.head = (self.head + 1) % RING;
            self.len -= 1;
        }
    }
};

const WordState = struct {
    active: bool = false,
    quote: u16 = 0,
    count: u8 = 0,
    next_word: u8 = 0,
    resolved: u64 = 0,
    resolved_n: u8 = 0,
    hits: u8 = 0,
    last_cap: u32 = 0,
    fall_scale: f32 = 1,
    holding: bool = false,
    hold_until: u64 = 0,
    /// Hold after this line completes.
    hold_s: f64 = PHRASE_HOLD_SECONDS,
    /// Code line: every character is typed, identifiers exactly.
    code_line: bool = false,
    /// Spawn a bonus vim cap with the line's first word.
    bonus_pending: bool = false,
    /// Which half of `line_buf` the next generated line uses.
    flip: u1 = 0,
    /// Recently used lines (quotes: index, one-liners: ONELINER_ID + index).
    recent: [8]u16 = @splat(0xffff),
    recent_i: u8 = 0,
};

const ONELINER_ID: u16 = 0x1000;

pub const Arcade = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    phase: Phase = .title,
    stats: model.Stats = .{},
    hud: model.Hud = .{},

    cap_buf: []Cap,
    cap_len: usize = 0,
    event_buf: []Event,
    event_len: usize = 0,
    /// Two generated Words-game lines (`hud.phrase.text` points here).
    line_buf: []u8,

    seed: u64,
    games: u64 = 0,
    rng: Rng,
    demo_rng: Rng,

    last_ms: ?i64 = null,
    /// Accumulated time in 1/120000 s units (ms * 120).
    acc: i64 = 0,

    /// Ticks of the current shift.
    tick: u64 = 0,
    overtime_ticks: u64 = 0,
    level: u8 = 0,
    next_spawn: f64 = FIRST_SPAWN_SECONDS,
    next_id: u32 = 1,
    last_effect: ?Effect = null,
    keys_window: Window = .{},
    chars_window: Window = .{},
    /// Correct key presses this shift (modifiers of chords included).
    key_units: u64 = 0,
    word: WordState = .{},

    demo_tick: u64 = 0,
    demo_next: f64 = 0.4,
    demo_combo: u32 = 0,
    demo_word: u8 = 0,
    /// Ticks spent on the results card (input lockout).
    results_ticks: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, seed: u64, opts: Options) !Arcade {
        const cap_buf = try allocator.alloc(Cap, MAX_CAPS);
        errdefer allocator.free(cap_buf);
        const event_buf = try allocator.alloc(Event, MAX_EVENTS);
        errdefer allocator.free(event_buf);
        const line_buf = try allocator.alloc(u8, 2 * LINE_CAP);
        var self: Arcade = .{
            .allocator = allocator,
            .opts = opts,
            .cap_buf = cap_buf,
            .event_buf = event_buf,
            .line_buf = line_buf,
            .seed = seed,
            .rng = Rng.init(seed),
            .demo_rng = Rng.init(seed ^ 0xD3E0_5EED_A77A_C7),
        };
        self.opts.speed = snapSpeed(opts.speed);
        self.reset(seed);
        return self;
    }

    pub fn deinit(self: *Arcade) void {
        self.allocator.free(self.cap_buf);
        self.allocator.free(self.event_buf);
        self.allocator.free(self.line_buf);
    }

    /// Back to the title screen with a new seed (options are kept).
    pub fn reset(self: *Arcade, seed: u64) void {
        self.seed = seed;
        self.games = 0;
        self.rng = Rng.init(seed);
        self.demo_rng = Rng.init(seed ^ 0xD3E0_5EED_A77A_C7);
        self.event_len = 0;
        self.last_ms = null;
        self.acc = 0;
        self.toTitle();
    }

    /// Update the play-area width used for spawn placement.
    pub fn setPlayWidth(self: *Arcade, cols: u16) void {
        self.opts.play_cols = @max(cols, 8);
    }

    pub fn caps(self: *const Arcade) []const Cap {
        return self.cap_buf[0..self.cap_len];
    }

    pub fn events(self: *const Arcade) []const Event {
        return self.event_buf[0..self.event_len];
    }

    pub fn clearEvents(self: *Arcade) void {
        self.event_len = 0;
    }

    /// Pace selected on the title screen (and used by the running shift).
    pub fn selectedPace(self: *const Arcade) Pace {
        return self.opts.pace;
    }

    /// Speed multiplier selected on the title screen.
    pub fn selectedSpeed(self: *const Arcade) u8 {
        return self.opts.speed;
    }

    /// Game selected on the title screen (and played by the running shift).
    pub fn selectedGame(self: *const Arcade) model.Game {
        return self.opts.game;
    }

    fn isReflexKey(c: u21) bool {
        return c == keys.code.space or c == keys.code.backspace or c == keys.code.enter;
    }

    fn wordsGame(self: *const Arcade) bool {
        return self.opts.game == .words;
    }

    /// True while the title attract demo is running.
    pub fn isAttract(self: *const Arcade) bool {
        return self.phase == .title;
    }

    /// Seconds played in the current shift.
    pub fn playSeconds(self: *const Arcade) f32 {
        return @as(f32, @floatFromInt(self.tick)) / @as(f32, @floatFromInt(TICK_HZ));
    }

    /// 0..1 progress through the current level ("hour").
    pub fn levelProgress(self: *const Arcade) f32 {
        const per = LEVEL_SECONDS * TICK_HZ;
        return @as(f32, @floatFromInt(self.tick % per)) / @as(f32, @floatFromInt(per));
    }

    /// Average correct keys per minute over the whole shift.
    pub fn avgKpm(self: *const Arcade) f32 {
        const secs = @max(self.playSeconds(), 1);
        return @as(f32, @floatFromInt(self.key_units)) * 60 / secs;
    }

    /// End-of-shift rank (peak keys/min in the Keys game, peak WPM in the
    /// Words game).
    pub fn rank(self: *const Arcade) model.Rank {
        if (self.wordsGame()) return scoring.wordRankFor(self.stats.peak_wpm, self.stats.accuracy(), self.level, self.opts.speed);
        return scoring.rankFor(self.stats.peak_kpm, self.stats.accuracy(), self.level, self.opts.speed);
    }

    /// Results flavor line ("audible from ...").
    pub fn heardLine(self: *const Arcade) []const u8 {
        if (self.wordsGame()) return scoring.wordHeardLine(self.avgKpm());
        return scoring.heardLine(self.avgKpm());
    }

    // -----------------------------------------------------------------------
    // Time

    /// Advance the simulation to `now_ms` in fixed 120 Hz steps.
    pub fn update(self: *Arcade, now_ms: i64) void {
        const last = self.last_ms orelse {
            self.last_ms = now_ms;
            return;
        };
        self.last_ms = now_ms;
        const dt = std.math.clamp(now_ms - last, 0, MAX_FRAME_MS);
        if (self.phase == .paused) {
            self.acc = 0;
            return;
        }
        self.acc += dt * @as(i64, TICK_HZ);
        while (self.acc >= 1000) {
            self.acc -= 1000;
            self.step();
        }
    }

    /// One fixed simulation step.
    pub fn step(self: *Arcade) void {
        switch (self.phase) {
            .title => self.stepTitle(),
            .playing => self.stepPlaying(),
            .paused => {},
            .results => self.animateOnly(),
        }
    }

    fn seconds(self: *const Arcade) f64 {
        return @as(f64, @floatFromInt(self.tick)) / @as(f64, @floatFromInt(TICK_HZ));
    }

    fn emit(self: *Arcade, ev: Event) void {
        if (self.event_len >= self.event_buf.len) return;
        self.event_buf[self.event_len] = ev;
        self.event_len += 1;
    }

    // -----------------------------------------------------------------------
    // Input

    pub fn handleKey(self: *Arcade, ev: keys.KeyEvent, now_ms: i64) void {
        if (ev.kind == .release) return;
        if (ev.kind == .press) self.emit(.{ .key_press = .{ .code = ev.code, .mods = ev.mods } });
        const plain = !ev.mods.ctrl and !ev.mods.alt and !ev.mods.super;
        switch (self.phase) {
            .title => self.titleKey(ev, now_ms),
            .playing => {
                if (ev.kind != .press) return;
                if (ev.code == keys.code.escape and plain and !ev.mods.shift) {
                    self.phase = .paused;
                    return;
                }
                self.playKey(ev);
            },
            .paused => {
                if (ev.kind != .press or !plain) return;
                if (ev.code == keys.code.escape) {
                    self.phase = .playing;
                    self.last_ms = now_ms;
                    self.acc = 0;
                } else if (ev.code == 'q' and !ev.mods.shift) {
                    self.toTitle();
                    self.last_ms = now_ms;
                }
            },
            .results => {
                if (ev.kind != .press or !plain) return;
                if (self.results_ticks < RESULTS_LOCK_TICKS) return;
                if (ev.code == keys.code.enter) {
                    self.startGame();
                    self.last_ms = now_ms;
                } else if (ev.code == keys.code.escape or (ev.code == 'q' and !ev.mods.shift)) {
                    self.toTitle();
                    self.last_ms = now_ms;
                }
            },
        }
    }

    fn titleKey(self: *Arcade, ev: keys.KeyEvent, now_ms: i64) void {
        if (ev.mods.ctrl or ev.mods.alt or ev.mods.super) return;
        const pace_n = @typeInfo(Pace).@"enum".field_names.len;
        const p: usize = @backingInt(self.opts.pace);
        const si = speedIndex(self.opts.speed);
        switch (ev.code) {
            keys.code.left, 'h' => self.opts.pace = @fromBackingInt(@intCast((p + pace_n - 1) % pace_n)),
            keys.code.right, 'l' => self.opts.pace = @fromBackingInt(@intCast((p + 1) % pace_n)),
            keys.code.up, 'k' => self.opts.speed = speeds[(si + 1) % speeds.len],
            keys.code.down, 'j' => self.opts.speed = speeds[(si + speeds.len - 1) % speeds.len],
            keys.code.tab, 'g' => {
                if (ev.kind != .press or ev.mods.shift) return;
                self.opts.game = if (self.opts.game == .words) .keys else .words;
            },
            keys.code.enter => {
                if (ev.kind != .press) return;
                self.startGame();
                self.last_ms = now_ms;
                return;
            },
            else => return,
        }
        self.hud.pace = self.opts.pace;
        self.hud.pace_mult = self.opts.speed;
    }

    /// Ignored keys: modifiers, locks, F-keys, media keys. Keypad keys
    /// that type text (kitty reports KP_1 with text "1") still count.
    fn isNeutralKey(ev: keys.KeyEvent) bool {
        return ev.code >= keys.code.caps_lock and (ev.text == 0 or keys.code.isModifier(ev.code));
    }

    /// Whether falling cap `c` should take a key over the current best `b`:
    /// more typed steps first; in the Words game the active word wins ties
    /// over bonus caps; then the cap closest to landing.
    fn takesOver(self: *const Arcade, c: *const Cap, b: *const Cap) bool {
        if (c.typed != b.typed) return c.typed > b.typed;
        if (self.wordsGame() and (c.kind == .word) != (b.kind == .word)) return c.kind == .word;
        return c.progress > b.progress;
    }

    fn playKey(self: *Arcade, ev: keys.KeyEvent) void {
        if (isNeutralKey(ev)) return;

        const active_word = self.activeWordCap();
        var best: ?usize = null;
        for (self.cap_buf[0..self.cap_len], 0..) |*c, i| {
            if (c.state != .falling) continue;
            if (c.kind == .word and c.id != active_word) continue;
            if (!levels.stepMatches(c.steps[c.typed], ev, c.kind == .word and !c.exact)) continue;
            if (best) |b| {
                if (!self.takesOver(c, &self.cap_buf[b])) continue;
            }
            best = i;
        }
        // Words are never followed by Space, and there is nothing to erase;
        // a reflexive Space/Backspace/Enter is ignored unless some cap wants it.
        if (best == null and self.wordsGame() and isReflexKey(ev.code) and self.findReroute(ev) == null) return;
        self.stats.keystrokes += 1;
        // A typed prefix moved to a sibling sequence ("d" of "dd" -> "dw")
        // has more progress than any fresh cap, so it wins over them.
        if (self.findReroute(ev)) |r| {
            if (best == null or self.cap_buf[best.?].typed < r.k) {
                self.cap_buf[r.to].typed = r.k;
                self.cap_buf[r.from].typed = 0;
                best = r.to;
            }
        }
        if (best) |i| {
            self.advance(i);
        } else {
            self.wrong(ev);
        }
    }

    const Reroute = struct { from: usize, to: usize, k: u8 };

    /// When a partially typed sequence cannot take `ev`, find another falling
    /// cap that shares the typed prefix and accepts `ev` ("d" then "w" with
    /// both "dd" and "dw" on screen). The caller moves the progress.
    fn findReroute(self: *const Arcade, ev: keys.KeyEvent) ?Reroute {
        const list = self.cap_buf[0..self.cap_len];
        for (list, 0..) |*p, pi| {
            if (p.state != .falling or p.kind != .sequence or p.typed == 0) continue;
            const k = p.typed;
            var best: ?usize = null;
            for (list, 0..) |*c, j| {
                if (c == p or c.state != .falling or c.typed != 0 or c.len <= k) continue;
                if (c.kind != .sequence) continue;
                if (!samePrefix(p, c, k)) continue;
                if (!levels.stepMatches(c.steps[k], ev, false)) continue;
                if (best == null or c.progress > list[best.?].progress) best = j;
            }
            if (best) |j| return .{ .from = pi, .to = j, .k = k };
        }
        return null;
    }

    fn samePrefix(a: *const Cap, b: *const Cap, n: u8) bool {
        for (0..n) |i| {
            const x = a.steps[i];
            const y = b.steps[i];
            if (x.code != y.code or x.text != y.text or !model.Mods.eql(x.mods, y.mods)) return false;
        }
        return true;
    }

    fn advance(self: *Arcade, i: usize) void {
        const c = &self.cap_buf[i];
        const s = c.steps[c.typed];
        c.typed += 1;
        const units: u8 = 1 + @as(u8, @intFromBool(s.mods.ctrl)) + @intFromBool(s.mods.alt) + @intFromBool(s.mods.shift) + @intFromBool(s.mods.super);
        for (0..units) |_| self.keys_window.push(self.tick);
        self.key_units += units;

        if (c.kind == .word) {
            self.chars_window.push(self.tick);
            self.bumpCombo();
            self.stats.score += @as(u64, 10) * self.stats.mult * self.opts.speed;
        }
        if (c.typed >= c.len) {
            self.complete(i);
        } else {
            self.emit(.{ .step = .{ .cap_id = c.id, .index = c.typed - 1 } });
            if (c.kind == .word) self.syncPhrase();
        }
        self.refreshRates();
    }

    fn bumpCombo(self: *Arcade) void {
        const st = &self.stats;
        st.combo += 1;
        st.best_combo = @max(st.best_combo, st.combo);
        st.mult = scoring.comboMult(st.combo);
        if (scoring.milestoneFor(st.combo)) |text| {
            self.hud.callout = text;
            self.hud.callout_t = 0;
            self.emit(.{ .milestone = .{ .combo = st.combo, .text = text } });
        }
    }

    fn complete(self: *Arcade, i: usize) void {
        const c = &self.cap_buf[i];
        if (c.kind != .word) self.bumpCombo();
        const st = &self.stats;
        const quick = c.progress < scoring.QUICK_PROGRESS;
        const pts = scoring.points(scoring.basePoints(c), c.rarity, quick, st.mult, self.opts.speed);
        st.score += pts;
        st.hits += 1;
        st.health = @min(100, st.health + scoring.heal(c));

        var tier = scoring.effectTier(c, st.combo);
        // The word that completes a line goes out with a bang.
        if (c.kind == .word and self.isLineFinal(c.word)) tier = 3;
        const effect = scoring.pickEffect(tier, self.last_effect, self.rng.next());
        self.last_effect = effect;
        self.emit(.{ .hit = .{
            .cap_id = c.id,
            .x = c.x,
            .y = c.progress,
            .effect = effect,
            .points = pts,
            .quick = quick,
            .intensity = scoring.intensity(st.combo, layout.keyCount(c), c.rarity, quick),
            .hue = c.hue,
            .rarity = c.rarity,
            .caption = c.caption,
            .kind = c.kind,
            .combo = st.combo,
        } });
        c.state = .hit;
        c.state_t = 0;
        if (c.kind == .word) self.resolveWord(c.word, true);
    }

    fn wrong(self: *Arcade, ev: keys.KeyEvent) void {
        const st = &self.stats;
        st.combo = 0;
        st.mult = 1;
        st.wrongs += 1;
        st.health -= scoring.WRONG_DAMAGE;
        // A stray key cancels pending vim sequences (word progress is kept).
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.state == .falling and c.kind == .sequence) c.typed = 0;
        }
        self.emit(.{ .wrong = .{ .code = ev.code } });
        self.checkGameOver();
    }

    fn miss(self: *Arcade, c: *Cap) void {
        const st = &self.stats;
        c.state = .missed;
        c.state_t = 0;
        c.progress = 1;
        if (self.wordsGame() and c.kind != .word) {
            // A missed bonus cap costs nothing; it just dissolves.
            self.emit(.{ .miss = .{ .cap_id = c.id, .x = c.x, .hue = c.hue } });
            return;
        }
        st.combo = 0;
        st.mult = 1;
        st.misses += 1;
        st.health -= scoring.paceParams(self.opts.pace).miss_damage;
        self.emit(.{ .miss = .{ .cap_id = c.id, .x = c.x, .hue = c.hue } });
        if (c.kind == .word) self.resolveWord(c.word, false);
        self.checkGameOver();
    }

    fn checkGameOver(self: *Arcade) void {
        if (self.stats.health > 0 or self.phase != .playing) return;
        self.stats.health = 0;
        self.endShift();
    }

    fn endShift(self: *Arcade) void {
        self.phase = .results;
        self.results_ticks = 0;
        // Let the remaining caps dissolve silently behind the results card.
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.state == .falling) {
                c.state = .missed;
                c.state_t = 0;
            }
        }
        self.emit(.game_over);
    }

    // -----------------------------------------------------------------------
    // Phases

    fn clearCaps(self: *Arcade) void {
        self.cap_len = 0;
    }

    fn toTitle(self: *Arcade) void {
        self.phase = .title;
        self.clearCaps();
        self.stats = .{};
        self.hud = .{ .pace = self.opts.pace, .pace_mult = self.opts.speed };
        self.demo_word = 0;
        self.word = .{};
        self.demo_tick = 0;
        self.demo_next = 0.4;
        self.demo_combo = 0;
        self.acc = 0;
    }

    /// Clock in: start a new shift of the selected game, pace and speed.
    pub fn startGame(self: *Arcade) void {
        self.games += 1;
        self.rng = Rng.init(self.seed +% self.games *% 0x9E37_79B9_7F4A_7C15);
        self.phase = .playing;
        self.clearCaps();
        self.stats = .{ .per_key = self.wordsGame() };
        self.hud = .{ .pace = self.opts.pace, .pace_mult = self.opts.speed, .word_stage = self.wordsGame() };
        self.tick = 0;
        self.overtime_ticks = 0;
        self.next_spawn = FIRST_SPAWN_SECONDS;
        self.last_effect = null;
        self.keys_window = .{};
        self.chars_window = .{};
        self.key_units = 0;
        self.word = .{};
        self.acc = 0;
        self.emit(.start);
        self.enterLevel(0, false);
    }

    const overtime_banners = [_][]const u8{
        "OVERTIME · everything, faster",
        "OVERTIME · the office lights dim",
        "OVERTIME · the cleaners wave hello",
        "OVERTIME · cold pizza has arrived",
        "OVERTIME · the deploy window opens",
        "OVERTIME · the coffee machine gives up",
    };

    const words_overtime_banners = [_][]const u8{
        "OVERTIME · anything, faster",
        "OVERTIME · the office lights dim",
        "OVERTIME · the cleaners wave hello",
        "OVERTIME · cold pizza has arrived",
        "OVERTIME · the deploy window opens",
        "OVERTIME · the coffee machine gives up",
    };

    fn enterLevel(self: *Arcade, lvl: u8, announce: bool) void {
        self.level = lvl;
        self.hud.level = lvl;
        if (self.wordsGame()) {
            const ws = levels.wordStage(lvl);
            self.hud.level_name = ws.name;
            self.hud.banner = if (lvl >= levels.OVERTIME_LEVEL)
                words_overtime_banners[(lvl - levels.OVERTIME_LEVEL) % words_overtime_banners.len]
            else
                ws.banner;
        } else {
            const st = levels.stage(lvl, self.opts.chords);
            self.hud.level_name = st.name;
            self.hud.banner = if (lvl >= levels.OVERTIME_LEVEL)
                overtime_banners[(lvl - levels.OVERTIME_LEVEL) % overtime_banners.len]
            else
                st.banner;
        }
        self.hud.banner_t = 0;
        if (announce) self.emit(.{ .level_up = .{ .level = lvl } });
        // The Words game starts its first line at once; later lines follow
        // the hold of the previous one, across level changes.
        if ((self.wordsGame() and lvl == 0) or (!self.wordsGame() and lvl == levels.WORD_LEVEL)) {
            self.word.active = true;
            self.hud.word_stage = true;
            self.beginPhrase();
        }
        if (lvl == levels.OVERTIME_LEVEL) {
            self.overtime_ticks = 0;
            const now = self.seconds();
            if (self.next_spawn < now + 0.5) self.next_spawn = now + 0.5;
        }
        self.updateClock();
    }

    fn updateClock(self: *Arcade) void {
        const per = LEVEL_SECONDS * TICK_HZ;
        const minutes: u64 = (self.tick % per) * 60 / per;
        self.hud.clock_minutes = @intCast((9 * 60 + @as(u64, self.level) * 60 + minutes) % (24 * 60));
    }

    fn stepPlaying(self: *Arcade) void {
        self.tick += 1;
        const lvl_now: u64 = self.tick / (LEVEL_SECONDS * TICK_HZ);
        while (self.level < lvl_now and self.level < 255) self.enterLevel(self.level + 1, true);
        if (self.level >= levels.OVERTIME_LEVEL) self.overtime_ticks += 1;
        self.updateClock();

        if (self.word.active) self.wordUpdate();
        if (!self.inWordStage()) self.keySpawnUpdate();

        const fall = self.fallTime();
        var i: usize = 0;
        while (i < self.cap_len) : (i += 1) {
            const c = &self.cap_buf[i];
            c.age += DT;
            if (c.state != .falling) {
                c.state_t += DT;
                continue;
            }
            const target: f32 = @floatCast(1.0 / (fall * c.fall_scale));
            c.speed += (target - c.speed) * EASE_PER_TICK;
            c.progress += c.speed * DT;
            if (c.progress >= 1) {
                self.miss(c);
                if (self.phase != .playing) break;
            }
        }
        self.removeExpired();
        self.hud.banner_t += DT;
        self.hud.callout_t += DT;
        self.keys_window.expire(self.tick);
        self.chars_window.expire(self.tick);
        self.refreshRates();

        if (self.phase == .playing and self.tick >= @as(u64, SHIFT_SECONDS) * TICK_HZ) self.endShift();
    }

    /// Results: finish hit/miss animations and HUD timers, nothing falls.
    fn animateOnly(self: *Arcade) void {
        self.results_ticks +|= 1;
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.state != .falling) c.state_t += DT;
        }
        self.removeExpired();
        self.hud.banner_t += DT;
        self.hud.callout_t += DT;
    }

    fn removeExpired(self: *Arcade) void {
        // Caps are ~800 bytes; only move the ones that shift down.
        var w: usize = 0;
        for (0..self.cap_len) |i| {
            const c = &self.cap_buf[i];
            if (c.state != .falling and c.state_t >= LINGER_SECONDS) continue;
            if (w != i) self.cap_buf[w] = c.*;
            w += 1;
        }
        self.cap_len = w;
    }

    fn refreshRates(self: *Arcade) void {
        // Early in a shift divide by the elapsed time (at least 5 s) so the
        // meter is meaningful before the window fills.
        const elapsed = std.math.clamp(self.seconds(), 5.0, 10.0);
        const k: f32 = @floatCast(@as(f64, @floatFromInt(self.keys_window.len)) * 60.0 / elapsed);
        const w: f32 = @floatCast(@as(f64, @floatFromInt(self.chars_window.len)) * 60.0 / 5.0 / elapsed);
        self.stats.kpm = k;
        self.stats.wpm = w;
        self.stats.peak_kpm = @max(self.stats.peak_kpm, k);
        self.stats.peak_wpm = @max(self.stats.peak_wpm, w);
    }

    // -----------------------------------------------------------------------
    // Pace

    fn curveS(self: *const Arcade) f64 {
        if (self.wordsGame()) return scoring.wordsCurveS(self.opts.pace, self.level, self.overtime_ticks);
        return scoring.curveS(self.opts.pace, self.level, self.overtime_ticks);
    }

    /// Current fall time in seconds for a regular cap.
    pub fn fallTime(self: *const Arcade) f64 {
        return scoring.fallTime(self.opts.pace, self.curveS(), self.opts.speed);
    }

    /// Current base spawn gap in seconds.
    pub fn spawnGap(self: *const Arcade) f64 {
        return scoring.spawnGap(self.opts.pace, self.curveS(), self.opts.speed);
    }

    /// Word caps are falling: the whole Words game, or the Keys game's
    /// deep work stage.
    fn inWordStage(self: *const Arcade) bool {
        return self.wordsGame() or self.level == levels.WORD_LEVEL;
    }

    // -----------------------------------------------------------------------
    // Spawning

    fn randF(rng: *Rng) f64 {
        return @as(f64, @floatFromInt(rng.next() >> 11)) / 9007199254740992.0;
    }

    fn keySpawnUpdate(self: *Arcade) void {
        const now = self.seconds();
        if (now < self.next_spawn) return;
        const spawned = self.spawnKeyCap(&self.rng, self.level);
        if (spawned) |kc| {
            const u = 0.75 + 0.5 * randF(&self.rng);
            const extra = 1.0 + 0.4 * @as(f64, @floatFromInt(kc -| 1));
            self.next_spawn = now + self.spawnGap() * u * extra;
        } else {
            self.next_spawn = now + 0.1;
        }
    }

    fn onScreen(self: *const Arcade, f: Family, item: u16) bool {
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.state == .falling and c.family == f and c.item == item) return true;
        }
        return false;
    }

    /// Spawn one key/chord/sequence cap for `level`. Returns its key count,
    /// or null when nothing could be spawned.
    fn spawnKeyCap(self: *Arcade, rng: *Rng, level: u8) ?u8 {
        const mix_level: u8 = if (level == levels.WORD_LEVEL) 8 else level;
        return self.spawnFromWeights(rng, levels.familyWeights(mix_level, self.opts.chords), 1);
    }

    /// Words game bonus: one vim sequence or ex command, falling at the
    /// regular (slower than word) pace.
    fn spawnBonusCap(self: *Arcade, rng: *Rng) ?u8 {
        var w: [levels.family_count]f32 = @splat(0);
        for ([_]Family{ .operators, .ex, .macros }) |f| w[@backingInt(f)] = levels.familyWeight(f);
        return self.spawnFromWeights(rng, w, 1.1);
    }

    /// Spawn one cap from the family `weights` (indexed by family).
    fn spawnFromWeights(self: *Arcade, rng: *Rng, weights_in: [levels.family_count]f32, fall_scale: f32) ?u8 {
        if (self.cap_len >= self.cap_buf.len) return null;
        var weights = weights_in;
        var tries: usize = 0;
        while (tries < levels.family_count) : (tries += 1) {
            var total: f32 = 0;
            for (weights) |w| total += w;
            if (total <= 0) return null;
            var r: f32 = @floatCast(randF(rng) * total);
            var fi: usize = 0;
            for (weights, 0..) |w, i| {
                if (w <= 0) continue;
                fi = i;
                if (r < w) break;
                r -= w;
            }
            const fam: Family = @fromBackingInt(@intCast(fi));
            const pool = levels.pool(fam);
            var free: usize = 0;
            for (0..pool.len) |j| {
                if (!self.onScreen(fam, @intCast(j))) free += 1;
            }
            if (free == 0) {
                weights[fi] = 0;
                continue;
            }
            var pick = rng.range(free);
            var idx: usize = 0;
            for (0..pool.len) |j| {
                if (self.onScreen(fam, @intCast(j))) continue;
                if (pick == 0) {
                    idx = j;
                    break;
                }
                pick -= 1;
            }
            const item = pool[idx];
            var c: Cap = .{
                .id = self.nextId(),
                .kind = item.kind,
                .len = @intCast(item.steps.len),
                .caption = item.caption,
                .x = 0.5,
                .hue = @floatCast(randF(rng)),
                .family = fam,
                .item = @intCast(idx),
                .rarity = scoring.rarityFromRoll(randF(rng)),
                .fall_scale = fall_scale,
            };
            @memcpy(c.steps[0..item.steps.len], item.steps);
            c.x = self.placeX(rng, capWidthCells(&c));
            c.speed = @floatCast(0.3 / (self.fallTime() * fall_scale));
            self.cap_buf[self.cap_len] = c;
            self.cap_len += 1;
            return layout.keyCount(&c);
        }
        return null;
    }

    fn nextId(self: *Arcade) u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    /// Horizontal center (0..1) for a new cap `width` cells wide: up to 16
    /// random tries avoiding caps near the top, else the least crowded try.
    fn placeX(self: *const Arcade, rng: *Rng, width: u16) f32 {
        const cols: f64 = @floatFromInt(@max(self.opts.play_cols, 8));
        const half = @as(f64, @floatFromInt(width)) / 2.0;
        const lo = half + 1;
        const hi = cols - half - 1;
        if (hi <= lo) return 0.5;
        var best_x: f64 = (lo + hi) / 2;
        var best_score: f64 = std.math.inf(f64);
        for (0..16) |_| {
            const xc = lo + randF(rng) * (hi - lo);
            var score: f64 = 0;
            for (self.cap_buf[0..self.cap_len]) |*c| {
                if (c.state != .falling or c.progress >= 0.35) continue;
                const ch = @as(f64, @floatFromInt(capWidthCells(c))) / 2.0;
                const cx = @as(f64, c.x) * cols;
                const overlap = @min(xc + half, cx + ch) - @max(xc - half, cx - ch) + 2; // 1-cell margin each side
                if (overlap > 0) score += overlap * (0.35 - @as(f64, c.progress));
            }
            if (score == 0) return @floatCast(xc / cols);
            if (score < best_score) {
                best_score = score;
                best_x = xc;
            }
        }
        return @floatCast(best_x / cols);
    }

    // -----------------------------------------------------------------------
    // Deep work (words)

    fn beginPhrase(self: *Arcade) void {
        if (self.wordsGame()) return self.beginWordsLine();
        const ws = &self.word;
        ws.hold_s = PHRASE_HOLD_SECONDS;
        ws.code_line = false;
        var q: u16 = 0;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            q = @intCast(self.rng.range(quotes.all.len));
            if (attempts > 16 or std.mem.indexOfScalar(u16, &ws.recent, q) == null) break;
        }
        ws.recent[ws.recent_i % ws.recent.len] = q;
        ws.recent_i +%= 1;
        const text = quotes.all[q].text;
        const n: u8 = @intCast(@min(quotes.wordCount(text), 64));
        var max_len: usize = 1;
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        while (it.next()) |w| {
            var letters: usize = 0;
            for (w) |ch| letters += @intFromBool(std.ascii.isAlphabetic(ch));
            max_len = @max(max_len, letters);
        }
        ws.quote = q;
        ws.count = n;
        ws.next_word = 0;
        ws.resolved = 0;
        ws.resolved_n = 0;
        ws.hits = 0;
        ws.last_cap = 0;
        ws.holding = false;
        ws.fall_scale = scoring.wordFallScale(max_len);
        self.hud.phrase = .{
            .text = text,
            .attribution = quotes.all[q].by,
            .word_start = 0,
            .word_end = 0,
            .done_upto = 0,
            .word_count = n,
        };
        self.syncPhrase();
    }

    fn wordUpdate(self: *Arcade) void {
        const ws = &self.word;
        if (ws.holding) {
            if (self.tick < ws.hold_until) return;
            if (self.inWordStage()) {
                self.beginPhrase();
            } else {
                self.endWordMode();
            }
            return;
        }
        var live: usize = 0;
        var last_progress: f32 = 1;
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.kind != .word or c.state != .falling) continue;
            live += 1;
            if (c.id == ws.last_cap) last_progress = c.progress;
        }
        if (!self.inWordStage()) {
            // The stage ended mid-line: let live words finish, drop the rest.
            if (live == 0) self.endWordMode();
            return;
        }
        if (ws.next_word < ws.count and (live == 0 or (live < 2 and last_progress >= 0.3))) {
            self.spawnWord();
        }
    }

    fn rememberLine(self: *Arcade, id: u16) void {
        const ws = &self.word;
        ws.recent[ws.recent_i % ws.recent.len] = id;
        ws.recent_i +%= 1;
    }

    /// Random index among the lines of `texts` with a word count in
    /// [lo, hi], avoiding recently used ones; widens the range if needed.
    fn pickLine(self: *Arcade, texts: []const []const u8, id_base: u16, lo: u8, hi: u8) u16 {
        var cand: [128]u16 = undefined;
        var pass: u8 = 0;
        while (pass < 3) : (pass += 1) {
            var n: usize = 0;
            for (texts, 0..) |t, i| {
                if (n >= cand.len) break;
                const wc = words.wordCount(t);
                if (pass < 2 and (wc < lo or wc > hi)) continue;
                if (pass == 0 and std.mem.indexOfScalar(u16, &self.word.recent, id_base + @as(u16, @intCast(i))) != null) continue;
                cand[n] = @intCast(i);
                n += 1;
            }
            if (n > 0) return cand[self.rng.range(n)];
        }
        return 0;
    }

    fn quoteTexts() [quotes.all.len][]const u8 {
        var out: [quotes.all.len][]const u8 = undefined;
        for (quotes.all, 0..) |q, i| out[i] = q.text;
        return out;
    }
    const quote_texts = quoteTexts();

    /// Random word for a generated line from `source`.
    fn randomWord(rng: *Rng, source: levels.LineSource) []const u8 {
        if (source == .code) return words.code[rng.range(words.code.len)];
        const long = source == .long_words and rng.range(2) == 0;
        var tries: usize = 0;
        while (true) : (tries += 1) {
            const w = words.common[rng.range(words.common.len)];
            if (tries >= 64) return w;
            switch (source) {
                .short_words => if (w.len > 5) continue,
                .common_words => if (w.len > 6) continue,
                else => if (long and w.len < 7) continue,
            }
            return w;
        }
    }

    fn containsWord(list: []const []const u8, w: []const u8) bool {
        for (list) |x| {
            if (std.mem.eql(u8, x, w)) return true;
        }
        return false;
    }

    /// Words game: start the next line for the current level.
    fn beginWordsLine(self: *Arcade) void {
        const ws = &self.word;
        const stage = levels.wordStage(self.level);
        var lo = stage.min_words;
        var hi = stage.max_words;
        var source = stage.source;
        if (source == .deadline) {
            source = switch (self.rng.range(10)) {
                0...3 => .oneliners,
                4...6 => .quotes,
                else => .mixed_words,
            };
        } else if (source == .any) {
            const pick = [_]levels.LineSource{ .mixed_words, .long_words, .code, .quotes, .quotes, .oneliners };
            source = pick[self.rng.range(pick.len)];
        }
        if (source == .code) hi = @min(hi, 6);
        if (source == .mixed_words or source == .long_words) hi = @min(hi, 12);
        lo = @min(lo, hi);

        var text: []const u8 = "";
        var by: []const u8 = "";
        ws.code_line = source == .code;
        switch (source) {
            .quotes => {
                const q = self.pickLine(&quote_texts, 0, lo, hi);
                self.rememberLine(q);
                text = quotes.all[q].text;
                by = quotes.all[q].by;
                ws.hold_s = PHRASE_HOLD_SECONDS;
            },
            .oneliners => {
                const q = self.pickLine(&words.oneliners, ONELINER_ID, lo, hi);
                self.rememberLine(ONELINER_ID + q);
                text = words.oneliners[q];
                ws.hold_s = ONELINER_HOLD_SECONDS;
            },
            else => {
                const n = lo + self.rng.range(hi - lo + 1);
                const buf = self.line_buf[@as(usize, ws.flip) * LINE_CAP ..][0..LINE_CAP];
                ws.flip +%= 1;
                var len: usize = 0;
                var picked: [32][]const u8 = undefined;
                var count: usize = 0;
                while (count < n and count < picked.len) {
                    var w = randomWord(&self.rng, source);
                    // no repeats within a line
                    var tries: usize = 0;
                    while (tries < 8 and containsWord(picked[0..count], w)) : (tries += 1) {
                        w = randomWord(&self.rng, source);
                    }
                    const need = w.len + @intFromBool(len > 0);
                    if (len + need > buf.len) break;
                    if (len > 0) {
                        buf[len] = ' ';
                        len += 1;
                    }
                    @memcpy(buf[len..][0..w.len], w);
                    len += w.len;
                    picked[count] = w;
                    count += 1;
                }
                text = buf[0..len];
                ws.hold_s = WORDLINE_HOLD_SECONDS;
            },
        }
        const n: u8 = @intCast(@min(words.wordCount(text), 64));
        ws.count = n;
        ws.next_word = 0;
        ws.resolved = 0;
        ws.resolved_n = 0;
        ws.hits = 0;
        ws.last_cap = 0;
        ws.holding = false;
        ws.fall_scale = 1;
        const chance = @min(BONUS_MAX_CHANCE, BONUS_PER_WORD * @as(f64, @floatFromInt(n)));
        ws.bonus_pending = self.level >= BONUS_LEVEL and randF(&self.rng) < chance;
        self.hud.phrase = .{
            .text = text,
            .attribution = by,
            .word_start = 0,
            .word_end = 0,
            .done_upto = 0,
            .word_count = n,
        };
        self.syncPhrase();
    }

    /// Whether resolving word `idx` completes the current line.
    fn isLineFinal(self: *const Arcade, idx: u8) bool {
        const ws = &self.word;
        if (!ws.active or ws.holding or idx >= 64) return false;
        if (ws.resolved & (@as(u64, 1) << @intCast(idx)) != 0) return false;
        return ws.resolved_n + 1 >= ws.count;
    }

    fn endWordMode(self: *Arcade) void {
        self.word.active = false;
        self.word.holding = false;
        self.hud.phrase = null;
        self.hud.word_stage = false;
    }

    fn spawnWord(self: *Arcade) void {
        const ws = &self.word;
        const phrase = self.hud.phrase orelse return;
        if (self.cap_len >= self.cap_buf.len) return;
        const idx = ws.next_word;
        ws.next_word += 1;
        const span = phrase.wordSpan(idx) orelse return;
        const text = phrase.text[span.start..span.end];
        var c: Cap = .{
            .id = self.nextId(),
            .kind = .word,
            .len = 0,
            .x = 0.5,
            .hue = @floatCast(randF(&self.rng)),
            .family = .words,
            .item = idx,
            .word = idx,
            .fall_scale = ws.fall_scale,
        };
        c.rarity = scoring.rarityFromRoll(randF(&self.rng));
        if (ws.code_line) {
            c.len = levels.identSteps(text, &c.steps);
            c.exact = words.hasUpper(text);
        } else {
            c.len = levels.wordSteps(text, &c.steps);
        }
        if (c.len == 0) {
            self.resolveWord(idx, true);
            return;
        }
        if (self.wordsGame()) c.fall_scale = scoring.wordsGameFallScale(c.len) * (if (ws.code_line) scoring.CODE_FALL_SCALE else 1);
        c.x = self.placeX(&self.rng, capWidthCells(&c));
        c.speed = @floatCast(0.3 / (self.fallTime() * c.fall_scale));
        self.cap_buf[self.cap_len] = c;
        self.cap_len += 1;
        ws.last_cap = c.id;
        if (ws.bonus_pending) {
            ws.bonus_pending = false;
            _ = self.spawnBonusCap(&self.rng);
        }
        self.syncPhrase();
    }

    fn resolveWord(self: *Arcade, idx: u8, hit: bool) void {
        const ws = &self.word;
        if (!ws.active or idx >= 64) return;
        const bit = @as(u64, 1) << @intCast(idx);
        if (ws.resolved & bit != 0) return;
        ws.resolved |= bit;
        ws.resolved_n += 1;
        if (hit) ws.hits += 1;
        if (self.hud.phrase) |*p| {
            if (!hit) p.missed |= bit;
        }
        self.syncPhrase();
        if (ws.resolved_n >= ws.count) self.completePhrase();
    }

    fn completePhrase(self: *Arcade) void {
        const ws = &self.word;
        if (ws.hits > 0) {
            const pts: u32 = 100 * @as(u32, ws.hits) * self.opts.speed;
            self.stats.score += pts;
            self.emit(.{ .phrase_done = .{ .points = pts } });
        }
        if (self.hud.phrase) |*p| {
            p.complete = true;
            p.done_upto = @intCast(p.text.len);
        }
        ws.holding = true;
        ws.hold_until = self.tick + @as(u64, @intFromFloat(ws.hold_s * @as(f64, @floatFromInt(TICK_HZ))));
    }

    /// Id of the word cap the player types next (0 if none).
    fn activeWordCap(self: *const Arcade) u32 {
        var best: ?*const Cap = null;
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.kind != .word or c.state != .falling) continue;
            if (best == null or c.word < best.?.word) best = c;
        }
        return if (best) |b| b.id else 0;
    }

    fn syncPhrase(self: *Arcade) void {
        const p = if (self.hud.phrase) |*ph| ph else return;
        if (p.complete) return;
        const ws = &self.word;
        const active = self.activeWordCap();
        var active_cap: ?*const Cap = null;
        for (self.cap_buf[0..self.cap_len]) |*c| {
            if (c.id == active and active != 0) active_cap = c;
        }
        // Active word: the lowest falling word, else the next to spawn.
        const idx: u8 = if (active_cap) |c| c.word else ws.next_word;
        p.word_index = idx;
        if (p.wordSpan(idx)) |span| {
            p.word_start = span.start;
            p.word_end = span.end;
            var done = span.start;
            if (active_cap) |c| {
                // Advance past `typed` letters (punctuation is skipped).
                var letters: u8 = 0;
                var pos = span.start;
                while (pos < span.end and letters < c.typed) : (pos += 1) {
                    if (levels.typesChar(p.text[pos], ws.code_line)) letters += 1;
                }
                done = pos;
            }
            p.done_upto = done;
        } else {
            p.word_start = @intCast(p.text.len);
            p.word_end = @intCast(p.text.len);
            p.done_upto = @intCast(p.text.len);
        }
    }

    // -----------------------------------------------------------------------
    // Title attract demo

    fn demoTarget(id: u32) f32 {
        var h: u32 = id *% 0x9E3779B1;
        h ^= h >> 15;
        return 0.25 + 0.45 * @as(f32, @floatFromInt(h & 0xffff)) / 65535.0;
    }

    fn stepTitle(self: *Arcade) void {
        self.demo_tick += 1;
        const now = @as(f64, @floatFromInt(self.demo_tick)) / @as(f64, @floatFromInt(TICK_HZ));
        var falling: usize = 0;
        for (self.cap_buf[0..self.cap_len]) |*c| falling += @intFromBool(c.state == .falling);
        if (now >= self.demo_next) {
            if (self.wordsGame()) {
                if (falling < 4) self.spawnDemoWord();
                self.demo_next = now + 0.8 + 0.8 * randF(&self.demo_rng);
            } else {
                if (falling < 6) {
                    const lvl: u8 = @intCast(self.demo_rng.range(9));
                    _ = self.spawnKeyCap(&self.demo_rng, lvl);
                }
                self.demo_next = now + 0.6 + 0.7 * randF(&self.demo_rng);
            }
        }
        const target: f32 = 1.0 / 4.5;
        for (self.cap_buf[0..self.cap_len]) |*c| {
            c.age += DT;
            if (c.state != .falling) {
                c.state_t += DT;
                continue;
            }
            c.speed += (target - c.speed) * EASE_PER_TICK;
            c.progress += c.speed * DT;
            if (c.progress >= demoTarget(c.id)) self.demoHit(c);
        }
        self.removeExpired();
        self.hud.banner_t += DT;
        self.hud.callout_t += DT;
    }

    /// Title attract for the Words game: a word plate (sometimes code, now
    /// and then a bonus vim cap).
    fn spawnDemoWord(self: *Arcade) void {
        if (self.cap_len >= self.cap_buf.len) return;
        const rng = &self.demo_rng;
        const roll = rng.range(100);
        if (roll < 12) {
            _ = self.spawnBonusCap(rng);
            return;
        }
        const code_word = roll < 35;
        const text = randomWord(rng, if (code_word) .code else .mixed_words);
        self.demo_word +%= 1;
        var c: Cap = .{
            .id = self.nextId(),
            .kind = .word,
            .len = 0,
            .x = 0.5,
            .hue = @floatCast(randF(rng)),
            .family = .words,
            .word = self.demo_word,
            .rarity = scoring.rarityFromRoll(randF(rng)),
        };
        if (code_word) {
            c.len = levels.identSteps(text, &c.steps);
            c.exact = words.hasUpper(text);
        } else {
            c.len = levels.wordSteps(text, &c.steps);
        }
        if (c.len == 0) return;
        c.x = self.placeX(rng, capWidthCells(&c));
        self.cap_buf[self.cap_len] = c;
        self.cap_len += 1;
    }

    fn demoHit(self: *Arcade, c: *Cap) void {
        for (c.stepSlice()) |s| self.emit(.{ .key_press = .{ .code = s.code, .mods = s.mods } });
        self.demo_combo += 1;
        const quick = c.progress < scoring.QUICK_PROGRESS;
        const mult = scoring.comboMult(self.demo_combo);
        const pts = scoring.points(scoring.basePoints(c), c.rarity, quick, mult, self.opts.speed);
        const effect = scoring.pickEffect(scoring.effectTier(c, self.demo_combo), self.last_effect, self.demo_rng.next());
        self.last_effect = effect;
        c.typed = c.len;
        c.state = .hit;
        c.state_t = 0;
        self.emit(.{ .hit = .{
            .cap_id = c.id,
            .x = c.x,
            .y = c.progress,
            .effect = effect,
            .points = pts,
            .quick = quick,
            .intensity = scoring.intensity(self.demo_combo, layout.keyCount(c), c.rarity, quick),
            .hue = c.hue,
            .rarity = c.rarity,
            .caption = c.caption,
            .kind = c.kind,
            .combo = self.demo_combo,
        } });
    }
};

fn speedIndex(speed: u8) usize {
    for (speeds, 0..) |s, i| {
        if (s == speed) return i;
    }
    return 0;
}

/// Snap an arbitrary multiplier down to a selectable one.
fn snapSpeed(speed: u8) u8 {
    var out: u8 = 1;
    for (speeds) |s| {
        if (s <= speed) out = s;
    }
    return out;
}

test {
    _ = @import("arcade_tests.zig");
}
