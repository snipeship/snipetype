const std = @import("std");
const snipetype = @import("snipetype");

const Game = snipetype.game.model.Game;

pub const HELP =
    \\snipetype - Terminal Typing Test with Vim Drills and an Arcade
    \\
    \\USAGE: snipetype [arcade] [OPTIONS]
    \\       snipetype stats [--csv] [--limit N]
    \\       <command> | snipetype [OPTIONS]      (type what was piped in)
    \\
    \\OPTIONS:
    \\  -m, --mode <MODE>   words | sentences | code | vim | zen | custom |
    \\                      daily | arcade
    \\  -w, --words <N>     Number of words/items, 1-250 (default: 10)
    \\  -t, --time <SEC>    Time limit in seconds (15, 30, 60, 120, ...)
    \\  -l, --lang <LANG>   zig | rust | go | ts | python | c | bash | lua |
    \\                      sql | java | yaml | mixed
    \\  --tier <TIER>       easy | common | 5k | full word list (default: common)
    \\  --punct             Words mode: capitals and punctuation
    \\  --numbers           Words mode: mix in numbers
    \\  --no-punct, --no-numbers   Turn them off (over the saved settings)
    \\  --weak              Words mode: words weighted toward your weak keys
    \\                      (same as --focus weak; --focus normal undoes it)
    \\  --keys <KEYS>       Code mode: plain | vim (retype the snippet with
    \\                      vim keys; also ctrl+k on the code idle screen)
    \\  --vim [KIND]        Vim mode: drills | type (default: drills).
    \\                      With -m code and no kind: same as --keys vim
    \\  --drill <ID>        Vim drill id or lesson name to start at
    \\  --daily             The daily challenge (same 50 words for everyone
    \\                      on a UTC date)
    \\  --text <TEXT>       Type this text (custom mode)
    \\  --file <PATH>       Type the text of a file (custom mode)
    \\  --pace <PACE>       Pace caret: off | pb | <wpm> (default: pb, shown
    \\                      once you have a personal best for the setup)
    \\  --stop-on-error <S> off | letter | word: a wrong letter is not
    \\                      typed / a wrong word is not committed
    \\  --no-backspace      No corrections (--backspace turns them back on)
    \\  --layout <L>        qwerty | dvorak | colemak | colemak-dh: type
    \\                      that layout on a QWERTY keyboard (leave qwerty
    \\                      when your OS layout is already set)
    \\  --syntax, --no-syntax   Syntax colours for code (default: on)
    \\  --theme <SLUG>      one-dark | one-light | dracula | nord | ...
    \\  --no-save           Do not write settings or history
    \\  -h, --help          Show help
    \\
    \\  Piped input (`echo text | snipetype`) is typed as custom text; keys
    \\  then come from the terminal. Custom text is kept in custom.txt next
    \\  to the config.
    \\
    \\  Flags beat the saved settings for this run; a change made in
    \\  ctrl+p saves the whole current setup. Settings:
    \\  ~/.config/snipetype/config.json,
    \\  history: ~/.local/state/snipetype/history.jsonl (XDG_CONFIG_HOME,
    \\  XDG_STATE_HOME or SNIPETYPE_HOME move them).
    \\
    \\STATS:
    \\  snipetype stats     Totals, recent runs, bests per setup, wpm trend
    \\                      and your weakest keys (no terminal needed)
    \\  --csv               Every run as CSV (header + one row per run)
    \\  --limit <N>         Recent runs to list (default: 10)
    \\
    \\ARCADE OPTIONS:
    \\  --game <GAME>       words | keys (default: words)
    \\                      words = falling words of a quote, keys =
    \\                      keycaps, vim motions, ctrl chords, ex commands
    \\  --pace <PACE>       junior | senior | staff | 10x (default: senior)
    \\                      (off, pb or a number set the typing pace caret)
    \\  --speed <N>         1 | 2 | 4 | 8 | 16 (default: 1)
    \\  --gfx <GFX>         auto | kitty | cells (default: auto)
    \\                      auto = kitty graphics when supported, else
    \\                      half-block cells (also: SNIPETYPE_GFX)
    \\
    \\TYPING KEYS:
    \\  ctrl+w, ctrl+backspace, alt+backspace   Delete the word
    \\  ctrl+u              Delete back to the line start
    \\  left/right, ctrl+left/right   Move inside the current word
    \\  enter               Code: next line. Mid-line it skips the rest of
    \\                      the line (counted as missed); on an untouched
    \\                      line it does nothing, so a double enter is safe
    \\  esc, tab            Restart with new text
    \\  ctrl+k              Code idle screen: plain keys <-> vim keys
    \\  f2                  History (idle and results screens)
    \\  ctrl+p              Settings (theme, mode, test and options)
    \\  ctrl+c              Quit
    \\
    \\ZEN KEYS:
    \\  type freely; esc or shift+enter shows the results, tab clears
    \\
    \\RESULTS KEYS:
    \\  enter, space        Next test (next drill)
    \\  r                   Retry the same text
    \\  m                   Practise the missed words
    \\  w                   Practise your weakest keys
    \\  h, f2               History: recent runs, bests, per-key accuracy
    \\                      (tab switches tabs, j/k scroll, esc closes)
    \\  tab, esc            New text
    \\  q, ctrl+c           Quit
    \\
    \\VIM MODE:
    \\  drills: edit the buffer until it matches the goal, in as few
    \\  keystrokes as you can (par and stars). f1 or :hint shows a hint,
    \\  :e! retries, :w submits, :q skips, tab (normal mode) skips.
    \\  type: retype a code snippet in an empty buffer with vim keys.
    \\  Motions, operators, text objects, counts, registers, visual mode,
    \\  search, undo/redo, dot repeat and macros; see docs/vim.md.
    \\  ctrl+c in insert mode = esc; twice in normal mode quits.
    \\
    \\ARCADE KEYS:
    \\  Title:      tab game, left/right pace, up/down speed, enter clock in,
    \\              esc quit
    \\  Playing:    type what falls before it lands, esc pause
    \\  Paused:     esc resume, q back to title
    \\
    \\EXAMPLES:
    \\  snipetype                      10 common words
    \\  snipetype -w 25 --punct        25 words with punctuation
    \\  snipetype -t 30 --tier easy    30 seconds of easy words
    \\  snipetype -m sentences         Sentences and quotes
    \\  snipetype -m code -l rust      Multi-line Rust snippets
    \\  snipetype -m code --vim -l rust   Retype Rust snippets with vim keys
    \\  snipetype --daily              Today's daily challenge
    \\  snipetype -m zen               Free typing, esc to finish
    \\  echo "some text" | snipetype   Type your own text
    \\  snipetype --file notes.md -t 60   60 seconds of your file
    \\  snipetype --pace 80 --stop-on-error word   Pace caret, strict words
    \\  snipetype stats --csv > runs.csv   Export every run
    \\  snipetype -m vim               Vim drills
    \\  snipetype -m vim --drill textobj   Start at the text-object lesson
    \\  snipetype -m vim --vim type -l zig Retype Zig code with vim keys
    \\  snipetype arcade               Falling words arcade
    \\  snipetype arcade --game keys   Keycaps, chords and vim motions
    \\  snipetype arcade --pace 10x --speed 2 --gfx cells
    \\
