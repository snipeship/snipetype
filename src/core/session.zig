//! Word-by-word typing engine (words, sentences and code modes).
//!
//! The target is a list of words split on spaces and newlines. Each word has
//! its own typed text, so an extra or missing letter only affects that word:
//! Space commits the active word (untyped letters become "missed", letters
//! past the end are "extra"), Backspace can only go back into a word that
//! was committed wrong, and caret keys stay inside the active word.
//!
//! In code (and multi-line custom text) Enter part-way through a line skips
//! the rest of it; zen has no target at all (every typed word is right).

const std = @import("std");

const constants = @import("constants.zig");
const types = @import("types.zig");
const keylog = @import("keylog.zig");
const KeyLog = keylog.KeyLog;
const source = @import("source.zig");
const Source = source.Source;
const stats = @import("stats.zig");
const syntax = @import("syntax.zig");

pub const Edit = union(enum) {
    /// 0x20..0x7e; ' ' commits the active word (if it has ≥1 typed char).
    char: u8,
    /// Enter: commits a typed word at a .newline separator. With
    /// `Options.enter_skips_line`, anywhere else on a line (mid-line, an
    /// untyped last word, the text's last word) it commits the active word
    /// and the rest of the line as typed (untyped letters missed), records
    /// one wrong `.newline` keystroke and moves to the next line (on the
    /// last line it ends the test); nothing typed on the line yet → nothing.
    /// Otherwise ignored (words, sentences).
    newline,
    backspace,
    delete_word,
    delete_line,
    /// Inside the active word only.
    delete_forward,
    delete_word_forward,
    /// Caret inside the active word only.
    left,
    right,
    word_left,
    word_right,
};

pub const Sep = enum { space, newline, end };
pub const WordStatus = enum { pending, active, correct, incorrect };

pub const WordView = struct {
    target: []const u8,
    typed: []const u8,
    sep: Sep,
    /// Leading spaces of the NEXT line when sep == .newline (auto-skipped,
    /// drawn dim).
    indent: u16,
    status: WordStatus,
    /// Empty lines between this word's line and the next (sep == .newline),
    /// e.g. the blank line between two code snippets.
    blank_lines: u8 = 0,
    /// Committed wrong by Enter mid-line (the rest of its line was skipped).
    skipped: bool = false,
};

pub const Policy = struct {
    /// Backspace may go back into a word that was committed correctly.
    backspace_into_correct: bool = false,
    max_extra: u8 = constants.MAX_EXTRA_LETTERS,
    /// letter: a wrong letter is not inserted (the keystroke still counts
    /// as an error); word: Space/Enter does not commit a wrong word (no
    /// keystroke recorded).
    stop_on_error: types.StopOnError = .off,
    /// backspace, delete_word, delete_line, delete_forward and
    /// delete_word_forward do nothing.
    no_backspace: bool = false,
};

pub const Options = struct {
    /// Timed test: keep pulling words while the active word is within
    /// ENDLESS_LOOKAHEAD_WORDS of the end.
    endless: bool = false,
    /// Untimed: pull chunks until at least this many words exist.
    min_words: usize = 1,
    policy: Policy = .{},
    /// Enter mid-line skips the rest of the line (code, multi-line custom).
    enter_skips_line: bool = false,
    /// Zen: no target; every typed letter is right, Space/Enter commit, the
    /// test never completes by itself (until ZEN_MAX_WORDS).
    zen: bool = false,
    /// Syntax colouring of the text (code); .mixed = none.
    lang: types.Lang = .mixed,
};

/// Zen sessions end by themselves after this many words.
pub const ZEN_MAX_WORDS: usize = 5000;

/// Where a typist is after some number of target characters.
pub const Loc = struct {
    word: usize,
    /// Letters into the word; == target.len means "on the separator".
    offset: usize,
};

const Word = struct {
    start: u32,
    len: u16,
    sep: Sep = .end,
    indent: u16 = 0,
    blank_lines: u8 = 0,
    skipped: bool = false,
    typed: std.ArrayList(u8) = .empty,
    /// First keystroke and commit times (ms since start) for slow_words.
    first_ms: ?u32 = null,
    commit_ms: ?u32 = null,
};

/// Where a chunk (word, sentence/quote, snippet) starts, with its quote
/// attribution.
pub const ChunkInfo = struct { first_word: u32, by: ?[]const u8 };

