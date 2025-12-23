//! Shared application state and logic.
//! Used by both native CLI and web entry points.

const std = @import("std");

const constants = @import("constants.zig");
const types = @import("types.zig");
const typing_test = @import("typing_test.zig");
const time = @import("../platform/time.zig");
const ansi = @import("../ui/ansi.zig");
const render_ui = @import("../ui/render.zig");
const theme_mod = @import("../ui/theme.zig");
const settings_mod = @import("../ui/settings.zig");
const RenderBuffer = @import("../platform/render_buffer.zig").RenderBuffer;
const Terminal = @import("../platform/terminal.zig").Terminal;
const Input = @import("../platform/input.zig").Input;
const Key = @import("../platform/input.zig").Key;

const Config = types.Config;
const TypingTest = typing_test.TypingTest;
const TestState = typing_test.TestState;
const ThemeId = theme_mod.ThemeId;
const Settings = settings_mod.Settings;

/// Result of handling a key
pub const KeyResult = enum {
    none,
    quit,
    handled,
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
        };
    }

    pub fn deinit(self: *App) void {
        self.test_state.deinit();
    }

    /// Reset the test with a new seed
    pub fn reset(self: *App, seed: u64) void {
        self.error_msg = null; // Clear any previous error
        self.test_state.reset(seed) catch {
            self.error_msg = "Failed to reset - out of memory";
            // Keep the current state usable
        };
        self.needs_full_clear = true;
        self.last_state = self.test_state.state;
        self.dirty = true;
    }

    /// Handle a key event. Returns KeyResult indicating what happened.
    /// For native CLI, quit=true means exit. For web, quit is ignored.
    pub fn handleKey(self: *App, key: Key, is_web: bool) KeyResult {
        // Clear error on any key press
        self.error_msg = null;

        // Handle settings overlay first
        if (self.settings_ui.is_open) {
            const action = self.settings_ui.handleKey(key);
            switch (action) {
                .none => {},
                .preview_theme => |id| {
                    self.theme_id = id;
                    self.needs_full_clear = true;
                },
                .apply_mode => |mode| {
                    self.test_state.config.mode = mode;
                    const seed = self.generateSeed();
                    self.reset(seed);
                },
                .close => self.needs_full_clear = true,
                .cancel => |id| {
                    self.theme_id = id;
                    self.needs_full_clear = true;
                },
            }
            self.dirty = true;
            return .handled;
        }

        // Normal key handling
        switch (key) {
            .Byte => |b| switch (b) {
                0x03 => { // Ctrl+C
                    if (is_web) {
                        // In web, Ctrl+C resets instead of quitting
                        const seed = self.generateSeed();
                        self.reset(seed);
                        return .handled;
                    }
                    return .quit;
                },
                0x10 => { // Ctrl+P: Open settings
                    self.settings_ui.open(self.theme_id, self.test_state.config.mode);
                    self.dirty = true;
                    return .handled;
                },
                0x1b => { // Escape
                    if (self.test_state.config.mode == .vim) {
                        self.test_state.handleKey(27);
                        self.dirty = true;
                    } else if (!is_web) {
                        // In native non-vim modes, Escape quits
                        return .quit;
                    } else {
                        // In web non-vim modes, Escape resets
                        const seed = self.generateSeed();
                        self.reset(seed);
                    }
                    return .handled;
                },
                '\t' => {
                    // Tab: indent in vim insert mode, otherwise reset
                    if (self.test_state.config.mode == .vim and
                        self.test_state.vim.mode == .insert and
                        self.test_state.state != .finished)
                    {
                        self.test_state.handleKey('\t');
                    } else {
                        const seed = self.generateSeed();
                        self.reset(seed);
                    }
                    self.dirty = true;
                    return .handled;
                },
                else => {
                    self.test_state.handleKey(b);
                    self.dirty = true;
                    return .handled;
                },
            },
            // Arrow keys - route to vim mode for navigation
            .ArrowUp,
            .ArrowDown,
            .ArrowLeft,
            .ArrowRight,
            .ShiftArrowLeft,
            .ShiftArrowRight,
            .CtrlArrowLeft,
            .CtrlArrowRight,
            .CtrlArrowUp,
            .CtrlArrowDown,
            => {
                if (self.test_state.config.mode == .vim) {
                    self.test_state.vim.handleArrow(key);
                    self.dirty = true;
                    return .handled;
                }
                return .none;
            },
        }
    }

    /// Check time limit and state changes. Returns true if state changed.
    pub fn update(self: *App) bool {
        self.test_state.checkTimeLimit();
        if (self.test_state.state != self.last_state) {
            self.last_state = self.test_state.state;
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// Check if render is needed based on dirty flag and timing
    pub fn shouldRender(self: *App, now: i64) bool {
        if (self.dirty) return true;
        if (self.test_state.state == .typing) {
            return now - self.last_render_ms >= constants.TIMER_REFRESH_MS;
        }
        return false;
    }

    /// Render the current state to the buffer
    pub fn render(self: *App, buf: *RenderBuffer, term: *Terminal) void {
        self.last_render_ms = time.milliTimestamp();
        self.dirty = false;

        buf.clear();
        buf.write(ansi.SYNC_BEGIN);

        const palette = theme_mod.resolve(self.theme_id);
        buf.write(palette.base);

        if (self.needs_full_clear) {
            buf.write(ansi.CLEAR);
            self.needs_full_clear = false;
        }

        if (self.test_state.config.mode == .vim) {
            render_ui.renderVim(buf, term, &self.test_state, palette);
        } else {
            render_ui.renderSimple(buf, term, &self.test_state, palette);
        }

        self.settings_ui.renderOverlay(buf, term, palette, self.theme_id, self.test_state.config.mode);

        buf.write(ansi.SYNC_END);
        buf.flush();
    }

    /// Mark the app as needing a resize clear
    pub fn onResize(self: *App) void {
        self.dirty = true;
        self.needs_full_clear = true;
    }

    /// Calculate poll wait time for native input
    pub fn getPollWaitMs(self: *App, now: i64) i64 {
        if (self.dirty) return 0;
        if (self.test_state.state == .typing) {
            const elapsed = now - self.last_render_ms;
            return @max(0, constants.TIMER_REFRESH_MS - elapsed);
        }
        return constants.IDLE_POLL_MS;
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
        self.theme_id = id;
        self.dirty = true;
        self.needs_full_clear = true;
    }

    pub fn setMode(self: *App, mode: types.Mode, seed: u64) void {
        self.test_state.config.mode = mode;
        self.reset(seed);
    }

    pub fn setWordCount(self: *App, count: usize, seed: u64) void {
        self.test_state.config.word_count = @max(1, @min(count, 100));
        self.reset(seed);
    }

    pub fn setTimeLimit(self: *App, seconds: usize, seed: u64) void {
        self.test_state.config.time_limit = seconds;
        self.reset(seed);
    }

    pub fn setLang(self: *App, lang: types.Lang, seed: u64) void {
        self.test_state.config.lang = lang;
        self.reset(seed);
    }

    pub fn getErrorMsg(self: *const App) ?[]const u8 {
        return self.error_msg;
    }

    pub fn clearError(self: *App) void {
        self.error_msg = null;
    }
};
