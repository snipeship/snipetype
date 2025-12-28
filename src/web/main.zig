//! snipetype Web - WASM Entry Point
//!
//! Exports a C-style API for JavaScript to drive the application.
//! The main loop is driven by JS calling tick() on requestAnimationFrame.
//! Uses CellRenderer for direct cell grid access from JavaScript.

const std = @import("std");
const snipetype = @import("snipetype");

const theme_mod = snipetype.theme;
const time = snipetype.time;

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
    app: snipetype.App,
    cell_renderer: snipetype.CellRenderer,
    input: snipetype.Input,
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
export fn snipetype_input_staging_ptr() [*]u8 {
    return &input_staging;
}

/// Returns capacity of input staging buffer
export fn snipetype_input_staging_cap() u32 {
    return @intCast(input_staging.len);
}

/// Commit bytes written to staging buffer (JS calls after writing)
export fn snipetype_input_commit(len: u32) void {
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
export fn snipetype_init(cols: u32, rows: u32, seed: u32) i32 {
    if (web_app != null) {
        snipetype_deinit();
    }

    const allocator = allocator_instance;
    const w: usize = @intCast(cols);
    const h: usize = @intCast(rows);

    // Initialize cell renderer
    var cell_renderer = snipetype.CellRenderer.init(allocator, w, h) catch return -1;

    // Default config
    const cfg = snipetype.Config{
        .mode = .words,
        .word_count = 10,
        .time_limit = 0,
        .lang = .mixed,
    };

    // Initialize app
    const app = snipetype.App.init(allocator, @as(u64, seed), cfg) catch {
        cell_renderer.deinit();
        return -2;
    };

    web_app = WebApp{
        .allocator = allocator,
        .app = app,
        .cell_renderer = cell_renderer,
        .input = snipetype.Input.init(),
    };

    return 0;
}

/// Clean up and free resources
export fn snipetype_deinit() void {
    if (web_app) |*wa| {
        wa.app.deinit();
        wa.cell_renderer.deinit();
    }
    web_app = null;
}

/// Update terminal size (called by JS on resize)
export fn snipetype_resize(cols: u32, rows: u32) void {
    if (web_app) |*wa| {
        wa.cell_renderer.resize(@intCast(cols), @intCast(rows)) catch {};
        wa.app.onResize();
    }
}

// ============================================================================
// Exported API: Configuration
// ============================================================================

/// Set typing mode: 0=words, 1=sentences, 2=code, 3=vim
export fn snipetype_set_mode(mode: u8) void {
    if (web_app) |*wa| {
        const m: snipetype.Mode = @enumFromInt(@min(mode, 3));
        wa.app.setMode(m, js_random_u32());
    }
}

/// Set word count (1-100)
export fn snipetype_set_word_count(count: u32) void {
    if (web_app) |*wa| {
        wa.app.setWordCount(@intCast(count), js_random_u32());
    }
}

/// Set time limit in seconds (0 = no limit)
export fn snipetype_set_time_limit(seconds: u32) void {
    if (web_app) |*wa| {
        wa.app.setTimeLimit(@intCast(seconds), js_random_u32());
    }
}

/// Set language: 0=mixed, 1=zig, 2=rust, 3=go, 4=typescript, 5=python, 6=c
export fn snipetype_set_lang(lang: u8) void {
    if (web_app) |*wa| {
        const l: snipetype.Lang = @enumFromInt(@min(lang, 6));
        wa.app.setLang(l, js_random_u32());
    }
}

/// Set theme: 0=system, 1=one_dark, 2=one_light, 3=dracula, 4=nord, 5=gruvbox_dark, 6=solarized_dark
export fn snipetype_set_theme(theme: u8) void {
    if (web_app) |*wa| {
        wa.app.setThemeId(@enumFromInt(@min(theme, 6)));
    }
}

// ============================================================================
// Exported API: State Queries
// ============================================================================

/// Get current test state: 0=waiting, 1=typing, 2=finished
export fn snipetype_get_state() u8 {
    if (web_app) |*wa| {
        return @intFromEnum(wa.app.getState());
    }
    return 0;
}

/// Get current WPM (returns 0 if not finished)
export fn snipetype_get_wpm() f32 {
    if (web_app) |*wa| {
        return @floatCast(wa.app.getWPM());
    }
    return 0;
}

/// Get current accuracy percentage
export fn snipetype_get_accuracy() f32 {
    if (web_app) |*wa| {
        return @floatCast(wa.app.getAccuracy());
    }
    return 0;
}

/// Get current theme id (matches ThemeId enum order)
export fn snipetype_get_theme() u8 {
    if (web_app) |*wa| {
        return @intFromEnum(wa.app.getThemeId());
    }
    return 0;
}

// ============================================================================
// Exported API: Main Loop
// ============================================================================

/// Main tick function - call this every animation frame
export fn snipetype_tick() void {
    if (web_app) |*wa| {
        tickImpl(wa);
    }
}

/// Force a reset of the current test
export fn snipetype_reset() void {
    if (web_app) |*wa| {
        wa.app.reset(js_random_u32());
    }
}

// ============================================================================
// Exported API: Cell Grid Access
// ============================================================================

/// Get pointer to cell grid (for JS to read directly from WASM memory)
export fn snipetype_get_cells_ptr() usize {
    if (web_app) |*wa| {
        return @intFromPtr(wa.cell_renderer.getCellsPtr());
    }
    return 0;
}

/// Get size of cell grid in bytes
export fn snipetype_get_cells_size() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.getCellsSize());
    }
    return 0;
}

/// Get grid width in cells
export fn snipetype_get_grid_width() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.width);
    }
    return 0;
}

/// Get grid height in cells
export fn snipetype_get_grid_height() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.height);
    }
    return 0;
}

/// Check if grid needs redraw
export fn snipetype_is_dirty() bool {
    if (web_app) |*wa| {
        return wa.cell_renderer.isDirty();
    }
    return false;
}

/// Get dirty region: x
export fn snipetype_get_dirty_x() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.getDirtyRegion().x);
    }
    return 0;
}

/// Get dirty region: y
export fn snipetype_get_dirty_y() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.getDirtyRegion().y);
    }
    return 0;
}

/// Get dirty region: width
export fn snipetype_get_dirty_w() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.getDirtyRegion().w);
    }
    return 0;
}

/// Get dirty region: height
export fn snipetype_get_dirty_h() u32 {
    if (web_app) |*wa| {
        return @intCast(wa.cell_renderer.getDirtyRegion().h);
    }
    return 0;
}

/// Clear dirty flag after rendering
export fn snipetype_clear_dirty() void {
    if (web_app) |*wa| {
        wa.cell_renderer.clearDirty();
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
        const r = wa.cell_renderer.renderer();
        wa.app.render(r);
    }
}