;

/// Parsed command line: the config to start with (defaults plus flags),
/// the explicit flags (re-applied over the saved config) and `--no-save`.
pub const Args = struct {
    config: snipetype.Config = .{},
    overrides: snipetype.ConfigOverrides = .{},
    no_save: bool = false,
    /// `--file`: read by main.zig into `overrides.custom_text`.
    text_file: ?[]const u8 = null,
    /// `snipetype stats ...`: print the history and exit (no terminal).
    stats: ?Stats = null,
};

/// `snipetype stats [--csv] [--limit N]`.
pub const Stats = struct {
    csv: bool = false,
    /// Recent runs listed by the text report.
    limit: usize = 10,
};

/// Zig 0.16: argv comes from `std.process.Init.minimal.args`; the argv slice is
/// allocated from `arena` (process-lifetime `init.arena`) and is not retained.
pub fn parseArgs(arena: std.mem.Allocator, process_args: std.process.Args) !Args {
    const args = try process_args.toSlice(arena);
    return parseSlice(args);
}

/// `--game` value, case-insensitive like `--pace` and `--gfx`.
fn gameFromString(s: []const u8) ?Game {
    inline for (comptime std.meta.tags(Game)) |g| {
        if (std.ascii.eqlIgnoreCase(s, @tagName(g))) return g;
    }
    return null;
}

