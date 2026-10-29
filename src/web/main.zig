//! snipetype Web - WASM Entry Point
//!
//! Exports a C-style API for the JavaScript host (web/app.js). JS drives the
//! main loop by calling `snipetype_tick()` every animation frame.
//!
//! Output: the app renders through `AnsiRenderer`; on wasm its bytes stay in
//! memory and the host feeds them to a ghostty-web terminal emulator
//! (`snipetype_get_output_ptr/len`, then `snipetype_clear_output`).
//! Input: JS writes raw terminal bytes (kitty `CSI u` key events, pasted
//! text) into a staging buffer and commits them.
//! Arcade: an RGBA pixel layer (`snipetype_get_fx_*`) is blitted by JS onto a
//! canvas under the terminal, and sound effect records (`snipetype_get_sfx_*`)
//! are synthesized with WebAudio.
//! Persistence: JS reads `localStorage` and hands the bytes over
//! (`snipetype_alloc` + `snipetype_load_saved`), then drains new history
//! lines and config changes every frame (`snipetype_take_record_*`,
//! `snipetype_take_config_*`). URL parameters arrive as a query string
//! (`snipetype_apply_query`) and beat the saved settings without being saved.
//! Classic modes draw through a `DiffRenderer` (only changed cells are
//! sent to ghostty-web); arcade frames keep the plain AnsiRenderer path.
//! Custom text: the host's dialog hands it over (`snipetype_set_custom_text`)
//! and persists what the core reports (`snipetype_take_custom_*`); history
//! trimming keeps personal bests via `snipetype_pb_lines_*`.

const std = @import("std");
const snipetype = @import("snipetype");

const time = snipetype.time;
const Mode = snipetype.Mode;

// ============================================================================
// JavaScript Imports
// ============================================================================

extern "env" fn js_random_u32() u32;

// ============================================================================
// Global State
// ============================================================================

const allocator = std.heap.wasm_allocator;

/// Staging buffer for input from JavaScript.
var input_staging: [4096]u8 = undefined;

const WebApp = struct {
    app: snipetype.App,
    ansi: snipetype.AnsiRenderer,
    /// Classic modes: diffs into `ansi` (set up once `web_app` holds the
    /// struct, since it points at `ansi`).
    diff: ?snipetype.DiffRenderer = null,
    /// The last frame was an arcade frame (the next classic one repaints).
    was_arcade: bool = false,
    input: snipetype.Input,
    cols: usize,
    rows: usize,
    /// Cursor style reported to JS (see `snipetype_get_cursor_style`).
    cursor_style: CursorStyle = .hidden,
    /// Smooth caret position for the host (see `snipetype_caret_visible`).
    caret_visible: bool = false,
    caret_x: usize = 0,
    caret_y: usize = 0,
};

var web_app: ?WebApp = null;

/// The host draws its own (animated) caret in the simple modes.
var smooth_caret: bool = false;

/// Terminal cell size in CSS pixels as measured by the host (0 = unknown).
/// Read by the arcade integration to pick the pixel surface resolution.
pub var cell_px_w: u32 = 0;
pub var cell_px_h: u32 = 0;

/// Hardware cursor style shown by ghostty-web (it ignores DECSCUSR, so the
/// host applies this through `term.options.cursorStyle`).
pub const CursorStyle = snipetype.App.CursorStyle;

// ----------------------------------------------------------------------------
// Arcade pixel layer: set after every tick from the App's arcade Surface
// (`.external` presenter backend), null when not rendering pixels.
// ----------------------------------------------------------------------------

pub const FxLayer = struct {
    /// RGBA8, row-major, `w * h * 4` bytes.
    pixels: []const u8,
    w: u32,
    h: u32,
};

pub var fx_layer: ?FxLayer = null;

// ----------------------------------------------------------------------------
// Sound effect queue (drained by JS every frame).
// ----------------------------------------------------------------------------

/// Sound effect kinds understood by web/audio.js (wire values are fixed;
/// shared with the core's event-to-sound mapping).
pub const SfxKind = snipetype.SfxKind;

