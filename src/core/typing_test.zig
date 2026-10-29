//! Typing test state machine: owns the word-by-word session (words,
//! sentences, code, custom, daily, zen), the vim editor (vim `.type` and
//! code with vim keys) or the drill session (vim `.drills`), the timer, and
//! the result computed once at finish.

const std = @import("std");
const time = @import("../platform/time.zig");

const content = @import("content.zig");
const types = @import("types.zig");
const Config = types.Config;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Edit = session_mod.Edit;
const Source = @import("source.zig").Source;
const stats = @import("stats.zig");
const daily = @import("daily.zig");
const syntax = @import("syntax.zig");
const Live = stats.Live;
const Result = stats.Result;

const Rng = @import("rng.zig").Rng;
const editor_mod = @import("../vim/editor.zig");
const VimEditor = editor_mod.VimEditor;
const FeedResult = editor_mod.FeedResult;
const VimKey = @import("../vim/key.zig").VimKey;
const drill_mod = @import("../vim/drill.zig");
const DrillSession = drill_mod.DrillSession;

pub const TestState = enum { waiting, typing, finished };

/// Each missed word appears this many times in a practice test.
const PRACTICE_REPEAT = 3;
/// Weak-key practice has at least this many words.
const WEAK_PRACTICE_MIN = 25;
/// Custom text is cut at this many bytes (after sanitizing).
pub const MAX_CUSTOM_BYTES: usize = 64 * 1024;