/// Parse argv (args[0] is the program name). String values (`--theme`,
/// `--drill`) point into `args`.
pub fn parseSlice(args: []const []const u8) !Args {
    var out: Args = .{};
    const cfg = &out.config;
    const ov = &out.overrides;
    if (args.len > 1 and std.mem.eql(u8, args[1], "stats")) return parseStats(args);
    // `--vim` without a kind: keys vim in code mode (decided at the end, so
    // `--vim -m code` works too).
    var bare_vim = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, a, "--daily")) {
            ov.mode = .daily;
        } else if (std.mem.eql(u8, a, "--keys") and has_value) {
            i += 1;
            ov.code_keys = snipetype.CodeKeys.fromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--stop-on-error") and has_value) {
            i += 1;
            ov.stop_on_error = snipetype.StopOnError.fromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--no-backspace")) {
            ov.no_backspace = true;
        } else if (std.mem.eql(u8, a, "--backspace")) {
            ov.no_backspace = false;
        } else if (std.mem.eql(u8, a, "--layout") and has_value) {
            i += 1;
            ov.layout = snipetype.Layout.fromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--weak")) {
            ov.focus = .weak;
        } else if (std.mem.eql(u8, a, "--focus") and has_value) {
            i += 1;
            ov.focus = snipetype.Focus.fromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--syntax")) {
            ov.syntax = true;
        } else if (std.mem.eql(u8, a, "--no-syntax")) {
            ov.syntax = false;
        } else if (std.mem.eql(u8, a, "--text") and has_value) {
            i += 1;
            ov.custom_text = args[i];
        } else if (std.mem.eql(u8, a, "--file") and has_value) {
            i += 1;
            out.text_file = args[i];
        } else if (std.mem.eql(u8, a, "arcade")) {
            ov.mode = .arcade;
        } else if ((std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--mode")) and has_value) {
            i += 1;
            ov.mode = snipetype.Mode.fromString(args[i]) orelse return error.InvalidArg;
        } else if ((std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--words")) and has_value) {
            i += 1;
            const n = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
            ov.word_count = std.math.clamp(n, snipetype.MIN_WORDS, snipetype.MAX_WORDS);
        } else if ((std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--time")) and has_value) {
            i += 1;
            ov.time_limit = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
        } else if ((std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--lang")) and has_value) {
            i += 1;
            ov.lang = snipetype.Lang.fromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--tier") and has_value) {
            i += 1;
            ov.tier = snipetype.WordTier.fromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--punct") or std.mem.eql(u8, a, "--punctuation")) {
            ov.punctuation = true;
        } else if (std.mem.eql(u8, a, "--numbers")) {
            ov.numbers = true;
        } else if (std.mem.eql(u8, a, "--no-punct") or std.mem.eql(u8, a, "--no-punctuation")) {
            ov.punctuation = false;
        } else if (std.mem.eql(u8, a, "--no-numbers")) {
            ov.numbers = false;
        } else if (std.mem.eql(u8, a, "--theme") and has_value) {
            i += 1;
            if (snipetype.theme.fromSlug(args[i]) == null) return error.InvalidArg;
            ov.theme = args[i];
        } else if (std.mem.eql(u8, a, "--vim")) {
            // A kind is consumed; anything else is the next argument.
            if (has_value) {
                if (snipetype.VimKind.fromString(args[i + 1])) |kind| {
                    i += 1;
                    ov.vim_kind = kind;
                    continue;
                }
            }
            bare_vim = true;
        } else if (std.mem.eql(u8, a, "--drill") and has_value) {
            i += 1;
            ov.drill = args[i];
            // A drill implies vim drills unless the mode was given.
            if (ov.mode == null) ov.mode = .vim;
            if (ov.vim_kind == null) ov.vim_kind = .drills;
        } else if (std.mem.eql(u8, a, "--no-save")) {
            out.no_save = true;
        } else if (std.mem.eql(u8, a, "--game") and has_value) {
            i += 1;
            cfg.arcade_game = gameFromString(args[i]) orelse return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--pace") and has_value) {
            i += 1;
            // Arcade pace names, else the typing pace caret (off/pb/wpm).
            if (snipetype.paceFromString(args[i])) |p| {
                cfg.arcade_pace = p;
            } else if (snipetype.parsePace(args[i])) |p| {
                ov.caret_pace = p.pace;
                if (p.wpm) |w| ov.caret_wpm = w;
            } else return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--speed") and has_value) {
            i += 1;
            const v = std.fmt.parseInt(u8, std.mem.trimEnd(u8, args[i], "xX"), 10) catch return error.InvalidArg;
            switch (v) {
                1, 2, 4, 8, 16 => cfg.arcade_speed = v,
                else => return error.InvalidArg,
            }
        } else if (std.mem.eql(u8, a, "--gfx") and has_value) {
            i += 1;
            cfg.gfx = snipetype.Gfx.fromString(args[i]) orelse return error.InvalidArg;
        } else {
            return error.InvalidArg;
        }
    }
    // `-w N` alone asks for N words: a saved time limit must not turn it
    // into a timed test.
    if (ov.word_count != null and ov.time_limit == null) ov.time_limit = 0;
    if (bare_vim) {
        // `-m code --vim`: vim keys; `--vim` alone: vim mode (drills).
        if (ov.mode == null) ov.mode = .vim;
        if (ov.mode.? == .code) ov.code_keys = .vim;
    }
    // Text implies custom mode unless a mode was given.
    if ((ov.custom_text != null or out.text_file != null) and ov.mode == null) ov.mode = .custom;
    ov.apply(cfg);
    return out;
}

fn parseStats(args: []const []const u8) !Args {
    var out: Args = .{ .stats = .{} };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--csv")) {
            out.stats.?.csv = true;
        } else if (std.mem.eql(u8, a, "--limit") and i + 1 < args.len) {
            i += 1;
            out.stats.?.limit = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
        } else if (std.mem.eql(u8, a, "--no-save")) {
            // Accepted (stats never writes).
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return error.HelpRequested;
        } else return error.InvalidArg;
    }
    return out;
}

