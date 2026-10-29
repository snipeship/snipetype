//! Shared application state and logic.
//! Used by both native CLI and web entry points.
//!
//! Typing modes render through the immediate-mode `Renderer`. Arcade mode
//! (`Mode.arcade`) owns a game sim, a scene, a pixel `Surface` and a
//! `Presenter` (created lazily on entry, destroyed on exit): each frame the
//! scene draws into the surface and the presenter's bytes go to the renderer
//! verbatim. The platform layer picks the presenter backend (`setGfx`).
//!
//! Classic modes route rich key events (contract 6): words / sentences /
//! code through `keymap.zig` into `TypingTest.handleEdit`, vim modes through
//! `vim/key.zig` into `TypingTest.handleVimKey`. Persistence is
//! platform-neutral here: hosts pass saved bytes to `loadSaved` and write
//! what `takeRecordLine` / `takeConfigJson` return.
//!
//! Round 2: code mode can retype its snippet with vim keys (Ctrl+K on the
//! idle screen, `TypingTest.vimKind()` routes it to the vim path); a
//! history overlay (F2, `h` on results) reads `log` and `pb_table`; zen,
//! custom and daily modes; weak-key practice; layout emulation of typed
//! chars; web typing sounds; and an animation render tail for the results
//! (`render_ui.animating`).

const std = @import("std");

const constants = @import("constants.zig");
const types = @import("types.zig");
const typing_test = @import("typing_test.zig");
const time = @import("../platform/time.zig");
const render_ui = @import("../ui/render.zig");
const theme_mod = @import("../ui/theme.zig");
const settings_mod = @import("../ui/settings.zig");
const ui_state = @import("../ui/ui_state.zig");
const history_view = @import("../ui/history_view.zig");
const keymap = @import("keymap.zig");
const history = @import("history.zig");
const daily = @import("daily.zig");
const layout_mod = @import("layout.zig");
const stats_mod = @import("stats.zig");
const vimkey = @import("../vim/key.zig");
const vim_editor = @import("../vim/editor.zig");
const drill = @import("../vim/drill.zig");
const Renderer = @import("../platform/renderer.zig").Renderer;
const Input = @import("../platform/input.zig").Input;
const Key = @import("../platform/input.zig").Key;
const keys = @import("../platform/keys.zig");
const arcade_mod = @import("../game/arcade.zig");
const model = @import("../game/model.zig");
const scene_mod = @import("../game/scene.zig");
const gfx = @import("../gfx/presenter.zig");
const Surface = @import("../fx/surface.zig").Surface;

const Arcade = arcade_mod.Arcade;
const Scene = scene_mod.Scene;
const Presenter = gfx.Presenter;

const Config = types.Config;
const TypingTest = typing_test.TypingTest;
const TestState = typing_test.TestState;
const ThemeId = theme_mod.ThemeId;
const Settings = settings_mod.Settings;
const UiState = ui_state.UiState;
const VimKey = vimkey.VimKey;
const FeedResult = vim_editor.FeedResult;

/// Redraw interval while typing with nothing changed (timer, live stats).
pub const TYPING_REDRAW_MS: i64 = 100;
/// Redraw interval while a pace caret moves (the diff renderer keeps each
/// frame to a few changed cells).
pub const PACE_REDRAW_MS: i64 = 50;
/// Largest bracketed paste kept as custom text (TypingTest truncates
/// further to MAX_CUSTOM_BYTES).
pub const MAX_PASTE_BYTES: usize = 64 * 1024;
/// How long a toast stays on screen.
pub const TOAST_MS: i64 = 2500;
/// Second Ctrl+C in vim NORMAL within this window quits (web: restarts).
pub const CTRL_C_WINDOW_MS: i64 = 1500;
/// Results keys are ignored this long after a finish: keys still in flight
/// (a trailing space, the next word when a timed test ends, a vim key after
/// the drill solved itself) must not skip the results or quit. Ctrl chords
/// (Ctrl+C, Ctrl+P) always work.
pub const RESULTS_GUARD_MS: i64 = 500;

/// Result of handling a key
pub const KeyResult = enum {
    none,
    quit,
    handled,
};

/// Sound effect kinds (wire values shared with web/audio.js).
pub const SfxKind = enum(u32) {
    key_letter = 0,
    key_digit = 1,
    key_big = 2,
    key_arrow = 3,
    wrong = 4,
    miss = 5,
    level_up = 6,
    milestone = 7,
    fx_tier1 = 8,
    fx_tier2 = 9,
    fx_tier3 = 10,
    phrase_done = 11,
    game_over = 12,
    start = 13,
};

/// One sound to play: stereo `pan` -1..1, `intensity` 0..1.
pub const Sfx = struct { kind: SfxKind, pan: f32, intensity: f32 };

const SFX_CAPACITY = 64;

/// Arcade frame interval (~60 fps).
pub const ARCADE_FRAME_MS: i64 = 16;

/// Arcade output configuration chosen by the platform layer.
pub const GfxSetup = struct {
    /// Native: `.kitty` or `.halfblock`; web: `.external`.
    backend: gfx.Backend = .halfblock,
    /// Presenter options (kitty media, temp dir, unique id, ...).
    opts: gfx.Options = .{},
    /// Terminal reports modifier chords (kitty keyboard / web host).
    chords: bool = true,
    /// Minimum time between arcade frames.
    frame_ms: i64 = ARCADE_FRAME_MS,
};

/// Everything arcade mode needs; heap-allocated so nothing moves.
const ArcadeState = struct {
    arc: Arcade,
    scene: Scene,
    surface: Surface,
    presenter: Presenter,
    /// The settings overlay is drawn over a frozen frame.
    overlay_shown: bool = false,
};

