//! The drill library, concatenated in lesson order.

const basics = @import("basics.zig");
const words = @import("words.zig");
const find = @import("find.zig");
const line = @import("line.zig");
const operators = @import("operators.zig");
const textobj = @import("textobj.zig");
const visual = @import("visual.zig");
const registers = @import("registers.zig");
const dot = @import("dot.zig");
const search = @import("search.zig");
const ex = @import("ex.zig");
const macros = @import("macros.zig");
const block = @import("block.zig");
const global = @import("global.zig");
const substitute = @import("substitute.zig");
const gn = @import("gn.zig");
const sentences = @import("sentences.zig");

pub const list = basics.list ++ words.list ++ find.list ++ line.list ++ operators.list ++ textobj.list ++ visual.list ++ registers.list ++ dot.list ++ search.list ++ ex.list ++ macros.list ++
    block.list ++ global.list ++ substitute.list ++ gn.list ++ sentences.list;