pub const Session = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    words: std.ArrayList(Word) = .empty,
    chunks: std.ArrayList(ChunkInfo) = .empty,
    active: usize = 0,
    caret_pos: usize = 0,
    complete: bool = false,
    src: Source,
    opts: Options,
    exhausted: bool = false,
    log: KeyLog = .{},
    /// Characters of correctly committed words plus their separators (the
    /// WPM numerator without the active word).
    correct_chars: u32 = 0,
    /// The test ended by committing the last word (Space), so it is already
    /// in `correct_chars` (if right) and adds no correct prefix.
    last_committed: bool = false,
    /// Per-key accuracy and speed of this run (expected key of each letter
    /// keystroke; extra letters, Space and Enter are not tracked).
    per_key: stats.PerKey = .{},
    /// Time of the previous typed keystroke (per-key timing).
    prev_key_ms: ?u32 = null,
    /// Syntax class per byte of `text` (empty without a language).
    kinds: std.ArrayList(syntax.Kind) = .empty,

    pub fn init(allocator: std.mem.Allocator, src: Source, opts: Options) !Session {
        var s: Session = .{ .allocator = allocator, .src = src, .opts = opts };
        errdefer s.deinit();
        if (opts.zen) {
            // One empty word to type into; more are added on commit.
            try s.words.append(allocator, .{ .start = 0, .len = 0 });
            s.exhausted = true;
        } else if (opts.endless) {
            try s.refill();
        } else {
            while (s.words.items.len < @max(1, opts.min_words)) {
                if (!try s.pull()) break;
            }
            s.exhausted = true;
        }
        return s;
    }

    pub fn deinit(self: *Session) void {
        for (self.words.items) |*w| w.typed.deinit(self.allocator);
        self.words.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.log.deinit(self.allocator);
        self.kinds.deinit(self.allocator);
    }

    // ---- read API (renderer, stats) ----

    pub fn wordCount(self: *const Session) usize {
        return self.words.items.len;
    }

    pub fn word(self: *const Session, i: usize) WordView {
        const w = &self.words.items[i];
        const target = self.targetOf(i);
        const status: WordStatus = if (i < self.active or (self.complete and i == self.active))
            (if (std.mem.eql(u8, w.typed.items, target)) .correct else .incorrect)
        else if (i == self.active) .active else .pending;
        return .{
            .target = target,
            .typed = w.typed.items,
            .sep = w.sep,
            .indent = w.indent,
            .status = status,
            .blank_lines = w.blank_lines,
            .skipped = w.skipped,
        };
    }

    /// Where a typist is after `chars` target characters: each word costs
    /// its length plus 1 for its separator (indentation and blank lines
    /// cost 0). Clamps to the end of the last word.
    pub fn locate(self: *const Session, chars: u64) Loc {
        const n = self.words.items.len;
        if (n == 0) return .{ .word = 0, .offset = 0 };
        var rem = chars;
        for (0..n) |i| {
            const len = self.targetOf(i).len;
            if (rem <= len) return .{ .word = i, .offset = @intCast(rem) };
            rem -= len + 1;
        }
        return .{ .word = n - 1, .offset = self.targetOf(n - 1).len };
    }

    /// Syntax class of letter j of word i (.plain past the target or with
    /// no language).
    pub fn syntaxKind(self: *const Session, i: usize, j: usize) syntax.Kind {
        if (i >= self.words.items.len) return .plain;
        const w = self.words.items[i];
        if (j >= w.len) return .plain;
        const at = @as(usize, w.start) + j;
        return if (at < self.kinds.items.len) self.kinds.items[at] else .plain;
    }

    pub fn activeIndex(self: *const Session) usize {
        return self.active;
    }

    /// Byte offset into the active word's typed text.
    pub fn caret(self: *const Session) usize {
        return self.caret_pos;
    }

    pub fn isComplete(self: *const Session) bool {
        return self.complete;
    }

    /// The word's target (zen: what was typed).
    pub fn targetOf(self: *const Session, i: usize) []const u8 {
        const w = &self.words.items[i];
        if (self.opts.zen) return w.typed.items;
        return self.text.items[w.start..][0..w.len];
    }

    pub fn typedOf(self: *const Session, i: usize) []const u8 {
        return self.words.items[i].typed.items;
    }

    pub fn firstMs(self: *const Session, i: usize) ?u32 {
        return self.words.items[i].first_ms;
    }

    pub fn commitMs(self: *const Session, i: usize) ?u32 {
        return self.words.items[i].commit_ms;
    }

    /// Words committed so far (the finishing exact word counts too).
    pub fn doneCount(self: *const Session) usize {
        return if (self.complete) @min(self.active + 1, self.words.items.len) else self.active;
    }

    /// Correct leading letters of the active word (all of it once the test
    /// finished on an exact last word).
    pub fn activeCorrectPrefix(self: *const Session) usize {
        if (self.active >= self.words.items.len) return 0;
        const typed = self.typedOf(self.active);
        const target = self.targetOf(self.active);
        var n: usize = 0;
        while (n < typed.len and n < target.len and typed[n] == target[n]) n += 1;
        return n;
    }

    /// WPM characters of the active word not yet in `correct_chars`: its
    /// correct prefix, or nothing once the last word was committed.
    pub fn tailChars(self: *const Session) usize {
        return if (self.last_committed) 0 else self.activeCorrectPrefix();
    }

    /// Attribution of the quote being typed last (sentences mode).
    pub fn quoteBy(self: *const Session) ?[]const u8 {
        const reached = @min(self.active, self.words.items.len -| 1);
        var by: ?[]const u8 = null;
        for (self.chunks.items) |c| {
            if (c.first_word > reached) break;
            by = c.by;
        }
        return by;
    }

    // ---- editing ----

    pub fn apply(self: *Session, edit: Edit, t_ms: u32) void {
        if (self.complete or self.active >= self.words.items.len) return;
        if (self.opts.policy.no_backspace) switch (edit) {
            .backspace, .delete_word, .delete_line, .delete_forward, .delete_word_forward => return,
            else => {},
        };
        self.log.edits += 1;
        switch (edit) {
            .char => |c| {
                if (c == ' ') {
                    self.commit(.space, t_ms);
                } else if (c >= 0x21 and c <= 0x7e) {
                    self.insert(c, t_ms);
                }
            },
            .newline => self.newline(t_ms),
            .backspace => self.backspace(t_ms),
            .delete_word => {
                if (self.activeWord().typed.items.len > 0 or self.moveBack(t_ms))
                    self.clearActive(.delete_word, t_ms);
            },
            .delete_line => self.deleteLine(t_ms),
            .delete_forward => if (self.caret_pos < self.activeWord().typed.items.len)
                self.removeForward(self.caret_pos + 1, t_ms),
            .delete_word_forward => if (self.caret_pos < self.activeWord().typed.items.len)
                self.removeForward(self.activeWord().typed.items.len, t_ms),
            .left => self.caret_pos -|= 1,
            .right => self.caret_pos = @min(self.caret_pos + 1, self.activeWord().typed.items.len),
            .word_left => self.caret_pos = 0,
            .word_right => self.caret_pos = self.activeWord().typed.items.len,
        }
    }

    fn activeWord(self: *Session) *Word {
        return &self.words.items[self.active];
    }

    fn record(self: *Session, kind: keylog.Kind, char: u8, correct: bool, t_ms: u32) void {
        self.log.add(self.allocator, .{
            .t_ms = t_ms,
            .char = char,
            .kind = kind,
            .correct = correct,
            .word = @intCast(@min(self.active, std.math.maxInt(u19))),
        });
    }

    fn isLast(self: *const Session) bool {
        return self.active + 1 == self.words.items.len;
    }

    /// Time since the previous typed keystroke (per-key speed); the first
    /// keystroke is not timed.
    fn keyGap(self: *Session, t_ms: u32) ?u32 {
        defer self.prev_key_ms = t_ms;
        const prev = self.prev_key_ms orelse return null;
        return t_ms -| prev;
    }

    fn insert(self: *Session, c: u8, t_ms: u32) void {
        const w = self.activeWord();
        const target = self.targetOf(self.active);
        const pos = self.caret_pos;
        if (self.opts.zen) {
            w.typed.insert(self.allocator, pos, c) catch return;
            self.caret_pos += 1;
            if (w.first_ms == null) w.first_ms = t_ms;
            _ = self.keyGap(t_ms);
            self.record(.char, c, true, t_ms);
            return;
        }
        if (w.typed.items.len >= target.len + self.opts.policy.max_extra) return;
        const right = pos < target.len and target[pos] == c;
        const gap = self.keyGap(t_ms);
        // Extra letters (past the target) are not attributed to a key.
        if (pos < target.len) self.per_key.note(target[pos], right, gap);
        if (!right and self.opts.policy.stop_on_error == .letter) {
            // Strict: the error counts, but the letter is not inserted.
            self.record(.char, c, false, t_ms);
            return;
        }
        w.typed.insert(self.allocator, pos, c) catch return;
        self.caret_pos += 1;
        if (w.first_ms == null) w.first_ms = t_ms;
        self.record(.char, c, right, t_ms);
        // Monkeytype: an exact last word ends the test without a space.
        if (self.isLast() and std.mem.eql(u8, w.typed.items, target)) {
            w.commit_ms = t_ms;
            self.complete = true;
        }
    }

    fn commit(self: *Session, kind: keylog.Kind, t_ms: u32) void {
        const w = self.activeWord();
        if (self.opts.zen) return self.zenCommit(kind, t_ms);
        if (w.typed.items.len == 0) return; // double space is harmless
        const correct = std.mem.eql(u8, w.typed.items, self.targetOf(self.active));
        if (!correct and self.opts.policy.stop_on_error == .word) return;
        _ = self.keyGap(t_ms);
        self.record(kind, if (kind == .newline) '\n' else ' ', correct, t_ms);
        w.commit_ms = t_ms;
        if (correct) self.correct_chars += @as(u32, w.len) + 1;
        if (self.isLast()) {
            self.complete = true;
            self.last_committed = true;
            return;
        }
        self.active += 1;
        self.caret_pos = 0;
        self.refill() catch {};
    }

    fn newline(self: *Session, t_ms: u32) void {
        if (self.opts.zen) return self.zenCommit(.newline, t_ms);
        const w = self.activeWord();
        // At a line break a typed word commits as before (as does every
        // Enter without enter_skips_line).
        if (w.sep == .newline and (w.typed.items.len > 0 or !self.opts.enter_skips_line))
            return self.commit(.newline, t_ms);
        if (!self.opts.enter_skips_line) return;
        // Nothing typed on this line yet: a double Enter is harmless.
        if (self.active == self.lineStart() and w.typed.items.len == 0) return;
        // Strict word mode never commits a wrong word, so it can't skip.
        if (self.opts.policy.stop_on_error == .word) return;
        self.skipLine(t_ms);
    }

    /// Enter mid-line: one wrong `.newline` keystroke, then the active word
    /// and the rest of its line are committed as typed (a right active word
    /// still counts, via a `.skip` record); the caret moves to the next
    /// line's first word, or the test ends on the last line.
    fn skipLine(self: *Session, t_ms: u32) void {
        var last = self.active;
        while (true) {
            while (self.words.items[last].sep == .space and last + 1 < self.words.items.len) last += 1;
            // A line longer than the lookahead may run past the loaded text
            // (endless): load on, or the skip would end a timed test.
            if (self.words.items[last].sep != .end or self.exhausted or !self.opts.endless) break;
            if (!(self.pull() catch false)) self.exhausted = true;
        }
        _ = self.keyGap(t_ms);
        self.record(.newline, '\n', false, t_ms);
        while (true) {
            const w = self.activeWord();
            const correct = std.mem.eql(u8, w.typed.items, self.targetOf(self.active));
            w.commit_ms = t_ms;
            if (correct) {
                self.correct_chars += @as(u32, w.len) + 1;
                self.record(.skip, 0, true, t_ms);
            } else w.skipped = true;
            if (self.active == last) break;
            self.active += 1;
        }
        self.caret_pos = 0;
        if (self.isLast()) {
            self.complete = true;
            self.last_committed = true;
            return;
        }
        self.active += 1;
        self.refill() catch {};
    }

    /// Zen: Space/Enter end the typed word (it is its own target) and open
    /// a new one. Enter on an empty word only changes the layout (the
    /// previous separator becomes a line break, then a blank line); it is
    /// not a keystroke.
    fn zenCommit(self: *Session, kind: keylog.Kind, t_ms: u32) void {
        const w = self.activeWord();
        if (w.typed.items.len == 0) {
            if (kind == .newline and self.active > 0) {
                const prev = &self.words.items[self.active - 1];
                if (prev.sep == .newline) prev.blank_lines +|= 1 else prev.sep = .newline;
            }
            return;
        }
        _ = self.keyGap(t_ms);
        self.record(kind, if (kind == .newline) '\n' else ' ', true, t_ms);
        w.commit_ms = t_ms;
        w.sep = if (kind == .newline) .newline else .space;
        if (kind != .newline) w.blank_lines = 0;
        self.correct_chars += @as(u32, @intCast(w.typed.items.len)) + 1;
        if (self.words.items.len >= ZEN_MAX_WORDS) {
            self.complete = true;
            self.last_committed = true;
            return;
        }
        if (self.isLast()) {
            self.words.append(self.allocator, .{ .start = 0, .len = 0 }) catch {
                self.complete = true;
                self.last_committed = true;
                return;
            };
        }
        self.active += 1;
        self.caret_pos = 0;
    }

    /// Backspace in an empty word: go back into the previous word if the
    /// policy allows (only incorrect words by default).
    fn moveBack(self: *Session, t_ms: u32) bool {
        if (self.active == 0) return false;
        const prev = &self.words.items[self.active - 1];
        const was_correct = std.mem.eql(u8, prev.typed.items, self.targetOf(self.active - 1));
        if (was_correct and !self.opts.policy.backspace_into_correct and !self.opts.zen) return false;
        self.active -= 1;
        self.caret_pos = prev.typed.items.len;
        prev.commit_ms = null;
        prev.skipped = false;
        if (was_correct) self.correct_chars -= @as(u32, @intCast(self.targetOf(self.active).len)) + 1;
        self.record(.uncommit, 0, was_correct, t_ms);
        return true;
    }

    /// Zen counts every removed letter (accuracy = kept / typed there).
    fn isWrongAt(self: *const Session, i: usize) bool {
        if (self.opts.zen) return true;
        const typed = self.typedOf(self.active);
        const target = self.targetOf(self.active);
        return i >= target.len or typed[i] != target[i];
    }

    fn backspace(self: *Session, t_ms: u32) void {
        const w = self.activeWord();
        if (self.caret_pos > 0) {
            const i = self.caret_pos - 1;
            const ch = w.typed.items[i];
            const wrong = self.isWrongAt(i);
            _ = w.typed.orderedRemove(i);
            self.caret_pos = i;
            if (wrong) self.log.addCorrected(1);
            self.record(.backspace, ch, !wrong, t_ms);
        } else if (w.typed.items.len == 0) {
            _ = self.moveBack(t_ms);
        }
    }

    fn wrongIn(self: *const Session, from: usize, to: usize) u32 {
        var n: u32 = 0;
        for (from..to) |i| {
            if (self.isWrongAt(i)) n += 1;
        }
        return n;
    }

    fn clearActive(self: *Session, kind: keylog.Kind, t_ms: u32) void {
        const w = self.activeWord();
        const wrong = self.wrongIn(0, w.typed.items.len);
        self.log.addCorrected(wrong);
        w.typed.clearRetainingCapacity();
        self.caret_pos = 0;
        self.record(kind, @intCast(@min(wrong, 255)), wrong == 0, t_ms);
    }

    fn removeForward(self: *Session, end: usize, t_ms: u32) void {
        const w = self.activeWord();
        const wrong = self.wrongIn(self.caret_pos, end);
        self.log.addCorrected(wrong);
        w.typed.replaceRangeAssumeCapacity(self.caret_pos, end - self.caret_pos, &.{});
        self.record(.delete_forward, @intCast(@min(wrong, 255)), wrong == 0, t_ms);
    }

    /// First word of the target line holding the active word.
    fn lineStart(self: *const Session) usize {
        var i = self.active;
        while (i > 0 and self.words.items[i - 1].sep != .newline) i -= 1;
        return i;
    }

    fn deleteLine(self: *Session, t_ms: u32) void {
        const start = self.lineStart();
        while (true) {
            if (self.activeWord().typed.items.len > 0) {
                self.clearActive(.delete_line, t_ms);
            } else if (self.active > start and self.moveBack(t_ms)) {
                continue;
            } else break;
        }
    }

    // ---- content ----

    /// Pulls chunks while the active word is near the end (endless only).
    fn refill(self: *Session) !void {
        if (!self.opts.endless or self.opts.zen) return;
        while (!self.exhausted and self.words.items.len - self.active <= constants.ENDLESS_LOOKAHEAD_WORDS) {
            if (!try self.pull()) self.exhausted = true;
        }
    }

    fn pull(self: *Session) !bool {
        const join = self.src.join();
        const chunk = self.src.next() orelse return false;
        try self.appendText(chunk.text, chunk.by, join);
        return true;
    }

    /// Splits `text` into words and appends them. Leading spaces of a line
    /// become the previous word's `indent`; empty lines its `blank_lines`.
    pub fn appendText(self: *Session, text: []const u8, by: ?[]const u8, join: source.Join) !void {
        const first_new = self.words.items.len;
        var blank: u8 = 0;
        var hl: syntax.State = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len == 0) {
                if (self.words.items.len > first_new) blank +|= 1;
                continue;
            }
            var indent: u16 = 0;
            for (line) |c| switch (c) {
                ' ' => indent += 1,
                '\t' => indent += 4,
                else => break,
            };
            const n = self.words.items.len;
            if (n > first_new) {
                const prev = &self.words.items[n - 1];
                prev.sep = .newline;
                prev.indent = indent;
                prev.blank_lines = blank;
            } else if (n > 0) {
                const prev = &self.words.items[n - 1];
                switch (join) {
                    .space => prev.sep = .space,
                    .newline => {
                        prev.sep = .newline;
                        prev.indent = indent;
                    },
                    .blank_line => {
                        prev.sep = .newline;
                        prev.indent = indent;
                        prev.blank_lines = 1;
                    },
                }
            }
            blank = 0;
            // Syntax classes of the whole line (state carried line to line).
            var line_kinds: [512]syntax.Kind = undefined;
            const coloured = self.opts.lang != .mixed and line.len <= line_kinds.len;
            if (coloured) syntax.highlightLine(self.opts.lang, line, &hl, &line_kinds);
            var toks = std.mem.tokenizeAny(u8, line, " \t");
            const line_first = self.words.items.len;
            while (toks.next()) |tok| {
                // Words inside one line are joined by a space.
                if (self.words.items.len > line_first) self.words.items[self.words.items.len - 1].sep = .space;
                const len: u16 = @intCast(@min(tok.len, std.math.maxInt(u16)));
                const start: u32 = @intCast(self.text.items.len);
                try self.text.appendSlice(self.allocator, tok[0..len]);
                try self.words.append(self.allocator, .{ .start = start, .len = len });
                if (self.opts.lang != .mixed) {
                    // `kinds` stays aligned with `text` (plain for a long line).
                    std.debug.assert(self.kinds.items.len == start);
                    const off = @intFromPtr(tok.ptr) - @intFromPtr(line.ptr);
                    if (coloured) {
                        try self.kinds.appendSlice(self.allocator, line_kinds[off..][0..len]);
                    } else try self.kinds.appendNTimes(self.allocator, .plain, len);
                }
            }
        }
        if (self.words.items.len > first_new) {
            try self.chunks.append(self.allocator, .{ .first_word = @intCast(first_new), .by = by });
        }
    }
};