/// Shared application state
pub const App = struct {
    allocator: std.mem.Allocator,
    test_state: TypingTest,
    settings_ui: Settings,
    theme_id: ThemeId,

    // Render state
    dirty: bool,
    needs_full_clear: bool,
    last_state: TestState,
    last_render_ms: i64,

    // Error message to display (cleared on next successful operation)
    error_msg: ?[]const u8,

    // Classic modes
    /// Seed of the current text (history records).
    seed: u64 = 0,
    /// Personal bests from the saved history.
    pb_table: history.PbTable,
    /// Outcome of the finished test against `pb_table` (results banner).
    pb: history.PbOutcome = .none,
    /// The current run's finish has been scored and recorded.
    finish_seen: bool = false,
    /// When the finish was seen (`RESULTS_GUARD_MS`).
    finished_ms: i64 = 0,
    toast_msg: ?[]const u8 = null,
    toast_until_ms: i64 = 0,
    /// Time of the last vim NORMAL Ctrl+C (double press quits).
    ctrl_c_ms: ?i64 = null,
    /// Inside a bracketed paste (keys are dropped in typing modes).
    in_paste: bool = false,
    /// Web on Windows/Linux: Ctrl+W closes the tab; show a one-time hint
    /// the first time vim insert mode is entered (see `setHost`).
    ctrlw_hint_pending: bool = false,
    /// The Ctrl+W hint was shown (the host remembers it; `takeHintShown`).
    ctrlw_hint_shown: bool = false,
    /// History line waiting for the host (`takeRecordLine`).
    record_buf: [2048]u8 = undefined,
    record_len: usize = 0,
    /// Config changed (theme, mode or test options) since the last save.
    config_dirty: bool = false,
    config_buf: [1024]u8 = undefined,
    /// Every run in the saved history plus this session's (history screen,
    /// weak keys).
    log: history.Log,
    /// Full-screen overlay (history) drawn instead of the test.
    overlay: ui_state.Overlay = .none,
    history_tab: ui_state.HistoryTab = .recent,
    history_scroll: usize = 0,
    /// Size of the last classic frame (history scroll is clamped to the
    /// view's last page; 0 until the first render).
    view_w: usize = 0,
    view_h: usize = 0,
    /// Custom mode: a bracketed paste on the idle screen becomes the text.
    paste_capture: bool = false,
    paste_buf: std.ArrayList(u8) = .empty,
    /// The custom text changed (hosts persist it; `takeCustomText`).
    custom_pending: bool = false,
    /// Web: the settings `text` row asked for the custom-text dialog.
    custom_dialog_requested: bool = false,
    /// Toasts with numbers ("custom text: 12 words").
    toast_buf: [64]u8 = undefined,
    /// Mode written to the config while arcade runs (arcade is not saved
    /// as the start mode).
    saved_mode: types.Mode = .words,

    /// Running in the web host (footer hints, Ctrl+C semantics in the UI).
    is_web: bool = false,

    // Arcade
    gfx_setup: GfxSetup = .{},
    /// Terminal cell size in pixels (0 = unknown; 8x16 assumed).
    cell_px_w: u16 = 0,
    cell_px_h: u16 = 0,
    arcade: ?*ArcadeState = null,
    /// Presenter teardown bytes still to be written (after leaving arcade).
    pending_buf: [256]u8 = undefined,
    pending_len: usize = 0,
    /// Collect arcade sounds for the host (web); native has no audio.
    collect_sfx: bool = false,
    sfx_buf: [SFX_CAPACITY]Sfx = undefined,
    sfx_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, seed: u64, config: Config) !App {
        const test_state = try TypingTest.init(allocator, seed, config);
        return .{
            .allocator = allocator,
            .test_state = test_state,
            .settings_ui = Settings{},
            .theme_id = .system,
            .dirty = true,
            .needs_full_clear = true,
            .last_state = test_state.state,
            .last_render_ms = 0,
            .error_msg = null,
            .seed = seed,
            .pb_table = history.PbTable.init(allocator),
            .log = history.Log.init(allocator),
            .saved_mode = if (config.mode == .arcade) .words else config.mode,
        };
    }

    pub fn deinit(self: *App) void {
        self.destroyArcade();
        self.test_state.deinit();
        self.pb_table.deinit();
        self.log.deinit();
        self.paste_buf.deinit(self.allocator);
    }

    /// Reset the test with a new seed
    pub fn reset(self: *App, seed: u64) void {
        self.error_msg = null; // Clear any previous error
        self.seed = seed;
        self.beforeReset();
        self.test_state.reset(seed) catch {
            self.error_msg = "Failed to reset - out of memory";
            // Keep the current state usable
        };
        self.afterReset();
        self.syncArcade();
        if (self.arcade) |st| {
            st.arc.reset(seed);
            st.scene.reset();
        }
    }

    /// Runtime config the next text depends on: today's UTC day (daily; a
    /// session crossing midnight gets the new day on the next test) and the
    /// weak-key weights (words with focus weak, from every run so far).
    fn beforeReset(self: *App) void {
        const c = &self.test_state.config;
        if (c.mode == .daily) c.day = daily.dayFromUnix(time.unixSeconds());
        if (c.focus == .weak and c.mode == .words) {
            var w: stats_mod.KeyWeights = undefined;
            self.test_state.setWeakWeights(if (self.log.weakWeights(&w)) &w else null);
        }
    }

    /// Bookkeeping after the test was reset or restarted.
    fn afterReset(self: *App) void {
        self.needs_full_clear = true;
        self.last_state = self.test_state.state;
        self.dirty = true;
        self.pb = .none;
        self.finish_seen = false;
        self.ctrl_c_ms = null;
    }

    // ------------------------------------------------------------------
    // Input

    /// Handle a rich input event (native and web). Probe replies are
    /// ignored (capabilities are detected at startup). In arcade mode keys
    /// (including releases) go to the game, except Ctrl+C (quit native,
    /// back to the title on web), Ctrl+P (settings) and Esc on the title
    /// screen (quit native). Bracketed-paste text is dropped in the other
    /// modes (and marks the run as pasted).
    pub fn handleEvent(self: *App, ev: keys.Event, is_web: bool) KeyResult {
        const k = switch (ev) {
            .reply => return .none,
            .key => |k| k,
        };
        if (!self.settings_ui.is_open) self.settings_ui.base = self.test_state.config;
        if (k.code == keys.code.paste_start or k.code == keys.code.paste_end) {
            self.in_paste = k.code == keys.code.paste_start;
            if (self.in_paste) {
                if (self.capturesPaste()) {
                    self.paste_capture = true;
                    self.paste_buf.clearRetainingCapacity();
                } else if (!self.isArcade()) self.notePaste();
            } else if (self.paste_capture) {
                self.paste_capture = false;
                self.finishPasteCapture();
            }
            return .handled;
        }
        if (self.isArcade() and !self.settings_ui.is_open) {
            const st = self.ensureArcade() orelse return .none;
            return self.arcadeKey(st, k, is_web);
        }
        if (self.in_paste) {
            if (self.paste_capture) self.capturePasteKey(k);
            return .none;
        }
        if (self.settings_ui.is_open) return self.settingsKey(k, is_web);
        if (self.overlay != .none) return self.overlayKey(k, is_web);
        const result = if (self.test_state.isVim()) self.vimKey(k, is_web) else self.simpleKey(k, is_web);
        self.checkFinish();
        return result;
    }

    fn arcadeKey(self: *App, st: *ArcadeState, k: keys.KeyEvent, is_web: bool) KeyResult {
        self.error_msg = null;
        const m = k.mods;
        const only_ctrl = m.ctrl and !m.alt and !m.super;
        const plain = !m.ctrl and !m.alt and !m.super and !m.shift;
        if (only_ctrl and (k.code == 'c' or k.code == 'p')) {
            if (k.kind == .release) return .handled;
            if (k.code == 'c') {
                if (!is_web) return .quit;
                st.arc.reset(self.generateSeed());
                st.scene.reset();
            } else {
                if (st.arc.phase == .playing) st.arc.phase = .paused;
                self.openSettings();
            }
            self.dirty = true;
            return .handled;
        }
        if (!is_web and plain and k.kind == .press and k.code == keys.code.escape and st.arc.phase == .title) {
            return .quit;
        }
        st.arc.handleKey(k, time.milliTimestamp());
        self.dirty = true;
        return .handled;
    }

    /// Settings overlay keys (legacy `Key` form). Native Ctrl+C quits even
    /// over the overlay.
    fn settingsKey(self: *App, k: keys.KeyEvent, is_web: bool) KeyResult {
        self.error_msg = null;
        const key = k.toLegacy() orelse return .none;
        if (!is_web and key == .Byte and key.Byte == 0x03) return .quit;
        const original_theme = self.settings_ui.original_theme;
        const action = self.settings_ui.handleKey(key);
        switch (action) {
            .none => {},
            .preview_theme => |id| {
                self.theme_id = id;
                self.needs_full_clear = true;
            },
            .apply_mode => |mode| {
                self.setMode(mode, self.generateSeed());
                self.config_dirty = true;
            },
            .apply_config => |cfg| {
                self.applyOptions(cfg);
                self.reset(self.generateSeed());
                self.config_dirty = true;
            },
            .close => self.needs_full_clear = true,
            .edit_custom_text => {
                // Web: the host opens its dialog; natively the row is a hint.
                if (is_web) self.custom_dialog_requested = true;
                self.needs_full_clear = true;
            },
            .cancel => |id| {
                self.theme_id = id;
                self.needs_full_clear = true;
            },
        }
        if (!self.settings_ui.is_open and self.theme_id != original_theme) self.config_dirty = true;
        self.dirty = true;
        return .handled;
    }

    /// Copy the test options of `cfg` (mode included; arcade and gfx
    /// fields stay as they are).
    fn applyOptions(self: *App, cfg: Config) void {
        const c = &self.test_state.config;
        c.mode = cfg.mode;
        c.word_count = std.math.clamp(cfg.word_count, types.MIN_WORDS, types.MAX_WORDS);
        c.time_limit = cfg.time_limit;
        c.lang = cfg.lang;
        c.tier = cfg.tier;
        c.punctuation = cfg.punctuation;
        c.numbers = cfg.numbers;
        c.vim_kind = cfg.vim_kind;
        c.drill_id = cfg.drill_id;
        c.code_keys = cfg.code_keys;
        c.caret_pace = cfg.caret_pace;
        c.caret_wpm = std.math.clamp(cfg.caret_wpm, types.CARET_WPM_MIN, types.CARET_WPM_MAX);
        c.stop_on_error = cfg.stop_on_error;
        c.no_backspace = cfg.no_backspace;
        c.layout = cfg.layout;
        c.focus = cfg.focus;
        c.syntax = cfg.syntax;
        c.sounds = cfg.sounds;
    }

    /// Words, sentences, code, zen, custom and daily (keymap.zig).
    fn simpleKey(self: *App, k: keys.KeyEvent, is_web: bool) KeyResult {
        self.error_msg = null;
        if (self.resultsGuarded(k)) return .none;
        const cfg = self.test_state.config;
        const action = if (self.test_state.state == .finished)
            keymap.resultsAction(k, is_web)
        else
            keymap.typingActionIn(k, .{
                .is_web = is_web,
                .waiting = self.test_state.state == .waiting,
                .code = cfg.mode == .code,
                .zen = self.test_state.isZen(),
            });
        switch (action) {
            .none => return .none,
            .edit => |e| {
                var edit = e;
                // Layout emulation: the char a QWERTY key position types.
                if (edit == .char and cfg.layout != .qwerty) edit = .{ .char = layout_mod.remap(cfg.layout, edit.char) };
                self.test_state.handleEdit(edit, time.milliTimestamp());
                self.keySound(k.code, self.test_state.lastEditWrong());
                self.dirty = true;
                return .handled;
            },
            .cmd => |c| return self.command(c),
        }
    }

    /// Web typing sounds for the classic modes (`Config.sounds`).
    fn keySound(self: *App, code: u21, wrong: bool) void {
        if (!self.collect_sfx or !self.test_state.config.sounds or self.isArcade()) return;
        if (keySfx(code, 0.5)) |s| self.pushSfx(s);
        if (wrong) self.pushSfx(.{ .kind = .wrong, .pan = 0, .intensity = 0.5 });
    }

    fn pushSfx(self: *App, s: Sfx) void {
        if (self.sfx_len >= SFX_CAPACITY) return;
        self.sfx_buf[self.sfx_len] = s;
        self.sfx_len += 1;
    }

    /// Vim modes: keys go to the editor (vim/key.zig), except Ctrl+P
    /// (settings), F1 (drill hint), Tab in NORMAL (restart / skip) and the
    /// results screen. Ctrl+C is fed as Esc; in NORMAL a second press
    /// within `CTRL_C_WINDOW_MS` quits (web: restarts).
    fn vimKey(self: *App, k: keys.KeyEvent, is_web: bool) KeyResult {
        self.error_msg = null;
        if (k.kind == .release or keys.code.isModifier(k.code)) return .none;
        const m = k.mods;
        const only_ctrl = m.ctrl and !m.alt and !m.super;
        const plain = !m.ctrl and !m.alt and !m.super and !m.shift;
        if (self.test_state.state == .finished) {
            if (self.resultsGuarded(k)) return .none;
            return switch (keymap.resultsAction(k, is_web)) {
                .none => .none,
                .edit => .none,
                .cmd => |c| self.command(c),
            };
        }
        if (only_ctrl and k.code == 'p') return self.command(.settings);
        if (self.test_state.state == .waiting) {
            // Idle-only app keys: Ctrl+K (code: back to plain keys), F2.
            if (only_ctrl and !m.shift and k.code == 'k' and self.test_state.config.mode == .code) {
                return self.command(.toggle_code_keys);
            }
            if (plain and k.code == keys.code.f(2)) return self.command(.history);
        }
        const now = time.milliTimestamp();
        const ed = self.test_state.activeEditor();
        if (plain and k.code == keys.code.f(1)) {
            self.revealHint();
            return .handled;
        }
        if (plain and k.code == keys.code.tab) {
            if (ed.mode == .normal) {
                if (!ed.isPending()) return self.command(.restart);
            } else if (ed.mode.isVisual()) {
                // Every visual mode (block too): Tab leaves it like Esc.
                return self.feedVim(.esc, now, is_web);
            }
            return self.feedVim(.tab, now, is_web);
        }
        if (only_ctrl and k.code == 'c') {
            const idle_normal = ed.mode == .normal and !ed.isPending();
            const res = self.test_state.handleVimKey(.{ .ctrl = 'c' }, now);
            self.dirty = true;
            if (res.interrupt or idle_normal) {
                if (self.ctrl_c_ms) |t| {
                    if (now - t <= CTRL_C_WINDOW_MS) {
                        self.ctrl_c_ms = null;
                        if (!is_web) return .quit;
                        self.reset(self.generateSeed());
                        return .handled;
                    }
                }
                self.ctrl_c_ms = now;
                self.showToast(if (is_web) "press ctrl+c again to restart" else "press ctrl+c again to quit");
                return .handled;
            }
            self.ctrl_c_ms = null;
            return self.afterFeed(res, is_web);
        }
        self.ctrl_c_ms = null;
        var buf: [2]VimKey = undefined;
        const vks = vimkey.fromKeyEvent(k, &buf);
        if (vks.len == 0) return .none;
        self.keySound(k.code, false);
        var result: KeyResult = .handled;
        for (vks) |vk| {
            result = self.feedVim(vk, now, is_web);
            if (result == .quit or self.test_state.state == .finished) break;
        }
        return result;
    }

    fn feedVim(self: *App, vk: VimKey, now: i64, is_web: bool) KeyResult {
        const res = self.test_state.handleVimKey(vk, now);
        self.dirty = true;
        return self.afterFeed(res, is_web);
    }

    /// Act on an editor feed: ex commands, the one-time web Ctrl+W hint.
    fn afterFeed(self: *App, res: FeedResult, is_web: bool) KeyResult {
        if (self.ctrlw_hint_pending and self.test_state.activeEditor().mode == .insert) {
            self.ctrlw_hint_pending = false;
            self.ctrlw_hint_shown = true;
            self.showToast("ctrl+w belongs to the browser here: use ctrl+backspace");
        }
        const ex = res.ex orelse return .handled;
        switch (ex) {
            .write, .write_quit => {
                if (!self.test_state.submit(time.milliTimestamp()) and self.isDrills()) {
                    self.showToast("not solved yet");
                }
            },
            .quit => return self.command(.next),
            .quit_force => {
                if (!is_web) return .quit;
                self.reset(self.generateSeed());
            },
            .restart => self.restartSame(),
            .hint => self.revealHint(),
        }
        return .handled;
    }

    /// A results key arriving within `RESULTS_GUARD_MS` of the finish
    /// (Ctrl chords excepted).
    fn resultsGuarded(self: *const App, k: keys.KeyEvent) bool {
        if (self.test_state.state != .finished or !self.finish_seen) return false;
        if (k.mods.ctrl) return false;
        return time.milliTimestamp() - self.finished_ms < RESULTS_GUARD_MS;
    }

    fn revealHint(self: *App) void {
        if (!self.isDrills() or self.test_state.state == .finished) return;
        self.test_state.drill.revealHint();
        self.dirty = true;
    }

    /// App-level commands from the keymap (and vim exceptions).
    fn command(self: *App, c: keymap.Command) KeyResult {
        switch (c) {
            .quit => return .quit,
            .settings => self.openSettings(),
            .restart => {
                // Vim drills: a new "text" is the next challenge.
                if (self.isDrills()) self.selectNextDrill();
                self.reset(self.generateSeed());
            },
            .next => {
                if (self.isDrills()) self.selectNextDrill();
                self.reset(self.generateSeed());
            },
            .retry => self.restartSame(),
            .practice_missed => {
                // Vim retype (vim mode or code + vim keys) and drills have
                // no missed words; zen has no target.
                if (self.test_state.isVim() or self.test_state.isZen()) return .none;
                const ok = self.test_state.practiceMissed() catch false;
                if (ok) self.afterReset() else self.showToast("no missed words to practise");
            },
            .practice_weak => {
                if (self.test_state.isVim() or self.test_state.isZen()) return .none;
                var w: stats_mod.KeyWeights = undefined;
                if (!self.log.weakWeights(&w)) {
                    self.showToast("not enough key data yet (type a few tests)");
                    return .handled;
                }
                self.test_state.setWeakWeights(&w);
                const ok = self.test_state.practiceWeak() catch false;
                if (ok) {
                    self.afterReset();
                    self.showToast("weak-key practice " ++ MIDDOT ++ " not recorded");
                } else self.showToast("not enough key data yet (type a few tests)");
            },
            .history => {
                if (self.test_state.state == .typing) return .none;
                self.openHistory();
            },
            .toggle_code_keys => {
                if (self.test_state.config.mode != .code or self.test_state.state != .waiting) return .none;
                const cfg = &self.test_state.config;
                cfg.code_keys = if (cfg.code_keys == .plain) .vim else .plain;
                self.config_dirty = true;
                self.reset(self.generateSeed());
                self.showToast(if (cfg.code_keys == .vim) "vim keys: retype with vim " ++ MIDDOT ++ " ctrl+k for plain" else "plain keys " ++ MIDDOT ++ " ctrl+k for vim");
            },
            .finish => {
                // Zen: results now; nothing typed yet → just a fresh start.
                if (!self.test_state.submit(time.milliTimestamp())) self.reset(self.generateSeed());
            },
        }
        self.dirty = true;
        return .handled;
    }

    /// Open the settings overlay with the host facts it shows (web-only
    /// rows, the custom text preview).
    fn openSettings(self: *App) void {
        self.settings_ui.is_web = self.is_web;
        self.settings_ui.custom_text = self.test_state.customText();
        self.settings_ui.open(self.theme_id, self.test_state.config.mode);
    }

    fn openHistory(self: *App) void {
        self.overlay = .history;
        self.history_scroll = 0;
        self.needs_full_clear = true;
        self.dirty = true;
    }

    /// Scroll bound for the current history tab: the view's last page once
    /// a frame has been drawn, else the row count (the view clamps).
    fn historyRows(self: *App) usize {
        if (self.view_w > 0 and self.view_h > 0) {
            const ui = self.uiState(self.is_web);
            return history_view.maxScroll(&ui, self.view_w, self.view_h);
        }
        return switch (self.history_tab) {
            .recent => self.log.runs().len,
            .bests => self.pb_table.map.count(),
            .keys => stats_mod.KEYSET.len,
        };
    }

    fn closeOverlay(self: *App) void {
        self.overlay = .none;
        self.needs_full_clear = true;
        self.dirty = true;
    }

    /// History screen keys (keymap.historyAction).
    fn overlayKey(self: *App, k: keys.KeyEvent, is_web: bool) KeyResult {
        self.error_msg = null;
        switch (keymap.historyAction(k, is_web)) {
            .none => return .none,
            .quit => return .quit,
            .close => self.closeOverlay(),
            .next_tab => {
                self.history_tab = self.history_tab.next();
                self.history_scroll = 0;
            },
            .prev_tab => {
                self.history_tab = self.history_tab.prev();
                self.history_scroll = 0;
            },
            .scroll => |d| {
                const max = self.historyRows();
                const cur = @min(self.history_scroll, max);
                self.history_scroll = if (d < 0)
                    cur -| @as(usize, @intCast(-d))
                else
                    @min(cur + @as(usize, @intCast(d)), max);
            },
            .top => self.history_scroll = 0,
            // The view clamps to its last page.
            .bottom => self.history_scroll = self.historyRows(),
        }
        self.dirty = true;
        return .handled;
    }

    fn restartSame(self: *App) void {
        self.test_state.restartSame() catch {
            self.error_msg = "Failed to reset - out of memory";
        };
        self.afterReset();
    }

    fn isDrills(self: *const App) bool {
        return self.test_state.vimKind() == .drills;
    }

    /// Advance `config.drill_id` to the challenge after the current one
    /// (wrapping to the first not yet 3-starred).
    fn selectNextDrill(self: *App) void {
        const cur = self.test_state.config.drill_id orelse if (drill.all.len > 0) drill.all[0].id else return;
        self.test_state.config.drill_id = if (drill.next(cur)) |ch| ch.id else self.firstUnstarredDrill();
    }

    /// The first challenge without 3 stars in the history (null: the first).
    fn firstUnstarredDrill(self: *const App) ?[]const u8 {
        for (drill.all) |*ch| {
            const best = self.pb_table.bestDrill(ch.id) orelse return ch.id;
            if (best.stars < 3) return ch.id;
        }
        return if (drill.all.len > 0) drill.all[0].id else null;
    }

    /// Score and record a finished run once.
    fn checkFinish(self: *App) void {
        if (self.test_state.state != .finished) return;
        if (self.finish_seen) return;
        self.finish_seen = true;
        self.finished_ms = time.milliTimestamp();
        const res = self.test_state.result() orelse return;
        const cfg = self.test_state.config;
        self.pb = self.pb_table.submit(cfg, res);
        if (res.valid or res.kind == .vim_drill) {
            const line = history.recordLine(res, cfg, time.unixSeconds(), self.seed, &self.record_buf);
            self.record_len = line.len;
            if (line.ptr != &self.record_buf and line.len <= self.record_buf.len) {
                std.mem.copyForwards(u8, self.record_buf[0..line.len], line);
            }
            if (self.record_len > 0) self.log.addLine(self.record_buf[0..self.record_len]);
        }
        self.dirty = true;
    }

    /// A bracketed paste becomes the custom text (custom mode, idle).
    fn capturesPaste(self: *const App) bool {
        return self.test_state.config.mode == .custom and self.test_state.state == .waiting and
            !self.settings_ui.is_open and self.overlay == .none;
    }

    /// One key of a captured paste. Pasted newlines arrive as CR (Enter)
    /// or as a raw LF byte, which the parser reads as Ctrl+J; both are
    /// kept as is and the custom-text cleanup folds CR, LF and CRLF into
    /// one newline. Tab is a tab.
    fn capturePasteKey(self: *App, k: keys.KeyEvent) void {
        if (k.kind == .release) return;
        var buf: [4]u8 = undefined;
        const bytes: []const u8 = switch (k.code) {
            keys.code.enter => "\r",
            keys.code.tab => "\t",
            'j' => if (keys.Mods.eql(k.mods, .{ .ctrl = true })) "\n" else blk: {
                const cp = k.char() orelse return;
                const n = std.unicode.utf8Encode(cp, &buf) catch return;
                break :blk buf[0..n];
            },
            else => blk: {
                const cp = k.char() orelse return;
                const n = std.unicode.utf8Encode(cp, &buf) catch return;
                break :blk buf[0..n];
            },
        };
        if (self.paste_buf.items.len + bytes.len > MAX_PASTE_BYTES) return;
        self.paste_buf.appendSlice(self.allocator, bytes) catch {};
    }

    fn finishPasteCapture(self: *App) void {
        if (self.paste_buf.items.len == 0) return;
        self.setCustomText(self.paste_buf.items);
        self.paste_buf.clearRetainingCapacity();
    }

    /// Bracketed paste started: the run is no longer a valid result.
    pub fn notePaste(self: *App) void {
        if (self.isArcade()) return;
        self.test_state.notePaste();
        self.showToast("paste ignored");
        self.dirty = true;
    }

    /// One-line message above the footer for `TOAST_MS` (static string).
    pub fn showToast(self: *App, msg: []const u8) void {
        self.toast_msg = msg;
        self.toast_until_ms = time.milliTimestamp() + TOAST_MS;
        self.dirty = true;
    }

    /// Toast with formatted text (kept in `toast_buf`).
    fn showToastFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.toast_buf, fmt, args) catch return;
        self.showToast(msg);
    }

    /// Host facts (web): `is_mac`; `ctrlw_hint` asks for the one-time
    /// "ctrl+w belongs to the browser" toast (non-Mac, not shown before).
    pub fn setHost(self: *App, is_mac: bool, ctrlw_hint: bool) void {
        self.ctrlw_hint_pending = !is_mac and ctrlw_hint;
    }

    /// True once after the Ctrl+W hint was shown (the host remembers it).
    pub fn takeHintShown(self: *App) bool {
        const v = self.ctrlw_hint_shown;
        self.ctrlw_hint_shown = false;
        return v;
    }

    /// Leaving now would lose a run in progress (web `beforeunload`).
    pub fn confirmLeave(self: *const App) bool {
        return !self.isArcade() and self.test_state.state == .typing;
    }

    // ------------------------------------------------------------------
    // Persistence (contract 7). The App never touches files; hosts feed
    // and drain bytes.

    /// Apply the saved config and theme, then the explicit CLI/URL
    /// overrides, and fill the personal-best table from history JSONL.
    /// Corrupt input is ignored. Resets the test.
    pub fn loadSaved(self: *App, config_json: ?[]const u8, history_jsonl: ?[]const u8, overrides: types.ConfigOverrides) void {
        if (config_json) |bytes| {
            var cfg = self.test_state.config;
            var theme_buf: [32]u8 = undefined;
            if (history.configFromJson(bytes, &cfg, &theme_buf)) |slug| {
                if (theme_mod.fromSlug(slug)) |id| self.theme_id = id;
            }
            // Arcade is never the saved start mode.
            if (cfg.mode == .arcade) cfg.mode = self.test_state.config.mode;
            self.applyOptions(cfg);
            // Kept as the start mode to save while arcade runs
            // (`snipetype arcade` must not reset it to words).
            if (cfg.mode != .arcade) self.saved_mode = cfg.mode;
        }
        overrides.apply(&self.test_state.config);
        if (overrides.theme) |slug| {
            if (theme_mod.fromSlug(slug)) |id| self.theme_id = id;
        }
        if (history_jsonl) |bytes| self.loadHistoryChunk(bytes);
        if (overrides.custom_text) |text| {
            self.test_state.setCustomText(text) catch {};
            self.custom_pending = true;
        }

        const c = &self.test_state.config;
        c.drill_id = null;
        if (overrides.drill) |d| c.drill_id = resolveDrill(d);
        if (c.drill_id == null) c.drill_id = self.firstUnstarredDrill();
        if (c.mode != .arcade) self.saved_mode = c.mode;
        self.config_dirty = false;
        self.reset(self.seed);
    }

    /// History JSONL in consecutive chunks of whole lines (native hosts
    /// stream big files): personal bests and the run log.
    pub fn loadHistoryChunk(self: *App, bytes: []const u8) void {
        self.pb_table.loadJsonl(bytes);
        self.log.loadJsonl(bytes);
    }

    /// Replace the custom text (CLI, stdin, paste, web dialog). Custom mode
    /// starts over with it; hosts persist it via `takeCustomText`.
    pub fn setCustomText(self: *App, text: []const u8) void {
        self.test_state.setCustomText(text) catch {
            self.showToast("could not use that text");
            return;
        };
        self.custom_pending = true;
        if (self.test_state.config.mode == .custom) self.reset(self.generateSeed());
        const custom = self.test_state.customText();
        self.showToastFmt("custom text: {d} words", .{countWords(custom)});
    }

    /// The saved custom text at startup: no toast, nothing to persist.
    pub fn loadCustomText(self: *App, text: []const u8) void {
        self.test_state.setCustomText(text) catch return;
        if (self.test_state.config.mode == .custom) self.reset(self.seed);
    }

    /// The sanitized custom text once after it changed (hosts persist it).
    pub fn takeCustomText(self: *App) ?[]const u8 {
        if (!self.custom_pending) return null;
        self.custom_pending = false;
        return self.test_state.customText();
    }

    /// Web: true once after the settings `text` row asked for the dialog.
    pub fn takeCustomDialogRequest(self: *App) bool {
        const v = self.custom_dialog_requested;
        self.custom_dialog_requested = false;
        return v;
    }

    /// One "pb":true record per personal best (history compaction keeps
    /// them); null when out of memory. Caller frees.
    pub fn pbLines(self: *App, allocator: std.mem.Allocator) ?[]u8 {
        return self.pb_table.pbLines(allocator) catch null;
    }

    /// A pending history line (JSON, no newline) to append, once.
    pub fn takeRecordLine(self: *App) ?[]const u8 {
        if (self.record_len == 0) return null;
        const n = self.record_len;
        self.record_len = 0;
        return self.record_buf[0..n];
    }

    /// The config JSON when it changed (theme, mode or test options), once.
    pub fn takeConfigJson(self: *App) ?[]const u8 {
        if (!self.config_dirty) return null;
        self.config_dirty = false;
        var cfg = self.test_state.config;
        if (cfg.mode == .arcade) cfg.mode = self.saved_mode else self.saved_mode = cfg.mode;
        const json = history.configToJson(cfg, theme_mod.slug(self.theme_id), &self.config_buf);
        return if (json.len == 0) null else json;
    }

    /// Drop a pending config save (web: URL parameters are not saved).
    pub fn discardConfigChange(self: *App) void {
        self.config_dirty = false;
    }

    /// Mark the config as changed (hosts' setters).
    pub fn markConfigDirty(self: *App) void {
        self.config_dirty = true;
    }

    /// Per-frame UI facts for the renderer (contract 4).
    pub fn uiState(self: *App, is_web: bool) UiState {
        var ui: UiState = .{
            .is_web = is_web,
            .pb = self.pb,
            .practice = self.test_state.isPractice(),
            .overlay = self.overlay,
            .history_tab = self.history_tab,
            .history_scroll = self.history_scroll,
            .log = &self.log,
            .pbs = &self.pb_table,
            .finished_ms = if (self.finish_seen) self.finished_ms else null,
        };
        const cfg = self.test_state.config;
        if (self.isDrills()) {
            if (cfg.drill_id) |id| {
                if (self.pb_table.bestDrill(id)) |b| ui.drill_best = .{ .strokes = b.strokes, .stars = b.stars };
            }
        } else {
            var buf: [96]u8 = undefined;
            ui.best_wpm = self.pb_table.bestWpm(history.pbKey(cfg, &buf));
        }
        ui.pace_wpm = self.paceWpm(ui.best_wpm);
        if (self.toast_msg) |msg| {
            if (time.milliTimestamp() < self.toast_until_ms) ui.toast = msg;
        }
        return ui;
    }

    /// Pace caret speed: the PB for this setup (when one exists) or the
    /// fixed speed; never in zen, vim modes, drills or practice runs.
    fn paceWpm(self: *const App, best_wpm: ?f32) ?f32 {
        const t = &self.test_state;
        if (t.isVim() or t.isZen() or t.isPractice() or self.isArcade()) return null;
        return switch (t.config.caret_pace) {
            .off => null,
            .pb => best_wpm,
            .fixed => @floatFromInt(std.math.clamp(t.config.caret_wpm, types.CARET_WPM_MIN, types.CARET_WPM_MAX)),
        };
    }

    /// Redraw interval while typing: faster while a pace caret moves.
    fn typingRedrawMs(self: *App) i64 {
        if (self.test_state.config.caret_pace == .off) return TYPING_REDRAW_MS;
        var buf: [96]u8 = undefined;
        const best = self.pb_table.bestWpm(history.pbKey(self.test_state.config, &buf));
        return if (self.paceWpm(best) != null) PACE_REDRAW_MS else TYPING_REDRAW_MS;
    }

    /// Results animations (count-up, graph draw-in, PB sparkle) still need
    /// frames.
    fn animating(self: *App, now: i64) bool {
        if (self.isArcade() or !self.finish_seen) return false;
        const ui = self.uiState(self.is_web);
        return render_ui.animating(&self.test_state, &ui, now);
    }

    /// Check time limit and state changes. Returns true if state changed.
    pub fn update(self: *App) bool {
        if (self.arcade) |st| {
            // Frozen while the settings overlay is open.
            if (self.isArcade() and !self.settings_ui.is_open) st.arc.update(time.milliTimestamp());
        }
        self.test_state.tick(time.milliTimestamp());
        self.checkFinish();
        if (self.test_state.state != self.last_state) {
            self.last_state = self.test_state.state;
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// Check if render is needed based on dirty flag and timing
    pub fn shouldRender(self: *App, now: i64) bool {
        if (self.pending_len > 0) return true;
        if (self.isArcade()) {
            if (self.settings_ui.is_open or self.arcade == null) return self.dirty;
            return now - self.last_render_ms >= self.gfx_setup.frame_ms;
        }
        if (self.toast_msg != null and now >= self.toast_until_ms) {
            self.toast_msg = null;
            self.dirty = true;
        }
        if (self.dirty) return true;
        if (self.test_state.state == .typing) {
            return now - self.last_render_ms >= self.typingRedrawMs();
        }
        // Render tail: results animations draw every ANIM_FRAME_MS.
        if (self.animating(now)) return now - self.last_render_ms >= render_ui.ANIM_FRAME_MS;
        return false;
    }

    /// Render the current state using the abstract renderer
    pub fn render(self: *App, r: Renderer) void {
        self.last_render_ms = time.milliTimestamp();
        self.dirty = false;

        if (self.pending_len > 0) {
            r.write(self.pending_buf[0..self.pending_len]);
            self.pending_len = 0;
        }

        if (self.isArcade()) {
            if (self.ensureArcade()) |st| {
                self.renderArcade(r, st);
                return;
            }
        }

        const palette = theme_mod.resolve(self.theme_id);
        r.setUseTerminalDefaults(palette.use_terminal_defaults);
        r.setDefaultColors(palette.fg, palette.bg);
        r.resetStyle();

        if (self.needs_full_clear) {
            r.clear();
            self.needs_full_clear = false;
        }

        self.view_w = r.width();
        self.view_h = r.height();
        const ui = self.uiState(self.is_web);
        render_ui.renderScreen(r, &self.test_state, palette, &ui);

        self.settings_ui.renderOverlay(r, palette, self.theme_id, self.test_state.config.mode);

        r.flush();
    }

    /// Mark the app as needing a resize clear
    pub fn onResize(self: *App) void {
        self.dirty = true;
        self.needs_full_clear = true;
    }

    /// Calculate poll wait time for native input
    pub fn getPollWaitMs(self: *App, now: i64) i64 {
        if (self.pending_len > 0) return 0;
        if (self.isArcade() and self.arcade != null and !self.settings_ui.is_open) {
            const elapsed = now - self.last_render_ms;
            return std.math.clamp(self.gfx_setup.frame_ms - elapsed, 0, self.gfx_setup.frame_ms);
        }
        if (self.dirty) return 0;
        var wait: i64 = constants.IDLE_POLL_MS;
        if (self.test_state.state == .typing) {
            const elapsed = now - self.last_render_ms;
            wait = @max(0, self.typingRedrawMs() - elapsed);
        } else if (self.animating(now)) {
            wait = @max(0, render_ui.ANIM_FRAME_MS - (now - self.last_render_ms));
        }
        if (self.toast_msg != null) wait = @min(wait, @max(0, self.toast_until_ms - now));
        return wait;
    }

    /// Generate a seed (platform-specific implementation should override for web)
    fn generateSeed(self: *App) u64 {
        _ = self;
        return @truncate(@as(u128, @bitCast(time.nanoTimestamp())));
    }

    // Accessors for web API
    pub fn getState(self: *const App) TestState {
        return self.test_state.state;
    }

    pub fn getWPM(self: *const App) f64 {
        return self.test_state.getWPM();
    }

    pub fn getAccuracy(self: *const App) f64 {
        return self.test_state.getAccuracy();
    }

    pub fn getThemeId(self: *const App) ThemeId {
        return self.theme_id;
    }

    pub fn setThemeId(self: *App, id: ThemeId) void {
        if (id != self.theme_id) self.config_dirty = true;
        self.theme_id = id;
        self.dirty = true;
        self.needs_full_clear = true;
    }

    /// Switch modes. Leaving arcade queues the presenter teardown (written
    /// at the start of the next frame); entering it creates the arcade
    /// state lazily on the next event/frame.
    pub fn setMode(self: *App, mode: types.Mode, seed: u64) void {
        self.test_state.config.mode = mode;
        self.reset(seed);
    }

    pub fn setWordCount(self: *App, count: usize, seed: u64) void {
        self.test_state.config.word_count = std.math.clamp(count, types.MIN_WORDS, types.MAX_WORDS);
        self.config_dirty = true;
        self.reset(seed);
    }

    pub fn setTimeLimit(self: *App, seconds: usize, seed: u64) void {
        self.test_state.config.time_limit = seconds;
        self.config_dirty = true;
        self.reset(seed);
    }

    pub fn setLang(self: *App, lang: types.Lang, seed: u64) void {
        self.test_state.config.lang = lang;
        self.config_dirty = true;
        self.reset(seed);
    }

    /// Apply explicit overrides now (web URL parameters after `loadSaved`).
    pub fn applyOverrides(self: *App, ov: types.ConfigOverrides, seed: u64) void {
        ov.apply(&self.test_state.config);
        if (ov.theme) |slug| {
            if (theme_mod.fromSlug(slug)) |id| self.theme_id = id;
        }
        if (ov.drill) |d| {
            if (resolveDrill(d)) |id| self.test_state.config.drill_id = id;
        }
        self.reset(seed);
    }

    pub fn getErrorMsg(self: *const App) ?[]const u8 {
        return self.error_msg;
    }

    pub fn clearError(self: *App) void {
        self.error_msg = null;
    }

    /// Get the screen position of the typing cursor
    pub fn getCursorPos(self: *App, width: usize, height: usize) render_ui.CursorPos {
        const ui = self.uiState(self.is_web);
        return render_ui.getCursorPos(&self.test_state, &ui, width, height);
    }

    // ------------------------------------------------------------------
    // Arcade

    pub fn isArcade(self: *const App) bool {
        return self.test_state.config.mode == .arcade;
    }

    /// Kitty keyboard flags the terminal should use for the current mode
    /// (the platform layer applies them when this value changes).
    pub fn keyboardFlags(self: *const App) u8 {
        // Mirrors platform/terminal.zig `keyboard_flags` (typing / arcade).
        return if (self.isArcade()) 1 | 2 | 8 | 16 else 1;
    }

    /// Hardware cursor style for the current screen.
    pub const CursorStyle = enum(u32) { hidden = 0, block = 1, bar = 2, underline = 3 };

    /// Cursor the host terminal should show: hidden whenever the app is not
    /// waiting for typing at a text position (arcade, settings overlay,
    /// results); a block in vim normal/visual mode; a bar while typing, in
    /// vim insert/replace and on the vim command line (the renderer draws
    /// no caret of its own there).
    pub fn cursorStyle(self: *const App) CursorStyle {
        if (self.isArcade()) return .hidden;
        if (self.settings_ui.is_open) return .hidden;
        if (self.overlay != .none) return .hidden;
        if (self.test_state.state == .finished) return .hidden;
        if (self.test_state.vimKind()) |kind| {
            // Code + vim keys retype in `vim` like vim mode's .type.
            const ed = if (kind == .drills) &self.test_state.drill.editor else &self.test_state.vim;
            return switch (ed.mode) {
                .insert, .replace, .cmdline => .bar,
                else => .block,
            };
        }
        return .bar;
    }

    /// Hardware cursor should be visible (see `cursorStyle`).
    pub fn cursorVisible(self: *const App) bool {
        return self.cursorStyle() != .hidden;
    }

    /// Choose the arcade game (`Config.arcade_game`). A running arcade goes
    /// back to its title screen with the new game.
    pub fn setArcadeGame(self: *App, game: types.Game, seed: u64) void {
        self.test_state.config.arcade_game = game;
        if (self.arcade) |st| {
            st.arc.opts.game = game;
            st.arc.reset(seed);
            st.scene.reset();
        }
        self.dirty = true;
    }

    /// The arcade game in effect: the sim's (Tab on the title switches it)
    /// while arcade runs, else the configured one.
    pub fn arcadeGame(self: *const App) types.Game {
        if (self.arcade) |st| return st.arc.selectedGame();
        return self.test_state.config.arcade_game;
    }

    /// Configure arcade output (call before the first frame; changing the
    /// backend later recreates the presenter on the next arcade entry).
    pub fn setGfx(self: *App, setup: GfxSetup) void {
        self.gfx_setup = setup;
    }

    /// Terminal cell size in pixels (picks the kitty/web surface size).
    pub fn setCellPx(self: *App, w: u16, h: u16) void {
        if (w == self.cell_px_w and h == self.cell_px_h) return;
        self.cell_px_w = w;
        self.cell_px_h = h;
        self.dirty = true;
    }

    /// The arcade pixel surface when the host draws pixels itself
    /// (`.external` backend), else null.
    pub fn arcadeSurface(self: *const App) ?*const Surface {
        if (!self.isArcade() or self.gfx_setup.backend != .external) return null;
        const st = self.arcade orelse return null;
        if (st.surface.w == 0 or st.surface.h == 0) return null;
        return &st.surface;
    }

    /// The arcade sim, if active (read-only; tests and hosts).
    pub fn arcadeSim(self: *const App) ?*const Arcade {
        const st = self.arcade orelse return null;
        return &st.arc;
    }

    /// Sounds produced by the last arcade frame (when `collect_sfx`).
    /// Valid until the next `render`.
    pub fn sfx(self: *const App) []const Sfx {
        return self.sfx_buf[0..self.sfx_len];
    }

    pub fn clearSfx(self: *App) void {
        self.sfx_len = 0;
    }

    /// Bytes to write before exiting (kitty image delete + SGR reset),
    /// including a teardown still queued from leaving arcade.
    pub fn teardownBytes(self: *App) []const u8 {
        if (self.arcade) |st| return st.presenter.teardown();
        const n = self.pending_len;
        self.pending_len = 0;
        return self.pending_buf[0..n];
    }

    /// Create or destroy the arcade state to match the current mode.
    fn syncArcade(self: *App) void {
        if (!self.isArcade() and self.arcade != null) {
            const st = self.arcade.?;
            // Keep the title-screen choices for the next arcade visit.
            self.test_state.config.arcade_game = st.arc.selectedGame();
            self.test_state.config.arcade_pace = st.arc.selectedPace();
            self.test_state.config.arcade_speed = st.arc.selectedSpeed();
            const bytes = st.presenter.teardown();
            const n = @min(bytes.len, self.pending_buf.len - self.pending_len);
            @memcpy(self.pending_buf[self.pending_len..][0..n], bytes[0..n]);
            self.pending_len += n;
            self.destroyArcade();
            self.settings_ui.close();
            self.sfx_len = 0;
        }
    }

    fn ensureArcade(self: *App) ?*ArcadeState {
        if (self.arcade) |st| return st;
        const st = self.createArcade() catch {
            self.error_msg = "Failed to start arcade - out of memory";
            self.test_state.config.mode = .words;
            self.reset(self.generateSeed());
            return null;
        };
        self.arcade = st;
        self.needs_full_clear = true;
        return st;
    }

    fn createArcade(self: *App) !*ArcadeState {
        const a = self.allocator;
        const seed = self.generateSeed();
        const cfg = self.test_state.config;
        const st = try a.create(ArcadeState);
        errdefer a.destroy(st);
        var arc = try Arcade.init(a, seed, .{
            .game = cfg.arcade_game,
            .pace = cfg.arcade_pace,
            .speed = cfg.arcade_speed,
            .chords = self.gfx_setup.chords,
        });
        errdefer arc.deinit();
        var scene = try Scene.init(a, seed ^ 0x5CE7E);
        errdefer scene.deinit();
        var surface = try Surface.init(a, 1, 1, 1, 1);
        errdefer surface.deinit();
        const presenter = try Presenter.init(a, self.gfx_setup.backend, self.gfx_setup.opts);
        st.* = .{ .arc = arc, .scene = scene, .surface = surface, .presenter = presenter };
        return st;
    }

    fn destroyArcade(self: *App) void {
        const st = self.arcade orelse return;
        st.presenter.deinit();
        st.surface.deinit();
        st.scene.deinit();
        st.arc.deinit();
        self.allocator.destroy(st);
        self.arcade = null;
    }

    fn renderArcade(self: *App, r: Renderer, st: *ArcadeState) void {
        if (self.settings_ui.is_open) {
            // Frozen frame + overlay. Explicit colors so the overlay stays
            // opaque over pixels; SGR reset afterwards so the presenter's
            // pen assumption holds on the next frame.
            const palette = theme_mod.resolve(self.theme_id);
            // Emulators may draw a cell whose bg equals their theme
            // background as "default" (transparent over the pixel layer, as
            // ghostty-web does); nudge it by one step so it stays opaque.
            var bg = palette.bg;
            bg.b = if (bg.b < 255) bg.b + 1 else bg.b - 1;
            r.write("\x1b[?2026h");
            r.setUseTerminalDefaults(false);
            r.setDefaultColors(palette.fg, bg);
            r.resetStyle();
            self.settings_ui.renderOverlay(r, palette, self.theme_id, self.test_state.config.mode);
            r.write("\x1b[0m\x1b[?2026l");
            r.flush();
            st.overlay_shown = true;
            self.needs_full_clear = false;
            return;
        }
        if (st.overlay_shown or self.needs_full_clear) {
            // Never clear the screen in arcade (2J would delete the kitty
            // placement); the presenter repaints every cell instead.
            st.presenter.invalidate();
            st.overlay_shown = false;
            self.needs_full_clear = false;
        }

        const cols: u16 = @intCast(@min(@max(r.width(), 1), std.math.maxInt(u16)));
        const rows: u16 = @intCast(@min(@max(r.height(), 1), std.math.maxInt(u16)));
        const px = gfx.pixelSize(self.gfx_setup.backend, cols, rows, self.cell_px_w, self.cell_px_h);
        if (st.surface.cols != cols or st.surface.rows != rows or st.surface.w != px.w or st.surface.h != px.h) {
            st.surface.resize(cols, rows, px.w, px.h) catch {
                self.error_msg = "Failed to resize arcade - out of memory";
                return;
            };
            st.presenter.invalidate();
        }
        const halfblock = self.gfx_setup.backend == .halfblock;
        const quality: scene_mod.Quality = .{
            .bloom = if (halfblock) .off else .low,
            .halfblock = halfblock,
        };
        // Big (3-row) caps are drawn wider than layout.zig says; the sim
        // places spawns on a proportionally narrower field.
        st.arc.setPlayWidth(scene_mod.simPlayCols(&st.surface, quality));

        st.scene.render(&st.surface, &st.arc, time.milliTimestamp(), quality);
        const bytes = st.presenter.present(&st.surface) catch "";
        r.write(bytes);
        r.flush();

        if (self.collect_sfx) self.collectSfx(&st.arc);
        st.arc.clearEvents();
    }

    /// Map this frame's game events to sounds. The title attract demo is
    /// muted (only events after a `start` in the same frame are kept).
    fn collectSfx(self: *App, arc: *const Arcade) void {
        if (arc.isAttract()) return;
        const evs = arc.events();
        var first: usize = 0;
        for (evs, 0..) |ev, i| {
            if (ev == .start) first = i;
        }
        const combo_boost = @min(1.0, @as(f32, @floatFromInt(arc.stats.combo)) / 60.0);
        for (evs[first..]) |ev| {
            const s: ?Sfx = switch (ev) {
                .key_press => |kp| keySfx(kp.code, 0.5 + 0.3 * combo_boost),
                .hit => |h| .{
                    .kind = switch (h.effect.tier()) {
                        0, 1 => .fx_tier1,
                        2 => .fx_tier2,
                        3 => .fx_tier3,
                    },
                    .pan = h.x * 2 - 1,
                    .intensity = h.intensity,
                },
                .wrong => .{ .kind = .wrong, .pan = 0, .intensity = 0.7 },
                .miss => |mi| .{ .kind = .miss, .pan = mi.x * 2 - 1, .intensity = 0.8 },
                .level_up => .{ .kind = .level_up, .pan = 0, .intensity = 0.8 },
                .milestone => .{ .kind = .milestone, .pan = 0, .intensity = 0.8 },
                .phrase_done => .{ .kind = .phrase_done, .pan = 0, .intensity = 0.8 },
                .game_over => .{ .kind = .game_over, .pan = 0, .intensity = 1 },
                .start => .{ .kind = .start, .pan = 0, .intensity = 0.8 },
                .step => null,
            };
            if (s) |v| {
                if (self.sfx_len >= SFX_CAPACITY) return;
                self.sfx_buf[self.sfx_len] = v;
                self.sfx_len += 1;
            }
        }
    }
};

const MIDDOT = "\u{00b7}";

/// Whitespace-separated words in `text` (toasts).
fn countWords(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |_| n += 1;
    return n;
}

/// `--drill` / URL value → a static challenge id: an exact id, a lesson
/// name ("text_objects") or an id prefix ("textobj", "words/dw").
fn resolveDrill(s: []const u8) ?[]const u8 {
    if (drill.byId(s)) |ch| return ch.id;
    for (drill.all) |*ch| {
        if (std.ascii.eqlIgnoreCase(@tagName(ch.lesson), s)) return ch.id;
    }
    for (drill.all) |*ch| {
        if (s.len > 0 and std.mem.startsWith(u8, ch.id, s)) return ch.id;
    }
    return null;
}

/// Switch sound for a key press, panned by its position on a US keyboard.
fn keySfx(code: u21, intensity: f32) ?Sfx {
    const rows_us = [_][]const u8{ "`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./" };
    var pan: f32 = 0;
    if (code < 128) {
        for (rows_us) |row| {
            if (std.mem.indexOfScalar(u8, row, @intCast(code))) |i| {
                const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(row.len - 1));
                pan = (f * 2 - 1) * 0.8;
                break;
            }
        }
    }
    const kind: SfxKind = switch (code) {
        'a'...'z' => .key_letter,
        '0'...'9' => .key_digit,
        keys.code.space, keys.code.enter, keys.code.tab, keys.code.backspace, keys.code.escape => .key_big,
        keys.code.left, keys.code.right, keys.code.up, keys.code.down => .key_arrow,
        else => if (keys.code.isModifier(code))
            .key_big
        else if (code > 32 and code < 127)
            .key_letter
        else
            return null,
    };
    return .{ .kind = kind, .pan = pan, .intensity = if (kind == .key_big and keys.code.isModifier(code)) intensity * 0.6 else intensity };
}