pub const TypingTest = struct {
    state: TestState,
    config: Config,
    start_time: ?i64,
    end_time: ?i64,
    allocator: std.mem.Allocator,
    /// Words / sentences / code (empty in vim mode).
    session: Session,
    /// Vim `.type`.
    vim: VimEditor,
    /// Vim `.drills`.
    drill: DrillSession,
    /// Vim `.type` target lines (ghost text), slices of `target_text`.
    target_lines: std.ArrayList([]const u8),
    /// Vim `.type` snippet (empty in the other modes).
    target_text: []u8 = &.{},

    seed: u64,
    pasted: bool = false,
    res: Result = undefined,
    has_result: bool = false,
    bufs: stats.Buffers = .{},
    /// Practice-missed list (owned words, shuffled); restartSame keeps it.
    practice_text: []u8 = &.{},
    practice_list: [][]const u8 = &.{},
    /// A weak-key practice test (unrecorded); restartSame keeps it.
    weak_practice: bool = false,
    /// Weak-key weights (focus == .weak and practiceWeak).
    weights: ?stats.KeyWeights = null,
    /// Sanitized custom text (owned; empty = the built-in sample).
    custom_text: []u8 = &.{},
    /// Language of the current code / vim-type text.
    code_lang: types.Lang = .mixed,
    /// The last handleEdit typed a wrong letter or skipped letters.
    last_wrong: bool = false,
    /// Per-key stats behind `Result.per_key` (heap: stable address).
    per_key: *stats.PerKey,

    pub fn init(allocator: std.mem.Allocator, seed: u64, config: Config) !TypingTest {
        var self: TypingTest = .{
            .state = .waiting,
            .config = config,
            .start_time = null,
            .end_time = null,
            .allocator = allocator,
            .session = try emptySession(allocator, seed, config),
            .vim = VimEditor.init(allocator, .{}),
            .drill = DrillSession.init(allocator),
            .target_lines = .empty,
            .seed = seed,
            .per_key = undefined,
        };
        self.per_key = allocator.create(stats.PerKey) catch |e| {
            self.session.deinit();
            self.vim.deinit();
            self.drill.deinit();
            return e;
        };
        errdefer self.deinit();
        try self.build();
        return self;
    }

    pub fn deinit(self: *TypingTest) void {
        self.session.deinit();
        self.vim.deinit();
        self.drill.deinit();
        self.target_lines.deinit(self.allocator);
        self.bufs.deinit(self.allocator);
        self.clearPractice();
        self.allocator.free(self.target_text);
        self.allocator.free(self.custom_text);
        self.allocator.destroy(self.per_key);
    }

    /// New text (vim drills: loads `config.drill_id` or the first drill).
    pub fn reset(self: *TypingTest, seed: u64) !void {
        self.clearPractice();
        self.seed = seed;
        try self.build();
    }

    /// Same text / challenge, fresh attempt.
    pub fn restartSame(self: *TypingTest) !void {
        try self.build();
    }

    /// A new test from the last result's missed words (each repeated 3
    /// times, shuffled with the seed). False if there were none.
    pub fn practiceMissed(self: *TypingTest) !bool {
        if (self.isVim()) return false;
        const r = self.result() orelse return false;
        if (r.missed_words.len == 0) return false;
        var total: usize = 0;
        for (r.missed_words) |w| total += w.len;
        const text = try self.allocator.alloc(u8, total);
        errdefer self.allocator.free(text);
        const list = try self.allocator.alloc([]const u8, r.missed_words.len * PRACTICE_REPEAT);
        var pos: usize = 0;
        for (r.missed_words, 0..) |w, i| {
            @memcpy(text[pos..][0..w.len], w);
            for (0..PRACTICE_REPEAT) |k| list[i * PRACTICE_REPEAT + k] = text[pos..][0..w.len];
            pos += w.len;
        }
        var rng = Rng.init(self.seed);
        var i = list.len;
        while (i > 1) {
            i -= 1;
            std.mem.swap([]const u8, &list[i], &list[rng.range(i + 1)]);
        }
        self.clearPractice();
        self.practice_text = text;
        self.practice_list = list;
        try self.build();
        return true;
    }

    /// One-off, unrecorded words test (config.word_count words, min 25)
    /// weighted toward weak keys. False when no weights are set.
    pub fn practiceWeak(self: *TypingTest) !bool {
        if (self.weights == null) return false;
        self.clearPractice();
        self.weak_practice = true;
        try self.build();
        return true;
    }

    /// Weights for focus == .weak and practiceWeak (copied; null clears).
    pub fn setWeakWeights(self: *TypingTest, w: ?*const stats.KeyWeights) void {
        self.weights = if (w) |p| p.* else null;
    }

    /// Sanitizes (CRLF/CR → LF, tab → 4 spaces, other control and non-ASCII
    /// bytes dropped, trailing blanks trimmed, ≤ MAX_CUSTOM_BYTES) and copies
    /// `text`; sets config.custom_hash. Takes effect on the next reset or
    /// restartSame.
    pub fn setCustomText(self: *TypingTest, text: []const u8) !void {
        const clean = try sanitizeCustom(self.allocator, text);
        self.allocator.free(self.custom_text);
        self.custom_text = clean;
        self.config.custom_hash = fnv1a(clean);
    }

    /// The sanitized custom text ("" when none: custom mode then types a
    /// built-in sample).
    pub fn customText(self: *const TypingTest) []const u8 {
        return self.custom_text;
    }

    /// Target characters a typist at `wpm` would have typed by now (elapsed
    /// × wpm × 5 / 60 000); null unless a simple mode (not zen) is typing.
    pub fn paceChars(self: *const TypingTest, now_ms: i64, wpm: f32) ?u64 {
        if (self.state != .typing or self.isVim() or self.isZen()) return null;
        if (!std.math.isFinite(wpm) or wpm <= 0) return null;
        const start = self.start_time orelse return null;
        var elapsed: i64 = @max(0, now_ms - start);
        if (self.limitMs()) |l| elapsed = @min(elapsed, l);
        const chars = @as(f64, @floatFromInt(elapsed)) * wpm * 5.0 / 60000.0;
        return @intFromFloat(@floor(chars));
    }

    /// The last handleEdit typed a wrong letter or skipped letters (web
    /// typing sounds).
    pub fn lastEditWrong(self: *const TypingTest) bool {
        return self.last_wrong;
    }

    /// Simple modes. The timer starts on the first letter.
    pub fn handleEdit(self: *TypingTest, edit: Edit, now_ms: i64) void {
        self.last_wrong = false;
        if (self.isVim() or self.state == .finished) return;
        self.tick(now_ms);
        if (self.state == .finished) return;
        if (self.state == .waiting) {
            const starts = switch (edit) {
                .char => |c| c != ' ',
                else => false,
            };
            if (!starts) return;
            self.state = .typing;
            self.start_time = now_ms;
        }
        const typed = self.session.log.typed;
        const correct = self.session.log.correct;
        self.session.apply(edit, self.msSinceStart(now_ms));
        self.last_wrong = self.session.log.typed - typed > self.session.log.correct - correct;
        if (self.session.isComplete()) self.finish(now_ms);
    }

    /// Vim modes (both kinds). The timer starts on any key.
    pub fn handleVimKey(self: *TypingTest, key: VimKey, now_ms: i64) FeedResult {
        if (!self.isVim() or self.state == .finished) return .{};
        self.tick(now_ms);
        if (self.state == .finished) return .{};
        if (self.state == .waiting) {
            self.state = .typing;
            self.start_time = now_ms;
        }
        if (self.vimKind() == .drills) {
            const r = self.drill.feed(key);
            if (self.drill.isSolved()) self.finish(now_ms);
            return r;
        }
        const r = self.vim.feed(key);
        if (self.vimTypeDone()) self.finish(now_ms);
        return r;
    }

    /// `:w` / `:wq` (and zen's Esc / Shift+Enter): a drill finishes only
    /// when solved ("not solved yet" otherwise → false); every other mode
    /// finishes now. False while waiting. True if finished.
    pub fn submit(self: *TypingTest, now_ms: i64) bool {
        if (self.state == .finished) return true;
        if (self.state == .waiting) return false;
        if (self.vimKind() == .drills and !self.drill.isSolved()) return false;
        self.finish(now_ms);
        return true;
    }

    pub fn notePaste(self: *TypingTest) void {
        self.pasted = true;
    }

    /// Ends timed tests (end clamped to start + limit). Vim drills have no
    /// time limit.
    pub fn tick(self: *TypingTest, now_ms: i64) void {
        if (self.state != .typing) return;
        const limit = self.limitMs() orelse return;
        const start = self.start_time orelse return;
        if (now_ms - start >= limit) self.finish(start + limit);
    }

    pub fn live(self: *const TypingTest, now_ms: i64) Live {
        const limit = self.limitMs();
        const total = !self.isVim() and !self.isZen() and limit == null;
        const start = self.start_time orelse return .{
            .remaining_ms = limit,
            .words_total = if (total) @intCast(self.session.wordCount()) else null,
        };
        const elapsed = @max(0, (self.end_time orelse now_ms) - start);
        if (!self.isVim()) {
            var l = stats.live(&self.session, elapsed, limit, total);
            if (self.isZen()) l.acc = zenAcc(&self.session);
            return l;
        }
        var l: Live = .{ .elapsed_ms = elapsed, .remaining_ms = if (limit) |m| @max(0, m - elapsed) else null };
        if (self.vimKind() == .drills) {
            l.keystrokes = self.drill.strokes();
        } else {
            const st = self.vim.stats();
            l.keystrokes = st.keystrokes;
            const matching = self.vim.buffer.countMatchingChars(self.target_lines.items).correct;
            if (elapsed >= 500) l.wpm = stats.perMinute(matching, elapsed);
            if (elapsed >= 500) l.raw = stats.perMinute(st.inserted, elapsed);
            l.acc = vimTypeAcc(self.target_text.len, st.inserted);
        }
        return l;
    }

    /// Non-null iff finished.
    pub fn result(self: *const TypingTest) ?*const Result {
        return if (self.has_result) &self.res else null;
    }

    /// .drills / .type in vim mode; .type in code mode with vim keys; null
    /// otherwise.
    pub fn vimKind(self: *const TypingTest) ?types.VimKind {
        return switch (self.config.mode) {
            .vim => self.config.vim_kind,
            .code => if (self.config.code_keys == .vim) .type else null,
            else => null,
        };
    }

    /// Keys go to a vim editor (vim mode, or code with vim keys).
    pub fn isVim(self: *const TypingTest) bool {
        return self.vimKind() != null;
    }

    pub fn isZen(self: *const TypingTest) bool {
        return self.config.mode == .zen;
    }

    /// Language of the current code / vim-type text (the language "mixed"
    /// picked); .mixed for drills and the other modes.
    pub fn codeLang(self: *const TypingTest) types.Lang {
        return self.code_lang;
    }

    /// A practice test (missed words or weak keys; not recorded: its result
    /// is not `valid`).
    pub fn isPractice(self: *const TypingTest) bool {
        return self.practice_list.len > 0 or self.weak_practice;
    }

    /// The editor keys go to: the drill's or the `.type` one.
    pub fn activeEditor(self: *TypingTest) *VimEditor {
        return if (self.vimKind() == .drills) &self.drill.editor else &self.vim;
    }

    // ---- kept API ----

    pub fn getWPM(self: *const TypingTest) f64 {
        const r = self.result() orelse return 0;
        return r.wpm;
    }

    pub fn getAccuracy(self: *const TypingTest) f64 {
        const r = self.result() orelse return 100;
        return r.acc;
    }

    pub fn getElapsedSeconds(self: *const TypingTest) f64 {
        const start = self.start_time orelse return 0;
        const end = self.end_time orelse time.milliTimestamp();
        const ms = end - start;
        return if (ms > 0) @as(f64, @floatFromInt(ms)) / 1000.0 else 0;
    }

    pub fn getRemainingSeconds(self: *const TypingTest) f64 {
        if (self.config.time_limit == 0) return 0;
        return @max(0, @as(f64, @floatFromInt(self.config.time_limit)) - self.getElapsedSeconds());
    }

    // ---- internals ----

    fn emptySession(allocator: std.mem.Allocator, seed: u64, config: Config) !Session {
        return Session.init(allocator, Source.init(seed, config, &.{}), .{});
    }

    fn limitMs(self: *const TypingTest) ?i64 {
        if (self.config.time_limit == 0) return null;
        if (self.vimKind() == .drills or self.isZen() or self.config.mode == .daily) return null;
        return @as(i64, @intCast(self.config.time_limit)) * 1000;
    }

    fn msSinceStart(self: *const TypingTest, now_ms: i64) u32 {
        const start = self.start_time orelse return 0;
        return @intCast(std.math.clamp(now_ms - start, 0, std.math.maxInt(u32)));
    }

    fn clearPractice(self: *TypingTest) void {
        self.allocator.free(self.practice_text);
        self.allocator.free(self.practice_list);
        self.practice_text = &.{};
        self.practice_list = &.{};
        self.weak_practice = false;
    }

    /// Strict policies (words, sentences, code, custom, daily).
    fn policy(self: *const TypingTest) session_mod.Policy {
        // Stop on a wrong word with no Backspace would leave no way out of
        // a wrong letter, so that pair stops on the letter instead.
        const stop = self.config.stop_on_error;
        const eff: types.StopOnError = if (stop == .word and self.config.no_backspace) .letter else stop;
        return .{ .stop_on_error = eff, .no_backspace = self.config.no_backspace };
    }

    /// The simple-mode session for the current config.
    fn buildSession(self: *TypingTest) !Session {
        const cfg = self.config;
        const words_n = std.math.clamp(cfg.word_count, types.MIN_WORDS, types.MAX_WORDS);
        // Practice lists replace the generator.
        if (self.practice_list.len > 0) {
            const src = Source.init(self.seed, cfg, self.practice_list);
            return Session.init(self.allocator, src, .{
                .endless = cfg.time_limit > 0 and cfg.mode != .daily,
                .min_words = std.math.maxInt(usize),
                .policy = self.policy(),
            });
        }
        if (self.weak_practice) {
            var wcfg: Config = .{ .mode = .words, .tier = cfg.tier, .word_count = @max(words_n, WEAK_PRACTICE_MIN) };
            wcfg.word_count = @min(wcfg.word_count, types.MAX_WORDS);
            var src = Source.init(self.seed, wcfg, null);
            src.weights = if (self.weights) |*w| w else null;
            return Session.init(self.allocator, src, .{ .min_words = wcfg.word_count, .policy = self.policy() });
        }
        switch (cfg.mode) {
            .zen => return Session.init(self.allocator, Source.init(self.seed, cfg, &.{}), .{ .zen = true }),
            .daily => {
                // Same text for everyone on a UTC date, whatever the words options.
                const dcfg: Config = .{ .mode = .words, .tier = .common, .punctuation = true, .numbers = false, .word_count = types.DAILY_WORDS };
                const src = Source.init(daily.seedFor(cfg.day), dcfg, null);
                return Session.init(self.allocator, src, .{ .min_words = types.DAILY_WORDS, .policy = self.policy() });
            },
            .custom => {
                var src = Source.init(self.seed, cfg, null);
                src.text = self.custom_text;
                const multi = std.mem.indexOfScalar(u8, src.customText(), '\n') != null;
                return Session.init(self.allocator, src, .{
                    .endless = cfg.time_limit > 0,
                    .min_words = std.math.maxInt(usize),
                    .policy = self.policy(),
                    .enter_skips_line = multi,
                    .lang = if (multi) syntax.guessCustomLang(src.customText()) else .mixed,
                });
            },
            else => {},
        }
        var src = Source.init(self.seed, cfg, null);
        if (cfg.mode == .words and cfg.focus == .weak) src.weights = if (self.weights) |*w| w else null;
        if (cfg.mode == .code) self.code_lang = src.code_lang;
        return Session.init(self.allocator, src, .{
            .endless = cfg.time_limit > 0,
            .min_words = words_n,
            .policy = self.policy(),
            .enter_skips_line = cfg.mode == .code,
            .lang = if (cfg.mode == .code and cfg.syntax) src.code_lang else .mixed,
        });
    }

    /// (Re)builds the test from `seed`, `config` and the practice list.
    fn build(self: *TypingTest) !void {
        self.state = .waiting;
        self.start_time = null;
        self.end_time = null;
        self.pasted = false;
        self.has_result = false;
        self.bufs.clear();
        self.target_lines.clearRetainingCapacity();
        self.allocator.free(self.target_text);
        self.target_text = &.{};

        self.per_key.* = .{};
        self.code_lang = .mixed;

        const cfg = self.config;
        const kind = self.vimKind();
        var next = switch (cfg.mode) {
            .words, .sentences, .code, .custom, .daily, .zen => if (kind == null)
                try self.buildSession()
            else
                try emptySession(self.allocator, self.seed, cfg),
            else => try emptySession(self.allocator, self.seed, cfg),
        };
        std.mem.swap(Session, &self.session, &next);
        next.deinit();

        if (cfg.mode == .code and kind == .type) {
            // Code with vim keys: retype ONE snippet of the code bank.
            var rng = Rng.init(self.seed);
            const lang = if (cfg.lang == .mixed) content.pickLang(&rng) else cfg.lang;
            self.code_lang = lang;
            self.target_text = try content.codeTarget(&rng, self.allocator, lang);
            var it = std.mem.splitScalar(u8, self.target_text, '\n');
            while (it.next()) |line| try self.target_lines.append(self.allocator, line);
            self.vim.reset();
        } else if (cfg.mode == .vim) {
            if (cfg.vim_kind == .drills) {
                if (drill_mod.all.len > 0) {
                    const first = &drill_mod.all[0];
                    const ch = if (cfg.drill_id) |id| drill_mod.byId(id) orelse first else first;
                    try self.drill.start(ch);
                }
            } else {
                var rng = Rng.init(self.seed);
                self.target_text = try content.vimTarget(&rng, self.allocator, cfg.lang);
                self.code_lang = if (cfg.lang == .mixed) syntax.guessLang(self.target_text) else cfg.lang;
                var it = std.mem.splitScalar(u8, self.target_text, '\n');
                while (it.next()) |line| try self.target_lines.append(self.allocator, line);
                self.vim.reset();
            }
        }
    }

    fn vimTypeDone(self: *const TypingTest) bool {
        return self.vim.buffer.matchesTarget(self.target_lines.items, self.target_text.len);
    }

    fn vimTypeAcc(target_len: usize, inserted: u32) f32 {
        if (target_len == 0) return 100;
        const t: f32 = @floatFromInt(target_len);
        return t / @max(t, @as(f32, @floatFromInt(inserted))) * 100;
    }

    fn finish(self: *TypingTest, end_ms: i64) void {
        if (self.state == .finished) return;
        const start = self.start_time orelse end_ms;
        var end = @max(end_ms, start);
        if (self.limitMs()) |l| end = @min(end, start + l);
        self.state = .finished;
        self.start_time = start;
        self.end_time = end;
        const duration: u32 = @intCast(@min(end - start, std.math.maxInt(u32)));
        // Practice runs (missed words, weak keys) never count towards
        // history or PBs.
        self.res = if (!self.isVim())
            self.simpleResult(duration)
        else if (self.vimKind() == .drills)
            self.drillResult(duration)
        else
            self.vimTypeResult(duration);
        self.has_result = true;
    }

    fn simpleResult(self: *TypingTest, duration: u32) Result {
        var r = stats.typingResult(&self.session, duration, self.pasted or self.isPractice(), &self.bufs, self.allocator);
        if (self.isZen()) {
            r.acc = zenAcc(&self.session);
        } else {
            self.per_key.* = self.session.per_key;
            r.per_key = self.per_key;
        }
        return r;
    }

    /// Zen accuracy: keystrokes kept / typed (100 unless something was
    /// deleted).
    fn zenAcc(s: *const Session) f32 {
        if (s.log.typed == 0) return 100;
        const kept: f32 = @floatFromInt(s.log.typed -| s.log.corrected);
        return kept / @as(f32, @floatFromInt(s.log.typed)) * 100;
    }

    fn baseResult(kind: stats.ResultKind, duration: u32) Result {
        return .{
            .kind = kind,
            .wpm = 0,
            .raw = 0,
            .acc = 100,
            .consistency = null,
            .chars = .{},
            .corrected = 0,
            .keystrokes = 0,
            .duration_ms = duration,
            .series = &.{},
            .missed_words = &.{},
            .slow_words = &.{},
            .valid = false,
        };
    }

    fn vimTypeResult(self: *TypingTest, duration: u32) Result {
        const st = self.vim.stats();
        const target_len = self.target_text.len;
        const m = self.vim.buffer.countMatchingChars(self.target_lines.items);
        var r = baseResult(.vim_type, duration);
        // Target characters typed right (all of them on an exact match).
        const done = if (self.vimTypeDone()) target_len else m.correct;
        r.wpm = stats.perMinute(done, duration);
        r.raw = stats.perMinute(st.inserted, duration);
        r.acc = vimTypeAcc(target_len, st.inserted);
        r.chars = .{ .correct = @intCast(done), .incorrect = @intCast(m.errors), .missed = @intCast(target_len -| @max(done, m.total)) };
        r.keystrokes = st.keystrokes;
        r.strokes = st.keystrokes;
        // Target characters produced per keystroke: an early `:w` with
        // nothing typed scores 0, not target_len / 3.
        r.efficiency = if (st.keystrokes > 0) @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(st.keystrokes)) else 0;
        r.valid = duration >= 1000 and !self.pasted;
        return r;
    }

    fn drillResult(self: *TypingTest, duration: u32) Result {
        var r = baseResult(.vim_drill, duration);
        const strokes = self.drill.strokes();
        r.strokes = strokes;
        r.keystrokes = strokes;
        r.hinted = self.drill.hinted();
        if (self.drill.challenge) |ch| {
            r.par = ch.par;
            r.drill_id = ch.id;
            if (self.drill.isSolved()) r.stars = drill_mod.stars(strokes, ch.par, r.hinted);
            r.efficiency = if (strokes > 0) @as(f32, @floatFromInt(ch.par)) / @as(f32, @floatFromInt(strokes)) else 0;
        }
        r.valid = self.drill.isSolved();
        return r;
    }
};