/// One 12-byte little-endian record: `{ kind: u32, pan: f32, intensity: f32 }`.
pub const SfxRecord = extern struct {
    kind: u32,
    /// Stereo position, -1 (left) .. 1 (right).
    pan: f32,
    /// 0 .. 1; scales gain and brightness.
    intensity: f32,
};

comptime {
    std.debug.assert(@sizeOf(SfxRecord) == 12);
}

const sfx_capacity = 64;
var sfx_buf: [sfx_capacity]SfxRecord = undefined;
var sfx_len: u32 = 0;

/// Queue a sound for the host. Drops the sound if the queue is full (the
/// host drains it every frame, so that only happens while the tab is hidden).
pub fn queueSfx(kind: SfxKind, pan: f32, intensity: f32) void {
    if (sfx_len >= sfx_capacity) return;
    sfx_buf[sfx_len] = .{
        .kind = @backingInt(kind),
        .pan = std.math.clamp(pan, -1, 1),
        .intensity = std.math.clamp(intensity, 0, 1),
    };
    sfx_len += 1;
}

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

/// Initialize the application. Returns 0 on success, -2 if the app failed.
export fn snipetype_init(cols: u32, rows: u32, seed: u32) i32 {
    if (web_app != null) {
        snipetype_deinit();
    }

    const w: usize = @max(cols, 1);
    const h: usize = @max(rows, 1);

    const cfg = snipetype.Config{
        .mode = .words,
        .word_count = 10,
        .time_limit = 0,
        .lang = .mixed,
    };

    var app = snipetype.App.init(allocator, @as(u64, seed), cfg) catch return -2;
    app.is_web = true;
    // Arcade: text layer as ANSI, pixels blitted by the host; render at most
    // every 12 ms (every rAF at 60 Hz, every other one at 120/144 Hz).
    app.setGfx(.{ .backend = .external, .chords = true, .frame_ms = 12 });
    app.setCellPx(@intCast(@min(cell_px_w, 4096)), @intCast(@min(cell_px_h, 4096)));
    app.collect_sfx = true;

    web_app = WebApp{
        .app = app,
        .ansi = snipetype.AnsiRenderer.init(allocator, w, h),
        .input = snipetype.Input.init(),
        .cols = w,
        .rows = h,
    };
    sfx_len = 0;
    const wa = &web_app.?;
    wa.diff = snipetype.DiffRenderer.init(allocator, &wa.ansi, w, h) catch null;
    return 0;
}

/// Clean up and free resources
export fn snipetype_deinit() void {
    if (web_app) |*wa| {
        wa.app.deinit();
        if (wa.diff) |*d| d.deinit();
        wa.ansi.deinit();
    }
    web_app = null;
    fx_layer = null;
    sfx_len = 0;
}

/// Update terminal size (called by JS on resize). Forces a full redraw.
export fn snipetype_resize(cols: u32, rows: u32) void {
    if (web_app) |*wa| {
        wa.cols = @max(cols, 1);
        wa.rows = @max(rows, 1);
        wa.ansi.setSize(wa.cols, wa.rows);
        if (wa.diff) |*d| d.setSize(wa.cols, wa.rows) catch {
            d.deinit();
            wa.diff = null;
        };
        wa.app.onResize();
    }
}

/// Terminal cell size in CSS pixels (from ghostty-web's renderer metrics).
export fn snipetype_set_cell_px(w: u32, h: u32) void {
    cell_px_w = w;
    cell_px_h = h;
    if (web_app) |*wa| wa.app.setCellPx(@intCast(@min(w, 4096)), @intCast(@min(h, 4096)));
}

// ============================================================================
// Exported API: Configuration
// ============================================================================

/// Number of modes the core knows about (ids 0..7).
const mode_count = @typeInfo(Mode).@"enum".field_names.len;

/// Set typing mode: 0=words, 1=sentences, 2=code, 3=vim, 4=arcade, 5=zen,
/// 6=custom, 7=daily
export fn snipetype_set_mode(mode: u8) void {
    if (web_app) |*wa| {
        const idx: usize = @min(@as(usize, mode), mode_count - 1);
        wa.app.setMode(@fromBackingInt(@intCast(idx)), js_random_u32());
    }
}