test {
    _ = typing_test;
}

test "native ctrl+c quits even over the settings overlay" {
    for ([_]types.Mode{ .words, .vim, .arcade }) |mode| {
        var app = try App.init(std.testing.allocator, 1, .{ .mode = mode });
        defer app.deinit();
        const ctrl: keys.Mods = .{ .ctrl = true };
        _ = app.handleEvent(.{ .key = .{ .code = 'p', .mods = ctrl } }, false);
        try std.testing.expect(app.settings_ui.is_open);
        try std.testing.expectEqual(KeyResult.quit, app.handleEvent(.{ .key = .{ .code = 'c', .mods = ctrl } }, false));
        // Web keeps the overlay's handling (no quit).
        try std.testing.expect(app.handleEvent(.{ .key = .{ .code = 'c', .mods = ctrl } }, true) != .quit);
    }
}

// ----------------------------------------------------------------------------
// Classic-mode routing (contract 6) and persistence (contract 7)

const t_alloc = std.testing.allocator;

fn press(app: *App, c: u21, mods: keys.Mods, is_web: bool) KeyResult {
    return app.handleEvent(.{ .key = .{ .code = c, .mods = mods } }, is_web);
}

fn typeText(app: *App, text: []const u8) void {
    for (text) |ch| {
        const ev: keys.KeyEvent = if (ch == ' ') .{ .code = ' ', .text = ' ' } else .{ .code = ch, .text = ch };
        _ = app.handleEvent(.{ .key = ev }, false);
    }
}