/// FNV-1a 32 (custom text hash for its PB key).
pub fn fnv1a(bytes: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

/// Custom text cleanup: CRLF/CR → LF, tab → 4 spaces, other control and
/// non-ASCII bytes dropped, trailing blanks of every line and blank lines
/// at the end trimmed, cut to MAX_CUSTOM_BYTES (at a line or word break
/// when possible). Caller owns the result.
pub fn sanitizeCustom(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len and out.items.len < MAX_CUSTOM_BYTES) : (i += 1) {
        const c = text[i];
        switch (c) {
            '\r' => {
                trimTrailing(&out);
                try out.append(allocator, '\n');
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            },
            '\n' => {
                trimTrailing(&out);
                try out.append(allocator, '\n');
            },
            '\t' => try out.appendSlice(allocator, "    "),
            0x20...0x7e => try out.append(allocator, c),
            else => {},
        }
    }
    if (out.items.len > MAX_CUSTOM_BYTES) out.shrinkRetainingCapacity(MAX_CUSTOM_BYTES);
    if (i < text.len) {
        // Cut: don't end inside a word.
        if (std.mem.lastIndexOfAny(u8, out.items, " \n")) |cut| out.shrinkRetainingCapacity(cut);
    }
    // Trailing blanks and blank lines; leading blank lines too.
    const trimmed_end = std.mem.trimEnd(u8, out.items, " \n");
    out.shrinkRetainingCapacity(trimmed_end.len);
    var lead: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out.items, lead, '\n')) |nl| {
        if (std.mem.trim(u8, out.items[lead..nl], " ").len != 0) break;
        lead = nl + 1;
    }
    if (lead > 0) out.replaceRangeAssumeCapacity(0, lead, &.{});
    return out.toOwnedSlice(allocator);
}

