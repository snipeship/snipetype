//! Test entry for the web host's Zig side (run: `zig test src/web_tests.zig`).
//! src/web/main.zig itself is a wasm32 executable root with JS imports, so
//! only the platform pieces it relies on are tested natively here.

test {
    _ = @import("platform/ansi_renderer.zig");
    // Classic web frames are diffed before ghostty-web parses them.
    _ = @import("platform/diff_renderer.zig");
}