/// Get the current mode id (same numbering as `snipetype_set_mode`).
export fn snipetype_get_mode() u8 {
    if (web_app) |*wa| {
        return @intCast(@backingInt(wa.app.test_state.config.mode));
    }
    return 0;
}

/// Arcade game: 0=words (falling quote words), 1=keys (keycaps, chords,
/// vim motions). A running arcade returns to its title screen.
export fn snipetype_set_game(game: u8) void {
    if (web_app) |*wa| {
        const G = @FieldType(snipetype.Config, "arcade_game");
        const n = @typeInfo(G).@"enum".field_names.len;
        wa.app.setArcadeGame(@fromBackingInt(@intCast(@min(@as(usize, game), n - 1))), js_random_u32());
    }
}

/// Current arcade game id (same numbering as `snipetype_set_game`).
export fn snipetype_get_game() u8 {
    if (web_app) |*wa| return @intCast(@backingInt(wa.app.arcadeGame()));
    return 0;
}

/// Set word count (1-250)
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

/// Number of code languages (ids 0..11).
const lang_count = @typeInfo(snipetype.Lang).@"enum".field_names.len;

/// Set language: 0=mixed, 1=zig, 2=rust, 3=go, 4=typescript, 5=python, 6=c,
/// 7=bash, 8=lua, 9=sql, 10=java, 11=yaml
export fn snipetype_set_lang(lang: u8) void {
    if (web_app) |*wa| {
        const l: snipetype.Lang = @fromBackingInt(@intCast(@min(@as(usize, lang), lang_count - 1)));
        wa.app.setLang(l, js_random_u32());
    }
}

/// Number of themes (ids 0..theme_count-1).
const theme_count = @typeInfo(snipetype.theme.ThemeId).@"enum".field_names.len;

/// Set theme: 0=system, 1=one_dark, 2=one_light, 3=dracula, 4=nord,
/// 5=gruvbox_dark, 6=solarized_dark, 7=serika_dark, 8=catppuccin_mocha,
/// 9=tokyo_night, 10=rose_pine, 11=everforest, 12=gruvbox_light
export fn snipetype_set_theme(theme: u8) void {
    if (web_app) |*wa| {
        wa.app.setThemeId(@fromBackingInt(@intCast(@min(@as(usize, theme), theme_count - 1))));
    }
}

// ============================================================================
// Exported API: Host, paste, persistence
// ============================================================================

/// Allocate `n` bytes in wasm memory for the host (0 on failure).
export fn snipetype_alloc(n: u32) usize {
    const buf = allocator.alloc(u8, @max(n, 1)) catch return 0;
    return @intFromPtr(buf.ptr);
}