fn trimTrailing(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
}

// ---- tests ----

const testing = std.testing;

fn joinTargets(t: *const TypingTest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..t.session.wordCount()) |i| {
        try out.appendSlice(testing.allocator, t.session.targetOf(i));
        try out.append(testing.allocator, ' ');
    }
    return out.toOwnedSlice(testing.allocator);
}

fn typeTarget(t: *TypingTest, now: *i64, words: usize) void {
    for (0..words) |_| {
        const s = &t.session;
        if (s.isComplete()) return;
        for (s.targetOf(s.activeIndex())) |c| {
            now.* += 50;
            t.handleEdit(.{ .char = c }, now.*);
        }
        now.* += 50;
        t.handleEdit(.{ .char = ' ' }, now.*);
    }
}

test "timed tests never run out of words and end clamped to the limit" {
    var t = try TypingTest.init(testing.allocator, 7, .{ .mode = .words, .word_count = 10, .time_limit = 15 });
    defer t.deinit();
    var now: i64 = 1_000_000;
    // 200 words at a key every 50 ms is over a minute of typing; the limit
    // ends it, never the words running out.
    t.handleEdit(.{ .char = t.session.targetOf(0)[0] }, now);
    for (0..200) |_| {
        if (t.state == .finished) break;
        const s = &t.session;
        const target = s.targetOf(s.activeIndex());
        for (target[s.word(s.activeIndex()).typed.len..]) |c| {
            now += 5;
            t.handleEdit(.{ .char = c }, now);
        }
        now += 5;
        t.handleEdit(.{ .char = ' ' }, now);
        try testing.expect(!t.session.isComplete());
    }
    try testing.expectEqual(TestState.typing, t.state);
    try testing.expect(t.session.wordCount() > 200);
    now += 20_000; // a late tick
    t.tick(now);
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expectEqual(@as(i64, 15_000), t.end_time.? - t.start_time.?);
    const r = t.result().?;
    try testing.expectEqual(@as(u32, 15_000), r.duration_ms);
    try testing.expect(r.valid);
    try testing.expectEqual(@as(?u32, null), t.live(now).words_total);
}

