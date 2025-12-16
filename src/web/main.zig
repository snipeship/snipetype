//! ONE Web - WASM Entry Point
//!
//! Exports a C-style API for JavaScript to drive the application.
//! The main loop is driven by JS calling tick() on requestAnimationFrame.

const std = @import("std");
const one = @import("one");

// Import UI and platform modules through the one library
const ansi = one.ansi;
const render = one.render;
const theme_mod = one.theme;
const settings_mod = one.settings;
const time = one.time;

// ============================================================================
// JavaScript Imports
// ============================================================================

extern "env" fn js_random_u32() u32;

// ============================================================================
// Global State
// ============================================================================

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// Staging buffer for input from JavaScript
var input_staging: [4096]u8 = undefined;

const App = struct {
    allocator: std.mem.Allocator,
    term: one.Terminal,
    buf: one.RenderBuffer,
    test_state: one.TypingTest,
    input: one.Input,
    theme_id: theme_mod.ThemeId,
    settings_ui: settings_mod.Settings,

    // Render state
    dirty: bool,
    needs_full_clear: bool,
    last_state: one.TestState,
    last_render_ms: i64,
};

var app: ?App = null;

// ============================================================================
// Required main() - not used but required by executable
// ============================================================================

pub fn main() void {}

// ============================================================================
// Exported API: Input Staging
// ============================================================================

/// Returns pointer to input staging buffer (for JS to write into)
export fn one_web_input_staging_ptr() [*]u8 {
    return &input_staging;
}

/// Returns capacity of input staging buffer
export fn one_web_input_staging_cap() u32 {
    return @intCast(input_staging.len);
}

/// Commit bytes written to staging buffer (JS calls after writing)
export fn one_web_input_commit(len: u32) void {
    if (app) |*a| {
        const n: usize = @min(@as(usize, @intCast(len)), input_staging.len);
        a.input.pushBytes(input_staging[0..n]);
        a.dirty = true;
    }
}

// ============================================================================
// Exported API: Lifecycle
// ============================================================================

/// Initialize the application
export fn one_web_init(cols: u32, rows: u32, seed: u32) i32 {
    if (app != null) {
        // Already initialized - deinit first
        one_web_deinit();
    }

    const allocator = gpa.allocator();

    // Initialize terminal with size from JS
    var term = one.Terminal.init() catch return -1;
    term.width = @intCast(cols);
    term.height = @intCast(rows);

    // Initialize render buffer
    var buf = one.RenderBuffer.init(allocator);

    // Default config
    const cfg = one.Config{
        .mode = .words,
        .word_count = 10,
        .time_limit = 0,
        .lang = .mixed,
    };

    // Initialize typing test
    const test_state = one.TypingTest.init(allocator, @as(u64, seed), cfg) catch return -2;

    // Initialize input handler
    const input_handler = one.Input.init();

    // Initial terminal setup
    buf.write(ansi.RESET ++ ansi.CLEAR ++ ansi.HIDE_CURSOR);
    buf.flush();
    buf.clear();

    app = App{
        .allocator = allocator,
        .term = term,
        .buf = buf,
        .test_state = test_state,
        .input = input_handler,
        .theme_id = .system,
        .settings_ui = settings_mod.Settings{},
        .dirty = true,
        .needs_full_clear = true,
        .last_state = test_state.state,
        .last_render_ms = 0,
    };

    return 0;
}

/// Clean up and free resources
export fn one_web_deinit() void {
    if (app) |*a| {
        a.test_state.deinit();
        a.buf.deinit();
    }
    app = null;
}

/// Update terminal size (called by JS on resize)
export fn one_web_resize(cols: u32, rows: u32) void {
    if (app) |*a| {
        a.term.width = @intCast(cols);
        a.term.height = @intCast(rows);
        a.dirty = true;
        a.needs_full_clear = true;
    }
}

// ============================================================================
// Exported API: Configuration
// ============================================================================

/// Set typing mode: 0=words, 1=sentences, 2=code, 3=vim
export fn one_web_set_mode(mode: u8) void {
    if (app) |*a| {
        a.test_state.config.mode = @enumFromInt(@min(mode, 3));
        resetTest(a);
    }
}

/// Set word count (1-100)
export fn one_web_set_word_count(count: u32) void {
    if (app) |*a| {
        a.test_state.config.word_count = @max(1, @min(@as(usize, @intCast(count)), 100));
        resetTest(a);
    }
}

/// Set time limit in seconds (0 = no limit)
export fn one_web_set_time_limit(seconds: u32) void {
    if (app) |*a| {
        a.test_state.config.time_limit = @intCast(seconds);
        resetTest(a);
    }
}

/// Set language: 0=mixed, 1=zig, 2=rust, 3=go, 4=typescript, 5=python, 6=c
export fn one_web_set_lang(lang: u8) void {
    if (app) |*a| {
        a.test_state.config.lang = @enumFromInt(@min(lang, 6));
        resetTest(a);
    }
}

