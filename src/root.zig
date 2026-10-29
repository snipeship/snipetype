//! ONE - Core library exports
//! Platform-specific implementations are selected at compile time within each module.

// Core modules (platform-independent)
const types = @import("core/types.zig");
const rng = @import("core/rng.zig");
const app = @import("core/app.zig");
const vim_cursor = @import("vim/cursor.zig");
const vim_buffer = @import("vim/buffer.zig");
const vim_editor = @import("vim/editor.zig");
const typing_test = @import("core/typing_test.zig");

// Platform modules (compile-time platform selection is internal)
const render_buffer = @import("platform/render_buffer.zig");
const terminal = @import("platform/terminal.zig");
const input = @import("platform/input.zig");
const renderer = @import("platform/renderer.zig");
const ansi_renderer = @import("platform/ansi_renderer.zig");
const cell_renderer = @import("platform/cell_renderer.zig");

// UI modules
pub const ansi = @import("ui/ansi.zig");
pub const render = @import("ui/render.zig");
pub const theme = @import("ui/theme.zig");
pub const settings = @import("ui/settings.zig");

// Platform utilities
pub const time = @import("platform/time.zig");
pub const constants = @import("core/constants.zig");
pub const keys = @import("platform/keys.zig");
pub const caps = @import("platform/caps.zig");
/// Native config/history files (std.Io; not for wasm).
pub const store_native = @import("platform/store_native.zig");
/// History formats, the run log and `snipetype stats` output (pure).
pub const history = @import("core/history.zig");
pub const DiffRenderer = @import("platform/diff_renderer.zig").DiffRenderer;
pub const keyboard_flags = terminal.keyboard_flags;
pub const CellPx = terminal.CellPx;

// Arcade: pixel effects, presenters, game
pub const fx = @import("fx/fx.zig");
pub const gfx = @import("gfx/presenter.zig");
pub const game = struct {
    pub const arcade = @import("game/arcade.zig");
    pub const model = @import("game/model.zig");
    pub const layout = @import("game/layout.zig");
    pub const scene = @import("game/scene.zig");
};
pub const Arcade = game.arcade.Arcade;
pub const Scene = game.scene.Scene;
pub const Surface = fx.Surface;
pub const Presenter = gfx.Presenter;

// Public type exports
pub const Mode = types.Mode;
pub const Lang = types.Lang;
pub const Config = types.Config;
pub const WordTier = types.WordTier;
pub const VimKind = types.VimKind;
pub const ConfigOverrides = types.ConfigOverrides;
pub const CodeKeys = types.CodeKeys;
pub const CaretPace = types.CaretPace;
pub const StopOnError = types.StopOnError;
pub const Layout = types.Layout;
pub const Focus = types.Focus;
pub const parsePace = types.parsePace;
pub const MIN_WORDS = types.MIN_WORDS;
pub const MAX_WORDS = types.MAX_WORDS;
pub const Pace = types.Pace;
pub const Gfx = types.Gfx;
pub const paceFromString = types.paceFromString;

pub const Rng = rng.Rng;

pub const RenderBuffer = render_buffer.RenderBuffer;
pub const Terminal = terminal.Terminal;
pub const Key = input.Key;
pub const Input = input.Input;
pub const Renderer = renderer.Renderer;
pub const Cell = renderer.Cell;
pub const CellFlags = renderer.CellFlags;
pub const AnsiRenderer = ansi_renderer.AnsiRenderer;
pub const CellRenderer = cell_renderer.CellRenderer;

pub const Cursor = vim_cursor.Cursor;
pub const VimMode = vim_editor.Mode;
pub const VimKey = @import("vim/key.zig").VimKey;
pub const Buffer = vim_buffer.Buffer;
pub const VimEditor = vim_editor.VimEditor;

pub const TestState = typing_test.TestState;
pub const TypingTest = typing_test.TypingTest;

pub const App = app.App;
pub const KeyResult = app.KeyResult;
pub const GfxSetup = app.GfxSetup;
pub const Sfx = app.Sfx;
pub const SfxKind = app.SfxKind;

test {
    // Per-area suites (fx_tests.zig only here: on wasm it exports a smoke
    // function with a large static buffer that must stay out of the web
    // binary, and test blocks are never analyzed in non-test builds).
    _ = @import("platform_tests.zig");
    _ = @import("fx_tests.zig");
    _ = @import("gfx_tests.zig");
    _ = @import("game_tests.zig");
    _ = @import("web_tests.zig");
    _ = @import("ui_tests.zig");
    _ = @import("vim_tests.zig");
    _ = @import("core_tests.zig");
    _ = app;
    _ = types;
    _ = @import("core/keymap.zig");
    _ = store_native;
}