test "keys after the time limit are not counted" {
    var t = try TypingTest.init(testing.allocator, 3, .{ .mode = .words, .time_limit = 15 });
    defer t.deinit();
    t.handleEdit(.{ .char = 'x' }, 0);
    t.handleEdit(.{ .char = 'y' }, 16_000);
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expectEqual(@as(u32, 1), t.session.log.typed);
}

test "untimed word count is exact and not capped at 50" {
    var t = try TypingTest.init(testing.allocator, 11, .{ .mode = .words, .word_count = 120 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 120), t.session.wordCount());
    try t.reset(12);
    try testing.expectEqual(@as(usize, 120), t.session.wordCount());
    var now: i64 = 0;
    typeTarget(&t, &now, 120);
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expectEqual(@as(f32, 100), t.result().?.acc);
}

test "the timer starts on the first letter; result only once finished" {
    var t = try TypingTest.init(testing.allocator, 5, .{ .mode = .words, .word_count = 3 });
    defer t.deinit();
    t.handleEdit(.{ .char = ' ' }, 10);
    t.handleEdit(.backspace, 20);
    try testing.expectEqual(TestState.waiting, t.state);
    try testing.expect(t.result() == null);
    var now: i64 = 100;
    typeTarget(&t, &now, 3);
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expect(t.result() != null);
    try testing.expectEqual(t.result().?.wpm, @as(f32, @floatCast(t.getWPM())));
    // Keys after the end are ignored.
    t.handleEdit(.{ .char = 'a' }, now + 10);
    try testing.expectEqual(TestState.finished, t.state);
}

test "restartSame gives an identical target; reset a new one" {
    var t = try TypingTest.init(testing.allocator, 99, .{ .mode = .words, .word_count = 25, .punctuation = true });
    defer t.deinit();
    const before = try joinTargets(&t);
    defer testing.allocator.free(before);
    var now: i64 = 0;
    typeTarget(&t, &now, 4);
    try t.restartSame();
    try testing.expectEqual(TestState.waiting, t.state);
    const same = try joinTargets(&t);
    defer testing.allocator.free(same);
    try testing.expectEqualStrings(before, same);
    try testing.expectEqual(@as(usize, 0), t.session.activeIndex());
    try testing.expectEqualStrings("", t.session.word(0).typed);
    try t.reset(100);
    const other = try joinTargets(&t);
    defer testing.allocator.free(other);
    try testing.expect(!std.mem.eql(u8, before, other));
}

test "practiceMissed builds a test from missed words" {
    const list = [_][]const u8{ "alpha", "beta", "gamma" };
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .words, .word_count = 3 });
    defer t.deinit();
    try testing.expect(!try t.practiceMissed()); // no result yet
    // Swap in a known text.
    var next = try Session.init(testing.allocator, Source.init(1, t.config, &list), .{ .min_words = 10 });
    std.mem.swap(Session, &t.session, &next);
    next.deinit();
    var now: i64 = 0;
    for ("alpx beta gamm ") |c| {
        now += 100;
        t.handleEdit(.{ .char = c }, now);
    }
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expectEqual(@as(usize, 2), t.result().?.missed_words.len);
    try testing.expect(try t.practiceMissed());
    try testing.expect(t.isPractice());
    try testing.expectEqual(TestState.waiting, t.state);
    try testing.expectEqual(@as(usize, 6), t.session.wordCount());
    var alpha: usize = 0;
    for (0..6) |i| {
        const w = t.session.targetOf(i);
        try testing.expect(std.mem.eql(u8, w, "alpha") or std.mem.eql(u8, w, "gamma"));
        if (std.mem.eql(u8, w, "alpha")) alpha += 1;
    }
    try testing.expectEqual(@as(usize, 3), alpha);
    // restartSame keeps the practice list; reset drops it.
    try t.restartSame();
    try testing.expectEqual(@as(usize, 6), t.session.wordCount());
    for (0..6) |i| {
        for (t.session.targetOf(i)) |c| {
            now += 300;
            t.handleEdit(.{ .char = c }, now);
        }
        now += 300;
        t.handleEdit(.{ .char = ' ' }, now);
    }
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expect(!t.result().?.valid);
    try t.reset(2);
    try testing.expect(!t.isPractice());
    try testing.expectEqual(@as(usize, 3), t.session.wordCount());
    // A perfect run has nothing to practise.
    typeTarget(&t, &now, 3);
    try testing.expect(!try t.practiceMissed());
}

test "a paste marks the run invalid" {
    var t = try TypingTest.init(testing.allocator, 5, .{ .mode = .words, .word_count = 2 });
    defer t.deinit();
    t.notePaste();
    var now: i64 = 0;
    for (0..2) |_| {
        const s = &t.session;
        for (s.targetOf(s.activeIndex())) |c| {
            now += 400;
            t.handleEdit(.{ .char = c }, now);
        }
        now += 400;
        t.handleEdit(.{ .char = ' ' }, now);
    }
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expect(!t.result().?.valid);
}

test "code mode is multi-line and finishes on the last word" {
    var t = try TypingTest.init(testing.allocator, 4, .{ .mode = .code, .lang = .python, .word_count = 5 });
    defer t.deinit();
    var newlines: usize = 0;
    for (0..t.session.wordCount()) |i| {
        if (t.session.word(i).sep == .newline) newlines += 1;
    }
    try testing.expect(newlines >= 2);
    var now: i64 = 0;
    while (t.state != .finished) {
        const s = &t.session;
        const i = s.activeIndex();
        for (s.targetOf(i)) |c| {
            now += 30;
            t.handleEdit(.{ .char = c }, now);
        }
        if (t.state == .finished) break;
        now += 30;
        t.handleEdit(if (s.word(i).sep == .newline) .newline else .{ .char = ' ' }, now);
    }
    const r = t.result().?;
    try testing.expectEqual(@as(f32, 100), r.acc);
    try testing.expectEqual(@as(u32, 0), r.chars.missed + r.chars.incorrect + r.chars.extra);
}

