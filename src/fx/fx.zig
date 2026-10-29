//! Pixel effects engine namespace: one import for scenes.
//!
//!   const fx = @import("../fx/fx.zig");
//!   var engine = try fx.Fx.init(allocator);
//!   engine.update(dt); engine.drawUnder(s); ...; engine.drawOver(s); engine.post(s);
//!
//! Everything here is pure computation (wasm32-freestanding safe) and does
//! not allocate per frame.

pub const surface = @import("surface.zig");
pub const color = @import("color.zig");
pub const rng = @import("rng.zig");
pub const canvas = @import("canvas.zig");
pub const post = @import("post.zig");
pub const font = @import("font.zig");
pub const particles = @import("particles.zig");
pub const effects = @import("effects.zig");
pub const popup = @import("popup.zig");

pub const Surface = surface.Surface;
pub const Px = surface.Px;
pub const Rgb = color.Rgb;
pub const Blend = canvas.Blend;
pub const Fx = effects.Fx;
pub const CapLook = effects.CapLook;
pub const Spawn = effects.Spawn;
pub const BloomQuality = post.BloomQuality;
pub const Popup = popup.Popup;
pub const PopupStyle = popup.Style;
