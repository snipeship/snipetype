//! ONE - Core library exports

const types = @import("core/types.zig");
const rng = @import("core/rng.zig");
const render_buffer = @import("platform/render_buffer.zig");
const terminal = @import("platform/terminal.zig");
const input = @import("platform/input.zig");
const vim_cursor = @import("vim/cursor.zig");
const vim_mode = @import("vim/mode.zig");
const vim_operator = @import("vim/operator.zig");
const vim_buffer = @import("vim/buffer.zig");
const vim_editor = @import("vim/editor.zig");
const typing_test = @import("core/typing_test.zig");

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