// ---- tests ----

const testing = std.testing;

/// A session over a fixed text (practice-list style, untimed).
fn fixedSession(list: []const []const u8) !Session {
    return Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, list), .{ .min_words = 1000 });
}

fn typeStr(s: *Session, str: []const u8, t: *u32) void {
    for (str) |c| {
        t.* += 100;
        s.apply(if (c == '\n') .newline else .{ .char = c }, t.*);
    }
}

test "words split on spaces with separators" {
    const list = [_][]const u8{ "alpha", "beta", "gamma" };
    var s = try fixedSession(&list);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.wordCount());
    try testing.expectEqual(Sep.space, s.word(0).sep);
    try testing.expectEqual(Sep.end, s.word(2).sep);
    try testing.expectEqual(WordStatus.active, s.word(0).status);
    try testing.expectEqual(WordStatus.pending, s.word(1).status);
}

test "an extra letter stays in its word" {
    const list = [_][]const u8{ "alpha", "beta", "gamma" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "alphaz beta gamma", &t);
    try testing.expect(s.isComplete());
    try testing.expectEqual(WordStatus.incorrect, s.word(0).status);
    try testing.expectEqual(WordStatus.correct, s.word(1).status);
    try testing.expectEqual(WordStatus.correct, s.word(2).status);
}

