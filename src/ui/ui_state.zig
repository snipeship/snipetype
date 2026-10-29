//! Per-frame UI facts the App knows but the test doesn't (personal bests,
//! toasts, host, overlays, history). Filled by `App` before each
//! `render.renderScreen`.

const std = @import("std");
const history = @import("../core/history.zig");

pub const Log = history.Log;
pub const PbTable = history.PbTable;

/// Full-screen overlay drawn instead of the current screen.
pub const Overlay = enum { none, history };

/// Tabs of the history screen.
pub const HistoryTab = enum {
    recent,
    bests,
    keys,

    pub fn next(self: HistoryTab) HistoryTab {
        const n = std.meta.tags(HistoryTab).len;
        return @fromBackingInt(@intCast((@backingInt(self) + 1) % n));
    }

    pub fn prev(self: HistoryTab) HistoryTab {
        const n = std.meta.tags(HistoryTab).len;
        return @fromBackingInt(@intCast((@backingInt(self) + n - 1) % n));
    }

    pub fn label(self: HistoryTab) []const u8 {
        return @tagName(self);
    }
};

pub const UiState = struct {
    is_web: bool = false,
    /// Results banner for the finished test (`improved` / `missed` carry the
    /// previous best: wpm, or strokes for drills).
    pb: history.PbOutcome = .none,
    /// PB for the current pbKey (idle config bar, results).
    best_wpm: ?f32 = null,
    drill_best: ?history.DrillBest = null,
    /// The test is a missed-words or weak-keys practice run (never recorded).
    practice: bool = false,
    /// One-line message (static string), drawn above the footer.
    toast: ?[]const u8 = null,
    overlay: Overlay = .none,
    history_tab: HistoryTab = .recent,
    /// Rows scrolled in the history list (the view clamps it).
    history_scroll: usize = 0,
    log: ?*const Log = null,
    pbs: ?*const PbTable = null,
    /// Pace caret speed (null: no caret). App: caret_pace .pb → best_wpm,
    /// .fixed → caret_wpm, .off → null; always null in zen and vim modes.
    pace_wpm: ?f32 = null,
    /// When the results appeared (App.finished_ms); null = draw the final
    /// frame (tests, no animation).
    finished_ms: ?i64 = null,
};

test "defaults" {
    const ui: UiState = .{};
    try std.testing.expect(ui.pb == .none and ui.toast == null and !ui.is_web);
    try std.testing.expect(ui.overlay == .none and ui.pace_wpm == null and ui.finished_ms == null);
}

test "history tabs cycle" {
    try std.testing.expectEqual(HistoryTab.bests, HistoryTab.recent.next());
    try std.testing.expectEqual(HistoryTab.recent, HistoryTab.keys.next());
    try std.testing.expectEqual(HistoryTab.keys, HistoryTab.recent.prev());
    try std.testing.expectEqual(HistoryTab.bests, HistoryTab.keys.prev());
}
