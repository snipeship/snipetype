//! Questions the views ask the test (a `*TypingTest` or a test fixture,
//! passed as `anytype`) and its config, in one place: which screen a mode
//! uses, whether it is zen / custom / daily, the code language, the custom
//! text, the pace position.
//!
//! Each query prefers the facade method from the round-2 contracts (C1, C3)
//! and falls back to what the config says when the test type doesn't have
//! it, so fixtures only implement what a test needs.

const std = @import("std");
const types = @import("../core/types.zig");
const daily = @import("../core/daily.zig");

fn Child(comptime P: type) type {
    return switch (@typeInfo(P)) {
        .pointer => |p| p.child,
        else => P,
    };
}

fn has(comptime P: type, comptime name: []const u8) bool {
    const T = Child(P);
    return @typeInfo(T) == .@"struct" and @hasDecl(T, name);
}

/// `value == .tag` for an enum that may not have `tag` (false then).
pub fn is(value: anytype, comptime tag: []const u8) bool {
    const E = @TypeOf(value);
    if (comptime !@hasField(E, tag)) return false;
    return value == @field(E, tag);
}

/// `cfg.<field> == .<tag>` (false when the config has no such field).
pub fn cfgIs(cfg: anytype, comptime field: []const u8, comptime tag: []const u8) bool {
    if (comptime !@hasField(@TypeOf(cfg), field)) return false;
    return is(@field(cfg, field), tag);
}

/// A bool config field (`default` when the config has no such field).
pub fn cfgBool(cfg: anytype, comptime field: []const u8, default: bool) bool {
    if (comptime !@hasField(@TypeOf(cfg), field)) return default;
    return @field(cfg, field);
}

/// `.drills` / `.type` for the vim screens (vim mode, or code with vim
/// keys); null for the plain typing screens.
pub fn vimKind(t: anytype) ?types.VimKind {
    if (comptime has(@TypeOf(t), "vimKind")) return t.vimKind();
    const cfg = t.config;
    if (cfg.mode == .vim) return cfg.vim_kind;
    if (cfg.mode == .code and cfgIs(cfg, "code_keys", "vim")) return .type;
    return null;
}

/// Code typed with vim keys (the vim `.type` screen showing code).
pub fn isCodeVim(t: anytype) bool {
    return t.config.mode == .code and vimKind(t) == .type;
}

pub fn isZen(t: anytype) bool {
    if (comptime has(@TypeOf(t), "isZen")) return t.isZen();
    return is(t.config.mode, "zen");
}

pub fn isCustom(t: anytype) bool {
    return is(t.config.mode, "custom");
}

pub fn isDaily(t: anytype) bool {
    return is(t.config.mode, "daily");
}

/// Language of the current code (`config.lang` when the test can't say).
pub fn codeLang(t: anytype) types.Lang {
    if (comptime has(@TypeOf(t), "codeLang")) return t.codeLang();
    return t.config.lang;
}

/// The custom text ("" when none is set).
pub fn customText(t: anytype) []const u8 {
    if (comptime has(@TypeOf(t), "customText")) return t.customText();
    return "";
}

/// What a practice run drills, for the idle bar: "weak keys" for a
/// weak-key practice (`TypingTest.weak_practice`), else "missed words".
pub fn practiceKind(t: anytype) []const u8 {
    const T = Child(@TypeOf(t));
    if (comptime @hasField(T, "weak_practice")) {
        if (t.weak_practice) return "weak keys";
    }
    return "missed words";
}

/// Target characters a typist at `wpm` would have typed by now.
pub fn paceChars(t: anytype, now_ms: i64, wpm: f32) ?u64 {
    if (comptime has(@TypeOf(t), "paceChars")) return t.paceChars(now_ms, wpm);
    return null;
}

/// The daily run's date chip text, or null outside daily mode.
pub fn dailyDate(cfg: anytype, buf: *[10]u8) ?[]const u8 {
    if (!is(cfg.mode, "daily")) return null;
    return daily.format(cfg.day, buf);
}

/// Display column of byte `col` on a line (tabs to `tabstop`).
pub fn displayColOf(line: []const u8, col: usize, tabstop: usize) usize {
    var d: usize = 0;
    for (line[0..@min(col, line.len)]) |c| {
        d = if (c == '\t') nextTabStop(d, tabstop) else d + 1;
    }
    return d + (col -| line.len);
}

pub fn nextTabStop(d: usize, tabstop: usize) usize {
    const ts = @max(1, tabstop);
    return (d / ts + 1) * ts;
}

/// The editor's tabstop (8 when it has no options).
pub fn tabstopOf(ed: anytype) usize {
    const E = Child(@TypeOf(ed));
    if (comptime @hasField(E, "opts")) {
        if (comptime @hasField(@TypeOf(ed.opts), "tabstop")) return @max(1, ed.opts.tabstop);
    }
    return 8;
}

/// Display column of the editor's byte `col` on `row`.
pub fn displayCol(ed: anytype, row: usize, col: usize) usize {
    if (comptime has(@TypeOf(ed), "displayCol")) return ed.displayCol(row, col);
    const line = if (row < ed.buffer.lineCount()) ed.buffer.getLine(row) else "";
    return displayColOf(line, col, tabstopOf(ed));
}

/// Drill buffer equals the goal (any mode); the drill is solved only once
/// it is also back in NORMAL.
pub fn drillMatchesGoal(d: anytype) bool {
    if (comptime has(@TypeOf(d), "matchesGoal")) return d.matchesGoal();
    return false;
}

pub fn drillSolved(d: anytype) bool {
    if (comptime has(@TypeOf(d), "isSolved")) return d.isSolved();
    return false;
}

test "display columns expand tabs" {
    try std.testing.expectEqual(@as(usize, 0), displayColOf("\tab", 0, 8));
    try std.testing.expectEqual(@as(usize, 8), displayColOf("\tab", 1, 8));
    try std.testing.expectEqual(@as(usize, 9), displayColOf("\tab", 2, 8));
    try std.testing.expectEqual(@as(usize, 4), displayColOf("ab\tc", 3, 4));
    // Past the end: one column per byte.
    try std.testing.expectEqual(@as(usize, 5), displayColOf("ab", 5, 4));
}

test "enum queries tolerate missing tags" {
    const E = enum { a, b };
    try std.testing.expect(is(E.a, "a"));
    try std.testing.expect(!is(E.a, "zzz"));
    const C = struct { x: E = .b };
    try std.testing.expect(cfgIs(C{}, "x", "b"));
    try std.testing.expect(!cfgIs(C{}, "nope", "b"));
    try std.testing.expect(cfgBool(C{}, "nope", true));
}