test "space skips the rest of a word and double space is harmless" {
    const list = [_][]const u8{ "alpha", "beta" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "alp  ", &t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    try testing.expectEqual(WordStatus.incorrect, s.word(0).status);
    // Space in an empty word does nothing.
    typeStr(&s, " ", &t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    try testing.expectEqual(@as(u32, 4), s.log.typed); // a l p + one space
}

test "backspace goes back only into an incorrect word" {
    const list = [_][]const u8{ "one", "two", "three" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "one ", &t);
    s.apply(.backspace, t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex()); // blocked
    typeStr(&s, "twx ", &t);
    s.apply(.backspace, t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex()); // back into "twx"
    try testing.expectEqual(@as(usize, 3), s.caret());
    s.apply(.backspace, t);
    typeStr(&s, "o ", &t);
    try testing.expectEqual(WordStatus.correct, s.word(1).status);
    try testing.expectEqual(@as(u32, 1), s.log.corrected);
}

test "delete_word clears the word, then the previous incorrect one" {
    const list = [_][]const u8{ "one", "two", "three" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "one twp thr", &t);
    s.apply(.delete_word, t);
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    try testing.expectEqualStrings("", s.word(2).typed);
    s.apply(.delete_word, t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    try testing.expectEqualStrings("", s.word(1).typed);
    s.apply(.delete_word, t);
    // "one" is correct: blocked.
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    try testing.expectEqual(@as(u32, 1), s.log.corrected); // the 'p'
}

test "delete_line stops at a correct word or the line start" {
    const list = [_][]const u8{ "aa", "bb", "cc", "dd" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "aa bx cx d", &t);
    s.apply(.delete_line, t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    try testing.expectEqualStrings("", s.word(1).typed);
    try testing.expectEqualStrings("aa", s.word(0).typed);

    // Code: the line start of the active word bounds it.
    var c = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &.{}), .{});
    defer c.deinit();
    try c.appendText("ab cd\n    ef gh", null, .space);
    typeStr(&c, "ax cx\nex g", &t);
    try testing.expectEqual(@as(usize, 3), c.activeIndex());
    c.apply(.delete_line, t);
    try testing.expectEqual(@as(usize, 2), c.activeIndex());
    try testing.expectEqualStrings("cx", c.word(1).typed);
}

test "caret keys stay within the active word" {
    const list = [_][]const u8{ "hello", "world" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "hello wrld", &t);
    s.apply(.word_left, t);
    try testing.expectEqual(@as(usize, 0), s.caret());
    s.apply(.left, t);
    try testing.expectEqual(@as(usize, 0), s.caret());
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    s.apply(.right, t);
    typeStr(&s, "o", &t);
    try testing.expect(s.isComplete());
    try testing.expectEqual(WordStatus.correct, s.word(1).status);

    var s2 = try fixedSession(&list);
    defer s2.deinit();
    typeStr(&s2, "hello wxyz", &t);
    s2.apply(.word_right, t);
    s2.apply(.right, t);
    try testing.expectEqual(@as(usize, 4), s2.caret());
    s2.apply(.word_left, t);
    s2.apply(.delete_forward, t);
    try testing.expectEqualStrings("xyz", s2.word(1).typed);
    s2.apply(.right, t);
    s2.apply(.delete_word_forward, t);
    try testing.expectEqualStrings("x", s2.word(1).typed);
    try testing.expectEqualStrings("hello", s2.word(0).typed);
}

test "a wrong last letter doesn't finish; an exact last word does" {
    const list = [_][]const u8{ "ab", "cd" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "ab cx", &t);
    try testing.expect(!s.isComplete());
    s.apply(.backspace, t);
    typeStr(&s, "d", &t);
    try testing.expect(s.isComplete());
    // Keys after the end are ignored.
    typeStr(&s, "zz", &t);
    try testing.expectEqualStrings("cd", s.word(1).typed);
}

test "space on the last word commits and finishes" {
    const list = [_][]const u8{ "ab", "cd" };
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "ab c ", &t);
    try testing.expect(s.isComplete());
    try testing.expectEqual(WordStatus.incorrect, s.word(1).status);
}

test "extra letters are capped" {
    const list = [_][]const u8{"a"};
    var s = try fixedSession(&list);
    defer s.deinit();
    var t: u32 = 0;
    for (0..40) |_| typeStr(&s, "z", &t);
    try testing.expectEqual(@as(usize, 1 + constants.MAX_EXTRA_LETTERS), s.word(0).typed.len);
}

test "code: Enter commits at a newline and the indent is skipped" {
    var s = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &.{}), .{});
    defer s.deinit();
    try s.appendText("fn f() {\n    return  1;\n\n}", null, .space);
    try testing.expectEqual(@as(usize, 6), s.wordCount());
    try testing.expectEqual(Sep.space, s.word(0).sep);
    try testing.expectEqual(Sep.space, s.word(3).sep);
    try testing.expectEqual(Sep.newline, s.word(2).sep);
    try testing.expectEqual(@as(u16, 4), s.word(2).indent);
    try testing.expectEqual(@as(u8, 1), s.word(4).blank_lines);
    try testing.expectEqual(@as(u16, 0), s.word(4).indent);
    var t: u32 = 0;
    typeStr(&s, "fn f()", &t);
    s.apply(.newline, t); // at a .space separator: ignored
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    typeStr(&s, " {\nreturn 1; ", &t); // space also commits at a newline
    try testing.expectEqual(@as(usize, 5), s.activeIndex());
    typeStr(&s, "}", &t);
    try testing.expect(s.isComplete());
    for (0..6) |i| try testing.expectEqual(WordStatus.correct, s.word(i).status);
}