test "sentences carry the quote attribution" {
    var found = false;
    for (0..20) |seed| {
        var t = try TypingTest.init(testing.allocator, seed, .{ .mode = .sentences, .word_count = 1 });
        defer t.deinit();
        var now: i64 = 0;
        typeTarget(&t, &now, 100);
        try testing.expectEqual(TestState.finished, t.state);
        if (t.result().?.quote_by) |by| {
            try testing.expect(by.len > 0);
            found = true;
        }
    }
    try testing.expect(found);
}

test "vim type: retype the snippet, keystrokes and efficiency recorded" {
    var t = try TypingTest.init(testing.allocator, 2, .{ .mode = .vim, .vim_kind = .type, .lang = .zig });
    defer t.deinit();
    try testing.expect(t.isVim());
    try testing.expect(t.activeEditor() == &t.vim);
    var now: i64 = 0;
    _ = t.handleVimKey(.{ .char = 'i' }, now);
    for (t.target_text) |c| {
        now += 20;
        _ = t.handleVimKey(if (c == '\n') .enter else .{ .char = c }, now);
        if (t.state == .finished) break;
    }
    if (t.state != .finished) {
        // Auto-indent may differ from the snippet; then submit with :w.
        try testing.expect(t.submit(now));
    }
    const r = t.result().?;
    try testing.expectEqual(stats.ResultKind.vim_type, r.kind);
    try testing.expect(r.keystrokes > 0);
    try testing.expect(r.efficiency > 0);
    // Simple-mode edits are ignored in vim mode.
    t.handleEdit(.{ .char = 'x' }, now);
}

test "vim type: an early :w with nothing typed scores 0 efficiency" {
    var t = try TypingTest.init(testing.allocator, 2, .{ .mode = .code, .code_keys = .vim, .lang = .go });
    defer t.deinit();
    for (":w") |c| _ = t.handleVimKey(.{ .char = c }, 0);
    _ = t.handleVimKey(.enter, 1500);
    try testing.expect(t.submit(1500));
    const r = t.result().?;
    try testing.expectEqual(@as(f32, 0), r.efficiency);
    try testing.expectEqual(@as(f32, 0), r.wpm);
}

test "stop on a wrong word with no backspace stops on the letter instead" {
    var t = try TypingTest.init(testing.allocator, 3, .{ .mode = .words, .stop_on_error = .word, .no_backspace = true });
    defer t.deinit();
    const target = t.session.targetOf(0);
    const wrong: u8 = if (target[0] == 'q') 'z' else 'q';
    t.handleEdit(.{ .char = wrong }, 0);
    // The wrong letter is not inserted, so the word can still be typed.
    try testing.expectEqual(@as(usize, 0), t.session.typedOf(0).len);
    for (target) |c| t.handleEdit(.{ .char = c }, 10);
    t.handleEdit(.{ .char = ' ' }, 20);
    try testing.expectEqual(@as(usize, 1), t.session.activeIndex());
}

test "vim drill wrapper: reference solutions finish with 3 stars" {
    // The first 3 challenges (fewer while stream A is still adding them).
    if (drill_mod.all.len == 0) return error.SkipZigTest;
    for (drill_mod.all[0..@min(3, drill_mod.all.len)]) |*ch| {
        var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .vim, .vim_kind = .drills, .drill_id = ch.id });
        defer t.deinit();
        try testing.expect(t.activeEditor() == &t.drill.editor);
        try testing.expectEqualStrings(ch.id, t.drill.challenge.?.id);
        var notes = @import("../vim/key.zig").Notation.init(ch.solutions[0]);
        var now: i64 = 0;
        while (notes.next()) |k| {
            now += 100;
            _ = t.handleVimKey(k, now);
        }
        try testing.expectEqual(TestState.finished, t.state);
        const r = t.result().?;
        try testing.expectEqual(stats.ResultKind.vim_drill, r.kind);
        try testing.expectEqual(@as(u2, 3), r.stars);
        try testing.expectEqual(ch.par, r.par);
        try testing.expectEqualStrings(ch.id, r.drill_id.?);
        // tick never ends a drill.
        t.tick(now + 1_000_000);
        // restartSame reloads the same challenge.
        try t.restartSame();
        try testing.expectEqual(TestState.waiting, t.state);
        try testing.expectEqualStrings(ch.id, t.drill.challenge.?.id);
    }
}

test "vim drills default to the first challenge and ignore the time limit" {
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .vim, .time_limit = 15, .drill_id = "no/such-drill" });
    defer t.deinit();
    try testing.expectEqualStrings(drill_mod.all[0].id, t.drill.challenge.?.id);
    _ = t.handleVimKey(.{ .char = 'l' }, 0);
    t.tick(60_000);
    try testing.expectEqual(TestState.typing, t.state);
    try testing.expect(!t.submit(60_000)); // not solved yet
}

test "vimKind for every mode, kind and keys combination" {
    for (std.meta.tags(types.Mode)) |mode| {
        for (std.meta.tags(types.VimKind)) |vk| {
            for (std.meta.tags(types.CodeKeys)) |keys| {
                if (mode == .arcade) continue;
                var t = try TypingTest.init(testing.allocator, 3, .{ .mode = mode, .vim_kind = vk, .code_keys = keys });
                defer t.deinit();
                const want: ?types.VimKind = switch (mode) {
                    .vim => vk,
                    .code => if (keys == .vim) .type else null,
                    else => null,
                };
                try testing.expectEqual(want, t.vimKind());
                try testing.expectEqual(want != null, t.isVim());
                try testing.expectEqual(mode == .zen, t.isZen());
                const editor = t.activeEditor();
                try testing.expect(editor == if (want == .drills) &t.drill.editor else &t.vim);
            }
        }
    }
}

test "code with vim keys retypes one code snippet as vim type" {
    var t = try TypingTest.init(testing.allocator, 6, .{ .mode = .code, .code_keys = .vim, .lang = .go, .time_limit = 0 });
    defer t.deinit();
    try testing.expectEqual(types.Lang.go, t.codeLang());
    var found = false;
    for (content.codeSnippets(.go)) |snip| found = found or std.mem.eql(u8, snip, t.target_text);
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 0), t.session.wordCount());
    // Retype it in insert mode (autoindent may differ: then :w submits).
    var now: i64 = 0;
    _ = t.handleVimKey(.{ .char = 'i' }, now);
    for (t.target_text) |c| {
        now += 20;
        _ = t.handleVimKey(if (c == '\n') .enter else .{ .char = c }, now);
        if (t.state == .finished) break;
    }
    if (t.state != .finished) try testing.expect(t.submit(now));
    const r = t.result().?;
    try testing.expectEqual(stats.ResultKind.vim_type, r.kind);
    try testing.expect(r.per_key == null);
    var key_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("code|go|vim", @import("history.zig").pbKey(t.config, &key_buf));
    // Mixed picks a concrete language, the same one on restartSame.
    var m = try TypingTest.init(testing.allocator, 9, .{ .mode = .code, .code_keys = .vim });
    defer m.deinit();
    const lang = m.codeLang();
    try testing.expect(lang != .mixed);
    const text = try testing.allocator.dupe(u8, m.target_text);
    defer testing.allocator.free(text);
    try m.restartSame();
    try testing.expectEqual(lang, m.codeLang());
    try testing.expectEqualStrings(text, m.target_text);
    // Simple-mode edits are ignored.
    m.handleEdit(.{ .char = 'x' }, 0);
    try testing.expectEqual(TestState.waiting, m.state);
}