/// Pretend the finish happened long enough ago for results keys to work.
fn endGuard(app: *App) void {
    app.finished_ms -= RESULTS_GUARD_MS;
}

fn activeTyped(app: *App) []const u8 {
    const s = &app.test_state.session;
    return s.word(s.activeIndex()).typed;
}

fn targetsEqual(a: *App, words: []const []const u8) bool {
    const s = &a.test_state.session;
    if (s.wordCount() < words.len) return false;
    for (words, 0..) |w, i| {
        if (!std.mem.eql(u8, s.word(i).target, w)) return false;
    }
    return true;
}

test "words: ctrl+w, ctrl+backspace and alt+backspace delete the word" {
    var app = try App.init(t_alloc, 1, .{ .mode = .words, .word_count = 10 });
    defer app.deinit();
    const chords = [_]struct { c: u21, m: keys.Mods }{
        .{ .c = 'w', .m = .{ .ctrl = true } },
        .{ .c = keys.code.backspace, .m = .{ .ctrl = true } },
        .{ .c = keys.code.backspace, .m = .{ .alt = true } },
    };
    for (chords) |ch| {
        typeText(&app, "xyz");
        try std.testing.expectEqualStrings("xyz", activeTyped(&app));
        try std.testing.expectEqual(KeyResult.handled, press(&app, ch.c, ch.m, false));
        try std.testing.expectEqualStrings("", activeTyped(&app));
    }
}

