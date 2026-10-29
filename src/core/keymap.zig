//! Key mapping for the classic modes (contract 6): rich `KeyEvent`s become
//! typing edits (`session.Edit`) or app commands. Vim modes go through
//! `vim/key.zig` instead; the App applies the few vim-mode exceptions
//! (Ctrl+P, Ctrl+C, Tab, F1) itself.
//!
//! Word deletion has several spellings because terminals and browsers
//! disagree: Ctrl+W, Ctrl+Backspace (kitty `CSI 127;5u`), Alt+Backspace
//! (`ESC DEL`) and Ctrl+H (legacy terminals send ^H for Ctrl+Backspace).
//! On the web Ctrl+W closes the tab on Windows/Linux, so the others matter.
//!
//! Round 2 (contract C6): Ctrl+K toggles code keys on the code idle screen,
//! F2 / `h` open the history screen, `w` on results starts weak-key
//! practice, zen finishes on Esc / Shift+Enter, and `historyAction` maps
//! the history screen's keys.

const std = @import("std");
const keys = @import("../platform/keys.zig");
const session = @import("session.zig");

const code = keys.code;
const KeyEvent = keys.KeyEvent;

pub const Edit = session.Edit;

pub const Command = enum {
    /// New text (or the next drill from vim normal mode).
    restart,
    quit,
    settings,
    /// Results: the next test (next drill in vim drills).
    next,
    /// Results: the same text / challenge again.
    retry,
    /// Results: a test built from the missed words.
    practice_missed,
    /// The history screen (F2 on idle/results, `h` on results).
    history,
    /// Results: a words test weighted toward the weakest keys.
    practice_weak,
    /// Code idle screen: plain keys <-> vim keys (Ctrl+K).
    toggle_code_keys,
    /// Zen: end the run now (Esc, Shift+Enter).
    finish,
};

/// Where a typing key arrives (the few context-dependent bindings).
pub const Context = struct {
    is_web: bool = false,
    /// The test has not started (idle screen).
    waiting: bool = false,
    /// Code mode (Ctrl+K toggles the keys while waiting).
    code: bool = false,
    /// Zen mode: Esc and Shift+Enter finish, Tab restarts.
    zen: bool = false,
};

pub const Action = union(enum) {
    none,
    edit: Edit,
    cmd: Command,

    pub fn eql(a: Action, b: Action) bool {
        return switch (a) {
            .none => b == .none,
            .cmd => |c| b == .cmd and b.cmd == c,
            .edit => |e| b == .edit and std.meta.eql(e, b.edit),
        };
    }
};

/// Ctrl+C: quit natively, restart on the web (the browser owns closing).
fn ctrlC(is_web: bool) Action {
    return .{ .cmd = if (is_web) .restart else .quit };
}

/// Simple modes (words, sentences, code) while waiting or typing.
pub fn typingAction(ev: KeyEvent, is_web: bool) Action {
    return typingActionIn(ev, .{ .is_web = is_web });
}

/// `typingAction` with the round-2 context bindings: F2 (history, idle),
/// Ctrl+K (code idle: toggle keys) and zen's Esc / Shift+Enter (finish).
pub fn typingActionIn(ev: KeyEvent, ctx: Context) Action {
    if (ev.kind == .release or code.isModifier(ev.code)) return .none;
    const m = ev.mods;
    const plain_mods = !m.ctrl and !m.alt and !m.super and !m.hyper and !m.meta;
    if (ev.code == code.f(2) and plain_mods and !m.shift) {
        return if (ctx.waiting) .{ .cmd = .history } else .none;
    }
    if (ctx.code and ctx.waiting and m.ctrl and !m.alt and !m.super and !m.shift and ev.code == 'k') {
        return .{ .cmd = .toggle_code_keys };
    }
    if (ctx.zen and plain_mods) {
        if (ev.code == code.escape and !m.shift) return .{ .cmd = .finish };
        if (ev.code == code.enter and m.shift) return .{ .cmd = .finish };
    }
    return baseTypingAction(ev, ctx.is_web);
}

