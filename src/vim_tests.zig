//! Test entry point for the vim engine and drills (stream A).
//! `zig test src/vim_tests.zig` — lives at src/ so vim files can import
//! ../core and ../platform.

// Re-exported for tools that drive the engine directly.
pub const editor = @import("vim/editor.zig");
pub const drill = @import("vim/drill.zig");
pub const key = @import("vim/key.zig");

test {
    _ = @import("vim/key.zig");
    _ = @import("vim/editor.zig");
    _ = @import("vim/drill.zig");
    _ = @import("vim/tests.zig");
}