test "code chunks are joined with a blank line" {
    var s = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &.{}), .{});
    defer s.deinit();
    try s.appendText("a {\n}", null, .blank_line);
    try s.appendText("    b", "x", .blank_line);
    try testing.expectEqual(Sep.newline, s.word(2).sep);
    try testing.expectEqual(@as(u8, 1), s.word(2).blank_lines);
    try testing.expectEqual(@as(u16, 4), s.word(2).indent);
    try testing.expectEqual(@as(usize, 2), s.chunks.items.len);
}

test "endless sessions keep pulling words" {
    const cfg: types.Config = .{ .mode = .words, .word_count = 10, .time_limit = 15 };
    var s = try Session.init(testing.allocator, Source.init(7, cfg, null), .{ .endless = true });
    defer s.deinit();
    var t: u32 = 0;
    for (0..200) |_| {
        const target = s.targetOf(s.activeIndex());
        typeStr(&s, target, &t);
        typeStr(&s, " ", &t);
        try testing.expect(!s.isComplete());
        try testing.expect(s.wordCount() - s.activeIndex() > constants.ENDLESS_LOOKAHEAD_WORDS);
    }
}

/// A code-like session over `text` (Enter skips the rest of a line).
fn codeSession(text: []const u8, opts: Options) !Session {
    var s = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &.{}), opts);
    errdefer s.deinit();
    try s.appendText(text, null, .space);
    return s;
}