fn baseTypingAction(ev: KeyEvent, is_web: bool) Action {
    const m = ev.mods;
    if (m.hyper or m.meta) return .none;
    const ctrl = m.ctrl;
    const alt = m.alt;
    const sup = m.super;

    switch (ev.code) {
        code.backspace => {
            if (sup) return .{ .edit = .delete_line };
            if (ctrl or alt) return .{ .edit = .delete_word };
            return .{ .edit = .backspace };
        },
        code.delete => {
            if (ctrl or alt) return .{ .edit = .delete_word_forward };
            if (sup) return .none;
            return .{ .edit = .delete_forward };
        },
        code.left => return .{ .edit = if (ctrl or alt or m.shift or sup) .word_left else .left },
        code.right => return .{ .edit = if (ctrl or alt or m.shift or sup) .word_right else .right },
        // Shift+Enter is a newline too (zen maps it to finish first).
        code.enter => return if (ctrl or alt or sup) .none else .{ .edit = .newline },
        code.tab => return if (ctrl or alt or sup or m.shift) .none else .{ .cmd = .restart },
        code.escape => return .{ .cmd = .restart },
        else => {},
    }
    if (sup) return .none;

    if (ctrl and !alt) {
        return switch (ev.code) {
            'c' => ctrlC(is_web),
            'p' => .{ .cmd = .settings },
            'w', 'h' => .{ .edit = .delete_word },
            'u' => .{ .edit = .delete_line },
            '[' => .{ .cmd = .restart }, // Ctrl+[ is Esc
            else => .none,
        };
    }
    if (alt and !ctrl) {
        return switch (ev.code) {
            'b' => .{ .edit = .word_left },
            'f' => .{ .edit = .word_right },
            'd' => .{ .edit = .delete_word_forward },
            else => .none,
        };
    }
    if (ctrl or alt) return .none;

    const ch = ev.char() orelse return .none;
    if (ch < 0x20 or ch > 0x7e) return .none;
    return .{ .edit = .{ .char = @intCast(ch) } };
}

/// Results screen (simple and vim modes).
pub fn resultsAction(ev: KeyEvent, is_web: bool) Action {
    if (ev.kind == .release or code.isModifier(ev.code)) return .none;
    const m = ev.mods;
    if (m.super or m.hyper or m.meta) return .none;
    if (m.ctrl and !m.alt) {
        return switch (ev.code) {
            'c' => ctrlC(is_web),
            'p' => .{ .cmd = .settings },
            '[' => .{ .cmd = .restart },
            else => .none,
        };
    }
    if (m.ctrl or m.alt) return .none;
    return switch (ev.code) {
        code.enter, code.space => .{ .cmd = .next },
        code.tab, code.escape => if (m.shift) .none else .{ .cmd = .restart },
        'r' => if (m.shift) .none else .{ .cmd = .retry },
        'm' => if (m.shift) .none else .{ .cmd = .practice_missed },
        'w' => if (m.shift) .none else .{ .cmd = .practice_weak },
        'h' => if (m.shift) .none else .{ .cmd = .history },
        'q' => if (m.shift or is_web) .none else .{ .cmd = .quit },
        else => if (ev.code == code.f(2) and !m.shift) .{ .cmd = .history } else .none,
    };
}

/// What a key does on the history screen.
pub const HistoryAction = union(enum) {
    none,
    close,
    /// Native Ctrl+C.
    quit,
    next_tab,
    prev_tab,
    /// Rows to scroll (negative: up).
    scroll: i32,
    top,
    bottom,
};

/// Rows a PgUp/PgDn moves on the history screen.
pub const HISTORY_PAGE: i32 = 10;

/// History screen keys (contract C6): Esc/q/h/F2 close, Tab/arrows switch
/// tabs, j/k/arrows/PgUp/PgDn/g/G scroll, Ctrl+C quits (web: closes).
pub fn historyAction(ev: KeyEvent, is_web: bool) HistoryAction {
    if (ev.kind == .release or code.isModifier(ev.code)) return .none;
    const m = ev.mods;
    if (m.super or m.hyper or m.meta or m.alt) return .none;
    if (m.ctrl) {
        return switch (ev.code) {
            'c' => if (is_web) .close else .quit,
            '[' => .close,
            else => .none,
        };
    }
    return switch (ev.code) {
        code.escape => .close,
        'q', 'h' => if (m.shift) .none else .close,
        code.tab => if (m.shift) .prev_tab else .next_tab,
        code.right => .next_tab,
        code.left => .prev_tab,
        code.down => .{ .scroll = 1 },
        code.up => .{ .scroll = -1 },
        'j' => if (m.shift) .none else .{ .scroll = 1 },
        'k' => if (m.shift) .none else .{ .scroll = -1 },
        code.page_down => .{ .scroll = HISTORY_PAGE },
        code.page_up => .{ .scroll = -HISTORY_PAGE },
        'g' => if (m.shift) .bottom else .top,
        'G' => .bottom,
        code.home => .top,
        code.end => .bottom,
        else => if (ev.code == code.f(2)) .close else .none,
    };
}