test "esc restarts the simple modes instead of quitting" {
    var app = try App.init(t_alloc, 1, .{ .mode = .words, .word_count = 10 });
    defer app.deinit();
    typeText(&app, "ab");
    try std.testing.expectEqual(TestState.typing, app.test_state.state);
    try std.testing.expectEqual(KeyResult.handled, press(&app, keys.code.escape, .{}, false));
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    try std.testing.expectEqualStrings("", activeTyped(&app));
}

test "results: enter gives a new test, r the same text, q quits natively" {
    var app = try App.init(t_alloc, 7, .{ .mode = .words, .word_count = 3 });
    defer app.deinit();
    var first: [3][]const u8 = undefined;
    var store: [3][32]u8 = undefined;
    for (0..3) |i| {
        const w = app.test_state.session.word(i).target;
        @memcpy(store[i][0..w.len], w);
        first[i] = store[i][0..w.len];
    }
    for (first, 0..) |w, i| {
        typeText(&app, w);
        if (i + 1 < first.len) typeText(&app, " ");
    }
    try std.testing.expectEqual(TestState.finished, app.test_state.state);
    endGuard(&app);
    // r: same target, fresh attempt.
    try std.testing.expectEqual(KeyResult.handled, press(&app, 'r', .{}, false));
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    try std.testing.expect(targetsEqual(&app, &first));
    // Finish again, then Enter: a new test.
    for (first, 0..) |w, i| {
        typeText(&app, w);
        if (i + 1 < first.len) typeText(&app, " ");
    }
    try std.testing.expectEqual(TestState.finished, app.test_state.state);
    endGuard(&app);
    try std.testing.expectEqual(KeyResult.none, press(&app, 'q', .{}, true));
    try std.testing.expectEqual(KeyResult.handled, press(&app, keys.code.enter, .{}, false));
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    typeText(&app, "zz");
    app.test_state.state = .finished;
    try std.testing.expectEqual(KeyResult.quit, press(&app, 'q', .{}, false));
}