test "code+vim retype finishes on an exact match" {
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .code, .code_keys = .vim, .lang = .yaml });
    defer t.deinit();
    // Each line: open it with `o`, clear what autoindent put there (`0D`),
    // then append the exact line.
    var now: i64 = 0;
    var first = true;
    var it = std.mem.splitScalar(u8, t.target_text, '\n');
    while (it.next()) |line| {
        if (first) {
            _ = t.handleVimKey(.{ .char = 'i' }, now);
            first = false;
        } else {
            _ = t.handleVimKey(.esc, now);
            _ = t.handleVimKey(.{ .char = 'o' }, now);
            _ = t.handleVimKey(.esc, now);
            _ = t.handleVimKey(.{ .char = '0' }, now);
            _ = t.handleVimKey(.{ .char = 'D' }, now);
            _ = t.handleVimKey(.{ .char = 'a' }, now);
        }
        for (line) |c| {
            now += 30;
            _ = t.handleVimKey(.{ .char = c }, now);
        }
    }
    _ = t.handleVimKey(.esc, now + 30);
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expectEqual(stats.ResultKind.vim_type, t.result().?.kind);
    try testing.expect(t.result().?.wpm > 0);
}

test "Enter mid-line is wired for code mode and lowers accuracy by one key" {
    var t = try TypingTest.init(testing.allocator, 4, .{ .mode = .code, .lang = .python, .word_count = 3 });
    defer t.deinit();
    try testing.expect(t.session.opts.enter_skips_line);
    try testing.expectEqual(t.codeLang(), t.session.opts.lang);
    var now: i64 = 0;
    const first = t.session.targetOf(0);
    t.handleEdit(.{ .char = first[0] }, now);
    now += 100;
    t.handleEdit(.newline, now);
    try testing.expect(t.lastEditWrong() == (t.session.word(0).sep != .newline or first.len > 1));
    try testing.expectApproxEqAbs(@as(f32, 50), t.live(now).acc, 0.01);
    var w = try TypingTest.init(testing.allocator, 4, .{ .mode = .words });
    defer w.deinit();
    try testing.expect(!w.session.opts.enter_skips_line);
    // Syntax off: no colours.
    var p = try TypingTest.init(testing.allocator, 4, .{ .mode = .code, .lang = .zig, .syntax = false });
    defer p.deinit();
    try testing.expectEqual(types.Lang.mixed, p.session.opts.lang);
    try testing.expectEqual(types.Lang.zig, p.codeLang());
}

test "paceChars: elapsed x wpm x 5 / 60000, simple modes while typing" {
    var t = try TypingTest.init(testing.allocator, 2, .{ .mode = .words, .word_count = 25, .time_limit = 30 });
    defer t.deinit();
    try testing.expect(t.paceChars(1000, 60) == null); // waiting
    t.handleEdit(.{ .char = t.session.targetOf(0)[0] }, 10_000);
    try testing.expectEqual(@as(?u64, 0), t.paceChars(10_000, 60));
    try testing.expectEqual(@as(?u64, 50), t.paceChars(20_000, 60)); // 10 s at 60 wpm
    try testing.expectEqual(@as(?u64, 150), t.paceChars(10_000 + 99_000, 60)); // clamped to 30 s
    try testing.expect(t.paceChars(20_000, 0) == null);
    const loc = t.session.locate(t.paceChars(20_000, 60).?);
    try testing.expect(loc.word < t.session.wordCount());
    var z = try TypingTest.init(testing.allocator, 2, .{ .mode = .zen });
    defer z.deinit();
    z.handleEdit(.{ .char = 'a' }, 0);
    try testing.expect(z.paceChars(5000, 60) == null);
}

test "custom text: sanitizing and hash" {
    const clean = try sanitizeCustom(testing.allocator, "\r\n\n  Hello\tworld  \r\nsecond\rline\x01\xc3\xa9 \n\n\n");
    defer testing.allocator.free(clean);
    try testing.expectEqualStrings("  Hello    world\nsecond\nline", clean);
    try testing.expectEqual(@as(u32, 0x811c9dc5), fnv1a(""));
    try testing.expectEqual(@as(u32, 0xe40c292c), fnv1a("a"));
    // Size cap, cut at a word break.
    const big = try testing.allocator.alloc(u8, MAX_CUSTOM_BYTES + 100);
    defer testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 6 == 5) ' ' else 'x';
    const cut = try sanitizeCustom(testing.allocator, big);
    defer testing.allocator.free(cut);
    try testing.expect(cut.len <= MAX_CUSTOM_BYTES and cut.len > MAX_CUSTOM_BYTES - 10);
    try testing.expect(cut[cut.len - 1] == 'x');
    const blank = try sanitizeCustom(testing.allocator, " \t\n\x00 ");
    defer testing.allocator.free(blank);
    try testing.expectEqualStrings("", blank);
}

test "custom mode: untimed once, timed repeats, multi-line uses Enter, sample" {
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .custom });
    defer t.deinit();
    // No text yet: the sample, never a crash.
    try testing.expectEqualStrings("", t.customText());
    try testing.expect(t.session.wordCount() > 10);
    try t.setCustomText("one two\nthree");
    try testing.expectEqual(fnv1a("one two\nthree"), t.config.custom_hash);
    try t.restartSame();
    try testing.expectEqual(@as(usize, 3), t.session.wordCount());
    try testing.expect(t.session.opts.enter_skips_line);
    var now: i64 = 0;
    for ("one\nthree") |c| {
        now += 100;
        t.handleEdit(if (c == '\n') .newline else .{ .char = c }, now);
    }
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expectEqual(@as(u32, 3), t.result().?.chars.missed);
    var key_buf: [64]u8 = undefined;
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "custom|{x:0>8}|all", .{fnv1a("one two\nthree")}), @import("history.zig").pbKey(t.config, &key_buf));

    t.config.time_limit = 15;
    try t.reset(5);
    try testing.expect(t.session.wordCount() > 30); // repeated
    try testing.expectEqualStrings("one", t.session.targetOf(3));
    try testing.expectEqual(session_mod.Sep.newline, t.session.word(2).sep); // joined by a line break
    // Practice missed works in custom mode too.
    try t.setCustomText("alpha beta");
    t.config.time_limit = 0;
    try t.reset(5);
    for ("alphx beta") |c| {
        now += 100;
        t.handleEdit(.{ .char = c }, now);
    }
    try testing.expectEqual(TestState.finished, t.state);
    try testing.expect(try t.practiceMissed());
    try testing.expectEqual(@as(usize, 3), t.session.wordCount());
}