// ----------------------------------------------------------------------------

const testing = std.testing;

fn key(c: u21, mods: keys.Mods) KeyEvent {
    return .{ .code = c, .mods = mods };
}

fn expectAction(expected: Action, got: Action) !void {
    if (!expected.eql(got)) {
        std.debug.print("expected {any}, got {any}\n", .{ expected, got });
        return error.TestExpectedEqual;
    }
}

test "typing: word and line deletion spellings" {
    const dw: Action = .{ .edit = .delete_word };
    try expectAction(dw, typingAction(key('w', .{ .ctrl = true }), false));
    try expectAction(dw, typingAction(key('h', .{ .ctrl = true }), false));
    try expectAction(dw, typingAction(key(code.backspace, .{ .ctrl = true }), false));
    try expectAction(dw, typingAction(key(code.backspace, .{ .alt = true }), true));
    const dl: Action = .{ .edit = .delete_line };
    try expectAction(dl, typingAction(key('u', .{ .ctrl = true }), false));
    try expectAction(dl, typingAction(key(code.backspace, .{ .super = true }), true));
    try expectAction(.{ .edit = .backspace }, typingAction(key(code.backspace, .{}), false));
    try expectAction(.{ .edit = .delete_forward }, typingAction(key(code.delete, .{}), false));
    try expectAction(.{ .edit = .delete_word_forward }, typingAction(key(code.delete, .{ .alt = true }), false));
    try expectAction(.{ .edit = .delete_word_forward }, typingAction(key('d', .{ .alt = true }), false));
}

test "typing: chars, caret keys and commands" {
    try expectAction(.{ .edit = .{ .char = 'a' } }, typingAction(.{ .code = 'a', .text = 'a' }, false));
    try expectAction(.{ .edit = .{ .char = 'A' } }, typingAction(.{ .code = 'a', .mods = .{ .shift = true } }, false));
    try expectAction(.{ .edit = .{ .char = ' ' } }, typingAction(key(code.space, .{}), false));
    try expectAction(.{ .edit = .newline }, typingAction(key(code.enter, .{}), false));
    try expectAction(.{ .edit = .left }, typingAction(key(code.left, .{}), false));
    try expectAction(.{ .edit = .word_right }, typingAction(key(code.right, .{ .ctrl = true }), false));
    try expectAction(.{ .edit = .word_left }, typingAction(key('b', .{ .alt = true }), false));
    try expectAction(.{ .cmd = .restart }, typingAction(key(code.escape, .{}), false));
    try expectAction(.{ .cmd = .restart }, typingAction(key(code.tab, .{}), false));
    try expectAction(.{ .cmd = .quit }, typingAction(key('c', .{ .ctrl = true }), false));
    try expectAction(.{ .cmd = .restart }, typingAction(key('c', .{ .ctrl = true }), true));
    try expectAction(.{ .cmd = .settings }, typingAction(key('p', .{ .ctrl = true }), false));
    try expectAction(.none, typingAction(.{ .code = 'a', .kind = .release }, false));
    try expectAction(.none, typingAction(key(code.left_shift, .{ .shift = true }), false));
    try expectAction(.none, typingAction(key(0xe9, .{}), false));
    try expectAction(.none, typingAction(key(code.f(1), .{}), false));
}