test "results: keys in flight right after the finish are ignored" {
    var app = try App.init(t_alloc, 7, .{ .mode = .words, .word_count = 1 });
    defer app.deinit();
    var buf: [32]u8 = undefined;
    const w = app.test_state.session.word(0).target;
    @memcpy(buf[0..w.len], w);
    typeText(&app, buf[0..w.len]);
    try std.testing.expectEqual(TestState.finished, app.test_state.state);
    // A trailing space, q, r, enter: the results stay, the app keeps running.
    for ([_]u21{ ' ', 'q', 'r', keys.code.enter, keys.code.escape }) |c| {
        try std.testing.expectEqual(KeyResult.none, press(&app, c, .{}, false));
        try std.testing.expectEqual(TestState.finished, app.test_state.state);
    }
    // Ctrl chords are deliberate.
    try std.testing.expectEqual(KeyResult.quit, press(&app, 'c', .{ .ctrl = true }, false));
    endGuard(&app);
    try std.testing.expectEqual(KeyResult.handled, press(&app, keys.code.enter, .{}, false));
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
}

test "bracketed paste inserts nothing" {
    var app = try App.init(t_alloc, 1, .{ .mode = .words, .word_count = 10 });
    defer app.deinit();
    _ = press(&app, keys.code.paste_start, .{}, false);
    typeText(&app, "pasted words");
    _ = press(&app, keys.code.paste_end, .{}, false);
    try std.testing.expectEqualStrings("", activeTyped(&app));
    try std.testing.expectEqual(@as(usize, 0), app.test_state.session.activeIndex());
    typeText(&app, "a");
    try std.testing.expectEqualStrings("a", activeTyped(&app));
}

test "vim: ctrl+c leaves insert, a double ctrl+c in normal quits natively" {
    for ([_]types.VimKind{ .type, .drills }) |kind| {
        var app = try App.init(t_alloc, 1, .{ .mode = .vim, .vim_kind = kind });
        defer app.deinit();
        const ctrl: keys.Mods = .{ .ctrl = true };
        typeText(&app, "i");
        try std.testing.expectEqual(vim_editor.Mode.insert, app.test_state.activeEditor().mode);
        try std.testing.expectEqual(KeyResult.handled, press(&app, 'c', ctrl, false));
        try std.testing.expectEqual(vim_editor.Mode.normal, app.test_state.activeEditor().mode);
        try std.testing.expectEqual(KeyResult.handled, press(&app, 'c', ctrl, false));
        try std.testing.expect(app.toast_msg != null);
        try std.testing.expectEqual(KeyResult.quit, press(&app, 'c', ctrl, false));
        // Web: the double press restarts instead.
        try std.testing.expectEqual(KeyResult.handled, press(&app, 'c', ctrl, true));
        try std.testing.expectEqual(KeyResult.handled, press(&app, 'c', ctrl, true));
    }
}

test "vim: d then tab does not restart; tab in normal does" {
    var app = try App.init(t_alloc, 1, .{ .mode = .vim, .vim_kind = .drills });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    const id = app.test_state.config.drill_id.?;
    typeText(&app, "d");
    _ = press(&app, keys.code.tab, .{}, false);
    // Tab cancelled the pending operator; the run goes on.
    try std.testing.expectEqual(TestState.typing, app.test_state.state);
    try std.testing.expectEqualStrings(id, app.test_state.config.drill_id.?);
    _ = press(&app, keys.code.tab, .{}, false);
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    const next = drill.next(id) orelse &drill.all[0];
    try std.testing.expectEqualStrings(next.id, app.test_state.config.drill_id.?);
}