test "Enter mid-line skips the rest of the line" {
    var s = try codeSession("fn main() {\n    return 1;\n}", .{ .enter_skips_line = true });
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "fn ma", &t);
    const typed_before = s.log.typed;
    const correct_before = s.log.correct;
    s.apply(.newline, t);
    // One wrong keystroke; "main()" and "{" are committed as typed.
    try testing.expectEqual(typed_before + 1, s.log.typed);
    try testing.expectEqual(correct_before, s.log.correct);
    try testing.expectEqual(@as(usize, 3), s.activeIndex()); // "return", indent skipped
    try testing.expectEqual(@as(usize, 0), s.caret());
    try testing.expect(s.word(1).skipped and s.word(2).skipped);
    try testing.expect(!s.word(0).skipped);
    try testing.expectEqual(WordStatus.correct, s.word(0).status);
    try testing.expectEqual(WordStatus.incorrect, s.word(2).status);
    try testing.expectEqual(@as(u32, 3), s.correct_chars); // "fn "
    // Double Enter on the untouched line is harmless.
    s.apply(.newline, t);
    try testing.expectEqual(@as(usize, 3), s.activeIndex());
    try testing.expectEqual(typed_before + 1, s.log.typed);
    // Missed letters: "in()" (4) and "{" (1).
    var bufs: stats.Buffers = .{};
    defer bufs.deinit(testing.allocator);
    typeStr(&s, "return 1;\n}", &t);
    try testing.expect(s.isComplete());
    const r = stats.typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectEqual(@as(u32, 5), r.chars.missed);
    try testing.expectEqual(@as(u32, 0), r.chars.incorrect);
    // The untouched "{" is not a "missed word"; the half-typed "main()" is.
    try testing.expectEqual(@as(usize, 1), r.missed_words.len);
    try testing.expectEqualStrings("main()", r.missed_words[0]);
}