/// Piped stdin is read as custom text only when `--text` / `--file` did
/// not give one (an explicit flag wins; the pipe is then left unread).
pub fn wantsStdinText(args: *const Args) bool {
    return args.overrides.custom_text == null and args.text_file == null;
}

/// Mark stdin text as custom text (implies custom mode unless `-m` was
/// given). Empty text (e.g. `< /dev/null`) is ignored, and so is any text
/// when `--text` / `--file` already gave one.
pub fn useStdinText(args: *Args, text: []const u8) void {
    if (!wantsStdinText(args)) return;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    args.overrides.custom_text = text;
    if (args.overrides.mode == null) {
        args.overrides.mode = .custom;
        args.config.mode = .custom;
    }
}

test "arcade arguments" {
    const c = (try parseSlice(&.{ "snipetype", "arcade", "--pace", "10x", "--speed", "4", "--gfx", "cells" })).config;
    try std.testing.expectEqual(snipetype.Mode.arcade, c.mode);
    try std.testing.expectEqual(snipetype.Pace.tenx, c.arcade_pace);
    try std.testing.expectEqual(@as(u8, 4), c.arcade_speed);
    try std.testing.expectEqual(snipetype.Gfx.cells, c.gfx);

    const d = (try parseSlice(&.{ "snipetype", "-m", "arcade" })).config;
    try std.testing.expectEqual(snipetype.Mode.arcade, d.mode);
    try std.testing.expectEqual(snipetype.Pace.senior, d.arcade_pace);
    try std.testing.expectEqual(Game.words, d.arcade_game);

    const g = (try parseSlice(&.{ "snipetype", "arcade", "--game", "keys" })).config;
    try std.testing.expectEqual(Game.keys, g.arcade_game);
    try std.testing.expectEqual(Game.keys, (try parseSlice(&.{ "snipetype", "--game", "KEYS" })).config.arcade_game);
    try std.testing.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--game", "tetris" }));

    const w = (try parseSlice(&.{ "snipetype", "-w", "25" })).config;
    try std.testing.expectEqual(snipetype.Mode.words, w.mode);
    try std.testing.expectEqual(@as(usize, 25), w.word_count);

    try std.testing.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--speed", "3" }));
    try std.testing.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--gfx", "sixel" }));
    try std.testing.expectError(error.HelpRequested, parseSlice(&.{ "snipetype", "--help" }));
}