test "vim drills: :e! restarts the same drill" {
    var app = try App.init(t_alloc, 1, .{ .mode = .vim, .vim_kind = .drills });
    defer app.deinit();
    const id = app.test_state.config.drill_id;
    const ch = drill.byId(id orelse drill.all[0].id) orelse return error.SkipZigTest;
    _ = ch;
    typeText(&app, "x");
    try std.testing.expect(app.test_state.drill.strokes() > 0);
    typeText(&app, ":e!");
    _ = press(&app, keys.code.enter, .{}, false);
    try std.testing.expectEqual(id, app.test_state.config.drill_id);
    try std.testing.expectEqual(@as(u32, 0), app.test_state.drill.strokes());
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
}

test "persistence: overrides beat the saved config; corrupt config is ignored" {
    var app = try App.init(t_alloc, 1, .{});
    defer app.deinit();
    const saved = "{\"v\":1,\"theme\":\"nord\",\"mode\":\"words\",\"words\":50,\"time\":30,\"lang\":\"go\",\"tier\":\"easy\",\"punct\":true,\"num\":false,\"vim\":\"drills\"}";
    app.loadSaved(saved, null, .{ .time_limit = 60, .tier = .full });
    const c = app.test_state.config;
    try std.testing.expectEqual(@as(usize, 50), c.word_count);
    try std.testing.expectEqual(@as(usize, 60), c.time_limit);
    try std.testing.expectEqual(types.WordTier.full, c.tier);
    try std.testing.expect(c.punctuation);
    try std.testing.expectEqual(ThemeId.nord, app.theme_id);
    try std.testing.expect(app.takeConfigJson() == null);

    var bad = try App.init(t_alloc, 1, .{});
    defer bad.deinit();
    bad.loadSaved("{not json", "garbage\n{\"v\":1", .{});
    try std.testing.expectEqual(@as(usize, 10), bad.test_state.config.word_count);
    try std.testing.expectEqual(types.WordTier.common, bad.test_state.config.tier);
    try std.testing.expectEqual(ThemeId.system, bad.theme_id);

    // Starting in arcade keeps the saved start mode for the next save.
    var arc = try App.init(t_alloc, 1, .{ .mode = .arcade });
    defer arc.deinit();
    arc.loadSaved("{\"v\":1,\"mode\":\"code\"}", null, .{ .mode = .arcade });
    try std.testing.expect(arc.isArcade());
    arc.setThemeId(.nord);
    const arc_json = arc.takeConfigJson() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, arc_json, "\"mode\":\"code\"") != null);

    // A theme change is saved.
    bad.setThemeId(.dracula);
    const json = bad.takeConfigJson() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, json, "dracula") != null);
    try std.testing.expect(bad.takeConfigJson() == null);
}

test "persistence: a record line only for valid results" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words, .word_count = 2 });
    defer app.deinit();
    const Run = struct {
        fn finish(a: *App, step_ms: i64) void {
            var now: i64 = 1000;
            const n = a.test_state.session.wordCount();
            for (0..n) |i| {
                const w = a.test_state.session.word(i).target;
                for (w) |ch| {
                    a.test_state.handleEdit(.{ .char = ch }, now);
                    now += step_ms;
                }
                if (i + 1 < n) a.test_state.handleEdit(.{ .char = ' ' }, now);
            }
            _ = a.update();
        }
    };
    // Too fast (< 1 s): no record.
    Run.finish(&app, 1);
    try std.testing.expectEqual(TestState.finished, app.test_state.state);
    try std.testing.expect(app.takeRecordLine() == null);
    // A normal pace: one record, taken once.
    app.restartSame();
    Run.finish(&app, 200);
    const line = app.takeRecordLine() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, line, "{"));
    try std.testing.expect(app.takeRecordLine() == null);
    // Pasted runs are never recorded.
    app.restartSame();
    app.notePaste();
    Run.finish(&app, 200);
    try std.testing.expect(app.takeRecordLine() == null);
}

test "cursor style follows the screen" {
    var app = try App.init(std.testing.allocator, 1, .{ .mode = .words });
    defer app.deinit();
    try std.testing.expectEqual(App.CursorStyle.bar, app.cursorStyle());
    _ = app.handleEvent(.{ .key = .{ .code = 'p', .mods = .{ .ctrl = true } } }, false);
    try std.testing.expectEqual(App.CursorStyle.hidden, app.cursorStyle());
    _ = app.handleEvent(.{ .key = .{ .code = keys.code.escape } }, false);
    try std.testing.expect(!app.settings_ui.is_open);
    try std.testing.expect(app.cursorVisible());
    app.test_state.state = .finished;
    try std.testing.expect(!app.cursorVisible());

    app.setMode(.vim, 2);
    try std.testing.expectEqual(App.CursorStyle.block, app.cursorStyle());
    _ = app.handleEvent(.{ .key = .{ .code = ':' } }, false);
    try std.testing.expectEqual(App.CursorStyle.bar, app.cursorStyle());
    _ = app.handleEvent(.{ .key = .{ .code = keys.code.escape } }, false);
    try std.testing.expectEqual(App.CursorStyle.block, app.cursorStyle());
    app.setMode(.arcade, 3);
    try std.testing.expect(!app.cursorVisible());
}

test "arcade game option reaches the sim" {
    var app = try App.init(std.testing.allocator, 1, .{ .mode = .arcade, .arcade_game = .keys });
    defer app.deinit();
    // Any arcade event creates the sim.
    _ = app.handleEvent(.{ .key = .{ .code = 'a', .kind = .release } }, true);
    const sim = app.arcadeSim() orelse return error.NoArcade;
    try std.testing.expectEqual(types.Game.keys, sim.selectedGame());
    app.setArcadeGame(.words, 5);
    try std.testing.expectEqual(types.Game.words, app.test_state.config.arcade_game);
    try std.testing.expectEqual(types.Game.words, app.arcadeGame());

    // Tab on the title switches the game; leaving arcade keeps the choice.
    _ = app.handleEvent(.{ .key = .{ .code = keys.code.tab } }, true);
    try std.testing.expectEqual(types.Game.keys, app.arcadeGame());
    app.setMode(.words, 6);
    try std.testing.expect(app.arcadeSim() == null);
    try std.testing.expectEqual(types.Game.keys, app.arcadeGame());
}

// ----------------------------------------------------------------------------
// Round 2: code + vim keys, history screen, zen/daily/custom, layout,
// animation tail, persistence

const PK_LINE = "{\"v\":1,\"kind\":\"typing\",\"key\":\"words|common|w10|p0n0\",\"mode\":\"words\",\"wpm\":50,\"raw\":52,\"acc\":95,\"ms\":10000," ++
    "\"pk\":\"a:120/10/24000/110 s:120/40/36000/80 e:120/2/18000/118\"}";

test "code: ctrl+k toggles vim keys on the idle screen; the vim editor gets keys" {
    var app = try App.init(t_alloc, 5, .{ .mode = .code, .lang = .go });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    const ctrl: keys.Mods = .{ .ctrl = true };
    try std.testing.expect(!app.test_state.isVim());
    try std.testing.expectEqual(App.CursorStyle.bar, app.cursorStyle());
    try std.testing.expectEqual(KeyResult.handled, press(&app, 'k', ctrl, false));
    try std.testing.expectEqual(types.CodeKeys.vim, app.test_state.config.code_keys);
    try std.testing.expectEqual(@as(?types.VimKind, .type), app.test_state.vimKind());
    try std.testing.expect(app.toast_msg != null);
    try std.testing.expect(app.takeConfigJson() != null);
    // Vim NORMAL: a block cursor; i enters insert (a bar), text goes in.
    try std.testing.expectEqual(App.CursorStyle.block, app.cursorStyle());
    typeText(&app, "i");
    try std.testing.expectEqual(vim_editor.Mode.insert, app.test_state.activeEditor().mode);
    try std.testing.expectEqual(App.CursorStyle.bar, app.cursorStyle());
    typeText(&app, "pa");
    _ = press(&app, keys.code.escape, .{}, false);
    try std.testing.expectEqual(vim_editor.Mode.normal, app.test_state.activeEditor().mode);
    try std.testing.expectEqual(TestState.typing, app.test_state.state);
    // Ctrl+K only works before the run starts (in insert it is vim's own).
    _ = press(&app, 'k', ctrl, false);
    try std.testing.expectEqual(types.CodeKeys.vim, app.test_state.config.code_keys);
    // Back on the idle screen it toggles back to plain keys.
    _ = press(&app, keys.code.tab, .{}, false);
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    _ = press(&app, 'k', ctrl, false);
    try std.testing.expectEqual(types.CodeKeys.plain, app.test_state.config.code_keys);
    try std.testing.expect(!app.test_state.isVim());
    // Not in words mode.
    app.setMode(.words, 9);
    _ = press(&app, 'k', ctrl, false);
    try std.testing.expectEqual(types.CodeKeys.plain, app.test_state.config.code_keys);
}

test "code: enter mid-line skips to the next line" {
    var app = try App.init(t_alloc, 11, .{ .mode = .code, .lang = .zig });
    defer app.deinit();
    const s = &app.test_state.session;
    // The first line's last word (ends with a newline separator).
    var end: ?usize = null;
    for (s.words.items, 0..) |w, i| {
        if (w.sep == .newline) {
            end = i;
            break;
        }
    }
    const last = end orelse return error.SkipZigTest;
    if (last + 1 >= s.wordCount()) return error.SkipZigTest;
    // An untouched line: Enter does nothing.
    _ = press(&app, keys.code.enter, .{}, false);
    try std.testing.expectEqual(@as(usize, 0), s.activeIndex());
    const first = s.word(0).target;
    typeText(&app, first[0..1]);
    _ = press(&app, keys.code.enter, .{}, false);
    try std.testing.expectEqual(last + 1, s.activeIndex());
}

test "history screen: f2 and h open it, tabs and scroll, esc closes" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words, .word_count = 1 });
    defer app.deinit();
    app.loadSaved(null, PK_LINE ++ "\n" ++ PK_LINE ++ "\n", .{});
    try std.testing.expectEqual(@as(u32, 2), app.log.count());
    _ = press(&app, keys.code.f(2), .{}, false);
    try std.testing.expectEqual(ui_state.Overlay.history, app.overlay);
    try std.testing.expectEqual(App.CursorStyle.hidden, app.cursorStyle());
    const ui = app.uiState(false);
    try std.testing.expectEqual(ui_state.Overlay.history, ui.overlay);
    try std.testing.expect(ui.log != null and ui.pbs != null);
    // Keys don't reach the test while it is open.
    typeText(&app, "j");
    try std.testing.expectEqual(@as(usize, 1), app.history_scroll);
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    typeText(&app, "jjjjjj");
    try std.testing.expectEqual(@as(usize, 2), app.history_scroll); // two runs
    _ = press(&app, keys.code.tab, .{}, false);
    try std.testing.expectEqual(ui_state.HistoryTab.bests, app.history_tab);
    try std.testing.expectEqual(@as(usize, 0), app.history_scroll);
    _ = press(&app, keys.code.tab, .{ .shift = true }, false);
    try std.testing.expectEqual(ui_state.HistoryTab.recent, app.history_tab);
    _ = press(&app, keys.code.escape, .{}, false);
    try std.testing.expectEqual(ui_state.Overlay.none, app.overlay);
    // Not while typing; `h` on results.
    typeText(&app, "x");
    _ = press(&app, keys.code.f(2), .{}, false);
    try std.testing.expectEqual(ui_state.Overlay.none, app.overlay);
    app.test_state.state = .finished;
    endGuard(&app);
    _ = press(&app, 'h', .{}, false);
    try std.testing.expectEqual(ui_state.Overlay.history, app.overlay);
    try std.testing.expectEqual(KeyResult.quit, press(&app, 'c', .{ .ctrl = true }, false));
    _ = press(&app, 'q', .{}, false);
    try std.testing.expectEqual(ui_state.Overlay.none, app.overlay);
}