test "Enter: a finished word still counts, the last line ends the test" {
    var s = try codeSession("a bb\ncc dd ee", .{ .enter_skips_line = true });
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "a bb\ncc", &t);
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    s.apply(.newline, t);
    try testing.expect(s.isComplete());
    try testing.expect(s.last_committed);
    try testing.expectEqual(WordStatus.correct, s.word(2).status);
    try testing.expect(!s.word(2).skipped and s.word(3).skipped and s.word(4).skipped);
    // "a " + "bb " + "cc " (the skip keeps the right word's chars).
    try testing.expectEqual(@as(u32, 8), s.correct_chars);
    var bufs: stats.Buffers = .{};
    defer bufs.deinit(testing.allocator);
    const r = stats.typingResult(&s, t, false, &bufs, testing.allocator);
    try testing.expectApproxEqAbs(stats.perMinute(8, t), r.wpm, 0.01);
    try testing.expectApproxEqAbs(r.wpm, r.series[r.series.len - 1].wpm, 0.01);
}

test "Enter: words mode ignores it; at the line end it commits as before" {
    const list = [_][]const u8{ "alpha", "beta" };
    var w = try fixedSession(&list);
    defer w.deinit();
    var t: u32 = 0;
    typeStr(&w, "al", &t);
    w.apply(.newline, t);
    try testing.expectEqual(@as(usize, 0), w.activeIndex());
    try testing.expectEqual(@as(u32, 2), w.log.typed);

    var s = try codeSession("ab cd\nef", .{ .enter_skips_line = true });
    defer s.deinit();
    typeStr(&s, "ab c", &t);
    s.apply(.newline, t); // at the line's last word: an ordinary commit
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    try testing.expect(!s.word(1).skipped);
    try testing.expectEqual(WordStatus.incorrect, s.word(1).status);
}

test "Backspace from the next line goes back into a skipped word" {
    var s = try codeSession("one two three\nfour", .{ .enter_skips_line = true });
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "one tw\n", &t);
    try testing.expectEqual(@as(usize, 3), s.activeIndex());
    s.apply(.backspace, t);
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    try testing.expect(!s.word(2).skipped);
    try testing.expectEqual(WordStatus.active, s.word(2).status);
    s.apply(.backspace, t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    try testing.expectEqualStrings("tw", s.word(1).typed);
    typeStr(&s, "o three\nfour", &t);
    try testing.expect(s.isComplete());
    for (0..4) |i| try testing.expectEqual(WordStatus.correct, s.word(i).status);
}

test "locate: separators cost 1, indentation 0, clamped at the end" {
    var s = try codeSession("ab cd\n    efg", .{});
    defer s.deinit();
    try testing.expectEqual(Loc{ .word = 0, .offset = 0 }, s.locate(0));
    try testing.expectEqual(Loc{ .word = 0, .offset = 2 }, s.locate(2)); // on the space
    try testing.expectEqual(Loc{ .word = 1, .offset = 0 }, s.locate(3));
    try testing.expectEqual(Loc{ .word = 1, .offset = 2 }, s.locate(5)); // on the newline
    try testing.expectEqual(Loc{ .word = 2, .offset = 0 }, s.locate(6)); // indent is free
    try testing.expectEqual(Loc{ .word = 2, .offset = 3 }, s.locate(9));
    try testing.expectEqual(Loc{ .word = 2, .offset = 3 }, s.locate(1000));
}

test "syntaxKind lines up with each word's target" {
    var s = try codeSession("const x = \"a b\"; // hi\nfn f() void {}", .{ .lang = .zig });
    defer s.deinit();
    try testing.expectEqual(s.text.items.len, s.kinds.items.len);
    try testing.expectEqualStrings("const", s.targetOf(0));
    for (0..5) |j| try testing.expectEqual(syntax.Kind.keyword, s.syntaxKind(0, j));
    try testing.expectEqual(syntax.Kind.plain, s.syntaxKind(0, 5)); // past the word
    try testing.expectEqualStrings("\"a", s.targetOf(3));
    try testing.expectEqual(syntax.Kind.string, s.syntaxKind(3, 1));
    try testing.expectEqualStrings("b\";", s.targetOf(4));
    try testing.expectEqual(syntax.Kind.string, s.syntaxKind(4, 1));
    try testing.expectEqual(syntax.Kind.punct, s.syntaxKind(4, 2));
    try testing.expectEqual(syntax.Kind.comment, s.syntaxKind(6, 0));
    // The comment ends with its line.
    try testing.expectEqualStrings("void", s.targetOf(9));
    try testing.expectEqual(syntax.Kind.keyword, s.syntaxKind(9, 3));
    try testing.expectEqual(syntax.Kind.punct, s.syntaxKind(10, 1));
    // Without a language everything is plain.
    var p = try codeSession("const x", .{});
    defer p.deinit();
    try testing.expectEqual(syntax.Kind.plain, p.syntaxKind(0, 0));
    try testing.expectEqual(@as(usize, 0), p.kinds.items.len);
}

