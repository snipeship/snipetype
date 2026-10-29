//! Shared config types (mode/lang/config).

const std = @import("std");

pub const Mode = enum {
    words,
    sentences,
    code,
    vim,
    /// "snipetype arcade": falling keycaps (src/game/), rendered as pixels.
    arcade,
    /// Free typing, no target; Esc or Shift+Enter finishes (web id 5).
    zen,
    /// The user's own text: --text, --file, stdin, paste, web dialog (web id 6).
    custom,
    /// DAILY_WORDS common words with punctuation, the same text for everyone
    /// on a UTC date (web id 7).
    daily,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .words => "words",
            .sentences => "sentences",
            .code => "code",
            .vim => "vim",
            .arcade => "arcade",
            .zen => "zen",
            .custom => "custom",
            .daily => "daily",
        };
    }

    pub fn fromString(s: []const u8) ?Mode {
        inline for (comptime std.meta.tags(Mode)) |mode| {
            if (std.mem.eql(u8, s, @tagName(mode))) return mode;
        }
        return null;
    }
};

pub const Lang = enum {
    mixed,
    zig,
    rust,
    go,
    typescript,
    python,
    c,
    bash,
    lua,
    sql,
    java,
    yaml,

    pub fn name(self: Lang) []const u8 {
        return switch (self) {
            .mixed => "mixed",
            .zig => "zig",
            .rust => "rust",
            .go => "go",
            .typescript => "ts",
            .python => "python",
            .c => "c",
            .bash => "bash",
            .lua => "lua",
            .sql => "sql",
            .java => "java",
            .yaml => "yaml",
        };
    }

    pub fn fromString(s: []const u8) ?Lang {
        if (std.mem.eql(u8, s, "mixed")) return .mixed;
        if (std.mem.eql(u8, s, "zig")) return .zig;
        if (std.mem.eql(u8, s, "rust") or std.mem.eql(u8, s, "rs")) return .rust;
        if (std.mem.eql(u8, s, "go")) return .go;
        if (std.mem.eql(u8, s, "typescript") or std.mem.eql(u8, s, "ts") or std.mem.eql(u8, s, "js")) return .typescript;
        if (std.mem.eql(u8, s, "python") or std.mem.eql(u8, s, "py")) return .python;
        if (std.mem.eql(u8, s, "c")) return .c;
        if (std.mem.eql(u8, s, "bash") or std.mem.eql(u8, s, "sh") or std.mem.eql(u8, s, "shell")) return .bash;
        if (std.mem.eql(u8, s, "lua")) return .lua;
        if (std.mem.eql(u8, s, "sql")) return .sql;
        if (std.mem.eql(u8, s, "java")) return .java;
        if (std.mem.eql(u8, s, "yaml") or std.mem.eql(u8, s, "yml")) return .yaml;
        return null;
    }
};

/// Arcade difficulty (shared with the game sim).
pub const Pace = @import("../game/model.zig").Pace;

/// Arcade game: falling words (default) or the key/chord stages.
pub const Game = @import("../game/model.zig").Game;

/// Arcade pixel output preference (`--gfx`). Native only; the web host
/// always draws pixels on its own canvas.
pub const Gfx = enum {
    /// Kitty graphics when the terminal supports it, else half-blocks.
    auto,
    /// Force the kitty graphics protocol.
    kitty,
    /// Force half-block cells (works in any truecolor terminal).
    cells,

    pub fn fromString(s: []const u8) ?Gfx {
        if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(s, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(s, "cells") or std.ascii.eqlIgnoreCase(s, "halfblock")) return .cells;
        return null;
    }
};

/// Word list for words mode (`--tier`).
pub const WordTier = enum {
    /// Top-200 list.
    easy,
    /// Hand-written common 1k list (default).
    common,
    /// Hand-curated 5k list (wordlists/en_5k.txt).
    k5,
    /// The full words_en.txt list.
    full,

    pub fn name(self: WordTier) []const u8 {
        return if (self == .k5) "5k" else @tagName(self);
    }

    pub fn fromString(s: []const u8) ?WordTier {
        if (std.mem.eql(u8, s, "5k") or std.mem.eql(u8, s, "5K") or std.mem.eql(u8, s, "5000")) return .k5;
        inline for (comptime std.meta.tags(WordTier)) |t| {
            if (std.ascii.eqlIgnoreCase(s, @tagName(t))) return t;
        }
        return null;
    }
};