test "per-key stats reach the result; weak practice favours weak keys" {
    var t = try TypingTest.init(testing.allocator, 8, .{ .mode = .words, .word_count = 10 });
    defer t.deinit();
    try testing.expect(!try t.practiceWeak()); // no weights yet
    var now: i64 = 0;
    typeTarget(&t, &now, 10);
    const r = t.result().?;
    const pk = r.per_key.?;
    var letters: u32 = 0;
    for (0..t.session.wordCount()) |i| letters += @intCast(t.session.targetOf(i).len);
    try testing.expectEqual(letters, pk.total().hits);
    try testing.expectEqual(@as(u32, 0), pk.total().misses);

    var w: stats.KeyWeights = @splat(1);
    w[stats.keyIndex('q').?] = 40;
    w[stats.keyIndex('x').?] = 40;
    t.setWeakWeights(&w);
    t.config.word_count = 10;
    try testing.expect(try t.practiceWeak());
    try testing.expect(t.isPractice());
    try testing.expectEqual(@as(usize, 25), t.session.wordCount()); // at least 25
    var heavy: usize = 0;
    var plain_heavy: usize = 0;
    var plain = try TypingTest.init(testing.allocator, 8, .{ .mode = .words, .word_count = 250 });
    defer plain.deinit();
    t.config.word_count = 250;
    try testing.expect(try t.practiceWeak());
    for (0..250) |i| {
        heavy += std.mem.count(u8, t.session.targetOf(i), "q") + std.mem.count(u8, t.session.targetOf(i), "x");
        plain_heavy += std.mem.count(u8, plain.session.targetOf(i), "q") + std.mem.count(u8, plain.session.targetOf(i), "x");
    }
    try testing.expect(heavy > plain_heavy * 2);
    // Unrecorded; restartSame keeps it; reset drops it.
    try t.restartSame();
    try testing.expect(t.isPractice());
    now += 1000;
    typeTarget(&t, &now, 250);
    try testing.expect(!t.result().?.valid);
    try t.reset(9);
    try testing.expect(!t.isPractice());
    // focus = weak: recorded words with the same weighting.
    t.config.focus = .weak;
    try t.reset(9);
    try testing.expect(!t.isPractice());
    try testing.expect(t.session.src.weights != null);
    t.setWeakWeights(null);
    try t.reset(9);
    try testing.expect(t.session.src.weights == null);
}

test "zen: free typing, submit finishes, no word count or time limit" {
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .zen, .time_limit = 15, .word_count = 3 });
    defer t.deinit();
    try testing.expect(!t.submit(0)); // waiting
    var now: i64 = 0;
    for ("hello world foo bar baz qux\nnext lne") |c| {
        now += 120;
        t.handleEdit(if (c == '\n') .newline else .{ .char = c }, now);
    }
    t.handleEdit(.backspace, now);
    t.handleEdit(.backspace, now);
    for ("ine") |c| {
        now += 120;
        t.handleEdit(.{ .char = c }, now);
    }
    t.tick(now + 60_000);
    try testing.expectEqual(TestState.typing, t.state);
    try testing.expect(t.live(now).words_total == null);
    try testing.expect(t.submit(now));
    const r = t.result().?;
    try testing.expectEqual(stats.ResultKind.typing, r.kind);
    try testing.expect(r.per_key == null);
    try testing.expect(r.wpm > 0 and r.raw >= r.wpm);
    try testing.expect(r.acc < 100 and r.acc > 90);
    try testing.expectEqual(@as(u32, 0), r.chars.incorrect + r.chars.missed);
    var pb = @import("history.zig").PbTable.init(testing.allocator);
    defer pb.deinit();
    try testing.expectEqual(@import("history.zig").PbOutcome.none, pb.submit(t.config, r));
}

test "daily: same text for a date, different the next day" {
    const day: u32 = 20754; // 2026-10-28
    var a = try TypingTest.init(testing.allocator, 1, .{ .mode = .daily, .day = day, .tier = .easy, .numbers = true, .word_count = 7 });
    defer a.deinit();
    var b = try TypingTest.init(testing.allocator, 999, .{ .mode = .daily, .day = day, .time_limit = 30 });
    defer b.deinit();
    try testing.expectEqual(types.DAILY_WORDS, a.session.wordCount());
    const ta = try joinTargets(&a);
    defer testing.allocator.free(ta);
    const tb = try joinTargets(&b);
    defer testing.allocator.free(tb);
    try testing.expectEqualStrings(ta, tb);
    try testing.expect(std.ascii.isUpper(ta[0]));
    try a.restartSame();
    const tc = try joinTargets(&a);
    defer testing.allocator.free(tc);
    try testing.expectEqualStrings(ta, tc);
    a.config.day = day + 1;
    try a.reset(1);
    const td = try joinTargets(&a);
    defer testing.allocator.free(td);
    try testing.expect(!std.mem.eql(u8, ta, td));
    var key_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("daily|2026-10-28", @import("history.zig").pbKey(b.config, &key_buf));
    // Untimed even with a time limit set.
    var now: i64 = 0;
    b.handleEdit(.{ .char = b.session.targetOf(0)[0] }, now);
    now += 100_000;
    b.tick(now);
    try testing.expectEqual(TestState.typing, b.state);
}

test "zen ends by itself at the word cap; lastEditWrong flags errors" {
    var t = try TypingTest.init(testing.allocator, 1, .{ .mode = .zen });
    defer t.deinit();
    var now: i64 = 0;
    var n: usize = 0;
    while (t.state != .finished) : (n += 1) {
        now += 10;
        t.handleEdit(.{ .char = 'a' }, now);
        t.handleEdit(.{ .char = ' ' }, now);
        try testing.expect(!t.lastEditWrong());
    }
    try testing.expectEqual(session_mod.ZEN_MAX_WORDS, n);
    try testing.expect(t.result().?.valid);

    var w = try TypingTest.init(testing.allocator, 1, .{ .mode = .words, .word_count = 5 });
    defer w.deinit();
    const target = w.session.targetOf(0);
    w.handleEdit(.{ .char = target[0] }, 0);
    try testing.expect(!w.lastEditWrong());
    w.handleEdit(.{ .char = '#' }, 10);
    try testing.expect(w.lastEditWrong());
    w.handleEdit(.backspace, 20);
    try testing.expect(!w.lastEditWrong());
    w.handleEdit(.{ .char = ' ' }, 30); // skipped letters
    try testing.expect(w.lastEditWrong() == (target.len > 1));
}