test "strict: stop on a wrong letter, stop on a wrong word, no backspace" {
    const list = [_][]const u8{ "ab", "cd" };
    var l = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10, .policy = .{ .stop_on_error = .letter } });
    defer l.deinit();
    var t: u32 = 0;
    typeStr(&l, "ax", &t);
    try testing.expectEqualStrings("a", l.word(0).typed);
    try testing.expectEqual(@as(usize, 1), l.caret());
    try testing.expectEqual(@as(u32, 2), l.log.typed);
    try testing.expectEqual(@as(u32, 1), l.log.correct);
    typeStr(&l, "b cd", &t);
    try testing.expect(l.isComplete());

    var w = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10, .policy = .{ .stop_on_error = .word } });
    defer w.deinit();
    typeStr(&w, "ax ", &t);
    try testing.expectEqual(@as(usize, 0), w.activeIndex()); // Space refused
    try testing.expectEqual(@as(u32, 2), w.log.typed);
    w.apply(.backspace, t);
    typeStr(&w, "b ", &t);
    try testing.expectEqual(@as(usize, 1), w.activeIndex());

    var c = try codeSession("ab cd\nef", .{ .enter_skips_line = true, .policy = .{ .stop_on_error = .word } });
    defer c.deinit();
    typeStr(&c, "ab c", &t);
    c.apply(.newline, t); // "c" is wrong: not committed
    try testing.expectEqual(@as(usize, 1), c.activeIndex());
    c.apply(.backspace, t);
    c.apply(.newline, t); // nothing typed on "cd" but the line has "ab": no skip either
    try testing.expectEqual(@as(usize, 1), c.activeIndex());

    var n = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10, .policy = .{ .no_backspace = true } });
    defer n.deinit();
    typeStr(&n, "ax", &t);
    for ([_]Edit{ .backspace, .delete_word, .delete_line, .left, .delete_forward, .delete_word_forward }) |e| n.apply(e, t);
    try testing.expectEqualStrings("ax", n.word(0).typed);
    try testing.expectEqual(@as(usize, 1), n.caret()); // caret moves still work
    typeStr(&n, " ", &t);
    n.apply(.backspace, t); // can't go back into the wrong word either
    try testing.expectEqual(@as(usize, 1), n.activeIndex());
    // Extra letters stay capped.
    for (0..40) |_| typeStr(&n, "z", &t);
    try testing.expectEqual(@as(usize, 2 + constants.MAX_EXTRA_LETTERS), n.word(1).typed.len);
}

test "zen: free typing, every word right, Enter breaks lines" {
    var s = try Session.init(testing.allocator, Source.init(1, .{ .mode = .zen }, &.{}), .{ .zen = true });
    defer s.deinit();
    var t: u32 = 0;
    typeStr(&s, "hello  wrld", &t);
    try testing.expectEqual(@as(usize, 1), s.activeIndex());
    s.apply(.backspace, t);
    s.apply(.backspace, t);
    s.apply(.backspace, t);
    typeStr(&s, "orld\n\nnext ", &t);
    try testing.expect(!s.isComplete());
    try testing.expectEqual(@as(usize, 3), s.activeIndex());
    try testing.expectEqualStrings("world", s.word(1).target);
    try testing.expectEqual(WordStatus.correct, s.word(1).status);
    try testing.expectEqual(Sep.newline, s.word(1).sep);
    try testing.expectEqual(@as(u8, 1), s.word(1).blank_lines);
    try testing.expectEqual(Sep.space, s.word(2).sep);
    try testing.expectEqual(@as(u32, 6 + 6 + 5), s.correct_chars);
    try testing.expectEqual(@as(u32, 3), s.log.corrected);
    // Backspace goes back across words.
    s.apply(.backspace, t);
    try testing.expectEqual(@as(usize, 2), s.activeIndex());
    try testing.expectEqual(@as(u32, 12), s.correct_chars);
    try testing.expectEqual(WordStatus.active, s.word(2).status);
}

test "per-key: expected key, shifted chars, extras, timing cap" {
    const list = [_][]const u8{ "Ab", "c" };
    var s = try Session.init(testing.allocator, Source.init(1, .{ .mode = .words }, &list), .{ .min_words = 10 });
    defer s.deinit();
    s.apply(.{ .char = 'A' }, 100); // first keystroke: not timed
    s.apply(.{ .char = 'x' }, 300); // wrong, expected 'b'
    s.apply(.{ .char = 'y' }, 400); // extra: not attributed
    s.apply(.backspace, 500);
    s.apply(.backspace, 600);
    s.apply(.{ .char = 'b' }, 900);
    s.apply(.{ .char = ' ' }, 9000);
    s.apply(.{ .char = 'c' }, 9100);
    const a = s.per_key.get('a').?;
    try testing.expectEqual(stats.KeyStat{ .hits = 1, .misses = 0, .ms_sum = 0, .timed = 0 }, a);
    try testing.expectEqual(stats.KeyStat{ .hits = 2, .misses = 1, .ms_sum = 500, .timed = 1 }, s.per_key.get('B').?);
    // 'c' came 100 ms after the space (which is timed but not tracked).
    try testing.expectEqual(stats.KeyStat{ .hits = 1, .misses = 0, .ms_sum = 100, .timed = 1 }, s.per_key.get('c').?);
    try testing.expectEqual(@as(u32, 4), s.per_key.total().hits);
    try testing.expect(s.per_key.get(' ') == null);
    var p: stats.PerKey = .{};
    p.note('q', true, 99_999);
    try testing.expectEqual(stats.KEY_MS_CAP, p.get('q').?.ms_sum);
}
