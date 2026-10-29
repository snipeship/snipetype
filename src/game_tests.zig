//! Test entry for the arcade simulation (src/game/). Lives at src/ level so
//! the game modules may import ../platform and ../core.
//!
//! Run: `zig test src/game_tests.zig`
//! wasm check: `zig build-obj -target wasm32-freestanding -O ReleaseSmall -fno-emit-bin src/game_tests.zig`

pub const model = @import("game/model.zig");
pub const levels = @import("game/levels.zig");
pub const layout = @import("game/layout.zig");
pub const scoring = @import("game/scoring.zig");
pub const quotes = @import("game/quotes.zig");
pub const words = @import("game/words.zig");
pub const arcade = @import("game/arcade.zig");
pub const scene = @import("game/scene.zig");

test {
    _ = model;
    _ = levels;
    _ = layout;
    _ = scoring;
    _ = quotes;
    _ = words;
    _ = arcade;
    _ = scene;
}

comptime {
    _ = &arcade.Arcade.init;
    _ = &arcade.Arcade.deinit;
    _ = &arcade.Arcade.reset;
    _ = &arcade.Arcade.handleKey;
    _ = &arcade.Arcade.update;
    _ = &arcade.Arcade.caps;
    _ = &arcade.Arcade.events;
    _ = &arcade.Arcade.rank;
    _ = &arcade.Arcade.heardLine;
    _ = &arcade.Arcade.setPlayWidth;
    _ = &arcade.Arcade.selectedGame;
    _ = &layout.layout;
}