test "history screen: scroll stops at the view's last page once drawn" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words, .word_count = 1 });
    defer app.deinit();
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(t_alloc);
    for (0..60) |_| try lines.appendSlice(t_alloc, PK_LINE ++ "\n");
    app.loadSaved(null, lines.items, .{});
    _ = press(&app, keys.code.f(2), .{}, false);
    // As if a 120x40 frame was drawn.
    app.view_w = 120;
    app.view_h = 40;
    const ui = app.uiState(false);
    const max = history_view.maxScroll(&ui, 120, 40);
    try std.testing.expect(max > 0 and max < 60);
    _ = press(&app, 'G', .{}, false);
    try std.testing.expectEqual(max, app.history_scroll);
    // One press back up moves one row.
    typeText(&app, "k");
    try std.testing.expectEqual(max - 1, app.history_scroll);
    // A stale scroll past the end (after a resize) clamps first.
    app.history_scroll = 500;
    typeText(&app, "k");
    try std.testing.expectEqual(max - 1, app.history_scroll);
}

test "results w: weak-key practice needs key data" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words, .word_count = 3 });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    app.test_state.state = .finished;
    _ = press(&app, 'w', .{}, false);
    try std.testing.expect(app.toast_msg != null);
    try std.testing.expect(!app.test_state.isPractice());

    var rich = try App.init(t_alloc, 3, .{ .mode = .words, .word_count = 3 });
    defer rich.deinit();
    rich.loadSaved(null, PK_LINE, .{});
    rich.test_state.state = .finished;
    _ = press(&rich, 'w', .{}, false);
    try std.testing.expect(rich.test_state.isPractice());
    try std.testing.expectEqual(TestState.waiting, rich.test_state.state);
    try std.testing.expect(std.mem.startsWith(u8, rich.toast_msg.?, "weak-key practice"));
    // No pace caret for practice runs.
    try std.testing.expect(rich.uiState(false).pace_wpm == null);
}

test "zen: esc and shift+enter finish, esc on an empty run restarts" {
    var app = try App.init(t_alloc, 3, .{ .mode = .zen });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    _ = press(&app, keys.code.escape, .{}, false);
    try std.testing.expectEqual(TestState.waiting, app.test_state.state);
    typeText(&app, "free words");
    try std.testing.expectEqual(TestState.typing, app.test_state.state);
    _ = press(&app, keys.code.enter, .{ .shift = true }, false);
    try std.testing.expectEqual(TestState.finished, app.test_state.state);
    try std.testing.expect(app.uiState(false).pace_wpm == null);
}

test "daily: the day is set before every reset" {
    var app = try App.init(t_alloc, 3, .{ .mode = .daily });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    const today = daily.dayFromUnix(time.unixSeconds());
    try std.testing.expectEqual(today, app.test_state.config.day);
    app.test_state.config.day = 1;
    app.reset(4);
    try std.testing.expectEqual(today, app.test_state.config.day);
}

test "custom: a paste on the idle screen becomes the text; elsewhere it is ignored" {
    var app = try App.init(t_alloc, 3, .{ .mode = .custom });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    _ = press(&app, keys.code.paste_start, .{}, false);
    typeText(&app, "my pasted");
    _ = press(&app, keys.code.enter, .{}, false);
    typeText(&app, "text");
    _ = press(&app, keys.code.paste_end, .{}, false);
    try std.testing.expectEqualStrings("my pasted\ntext", app.test_state.customText());
    try std.testing.expectEqualStrings("custom text: 3 words", app.toast_msg.?);
    try std.testing.expectEqualStrings("my pasted\ntext", app.takeCustomText().?);
    try std.testing.expect(app.takeCustomText() == null);
    try std.testing.expectEqualStrings("my", app.test_state.session.word(0).target);
    // While typing, a paste is ignored (and marks the run).
    typeText(&app, "m");
    _ = press(&app, keys.code.paste_start, .{}, false);
    typeText(&app, "other");
    _ = press(&app, keys.code.paste_end, .{}, false);
    try std.testing.expectEqualStrings("my pasted\ntext", app.test_state.customText());
    try std.testing.expectEqualStrings("m", activeTyped(&app));
    // --text / stdin arrive as an override.
    var cli_app = try App.init(t_alloc, 3, .{ .mode = .custom });
    defer cli_app.deinit();
    cli_app.loadSaved(null, null, .{ .custom_text = "from the cli" });
    try std.testing.expectEqualStrings("from", cli_app.test_state.session.word(0).target);
    try std.testing.expect(cli_app.takeCustomText() != null);
}

test "custom: pasted LF, CRLF and CR newlines all survive (raw bytes through the parser)" {
    var app = try App.init(t_alloc, 3, .{ .mode = .custom });
    defer app.deinit();
    app.loadSaved(null, null, .{});
    // Terminals paste newlines as LF (read as Ctrl+J), CRLF or CR.
    var p: @import("../platform/input.zig").Parser = .{};
    _ = p.feed("\x1b[200~one two\nthree\r\nfour\rfive\x1b[201~");
    while (p.next(true)) |ev| _ = app.handleEvent(ev, false);
    try std.testing.expectEqualStrings("one two\nthree\nfour\nfive", app.test_state.customText());
}

test "layout emulation remaps typed chars in the simple modes" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words, .layout = .dvorak });
    defer app.deinit();
    // QWERTY s is Dvorak o.
    typeText(&app, "s");
    try std.testing.expectEqualStrings("o", activeTyped(&app));
}

test "sounds: classic key presses queue sfx only when enabled (web)" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words });
    defer app.deinit();
    app.collect_sfx = true;
    typeText(&app, "a");
    try std.testing.expectEqual(@as(usize, 0), app.sfx().len);
    app.test_state.config.sounds = true;
    typeText(&app, "b");
    try std.testing.expect(app.sfx().len >= 1);
    try std.testing.expectEqual(SfxKind.key_letter, app.sfx()[0].kind);
}

test "pace caret: pb when one exists, fixed speed, off" {
    var app = try App.init(t_alloc, 3, .{ .mode = .words, .word_count = 10 });
    defer app.deinit();
    app.loadSaved(null, PK_LINE, .{});
    try std.testing.expectEqual(@as(?f32, 50), app.uiState(false).pace_wpm);
    app.test_state.config.caret_pace = .fixed;
    app.test_state.config.caret_wpm = 70;
    try std.testing.expectEqual(@as(?f32, 70), app.uiState(false).pace_wpm);
    app.test_state.config.caret_pace = .off;
    try std.testing.expect(app.uiState(false).pace_wpm == null);
    app.test_state.config.caret_pace = .pb;
    app.setMode(.vim, 4);
    try std.testing.expect(app.uiState(false).pace_wpm == null);
}

test "animation tail: frames keep coming after a finish" {
    var app = try App.init(t_alloc, 7, .{ .mode = .words, .word_count = 1 });
    defer app.deinit();
    var buf: [32]u8 = undefined;
    const w = app.test_state.session.word(0).target;
    @memcpy(buf[0..w.len], w);
    typeText(&app, buf[0..w.len]);
    try std.testing.expectEqual(TestState.finished, app.test_state.state);
    const now = time.milliTimestamp();
    app.dirty = false;
    app.last_render_ms = now - render_ui.ANIM_FRAME_MS;
    try std.testing.expect(app.shouldRender(now));
    try std.testing.expect(app.getPollWaitMs(now) <= render_ui.ANIM_FRAME_MS);
    // Long after the finish: idle again.
    app.finished_ms = now - 60_000;
    app.last_render_ms = now;
    try std.testing.expect(!app.shouldRender(now + render_ui.ANIM_FRAME_MS));
}

test "config JSON carries the round 2 options; history chunks equal one load" {
    var app = try App.init(t_alloc, 1, .{});
    defer app.deinit();
    app.loadSaved(null, null, .{ .code_keys = .vim, .layout = .colemak, .caret_pace = .off });
    app.markConfigDirty();
    const json = app.takeConfigJson().?;
    for ([_][]const u8{ "\"keys\":\"vim\"", "\"layout\":\"colemak\"", "\"pace\":\"off\"", "\"stop\":", "\"nobs\":", "\"sounds\":" }) |k| {
        try std.testing.expect(std.mem.indexOf(u8, json, k) != null);
    }
    // A saved config round-trips through loadSaved.
    var copy: [1024]u8 = undefined;
    @memcpy(copy[0..json.len], json);
    var again = try App.init(t_alloc, 1, .{});
    defer again.deinit();
    again.loadSaved(copy[0..json.len], null, .{});
    try std.testing.expectEqual(types.CodeKeys.vim, again.test_state.config.code_keys);
    try std.testing.expectEqual(types.Layout.colemak, again.test_state.config.layout);

    const lines = PK_LINE ++ "\n" ++ PK_LINE ++ "\n" ++ PK_LINE ++ "\n";
    var chunked = try App.init(t_alloc, 1, .{});
    defer chunked.deinit();
    chunked.loadHistoryChunk(lines[0 .. PK_LINE.len + 1]);
    chunked.loadHistoryChunk(lines[PK_LINE.len + 1 ..]);
    chunked.loadSaved(null, null, .{});
    var whole = try App.init(t_alloc, 1, .{});
    defer whole.deinit();
    whole.loadSaved(null, lines, .{});
    try std.testing.expectEqual(whole.log.count(), chunked.log.count());
    try std.testing.expectEqual(@as(u32, 3), chunked.log.count());
    try std.testing.expectEqual(whole.pb_table.bestWpm("words|common|w10|p0n0"), chunked.pb_table.bestWpm("words|common|w10|p0n0"));
    const pbs = chunked.pbLines(t_alloc).?;
    defer t_alloc.free(pbs);
    try std.testing.expect(std.mem.indexOf(u8, pbs, "\"pb\":true") != null);
}

test "settings: options apply; the web text row asks the host for its dialog" {
    var app = try App.init(t_alloc, 1, .{ .mode = .custom });
    defer app.deinit();
    app.is_web = true;
    app.loadSaved(null, null, .{});
    _ = press(&app, 'p', .{ .ctrl = true }, true);
    try std.testing.expect(app.settings_ui.is_open and app.settings_ui.is_web);
    // theme → mode → test (length, text): select text, press right.
    _ = press(&app, keys.code.tab, .{}, true);
    _ = press(&app, keys.code.tab, .{}, true);
    _ = press(&app, keys.code.down, .{}, true);
    _ = press(&app, keys.code.right, .{}, true);
    try std.testing.expect(!app.settings_ui.is_open);
    try std.testing.expect(app.takeCustomDialogRequest());
    try std.testing.expect(!app.takeCustomDialogRequest());
}