/// Free a buffer from `snipetype_alloc` (same `n`).
export fn snipetype_free(ptr: usize, n: u32) void {
    if (ptr == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    allocator.free(p[0..@max(n, 1)]);
}

fn hostBytes(ptr: usize, len: u32) ?[]const u8 {
    if (ptr == 0 or len == 0) return null;
    const p: [*]const u8 = @ptrFromInt(ptr);
    return p[0..len];
}

/// Apply the saved config JSON and history JSONL (from localStorage; either
/// may be empty). Fills personal bests and resets the test.
export fn snipetype_load_saved(cfg_ptr: usize, cfg_len: u32, hist_ptr: usize, hist_len: u32) void {
    if (web_app) |*wa| {
        wa.app.loadSaved(hostBytes(cfg_ptr, cfg_len), hostBytes(hist_ptr, hist_len), .{});
    }
}

/// Apply URL parameters (`mode=code&words=25&theme=nord&...`, undecoded) as
/// overrides; applying them saves nothing (a later settings change saves
/// the whole current config). Keys: mode, words, time, lang, tier,
/// punct, numbers, theme, vim, drill.
export fn snipetype_apply_query(ptr: usize, len: u32) void {
    const wa = &(web_app orelse return);
    const q = hostBytes(ptr, len) orelse return;
    var theme_buf: [32]u8 = undefined;
    const ov = snipetype.ConfigOverrides.fromQuery(q, &theme_buf);
    wa.app.applyOverrides(ov, js_random_u32());
    wa.app.discardConfigChange();
}

/// The last line taken by `snipetype_take_record_ptr`.
var taken_record: []const u8 = "";
/// The last JSON taken by `snipetype_take_config_ptr`.
var taken_config: []const u8 = "";

/// Take the pending history line (JSON, no newline): pointer, then read
/// its length with `snipetype_take_record_len`. 0 when there is none.
export fn snipetype_take_record_ptr() usize {
    taken_record = "";
    if (web_app) |*wa| {
        if (wa.app.takeRecordLine()) |line| taken_record = line;
    }
    return if (taken_record.len == 0) 0 else @intFromPtr(taken_record.ptr);
}

export fn snipetype_take_record_len() u32 {
    return @intCast(taken_record.len);
}

/// Take the changed config JSON (theme, mode, options), like the record.
export fn snipetype_take_config_ptr() usize {
    taken_config = "";
    if (web_app) |*wa| {
        if (wa.app.takeConfigJson()) |json| taken_config = json;
    }
    return if (taken_config.len == 0) 0 else @intFromPtr(taken_config.ptr);
}

export fn snipetype_take_config_len() u32 {
    return @intCast(taken_config.len);
}

/// Replace the custom text (the host's dialog; UTF-8, sanitized by the
/// core). Custom mode restarts with it.
export fn snipetype_set_custom_text(ptr: usize, len: u32) void {
    const wa = &(web_app orelse return);
    wa.app.setCustomText(hostBytes(ptr, len) orelse "");
}

/// The custom text saved by the host (localStorage) at startup: quiet (no
/// toast) and not reported back by `snipetype_take_custom_ptr`.
export fn snipetype_load_custom_text(ptr: usize, len: u32) void {
    const wa = &(web_app orelse return);
    wa.app.loadCustomText(hostBytes(ptr, len) orelse return);
}

/// The last text taken by `snipetype_take_custom_ptr`.
var taken_custom: []const u8 = "";

/// Take the custom text once after it changed (the host saves it): pointer,
/// then `snipetype_take_custom_len`. 0 when unchanged.
export fn snipetype_take_custom_ptr() usize {
    taken_custom = "";
    if (web_app) |*wa| {
        if (wa.app.takeCustomText()) |t| taken_custom = t;
    }
    return if (taken_custom.len == 0) 0 else @intFromPtr(taken_custom.ptr);
}

export fn snipetype_take_custom_len() u32 {
    return @intCast(taken_custom.len);
}

/// 1 once after the settings `text` row asked for the custom-text dialog.
export fn snipetype_take_custom_dialog() u32 {
    if (web_app) |*wa| return @intFromBool(wa.app.takeCustomDialogRequest());
    return 0;
}

/// Personal-best lines (`"pb":true` records, '\n'-terminated) for history
/// trimming: pointer, then `snipetype_pb_lines_len`; valid until the next
/// call. 0 when there are none.
var pb_lines: ?[]u8 = null;

export fn snipetype_pb_lines_ptr() usize {
    if (pb_lines) |b| allocator.free(b);
    pb_lines = null;
    const wa = &(web_app orelse return 0);
    pb_lines = wa.app.pbLines(allocator);
    const b = pb_lines orelse return 0;
    return if (b.len == 0) 0 else @intFromPtr(b.ptr);
}

export fn snipetype_pb_lines_len() u32 {
    return if (pb_lines) |b| @intCast(b.len) else 0;
}

/// Length of the current custom text (0: none; the dialog then starts empty).
export fn snipetype_custom_text_len() u32 {
    if (web_app) |*wa| return @intCast(wa.app.test_state.customText().len);
    return 0;
}

/// Clipboard text was pasted into the terminal: not forwarded as keys; the
/// run is marked as pasted (no result is recorded).
export fn snipetype_note_paste() void {
    if (web_app) |*wa| wa.app.notePaste();
}

/// Host facts. Bit 0: macOS (Cmd chords). Bit 1: the one-time "ctrl+w
/// belongs to the browser" hint was already shown (localStorage).
export fn snipetype_set_host(flags: u32) void {
    if (web_app) |*wa| wa.app.setHost(flags & 1 != 0, flags & 2 == 0);
}

/// 1 once after the Ctrl+W hint was shown (the host then remembers it).
export fn snipetype_take_hint_shown() u32 {
    if (web_app) |*wa| return @intFromBool(wa.app.takeHintShown());
    return 0;
}

/// 1 while leaving the page would lose a run in progress (typing, or a vim
/// drill changed but not solved).
export fn snipetype_confirm_leave() u32 {
    if (web_app) |*wa| return @intFromBool(wa.app.confirmLeave());
    return 0;
}

// ============================================================================
// Exported API: State Queries
// ============================================================================

/// Get current test state: 0=waiting, 1=typing, 2=finished
export fn snipetype_get_state() u8 {
    if (web_app) |*wa| {
        return @backingInt(wa.app.getState());
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
        return @backingInt(wa.app.getThemeId());
    }
    return 0;
}

/// 1 while keys go to a vim editor (vim mode, or code with vim keys): the
/// host then lets Ctrl+R / Ctrl+V through and uses the insert cursor color.
export fn snipetype_is_vim() u32 {
    if (web_app) |*wa| return @intFromBool(wa.app.test_state.isVim());
    return 0;
}

/// Smooth caret (host flag): in the simple modes the emulator's own cursor
/// is hidden and the host draws a CSS caret at `snipetype_get_caret_*`.
export fn snipetype_set_smooth_caret(on: u32) void {
    smooth_caret = on != 0;
    if (web_app) |*wa| wa.app.dirty = true;
}

/// 1 while the host should draw its smooth caret (simple modes, bar).
export fn snipetype_caret_visible() u32 {
    if (web_app) |*wa| return @intFromBool(wa.caret_visible);
    return 0;
}

/// Caret cell column / row (valid while `snipetype_caret_visible`).
export fn snipetype_get_caret_x() u32 {
    if (web_app) |*wa| return @intCast(wa.caret_x);
    return 0;
}

export fn snipetype_get_caret_y() u32 {
    if (web_app) |*wa| return @intCast(wa.caret_y);
    return 0;
}

/// Hardware cursor style for the host: 0=hidden, 1=block, 2=bar, 3=underline.
export fn snipetype_get_cursor_style() u32 {
    if (web_app) |*wa| return @backingInt(wa.cursor_style);
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
// Exported API: ANSI Output
// ============================================================================

/// Pointer to the ANSI bytes produced since the last `snipetype_clear_output`.
export fn snipetype_get_output_ptr() usize {
    if (web_app) |*wa| return @intFromPtr(wa.ansi.output().ptr);
    return 0;
}

/// Length in bytes of the pending ANSI output (0 = nothing to write).
export fn snipetype_get_output_len() u32 {
    if (web_app) |*wa| return @intCast(wa.ansi.output().len);
    return 0;
}

/// Drop the pending output (JS calls this after copying it).
export fn snipetype_clear_output() void {
    if (web_app) |*wa| wa.ansi.clearBuffer();
}

// ============================================================================
// Exported API: Arcade pixel layer
// ============================================================================

/// Pointer to the RGBA8 pixel buffer (`w * h * 4` bytes), 0 when inactive.
export fn snipetype_get_fx_ptr() usize {
    const fx = fx_layer orelse return 0;
    return @intFromPtr(fx.pixels.ptr);
}

/// Pixel buffer width (0 when inactive).
export fn snipetype_get_fx_width() u32 {
    const fx = fx_layer orelse return 0;
    return fx.w;
}

/// Pixel buffer height (0 when inactive).
export fn snipetype_get_fx_height() u32 {
    const fx = fx_layer orelse return 0;
    return fx.h;
}

/// 1 while arcade mode renders pixels (JS then blits them), else 0.
export fn snipetype_fx_active() u32 {
    const fx = fx_layer orelse return 0;
    // u64: w*h*4 can overflow wasm32's usize for bogus sizes.
    const ok = fx.w > 0 and fx.h > 0 and fx.pixels.len >= @as(u64, fx.w) * fx.h * 4;
    return @intFromBool(ok);
}

// ============================================================================
// Exported API: Sound effects
// ============================================================================

/// Pointer to `snipetype_get_sfx_len()` 12-byte `SfxRecord`s.
export fn snipetype_get_sfx_ptr() usize {
    return @intFromPtr(&sfx_buf);
}

/// Number of queued sound records.
export fn snipetype_get_sfx_len() u32 {
    return sfx_len;
}

/// Drop queued sound records (JS calls this after playing them).
export fn snipetype_clear_sfx() void {
    sfx_len = 0;
}

// ============================================================================
// Internal Implementation
// ============================================================================

fn tickImpl(wa: *WebApp) void {
    // Process all pending input (kitty CSI u key events from the host)
    while (wa.input.readEvent()) |ev| {
        _ = wa.app.handleEvent(ev, true);
    }

    // Update state (check time limit, arcade sim, etc.)
    _ = wa.app.update();

    // Render if needed: one synchronized frame per tick, appended to the
    // output the host drains after this call.
    const now = time.milliTimestamp();
    if (wa.app.shouldRender(now)) {
        var r = wa.ansi.renderer();
        if (wa.app.isArcade()) {
            // The presenter emits its own synchronized text-layer frame.
            wa.app.render(r);
            wa.cursor_style = .hidden;
            wa.caret_visible = false;
            wa.ansi.hideCursor();
            wa.was_arcade = true;
        } else {
            if (wa.diff) |*d| {
                // Back from arcade: the screen holds the pixel frame's cells.
                if (wa.was_arcade) d.invalidate();
                r = d.renderer();
            }
            wa.was_arcade = false;
            wa.ansi.beginSync();
            wa.app.render(r);

            wa.cursor_style = wa.app.cursorStyle();
            if (wa.cursor_style != .hidden) {
                // Position the emulator's cursor at the typing position (like
                // the native main loop does) and make it visible.
                const pos = wa.app.getCursorPos(wa.cols, wa.rows);
                r.moveTo(@min(pos.x, wa.cols -| 1), @min(pos.y, wa.rows -| 1));
                if (!pos.visible) wa.cursor_style = .hidden;
            }
            // The diff renderer emits the cursor move with its next diff.
            if (wa.diff) |*d| d.emit();
            // Smooth caret: the host draws a bar at this cell; the
            // emulator's cursor stays hidden (vim and arcade keep theirs).
            wa.caret_visible = smooth_caret and wa.cursor_style == .bar and !wa.app.test_state.isVim();
            if (wa.caret_visible) {
                const pos = wa.app.getCursorPos(wa.cols, wa.rows);
                wa.caret_x = @min(pos.x, wa.cols -| 1);
                wa.caret_y = @min(pos.y, wa.rows -| 1);
            }
            if (wa.cursor_style == .hidden or wa.caret_visible) {
                wa.ansi.hideCursor();
            } else {
                wa.ansi.setCursorShape(switch (wa.cursor_style) {
                    .block => .block,
                    .underline => .underline,
                    else => .bar,
                });
                wa.ansi.showCursor();
            }
            wa.ansi.endSync();
        }
    }

    // Arcade pixels for the host's fx canvas (frozen under the settings
    // overlay; null outside arcade).
    if (wa.app.arcadeSurface()) |s| {
        fx_layer = .{ .pixels = std.mem.sliceAsBytes(s.pixels), .w = s.w, .h = s.h };
    } else {
        fx_layer = null;
    }

    // Sounds from this frame's game events.
    for (wa.app.sfx()) |sfx| queueSfx(sfx.kind, sfx.pan, sfx.intensity);
    wa.app.clearSfx();
}