test "results keys" {
    try expectAction(.{ .cmd = .next }, resultsAction(key(code.enter, .{}), false));
    try expectAction(.{ .cmd = .next }, resultsAction(key(code.space, .{}), false));
    try expectAction(.{ .cmd = .restart }, resultsAction(key(code.escape, .{}), false));
    try expectAction(.{ .cmd = .restart }, resultsAction(key(code.tab, .{}), false));
    try expectAction(.{ .cmd = .retry }, resultsAction(key('r', .{}), false));
    try expectAction(.{ .cmd = .practice_missed }, resultsAction(key('m', .{}), false));
    try expectAction(.{ .cmd = .quit }, resultsAction(key('q', .{}), false));
    try expectAction(.none, resultsAction(key('q', .{}), true));
    try expectAction(.{ .cmd = .restart }, resultsAction(key('c', .{ .ctrl = true }), true));
    try expectAction(.none, resultsAction(key('x', .{}), false));
}

test "round 2: ctrl+k, f2 and zen keys depend on the context" {
    const idle_code: Context = .{ .waiting = true, .code = true };
    try expectAction(.{ .cmd = .toggle_code_keys }, typingActionIn(key('k', .{ .ctrl = true }), idle_code));
    // Not in other modes, not once typing started.
    try expectAction(.none, typingActionIn(key('k', .{ .ctrl = true }), .{ .waiting = true }));
    try expectAction(.none, typingActionIn(key('k', .{ .ctrl = true }), .{ .code = true }));
    try expectAction(.{ .cmd = .history }, typingActionIn(key(code.f(2), .{}), .{ .waiting = true }));
    try expectAction(.none, typingActionIn(key(code.f(2), .{}), .{}));
    // Zen: Esc and Shift+Enter finish, Enter is a newline, Tab restarts.
    const zen: Context = .{ .zen = true };
    try expectAction(.{ .cmd = .finish }, typingActionIn(key(code.escape, .{}), zen));
    try expectAction(.{ .cmd = .finish }, typingActionIn(key(code.enter, .{ .shift = true }), zen));
    try expectAction(.{ .edit = .newline }, typingActionIn(key(code.enter, .{}), zen));
    try expectAction(.{ .cmd = .restart }, typingActionIn(key(code.tab, .{}), zen));
    try expectAction(.{ .cmd = .quit }, typingActionIn(key('c', .{ .ctrl = true }), zen));
    // Elsewhere Shift+Enter is a newline and Esc restarts.
    try expectAction(.{ .edit = .newline }, typingActionIn(key(code.enter, .{ .shift = true }), .{}));
    try expectAction(.{ .cmd = .restart }, typingActionIn(key(code.escape, .{}), .{}));
}

test "round 2: results h, w and f2" {
    try expectAction(.{ .cmd = .history }, resultsAction(key('h', .{}), false));
    try expectAction(.{ .cmd = .history }, resultsAction(key(code.f(2), .{}), true));
    try expectAction(.{ .cmd = .practice_weak }, resultsAction(key('w', .{}), false));
    try expectAction(.none, resultsAction(key('w', .{ .shift = true }), false));
}

test "history screen keys" {
    const H = HistoryAction;
    const eq = struct {
        fn f(a: H, b: H) !void {
            try testing.expect(std.meta.eql(a, b));
        }
    }.f;
    for ([_]u21{ code.escape, 'q', 'h', code.f(2) }) |c| try eq(.close, historyAction(key(c, .{}), false));
    try eq(.quit, historyAction(key('c', .{ .ctrl = true }), false));
    try eq(.close, historyAction(key('c', .{ .ctrl = true }), true));
    try eq(.next_tab, historyAction(key(code.tab, .{}), false));
    try eq(.prev_tab, historyAction(key(code.tab, .{ .shift = true }), false));
    try eq(.next_tab, historyAction(key(code.right, .{}), false));
    try eq(.prev_tab, historyAction(key(code.left, .{}), false));
    try eq(.{ .scroll = 1 }, historyAction(key('j', .{}), false));
    try eq(.{ .scroll = -1 }, historyAction(key(code.up, .{}), false));
    try eq(.{ .scroll = HISTORY_PAGE }, historyAction(key(code.page_down, .{}), false));
    try eq(.{ .scroll = -HISTORY_PAGE }, historyAction(key(code.page_up, .{}), false));
    try eq(.top, historyAction(key('g', .{}), false));
    try eq(.bottom, historyAction(key('g', .{ .shift = true }), false));
    try eq(.none, historyAction(key('x', .{}), false));
    try eq(.none, historyAction(.{ .code = 'q', .kind = .release }, false));
}
