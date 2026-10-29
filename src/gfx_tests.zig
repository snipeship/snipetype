//! Test entry for the presenters in src/gfx/ (see DESIGN.md "Testing your
//! module standalone"): `zig test src/gfx_tests.zig`.

const std = @import("std");

pub const presenter = @import("gfx/presenter.zig");
pub const ansi = @import("gfx/ansi.zig");
pub const textlayer = @import("gfx/textlayer.zig");
pub const halfblock = @import("gfx/halfblock.zig");
pub const kitty = @import("gfx/kitty.zig");
pub const media = @import("gfx/media.zig");
pub const bench = @import("gfx/bench.zig");

comptime {
    std.testing.refAllDecls(presenter);
    std.testing.refAllDecls(presenter.Presenter);
    std.testing.refAllDecls(kitty);
    std.testing.refAllDecls(kitty.Compressor);
    std.testing.refAllDecls(media);
    std.testing.refAllDecls(halfblock);
    std.testing.refAllDecls(textlayer);
    std.testing.refAllDecls(ansi);
}

test {
    _ = presenter;
    _ = ansi;
    _ = textlayer;
    _ = halfblock;
    _ = kitty;
    _ = media;
    _ = bench;
}