test "typing and persistence flags" {
    const t = std.testing;
    const a = try parseSlice(&.{ "snipetype", "--tier", "easy", "--punct", "--numbers", "--theme", "nord", "--no-save", "-t", "30" });
    try t.expectEqual(snipetype.WordTier.easy, a.config.tier);
    try t.expect(a.config.punctuation and a.config.numbers);
    try t.expectEqual(@as(usize, 30), a.config.time_limit);
    try t.expectEqualStrings("nord", a.overrides.theme.?);
    try t.expect(a.no_save);
    // Only what was given is an override.
    try t.expectEqual(@as(?usize, 30), a.overrides.time_limit);
    try t.expect(a.overrides.mode == null and a.overrides.word_count == null and a.overrides.lang == null);

    const v = try parseSlice(&.{ "snipetype", "-m", "vim", "--vim", "type" });
    try t.expectEqual(snipetype.VimKind.type, v.config.vim_kind);
    const d = try parseSlice(&.{ "snipetype", "--drill", "basics" });
    try t.expectEqual(snipetype.Mode.vim, d.config.mode);
    try t.expectEqual(snipetype.VimKind.drills, d.config.vim_kind);
    try t.expectEqualStrings("basics", d.overrides.drill.?);

    // -w clamps to 1..250.
    try t.expectEqual(@as(usize, 250), (try parseSlice(&.{ "snipetype", "-w", "999" })).config.word_count);
    try t.expectEqual(@as(usize, 200), (try parseSlice(&.{ "snipetype", "-w", "200" })).config.word_count);
    try t.expectEqual(@as(usize, 1), (try parseSlice(&.{ "snipetype", "-w", "0" })).config.word_count);

    // --no-punct / --no-numbers beat a saved "on".
    const off = try parseSlice(&.{ "snipetype", "--no-punct", "--no-numbers" });
    try t.expectEqual(@as(?bool, false), off.overrides.punctuation);
    try t.expectEqual(@as(?bool, false), off.overrides.numbers);

    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--tier", "hard" }));
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--vim", "emacs" }));
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--theme" }));
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--theme", "nope" }));
    try t.expectEqualStrings("one_dark", (try parseSlice(&.{ "snipetype", "--theme", "one_dark" })).overrides.theme.?);

    // -w alone is a word-count test even over a saved time limit; -t wins.
    try t.expectEqual(@as(?usize, 0), (try parseSlice(&.{ "snipetype", "-w", "25" })).overrides.time_limit);
    try t.expectEqual(@as(?usize, 30), (try parseSlice(&.{ "snipetype", "-w", "25", "-t", "30" })).overrides.time_limit);
    try t.expectEqual(@as(?usize, 30), (try parseSlice(&.{ "snipetype", "-t", "30", "-w", "25" })).overrides.time_limit);
    // Defaults: common tier, vim drills, saving on.
    const z = try parseSlice(&.{"snipetype"});
    try t.expectEqual(snipetype.WordTier.common, z.config.tier);
    try t.expectEqual(snipetype.VimKind.drills, z.config.vim_kind);
    try t.expect(!z.no_save);
}