/// What vim mode practises (`--vim`): goal-buffer drills or retyping code.
pub const VimKind = enum {
    drills,
    type,

    pub fn name(self: VimKind) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?VimKind {
        if (std.ascii.eqlIgnoreCase(s, "drills") or std.ascii.eqlIgnoreCase(s, "drill")) return .drills;
        if (std.ascii.eqlIgnoreCase(s, "type") or std.ascii.eqlIgnoreCase(s, "retype")) return .type;
        return null;
    }
};

/// Code mode keys: type the snippet plainly or retype it with vim keys.
pub const CodeKeys = enum {
    plain,
    vim,

    pub fn name(self: CodeKeys) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?CodeKeys {
        return tagFromString(CodeKeys, s);
    }
};

/// Pace caret: off, at the PB for this setup (only when one exists), or at
/// `Config.caret_wpm`.
pub const CaretPace = enum {
    off,
    pb,
    fixed,

    pub fn name(self: CaretPace) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?CaretPace {
        return tagFromString(CaretPace, s);
    }
};

/// Strict typing: a wrong letter is not inserted (letter) or a wrong word
/// is not committed (word).
pub const StopOnError = enum {
    off,
    letter,
    word,

    pub fn name(self: StopOnError) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?StopOnError {
        return tagFromString(StopOnError, s);
    }
};

