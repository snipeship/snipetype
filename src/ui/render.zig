//! UI rendering for the classic (non-arcade) modes through the abstract
//! `Renderer`. Both targets end in a real terminal (native, or ghostty-web in
//! the browser), so rounded box drawing, braille and the other one-column
//! UTF-8 glyphs from `ansi.zig` are used freely.
//!
//! `renderScreen` dispatches to one view per screen:
//! - `typing_view`: words / sentences / code while waiting or typing;
//! - `results`: the results card once a simple-mode test finished;
//! - `vim_view`: vim `.type` (retype the ghost target), results below;
//! - `drill_view`: vim `.drills` (edit the buffer to match the goal);
//! - `history_view`: the history overlay (`UiState.overlay == .history`),
//!   drawn instead of any of the above.
//!
//! Screens are chosen with the test's `vimKind()` (contract C3), so code
//! typed with vim keys uses `vim_view` like vim `.type`.
//!
//! Shared chrome (frame, header, footer hints, cards) lives in `draw.zig`.
//! Everything comes from the `TypingTest` (its `Session`, `live(now)` and
//! `result()`) and the App's `UiState`; the only state kept between frames
//! is the live WPM held for half a second (`typing_view.shown_wpm`). Every
//! view degrades down to a 30x8 terminal; below `MIN_WIDTH` x `MIN_HEIGHT`
//! (`MIN_HEIGHT_VIM` for the vim views) only a "terminal too small" notice
//! is drawn.

const std = @import("std");

const Theme = @import("theme.zig").Theme;
const Renderer = @import("../platform/renderer.zig").Renderer;
const TypingTest = @import("../core/typing_test.zig").TypingTest;
const drill_mod = @import("../vim/drill.zig");
const time = @import("../platform/time.zig");
const draw = @import("draw.zig");
const typing_view = @import("typing_view.zig");
const results = @import("results.zig");
const vim_view = @import("vim_view.zig");
const drill_view = @import("drill_view.zig");
const history_view = @import("history_view.zig");
const anim = @import("anim.zig");
const query = @import("query.zig");

pub const UiState = @import("ui_state.zig").UiState;

pub const Screen = enum { typing, results, vim_type, drill, history };

/// The screen drawn for `t` (a `*TypingTest` or a fixture) and `ui`.
pub fn screenOf(t: anytype, ui: *const UiState) Screen {
    if (ui.overlay == .history) return .history;
    if (query.vimKind(t)) |k| return if (k == .drills) .drill else .vim_type;
    if (t.state == .finished and t.result() != null) return .results;
    return .typing;
}

/// The App redraws this often while `animating` is true.
pub const ANIM_FRAME_MS: i64 = 33;

/// True while a results count-up, graph draw-in or PB sparkle needs frames
/// (at most `anim.SPARKLE_MS` after `ui.finished_ms`).
pub fn animating(t: *const TypingTest, ui: *const UiState, now_ms: i64) bool {
    return animatingAny(t, ui, now_ms);
}

pub fn animatingAny(t: anytype, ui: *const UiState, now_ms: i64) bool {
    if (ui.finished_ms == null or t.state != .finished or t.result() == null) return false;
    switch (screenOf(t, ui)) {
        .results, .vim_type => {},
        .typing, .drill, .history => return false,
    }
    return anim.active(ui.finished_ms, now_ms, sparkles(ui));
}

/// A PB sparkle runs for a first result or a new best.
pub fn sparkles(ui: *const UiState) bool {
    return ui.pb == .first or ui.pb == .improved;
}

fn catalogOf(t: *const TypingTest) drill_view.Catalog {
    const ch = t.drill.challenge orelse return .{ .total = drill_mod.all.len };
    return .{ .index = drill_mod.indexOf(ch.id) orelse 0, .total = drill_mod.all.len };
}

/// Draw the whole classic-mode screen for the test's current state.
pub fn renderScreen(r: Renderer, t: *TypingTest, theme: *const Theme, ui: *const UiState) void {
    renderAt(r, t, theme, ui, time.milliTimestamp());
}

/// Smallest terminal the views lay out in; below it (and below
/// `MIN_HEIGHT_VIM` rows for the vim views, whose buffer, stats and status
/// rows would overlap) only a notice is drawn. Writing a full layout into a
/// smaller terminal would run past its right edge, and the terminal's
/// autowrap would scroll the screen.
pub const MIN_WIDTH: usize = 20;
pub const MIN_HEIGHT: usize = 5;
pub const MIN_HEIGHT_VIM: usize = 7;

fn tooSmall(t: *const TypingTest, ui: *const UiState, w: usize, h: usize) bool {
    const min_h = switch (screenOf(t, ui)) {
        .vim_type, .drill => MIN_HEIGHT_VIM,
        .typing, .results, .history => MIN_HEIGHT,
    };
    return w < MIN_WIDTH or h < min_h;
}

fn renderTooSmall(r: Renderer, theme: *const Theme) void {
    const w = r.width();
    const h = r.height();
    draw.clearRows(r, 0, h -| 1);
    if (w == 0 or h == 0) return;
    const msg = "terminal too small";
    // Never the last column: a glyph there could wrap on some terminals.
    const max = w -| 1;
    const len = @min(msg.len, max);
    r.moveTo((w -| len) / 2, h / 2);
    draw.pen(r, theme.dim, null, false);
    _ = draw.writeClip(r, msg, max);
    r.resetStyle();
}

/// `renderScreen` at a given clock (tests).
pub fn renderAt(r: Renderer, t: *TypingTest, theme: *const Theme, ui: *const UiState, now_ms: i64) void {
    if (tooSmall(t, ui, r.width(), r.height())) return renderTooSmall(r, theme);
    switch (screenOf(t, ui)) {
        .history => history_view.render(r, theme, t.config, ui),
        .typing => typing_view.render(r, theme, t, ui, now_ms),
        .results => results.renderAnimated(r, theme, t.result().?, t.config, ui, now_ms),
        .vim_type => vim_view.render(r, theme, t, ui, now_ms),
        .drill => drill_view.render(r, theme, t, ui, catalogOf(t), now_ms),
    }
}

// ============================================================================
// Cursor Position
// ============================================================================

pub const CursorPos = struct {
    x: usize,
    y: usize,
    visible: bool = true,
};

/// Where the hardware cursor goes: the typing caret, the (scrolled) vim
/// cursor, the command line or the drill buffer pane's cursor. Hidden on
/// results and the history screen. Call after `renderScreen` (the editor
/// viewport is set there).
pub fn getCursorPos(t: *TypingTest, ui: *const UiState, width: usize, height: usize) CursorPos {
    if (tooSmall(t, ui, width, height)) return .{ .x = 0, .y = 0, .visible = false };
    switch (screenOf(t, ui)) {
        .history => return .{ .x = 0, .y = draw.frameFor(width, height).footer_y, .visible = false },
        .typing => {
            const p = typing_view.cursorPos(t, width, height);
            return .{ .x = p.x, .y = p.y };
        },
        .results => return .{ .x = 0, .y = draw.frameFor(width, height).footer_y, .visible = false },
        .vim_type => {
            const p = vim_view.cursorPos(t, width, height);
            return .{ .x = p.x, .y = p.y, .visible = p.visible };
        },
        .drill => {
            const p = drill_view.cursorPos(t, width, height);
            return .{ .x = p.x, .y = p.y, .visible = p.visible };
        },
    }
}

test {
    _ = anim;
    _ = query;
    _ = history_view;
    _ = draw;
    _ = typing_view;
    _ = results;
    _ = vim_view;
    _ = drill_view;
}
