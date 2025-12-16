//! ONE - Core library exports
//! Platform-specific implementations are selected at compile time.

const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;

// Core modules (platform-independent)
const types = @import("core/types.zig");
const rng = @import("core/rng.zig");
const vim_cursor = @import("vim/cursor.zig");
const vim_mode = @import("vim/mode.zig");
const vim_operator = @import("vim/operator.zig");
const vim_buffer = @import("vim/buffer.zig");
const vim_editor = @import("vim/editor.zig");
const typing_test = @import("core/typing_test.zig");

// UI modules
pub const ansi = @import("ui/ansi.zig");
pub const render = @import("ui/render.zig");
pub const theme = @import("ui/theme.zig");
pub const settings = @import("ui/settings.zig");

// Platform modules (exposed for web entry point)
pub const time = @import("platform/time.zig");

// Platform-specific modules (selected at compile time)
const render_buffer = if (is_wasm)
    @import("platform/render_buffer_web.zig")
else
    @import("platform/render_buffer.zig");

const terminal = if (is_wasm)
    @import("platform/terminal_web.zig")
else
    @import("platform/terminal.zig");

const input = if (is_wasm)
    @import("platform/input_web.zig")
else
    @import("platform/input.zig");

// Public exports
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