test "round 2 flags" {
    const t = std.testing;
    const a = try parseSlice(&.{ "snipetype", "-m", "zen" });
    try t.expectEqual(snipetype.Mode.zen, a.config.mode);
    try t.expectEqual(snipetype.Mode.daily, (try parseSlice(&.{ "snipetype", "--daily" })).config.mode);
    try t.expectEqual(snipetype.Mode.custom, (try parseSlice(&.{ "snipetype", "-m", "custom" })).config.mode);
    try t.expectEqual(snipetype.WordTier.k5, (try parseSlice(&.{ "snipetype", "--tier", "5k" })).config.tier);
    for ([_][]const u8{ "bash", "lua", "sql", "java", "yaml" }) |l| {
        _ = try parseSlice(&.{ "snipetype", "-l", l });
    }
    const b = try parseSlice(&.{ "snipetype", "--keys", "vim", "--pace", "60", "--stop-on-error", "word", "--no-backspace", "--layout", "colemak-dh", "--weak", "--no-syntax" });
    try t.expectEqual(snipetype.CodeKeys.vim, b.config.code_keys);
    try t.expectEqual(snipetype.CaretPace.fixed, b.config.caret_pace);
    try t.expectEqual(@as(u16, 60), b.config.caret_wpm);
    try t.expectEqual(snipetype.StopOnError.word, b.config.stop_on_error);
    try t.expect(b.config.no_backspace and !b.config.syntax);
    try t.expectEqual(snipetype.Layout.colemak_dh, b.config.layout);
    try t.expectEqual(snipetype.Focus.weak, b.config.focus);
    try t.expectEqual(@as(?bool, false), (try parseSlice(&.{ "snipetype", "--no-backspace", "--backspace" })).overrides.no_backspace);
    try t.expectEqual(snipetype.Focus.normal, (try parseSlice(&.{ "snipetype", "--focus", "normal" })).overrides.focus.?);
    try t.expectEqual(@as(?bool, true), (try parseSlice(&.{ "snipetype", "--syntax" })).overrides.syntax);
    // --pace: typing caret (off/pb/number) or the arcade pace names.
    try t.expectEqual(snipetype.CaretPace.off, (try parseSlice(&.{ "snipetype", "--pace", "off" })).config.caret_pace);
    try t.expectEqual(snipetype.CaretPace.pb, (try parseSlice(&.{ "snipetype", "--pace", "pb" })).overrides.caret_pace.?);
    const ap = try parseSlice(&.{ "snipetype", "arcade", "--pace", "10x" });
    try t.expectEqual(snipetype.Pace.tenx, ap.config.arcade_pace);
    try t.expect(ap.overrides.caret_pace == null);
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--pace", "fast" }));
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--layout", "azerty" }));
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--stop-on-error", "maybe" }));
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "--keys", "emacs" }));
}

