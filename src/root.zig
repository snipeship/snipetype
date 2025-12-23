//! ONE - Core library exports
//! Platform-specific implementations are selected at compile time within each module.

// Core modules (platform-independent)
const types = @import("core/types.zig");
const rng = @import("core/rng.zig");
const app = @import("core/app.zig");
const vim_cursor = @import("vim/cursor.zig");
const vim_mode = @import("vim/mode.zig");
const vim_operator = @import("vim/operator.zig");
const vim_buffer = @import("vim/buffer.zig");
const vim_editor = @import("vim/editor.zig");
const typing_test = @import("core/typing_test.zig");

// Platform modules (compile-time platform selection is internal)
const render_buffer = @import("platform/render_buffer.zig");
const terminal = @import("platform/terminal.zig");
const input = @import("platform/input.zig");

// UI modules
pub const ansi = @import("ui/ansi.zig");
pub const render = @import("ui/render.zig");
pub const theme = @import("ui/theme.zig");
pub const settings = @import("ui/settings.zig");

// Platform utilities
pub const time = @import("platform/time.zig");
pub const constants = @import("core/constants.zig");

// Public type exports
pub const Mode = types.Mode;
pub const Lang = types.Lang;
pub const Config = types.Config;

pub const Rng = rng.Rng;

pub const RenderBuffer = render_buffer.RenderBuffer;
pub const Terminal = terminal.Terminal;
pub const Key = input.Key;
pub const Input = input.Input;

pub const Cursor = vim_cursor.Cursor;
pub const VimMode = vim_mode.VimMode;
pub const Operator = vim_operator.Operator;
pub const Buffer = vim_buffer.Buffer;
pub const VimEditor = vim_editor.VimEditor;

pub const TestState = typing_test.TestState;
pub const TypingTest = typing_test.TypingTest;

pub const App = app.App;
pub const KeyResult = app.KeyResult;
