//! ONE Web - WASM Entry Point
//!
//! Exports a C-style API for JavaScript to drive the application.
//! The main loop is driven by JS calling tick() on requestAnimationFrame.

const std = @import("std");
const one = @import("one");

const ansi = one.ansi;
const theme_mod = one.theme;
const time = one.time;

// ============================================================================
// JavaScript Imports
// ============================================================================

extern "env" fn js_random_u32() u32;

// ============================================================================
// Global State
// ============================================================================

// Use page allocator for WASM (GPA uses threading which isn't available)
var allocator_instance = std.heap.page_allocator;

// Staging buffer for input from JavaScript
var input_staging: [4096]u8 = undefined;

const WebApp = struct {
    allocator: std.mem.Allocator,
    app: one.App,
    term: one.Terminal,
    buf: one.RenderBuffer,
    input: one.Input,
};

var web_app: ?WebApp = null;

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
    if (web_app) |*wa| {
        const n: usize = @min(@as(usize, @intCast(len)), input_staging.len);
        wa.input.pushBytes(input_staging[0..n]);
        wa.app.dirty = true;
    }
}

// ============================================================================
// Exported API: Lifecycle
// ============================================================================

/// Initialize the application
export fn one_web_init(cols: u32, rows: u32, seed: u32) i32 {
    if (web_app != null) {
        one_web_deinit();
    }

    const allocator = allocator_instance;

    // Initialize terminal with size from JS
    var term = one.Terminal.init() catch return -1;
    term.setSize(@intCast(cols), @intCast(rows));

    // Initialize render buffer
    var buf = one.RenderBuffer.init(allocator);

    // Default config
    const cfg = one.Config{
        .mode = .words,
        .word_count = 10,
        .time_limit = 0,
        .lang = .mixed,
    };

    // Initialize app
    const app = one.App.init(allocator, @as(u64, seed), cfg) catch return -2;

    // Initial terminal setup
    buf.write(ansi.RESET ++ ansi.CLEAR ++ ansi.HIDE_CURSOR);
    buf.flush();
    buf.clear();

    web_app = WebApp{
        .allocator = allocator,
        .app = app,
        .term = term,
        .buf = buf,
        .input = one.Input.init(),
    };

    return 0;
}

/// Clean up and free resources
export fn one_web_deinit() void {
    if (web_app) |*wa| {
        wa.app.deinit();
        wa.buf.deinit();
    }
    web_app = null;
}

/// Update terminal size (called by JS on resize)
export fn one_web_resize(cols: u32, rows: u32) void {
    if (web_app) |*wa| {
        wa.term.setSize(@intCast(cols), @intCast(rows));
        wa.app.onResize();
    }
}

// ============================================================================
// Exported API: Configuration
// ============================================================================

/// Set typing mode: 0=words, 1=sentences, 2=code, 3=vim
export fn one_web_set_mode(mode: u8) void {
    if (web_app) |*wa| {
        const m: one.Mode = @enumFromInt(@min(mode, 3));
        wa.app.setMode(m, js_random_u32());
    }
}

/// Set word count (1-100)
export fn one_web_set_word_count(count: u32) void {
    if (web_app) |*wa| {
        wa.app.setWordCount(@intCast(count), js_random_u32());
    }
}

/// Set time limit in seconds (0 = no limit)
export fn one_web_set_time_limit(seconds: u32) void {
    if (web_app) |*wa| {
        wa.app.setTimeLimit(@intCast(seconds), js_random_u32());
    }
}

/// Set language: 0=mixed, 1=zig, 2=rust, 3=go, 4=typescript, 5=python, 6=c
export fn one_web_set_lang(lang: u8) void {
    if (web_app) |*wa| {
        const l: one.Lang = @enumFromInt(@min(lang, 6));
        wa.app.setLang(l, js_random_u32());
    }
}

/// Set theme: 0=system, 1=one_dark, 2=one_light, 3=dracula, 4=nord, 5=gruvbox_dark, 6=solarized_dark
export fn one_web_set_theme(theme: u8) void {
    if (web_app) |*wa| {
        wa.app.setThemeId(@enumFromInt(@min(theme, 6)));
    }
}

// ============================================================================
// Exported API: State Queries
// ============================================================================

/// Get current test state: 0=waiting, 1=typing, 2=finished
export fn one_web_get_state() u8 {
    if (web_app) |*wa| {
        return @intFromEnum(wa.app.getState());
    }
    return 0;
}

/// Get current WPM (returns 0 if not finished)
export fn one_web_get_wpm() f32 {
    if (web_app) |*wa| {
        return @floatCast(wa.app.getWPM());
    }
    return 0;
}

/// Get current accuracy percentage
export fn one_web_get_accuracy() f32 {
    if (web_app) |*wa| {
        return @floatCast(wa.app.getAccuracy());
    }
    return 0;
}

/// Get current theme id (matches ThemeId enum order)
export fn one_web_get_theme() u8 {
    if (web_app) |*wa| {
        return @intFromEnum(wa.app.getThemeId());
    }
    return 0;
}

// ============================================================================
// Exported API: Main Loop
// ============================================================================

/// Main tick function - call this every animation frame
export fn one_web_tick() void {
    if (web_app) |*wa| {
        tickImpl(wa);
    }
}

/// Force a reset of the current test
export fn one_web_reset() void {
    if (web_app) |*wa| {
        wa.app.reset(js_random_u32());
    }
}

// ============================================================================
// Internal Implementation
// ============================================================================

fn tickImpl(wa: *WebApp) void {
    const now = time.milliTimestamp();

    // Process all pending input
    while (wa.input.readKey()) |key| {
        _ = wa.app.handleKey(key, true);
    }

    // Update state (check time limit, etc.)
    _ = wa.app.update();

    // Render if needed
    if (wa.app.shouldRender(now)) {
        wa.app.render(&wa.buf, &wa.term);
    }
}