/// Layout emulation: what a QWERTY key position types in the simple modes.
pub const Layout = enum {
    qwerty,
    dvorak,
    colemak,
    colemak_dh,

    pub fn name(self: Layout) []const u8 {
        return if (self == .colemak_dh) "colemak-dh" else @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Layout {
        if (std.ascii.eqlIgnoreCase(s, "colemak-dh") or std.ascii.eqlIgnoreCase(s, "colemakdh")) return .colemak_dh;
        return tagFromString(Layout, s);
    }
};

/// Words mode word choice: the normal list or weighted toward weak keys.
pub const Focus = enum {
    normal,
    weak,

    pub fn name(self: Focus) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Focus {
        return tagFromString(Focus, s);
    }
};

/// Case-insensitive tag-name lookup shared by the small option enums.
fn tagFromString(comptime E: type, s: []const u8) ?E {
    inline for (comptime std.meta.tags(E)) |t| {
        if (std.ascii.eqlIgnoreCase(s, @tagName(t))) return t;
    }
    return null;
}

pub fn paceFromString(s: []const u8) ?Pace {
    if (std.ascii.eqlIgnoreCase(s, "junior")) return .junior;
    if (std.ascii.eqlIgnoreCase(s, "senior")) return .senior;
    if (std.ascii.eqlIgnoreCase(s, "staff")) return .staff;
    if (std.ascii.eqlIgnoreCase(s, "10x") or std.ascii.eqlIgnoreCase(s, "tenx")) return .tenx;
    return null;
}

pub const Config = struct {
    mode: Mode = .words,
    word_count: usize = 10,
    time_limit: usize = 0,
    lang: Lang = .mixed,
    /// Arcade: starting pace and speed multiplier (1, 2, 4, 8, 16); both
    /// can still be changed on the title screen.
    arcade_pace: Pace = .senior,
    arcade_speed: u8 = 1,
    /// Arcade: which game the shift plays (`--game`).
    arcade_game: Game = .words,
    /// Arcade: pixel output backend preference (native).
    gfx: Gfx = .auto,
    /// Words mode: which word list.
    tier: WordTier = .common,
    punctuation: bool = false,
    numbers: bool = false,
    /// Vim mode: drills (default) or retype.
    vim_kind: VimKind = .drills,
    /// Drill to load on the next reset (a static challenge id literal from
    /// src/vim/drill.zig); null → first challenge.
    drill_id: ?[]const u8 = null,
    /// Code mode: type with plain keys or retype the snippet with vim keys.
    code_keys: CodeKeys = .plain,
    /// Pace caret: off, at your PB for this setup (shown only when one
    /// exists), or at caret_wpm.
    caret_pace: CaretPace = .pb,
    /// Fixed pace caret speed, clamped to CARET_WPM_MIN..CARET_WPM_MAX.
    caret_wpm: u16 = 80,
    stop_on_error: StopOnError = .off,
    /// "Confidence": Backspace, Ctrl+W, Ctrl+U and forward deletes do nothing.
    no_backspace: bool = false,
    /// Layout emulation: what a QWERTY key position types (simple modes).
    layout: Layout = .qwerty,
    focus: Focus = .normal,
    /// Syntax colours for untyped code (code mode, vim views).
    syntax: bool = true,
    /// Web: typing sounds in the classic modes.
    sounds: bool = false,
    // ---- runtime only, never persisted ----
    /// Daily: UTC days since 1970-01-01 (the App sets it before every reset
    /// in daily mode).
    day: u32 = 0,
    /// Custom: FNV-1a 32 of the sanitized custom text
    /// (TypingTest.setCustomText sets it).
    custom_hash: u32 = 0,
};

/// Daily challenge length (words).
pub const DAILY_WORDS: usize = 50;
/// Bounds for the fixed pace caret speed.
pub const CARET_WPM_MIN: u16 = 10;
pub const CARET_WPM_MAX: u16 = 300;

/// Settings given explicitly on the command line (native) or in the URL
/// (web). They beat the saved config (precedence: defaults, saved config,
/// overrides) and are applied by `App.loadSaved`.
pub const ConfigOverrides = struct {
    mode: ?Mode = null,
    word_count: ?usize = null,
    time_limit: ?usize = null,
    lang: ?Lang = null,
    tier: ?WordTier = null,
    punctuation: ?bool = null,
    numbers: ?bool = null,
    vim_kind: ?VimKind = null,
    /// Challenge id or lesson name (resolved by the App).
    drill: ?[]const u8 = null,
    /// Theme slug ("one-dark", ...).
    theme: ?[]const u8 = null,
    code_keys: ?CodeKeys = null,
    caret_pace: ?CaretPace = null,
    caret_wpm: ?u16 = null,
    stop_on_error: ?StopOnError = null,
    no_backspace: ?bool = null,
    layout: ?Layout = null,
    focus: ?Focus = null,
    syntax: ?bool = null,
    sounds: ?bool = null,
    /// Not applied by apply(): the App hands it to TypingTest.setCustomText
    /// (implies mode custom unless a mode was given).
    custom_text: ?[]const u8 = null,

    /// Write every explicit field into `cfg` (not `drill`, `theme` or
    /// `custom_text`).
    pub fn apply(self: ConfigOverrides, cfg: *Config) void {
        if (self.mode) |v| cfg.mode = v;
        if (self.word_count) |v| cfg.word_count = std.math.clamp(v, MIN_WORDS, MAX_WORDS);
        if (self.time_limit) |v| cfg.time_limit = v;
        if (self.lang) |v| cfg.lang = v;
        if (self.tier) |v| cfg.tier = v;
        if (self.punctuation) |v| cfg.punctuation = v;
        if (self.numbers) |v| cfg.numbers = v;
        if (self.vim_kind) |v| cfg.vim_kind = v;
        if (self.code_keys) |v| cfg.code_keys = v;
        if (self.caret_pace) |v| cfg.caret_pace = v;
        if (self.caret_wpm) |v| cfg.caret_wpm = std.math.clamp(v, CARET_WPM_MIN, CARET_WPM_MAX);
        if (self.stop_on_error) |v| cfg.stop_on_error = v;
        if (self.no_backspace) |v| cfg.no_backspace = v;
        if (self.layout) |v| cfg.layout = v;
        if (self.focus) |v| cfg.focus = v;
        if (self.syntax) |v| cfg.syntax = v;
        if (self.sounds) |v| cfg.sounds = v;
    }

    /// URL query → overrides. Unknown keys and bad values are ignored. The
    /// theme accepts `one-dark` and `one_dark` (copied into `theme_buf`).
    pub fn fromQuery(q: []const u8, theme_buf: *[32]u8) ConfigOverrides {
        var ov: ConfigOverrides = .{};
        var it = std.mem.splitScalar(u8, std.mem.trimStart(u8, q, "?"), '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const k = if (eq) |i| pair[0..i] else pair;
            const v = if (eq) |i| pair[i + 1 ..] else "";
            const on = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off"));
            if (std.mem.eql(u8, k, "mode")) {
                if (Mode.fromString(v)) |m| ov.mode = m;
            } else if (std.mem.eql(u8, k, "words")) {
                if (std.fmt.parseInt(usize, v, 10)) |n| {
                    ov.word_count = n;
                } else |_| {}
            } else if (std.mem.eql(u8, k, "time")) {
                if (std.fmt.parseInt(usize, v, 10)) |n| {
                    ov.time_limit = n;
                } else |_| {}
            } else if (std.mem.eql(u8, k, "lang")) {
                if (Lang.fromString(v)) |l| ov.lang = l;
            } else if (std.mem.eql(u8, k, "tier")) {
                if (WordTier.fromString(v)) |t| ov.tier = t;
            } else if (std.mem.eql(u8, k, "punct") or std.mem.eql(u8, k, "punctuation")) {
                ov.punctuation = on;
            } else if (std.mem.eql(u8, k, "numbers")) {
                ov.numbers = on;
            } else if (std.mem.eql(u8, k, "vim")) {
                if (VimKind.fromString(v)) |kind| ov.vim_kind = kind;
            } else if (std.mem.eql(u8, k, "drill")) {
                if (v.len > 0) ov.drill = v;
            } else if (std.mem.eql(u8, k, "keys")) {
                if (CodeKeys.fromString(v)) |ck| ov.code_keys = ck;
            } else if (std.mem.eql(u8, k, "pace")) {
                if (parsePace(v)) |p| {
                    ov.caret_pace = p.pace;
                    if (p.wpm) |w| ov.caret_wpm = w;
                }
            } else if (std.mem.eql(u8, k, "stop")) {
                if (StopOnError.fromString(v)) |so| ov.stop_on_error = so;
            } else if (std.mem.eql(u8, k, "nobs")) {
                ov.no_backspace = on;
            } else if (std.mem.eql(u8, k, "layout")) {
                if (Layout.fromString(v)) |l| ov.layout = l;
            } else if (std.mem.eql(u8, k, "focus")) {
                if (Focus.fromString(v)) |f| ov.focus = f;
            } else if (std.mem.eql(u8, k, "syntax")) {
                ov.syntax = on;
            } else if (std.mem.eql(u8, k, "sounds")) {
                ov.sounds = on;
            } else if (std.mem.eql(u8, k, "theme") and v.len > 0 and v.len <= theme_buf.len) {
                for (v, 0..) |c, i| theme_buf[i] = if (c == '_') '-' else c;
                ov.theme = theme_buf[0..v.len];
            }
        }
        // `words=N` alone asks for N words (not a saved time limit).
        if (ov.word_count != null and ov.time_limit == null) ov.time_limit = 0;
        // A drill implies vim drills unless the mode was given (like `--drill`).
        if (ov.drill != null) {
            if (ov.mode == null) ov.mode = .vim;
            if (ov.vim_kind == null) ov.vim_kind = .drills;
        }
        return ov;
    }
};

/// A pace caret spec: "off", "pb" or a wpm number (→ fixed, clamped).
pub const PaceSpec = struct { pace: CaretPace, wpm: ?u16 = null };

/// Parse `--pace` / `pace=`: "off", "pb", "fixed" or a number of wpm.
pub fn parsePace(s: []const u8) ?PaceSpec {
    if (CaretPace.fromString(s)) |p| return .{ .pace = p };
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    const w: u16 = @intCast(std.math.clamp(n, CARET_WPM_MIN, CARET_WPM_MAX));
    return .{ .pace = .fixed, .wpm = w };
}

/// Bounds for `word_count` (CLI and settings).
pub const MIN_WORDS: usize = 1;
pub const MAX_WORDS: usize = 250;

test "overrides from a URL query" {
    var tb: [32]u8 = undefined;
    const ov = ConfigOverrides.fromQuery("?mode=code&words=25&time=x&punct=1&numbers=0&theme=one_dark&tier=easy&drill=find&bogus", &tb);
    try std.testing.expectEqual(Mode.code, ov.mode.?);
    try std.testing.expectEqual(@as(usize, 25), ov.word_count.?);
    // `time=x` is invalid; `words` alone means a word-count test.
    try std.testing.expectEqual(@as(?usize, 0), ov.time_limit);
    try std.testing.expectEqual(@as(?usize, 30), ConfigOverrides.fromQuery("words=25&time=30", &tb).time_limit);
    try std.testing.expect(ConfigOverrides.fromQuery("mode=code", &tb).time_limit == null);
    const d = ConfigOverrides.fromQuery("drill=textobj", &tb);
    try std.testing.expectEqual(Mode.vim, d.mode.?);
    try std.testing.expectEqual(VimKind.drills, d.vim_kind.?);
    try std.testing.expect(ov.punctuation.? and !ov.numbers.?);
    try std.testing.expectEqualStrings("one-dark", ov.theme.?);
    try std.testing.expectEqual(WordTier.easy, ov.tier.?);
    try std.testing.expectEqualStrings("find", ov.drill.?);
    var cfg: Config = .{};
    (ConfigOverrides{ .word_count = 999 }).apply(&cfg);
    try std.testing.expectEqual(MAX_WORDS, cfg.word_count);
}

test "WordTier and VimKind round-trip" {
    for (std.meta.tags(WordTier)) |t| try std.testing.expectEqual(t, WordTier.fromString(t.name()).?);
    for (std.meta.tags(VimKind)) |k| try std.testing.expectEqual(k, VimKind.fromString(k.name()).?);
    try std.testing.expect(WordTier.fromString("hard") == null);
    try std.testing.expect(VimKind.fromString("x") == null);
}

test "round 2 enums round-trip" {
    for (std.meta.tags(Mode)) |m| try std.testing.expectEqual(m, Mode.fromString(m.name()).?);
    for (std.meta.tags(Lang)) |l| try std.testing.expectEqual(l, Lang.fromString(l.name()).?);
    for (std.meta.tags(CodeKeys)) |t| try std.testing.expectEqual(t, CodeKeys.fromString(t.name()).?);
    for (std.meta.tags(CaretPace)) |t| try std.testing.expectEqual(t, CaretPace.fromString(t.name()).?);
    for (std.meta.tags(StopOnError)) |t| try std.testing.expectEqual(t, StopOnError.fromString(t.name()).?);
    for (std.meta.tags(Layout)) |t| try std.testing.expectEqual(t, Layout.fromString(t.name()).?);
    for (std.meta.tags(Focus)) |t| try std.testing.expectEqual(t, Focus.fromString(t.name()).?);
    try std.testing.expectEqualStrings("5k", WordTier.k5.name());
    try std.testing.expectEqual(WordTier.k5, WordTier.fromString("5000").?);
    try std.testing.expectEqual(Lang.bash, Lang.fromString("sh").?);
    try std.testing.expectEqual(Lang.bash, Lang.fromString("shell").?);
    try std.testing.expectEqual(Lang.yaml, Lang.fromString("yml").?);
    try std.testing.expectEqual(Layout.colemak_dh, Layout.fromString("colemak_dh").?);
    try std.testing.expectEqual(Layout.colemak_dh, Layout.fromString("ColemakDH").?);
    try std.testing.expect(Layout.fromString("azerty") == null);
    // Web ids are the enum order: keep the round-1 ones stable.
    try std.testing.expectEqual(@as(usize, 5), @backingInt(Mode.zen));
    try std.testing.expectEqual(@as(usize, 7), @backingInt(Mode.daily));
    try std.testing.expectEqual(@as(usize, 7), @backingInt(Lang.bash));
    try std.testing.expectEqual(@as(usize, 11), @backingInt(Lang.yaml));
}

test "round 2 query keys and apply" {
    var tb: [32]u8 = undefined;
    const ov = ConfigOverrides.fromQuery("mode=zen&keys=vim&pace=60&stop=word&nobs=1&layout=colemak-dh&focus=weak&syntax=0&sounds=1&tier=5k&lang=bash", &tb);
    try std.testing.expectEqual(Mode.zen, ov.mode.?);
    try std.testing.expectEqual(CodeKeys.vim, ov.code_keys.?);
    try std.testing.expectEqual(CaretPace.fixed, ov.caret_pace.?);
    try std.testing.expectEqual(@as(u16, 60), ov.caret_wpm.?);
    try std.testing.expectEqual(StopOnError.word, ov.stop_on_error.?);
    try std.testing.expect(ov.no_backspace.?);
    try std.testing.expectEqual(Layout.colemak_dh, ov.layout.?);
    try std.testing.expectEqual(Focus.weak, ov.focus.?);
    try std.testing.expect(!ov.syntax.? and ov.sounds.?);
    try std.testing.expectEqual(WordTier.k5, ov.tier.?);
    try std.testing.expectEqual(Lang.bash, ov.lang.?);
    const off = ConfigOverrides.fromQuery("pace=off&mode=daily&keys=bogus&nobs=0", &tb);
    try std.testing.expectEqual(CaretPace.off, off.caret_pace.?);
    try std.testing.expect(off.caret_wpm == null and off.code_keys == null and !off.no_backspace.?);
    try std.testing.expectEqual(Mode.daily, off.mode.?);
    try std.testing.expectEqual(CaretPace.pb, ConfigOverrides.fromQuery("pace=pb", &tb).caret_pace.?);
    try std.testing.expect(ConfigOverrides.fromQuery("pace=fast", &tb).caret_pace == null);
    try std.testing.expectEqual(Mode.custom, ConfigOverrides.fromQuery("mode=custom", &tb).mode.?);

    var cfg: Config = .{};
    ov.apply(&cfg);
    try std.testing.expectEqual(CodeKeys.vim, cfg.code_keys);
    try std.testing.expectEqual(@as(u16, 60), cfg.caret_wpm);
    try std.testing.expectEqual(Layout.colemak_dh, cfg.layout);
    try std.testing.expect(cfg.no_backspace and !cfg.syntax and cfg.sounds);
    (ConfigOverrides{ .caret_wpm = 5000 }).apply(&cfg);
    try std.testing.expectEqual(CARET_WPM_MAX, cfg.caret_wpm);
    try std.testing.expectEqual(CARET_WPM_MIN, parsePace("1").?.wpm.?);
}