/// Set theme: 0=system, 1=one_dark, 2=one_light, 3=dracula, 4=nord, 5=gruvbox_dark, 6=solarized_dark
export fn one_web_set_theme(theme: u8) void {
    if (app) |*a| {
        a.theme_id = @enumFromInt(@min(theme, 6));
        a.dirty = true;
        a.needs_full_clear = true;
    }
}

// ============================================================================
// Exported API: State Queries
// ============================================================================

/// Get current test state: 0=waiting, 1=typing, 2=finished
export fn one_web_get_state() u8 {
    if (app) |*a| {
        return @intFromEnum(a.test_state.state);
    }
    return 0;
}

/// Get current WPM (returns 0 if not finished)
export fn one_web_get_wpm() f32 {
    if (app) |*a| {
        return @floatCast(a.test_state.getWPM());
    }
    return 0;
}

/// Get current accuracy percentage
export fn one_web_get_accuracy() f32 {
    if (app) |*a| {
        return @floatCast(a.test_state.getAccuracy());
    }
    return 0;
}

/// Get current theme id (matches ThemeId enum order)
export fn one_web_get_theme() u8 {
    if (app) |*a| {
        return @intFromEnum(a.theme_id);
    }
    return 0;
}

// ============================================================================
// Exported API: Main Loop
// ============================================================================

/// Main tick function - call this every animation frame
export fn one_web_tick() void {
    if (app) |*a| {
        tickImpl(a);
    }
}

/// Force a reset of the current test
export fn one_web_reset() void {
    if (app) |*a| {
        resetTest(a);
    }
}

// ============================================================================
// Internal Implementation
// ============================================================================

fn resetTest(a: *App) void {
    const seed = js_random_u32();
    a.test_state.reset(@as(u64, seed)) catch {};
    a.needs_full_clear = true;
    a.last_state = a.test_state.state;
    a.dirty = true;
}

fn tickImpl(a: *App) void {
    const now = time.milliTimestamp();

    // Process all pending input
    while (a.input.readKey()) |key| {
        handleKey(a, key);
    }

    // Check time limit
    a.test_state.checkTimeLimit();
    if (a.test_state.state != a.last_state) {
        a.last_state = a.test_state.state;
        a.dirty = true;
    }

    // Render if dirty or timer needs update
    const timer_refresh_ms: i64 = 100;
    const should_render = a.dirty or
        (a.test_state.state == .typing and now - a.last_render_ms >= timer_refresh_ms);

    if (should_render) {
        a.last_render_ms = now;
        a.dirty = false;

        a.buf.clear();
        a.buf.write(ansi.SYNC_BEGIN);

        const palette = theme_mod.resolve(a.theme_id);
        a.buf.write(palette.base);

        if (a.needs_full_clear) {
            a.buf.write(ansi.CLEAR);
            a.needs_full_clear = false;
        }

        if (a.test_state.config.mode == .vim) {
            render.renderVim(&a.buf, &a.term, &a.test_state, palette);
        } else {
            render.renderSimple(&a.buf, &a.term, &a.test_state, palette);
        }

        a.settings_ui.renderOverlay(&a.buf, &a.term, palette, a.theme_id, a.test_state.config.mode);

        a.buf.write(ansi.SYNC_END);
        a.buf.flush();
    }
}

fn handleKey(a: *App, key: one.Key) void {
    // Handle settings overlay first
    if (a.settings_ui.is_open) {
        const action = a.settings_ui.handleKey(key);
        switch (action) {
            .none => {},
            .preview_theme => |id| {
                a.theme_id = id;
                a.needs_full_clear = true;
            },
            .apply_mode => |mode| {
                a.test_state.config.mode = mode;
                resetTest(a);
            },
            .close => a.needs_full_clear = true,
            .cancel => |id| {
                a.theme_id = id;
                a.needs_full_clear = true;
            },
        }
        a.dirty = true;
        return;
    }

    // Normal key handling
    switch (key) {
        .Byte => |b| switch (b) {
            0x03 => {
                // Ctrl+C: Reset test (can't exit in browser)
                resetTest(a);
            },
            0x10 => {
                // Ctrl+P: Open settings
                a.settings_ui.open(a.theme_id, a.test_state.config.mode);
                a.dirty = true;
            },
            0x1b => {
                // Escape
                if (a.test_state.config.mode == .vim) {
                    a.test_state.handleKey(27);
                    a.dirty = true;
                } else {
                    // In non-vim modes, reset on Escape
                    resetTest(a);
                }
            },
            '\t' => {
                // Tab: indent in vim insert mode, otherwise reset
                if (a.test_state.config.mode == .vim and
                    a.test_state.vim.mode == .insert and
                    a.test_state.state != .finished)
                {
                    a.test_state.handleKey('\t');
                } else {
                    resetTest(a);
                }
                a.dirty = true;
            },
            else => {
                a.test_state.handleKey(b);
                a.dirty = true;
            },
        },
        // Arrow keys are currently unused in main app (vim handles its own)
        .ArrowUp, .ArrowDown, .ArrowLeft, .ArrowRight => {},
    }
}