test "--vim: a kind, or keys vim in code mode" {
    const t = std.testing;
    // Kind given: vim mode's kind, as before.
    const v = try parseSlice(&.{ "snipetype", "-m", "vim", "--vim", "type" });
    try t.expectEqual(snipetype.VimKind.type, v.config.vim_kind);
    try t.expect(v.overrides.code_keys == null);
    // -m code --vim and --vim -m code: code with vim keys.
    for ([_][]const []const u8{
        &.{ "snipetype", "-m", "code", "--vim" },
        &.{ "snipetype", "--vim", "-m", "code" },
        &.{ "snipetype", "-m", "code", "--vim", "-l", "rust" },
    }) |argv| {
        const c = try parseSlice(argv);
        try t.expectEqual(snipetype.Mode.code, c.config.mode);
        try t.expectEqual(snipetype.CodeKeys.vim, c.config.code_keys);
    }
    try t.expectEqual(snipetype.Lang.rust, (try parseSlice(&.{ "snipetype", "-m", "code", "--vim", "-l", "rust" })).config.lang);
    // --vim alone: vim mode.
    const alone = try parseSlice(&.{ "snipetype", "--vim" });
    try t.expectEqual(snipetype.Mode.vim, alone.config.mode);
    try t.expect(alone.overrides.code_keys == null);
    // A kind with -m code is still a kind (vim mode's setting, saved).
    try t.expectEqual(snipetype.VimKind.drills, (try parseSlice(&.{ "snipetype", "-m", "code", "--vim", "drills" })).overrides.vim_kind.?);
}

test "custom text sources and stats" {
    const t = std.testing;
    const a = try parseSlice(&.{ "snipetype", "--text", "hello there" });
    try t.expectEqual(snipetype.Mode.custom, a.config.mode);
    try t.expectEqualStrings("hello there", a.overrides.custom_text.?);
    const f = try parseSlice(&.{ "snipetype", "--file", "notes.md", "-t", "30" });
    try t.expectEqual(snipetype.Mode.custom, f.config.mode);
    try t.expectEqualStrings("notes.md", f.text_file.?);
    // An explicit mode wins.
    try t.expectEqual(snipetype.Mode.words, (try parseSlice(&.{ "snipetype", "-m", "words", "--text", "x" })).config.mode);

    var s = try parseSlice(&.{"snipetype"});
    useStdinText(&s, "piped words\n");
    try t.expectEqual(snipetype.Mode.custom, s.config.mode);
    try t.expectEqualStrings("piped words\n", s.overrides.custom_text.?);
    var e = try parseSlice(&.{ "snipetype", "-m", "code" });
    useStdinText(&e, "  \n");
    try t.expect(e.overrides.custom_text == null);
    useStdinText(&e, "x");
    try t.expectEqual(snipetype.Mode.code, e.config.mode);
    // `--text` / `--file` beat a pipe (`echo x | snipetype --text y`).
    var given = try parseSlice(&.{ "snipetype", "--text", "given" });
    try t.expect(!wantsStdinText(&given));
    useStdinText(&given, "piped");
    try t.expectEqualStrings("given", given.overrides.custom_text.?);
    var file = try parseSlice(&.{ "snipetype", "--file", "notes.md" });
    try t.expect(!wantsStdinText(&file));
    useStdinText(&file, "piped");
    try t.expect(file.overrides.custom_text == null);
    try t.expect(wantsStdinText(&(try parseSlice(&.{ "snipetype", "-m", "code" }))));

    const st = try parseSlice(&.{ "snipetype", "stats", "--csv", "--limit", "5" });
    try t.expect(st.stats.?.csv);
    try t.expectEqual(@as(usize, 5), st.stats.?.limit);
    try t.expect(!(try parseSlice(&.{ "snipetype", "stats" })).stats.?.csv);
    try t.expect((try parseSlice(&.{ "snipetype", "stats", "--no-save" })).stats != null);
    try t.expectError(error.InvalidArg, parseSlice(&.{ "snipetype", "stats", "--bogus" }));
    try t.expect((try parseSlice(&.{"snipetype"})).stats == null);
}
