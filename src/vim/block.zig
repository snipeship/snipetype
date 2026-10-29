//! Visual block mode (Ctrl+V): the rectangle of display columns between
//! the anchor and the cursor, and the commands that act on it (d c y p P
//! r I A ~ u U > <), ported from Vim's ops.c block_prep/op_insert. A tab
//! that straddles a block edge is split into spaces first, as in Vim.

const std = @import("std");
const editor_mod = @import("editor.zig");
const VimEditor = editor_mod.VimEditor;
const Pos = editor_mod.Pos;
const Op = editor_mod.Op;
const VimKey = editor_mod.VimKey;
const vcol = @import("vcol.zig");
const classify = @import("classify.zig");

/// Rows top..bot and display columns left..right (inclusive).
pub const Rect = struct {
    top: usize,
    bot: usize,
    left: usize,
    right: usize,
    /// `$`: every row extends to its line end.
    to_eol: bool,

    pub fn rows(self: Rect) usize {
        return self.bot - self.top + 1;
    }

    pub fn cols(self: Rect) usize {
        return self.right - self.left + 1;
    }
};

/// What Esc does with the text typed after `I`, `A` or `c` on a block.
pub const InsertKind = enum { insert, append, append_eol };

pub const BlockInsert = struct {
    rect: Rect,
    kind: InsertKind,
    /// Display column the text goes to on the other rows.
    vc: usize,
    /// Top row: where the insert started and its length then.
    col: usize,
    line_len: usize,
    /// `c`: Esc leaves the cursor at the end of the text, as for a plain
    /// insert (I and A go back to the block's corner).
    change: bool = false,
};

pub fn rect(ed: *const VimEditor) Rect {
    const ts = ed.opts.tabstop;
    const a = ed.vis_anchor;
    const c = ed.cursor;
    const la = ed.buffer.getLine(a.row);
    const lc = ed.buffer.getLine(c.row);
    return .{
        .top = @min(a.row, c.row),
        .bot = @max(a.row, c.row),
        .left = @min(vcol.displayCol(la, a.col, ts), vcol.displayCol(lc, c.col, ts)),
        .right = @max(vcol.displayEnd(la, a.col, ts), vcol.displayEnd(lc, c.col, ts)),
        .to_eol = ed.curswant == editor_mod.max_col,
    };
}

/// Bytes [a, b) of a line inside the block. `short`: the line ends before
/// the block starts (Vim's is_short; I and c skip such lines).
const Span = struct { a: usize, b: usize, short: bool };

fn span(line: []const u8, r: Rect, ts: u8) Span {
    const w = vcol.width(line, ts);
    if (w <= r.left) return .{ .a = line.len, .b = line.len, .short = w < r.left };
    const a = vcol.byteAtOrEnd(line, r.left, ts);
    const b = if (r.to_eol) line.len else @min(vcol.byteAtOrEnd(line, r.right, ts) + 1, line.len);
    return .{ .a = a, .b = b, .short = false };
}

/// Replaces a tab that covers display column `vc` but does not start
/// there (`at_start`) or does not end there (`!at_start`) with spaces.
fn splitTab(ed: *VimEditor, row: usize, vc: usize, at_start: bool) !void {
    const ts = ed.opts.tabstop;
    const line = ed.buffer.getLine(row);
    const i = vcol.byteAtOrEnd(line, vc, ts);
    if (i >= line.len or line[i] != '\t') return;
    const s = vcol.displayCol(line, i, ts);
    const e = vcol.displayEnd(line, i, ts);
    if (if (at_start) s == vc else e == vc) return;
    var tmp: [256]u8 = undefined;
    const n = @min(e - s + 1, tmp.len);
    @memset(tmp[0..n], ' ');
    try ed.buffer.replaceInLine(row, i, i + 1, tmp[0..n]);
}

/// Splits the tabs on both block edges of every row.
fn splitEdges(ed: *VimEditor, r: Rect) !void {
    var row = r.top;
    while (row <= r.bot and row <= ed.buffer.lastRow()) : (row += 1) {
        try splitTab(ed, row, r.left, true);
        if (!r.to_eol) try splitTab(ed, row, r.right, false);
    }
}

/// Text of the block, one row per line (partial tabs become spaces).
fn blockText(ed: *const VimEditor, r: Rect, out: *std.ArrayList(u8)) !usize {
    const ts = ed.opts.tabstop;
    var width: usize = 0;
    var row = r.top;
    while (row <= r.bot) : (row += 1) {
        if (row > r.top) try out.append(ed.allocator, '\n');
        const line = ed.buffer.getLine(row);
        const start = out.items.len;
        var vc: usize = 0;
        for (line) |c| {
            const w = vcol.charWidth(c, vc, ts);
            const e = vc + w - 1;
            defer vc += w;
            if (e < r.left) continue;
            if (!r.to_eol and vc > r.right) break;
            if (c == '\t' and (vc < r.left or (!r.to_eol and e > r.right))) {
                const lo = @max(vc, r.left);
                const hi = if (r.to_eol) e else @min(e, r.right);
                try out.appendNTimes(ed.allocator, ' ', hi - lo + 1);
            } else try out.append(ed.allocator, c);
        }
        width = @max(width, out.items.len - start);
    }
    return if (r.to_eol) width else r.cols();
}

fn topLeft(ed: *const VimEditor, r: Rect) Pos {
    const line = ed.buffer.getLine(r.top);
    return .{ .row = r.top, .col = vcol.byteAtOrEnd(line, r.left, ed.opts.tabstop) };
}

/// Records a block change for `.`: the same-sized block from the cursor.
fn recordDot(ed: *VimEditor, r: Rect, keys: []const VimKey) !void {
    ed.dot_build.clearRetainingCapacity();
    try ed.dot_build.append(ed.allocator, .{ .ctrl = 'v' });
    if (r.rows() > 1) try ed.appendCountKey(r.rows() - 1, 'j');
    if (r.to_eol) {
        try ed.dot_build.append(ed.allocator, .{ .char = '$' });
    } else if (r.cols() > 1) try ed.appendCountKey(r.cols() - 1, 'l');
    try ed.dot_build.appendSlice(ed.allocator, keys);
    ed.dot_build_count = 0;
    ed.dot_build_reg = ed.pend.reg;
}

fn opKey(o: Op) u8 {
    return switch (o) {
        .delete => 'd',
        .change => 'c',
        .yank => 'y',
        .indent => '>',
        .outdent => '<',
        .lower => 'u',
        .upper => 'U',
        .toggle => '~',
        .format => 'q',
        .reindent => '=',
        .format_keep => 'w',
    };
}

/// Vim saves a "U" line only for a one-line change: a block over several
/// rows leaves it as it was. Returns the old hold to restore.
fn holdU(ed: *VimEditor, rows: usize) bool {
    const old = ed.buffer.u_hold;
    if (rows > 1) ed.buffer.u_hold = true;
    return old;
}

/// An operator on the block (`d c y > < ~ u U`; a count shifts N times).
pub fn op(ed: *VimEditor, o: Op) !void {
    const r = rect(ed);
    const held = holdU(ed, r.rows());
    defer ed.buffer.u_hold = held;
    // Vim's operators start at the block's top-left corner ("U" puts the
    // cursor back there).
    ed.buffer.u_cursor = topLeft(ed, r);
    const times: usize = @max(ed.pend.count0(), 1);
    ed.markUndoPos(topLeft(ed, r));
    if (o.isChange()) {
        var ks: [14]VimKey = undefined;
        var n: usize = 0;
        if (times > 1) {
            var tmp: [12]u8 = undefined;
            for (std.fmt.bufPrint(&tmp, "{d}", .{times}) catch "") |d| {
                ks[n] = .{ .char = d };
                n += 1;
            }
        }
        if (o == .format) {
            ks[n] = .{ .char = 'g' };
            n += 1;
        }
        ks[n] = .{ .char = opKey(o) };
        try recordDot(ed, r, ks[0 .. n + 1]);
    }
    ed.exitVisual();
    switch (o) {
        .yank => {
            try yankBlock(ed, r, true);
            if (r.rows() > 2) ed.statusFmt("block of {d} lines yanked{s}{s}", .{ r.rows(), if (ed.pend.reg != null) " into \"" else "", if (ed.pend.reg) |c| &[1]u8{c} else "" });
        },
        .delete => try deleteBlock(ed, r),
        .change => {
            try deleteBlock(ed, r);
            try startInsert(ed, r, .insert, r.left, 0);
            ed.ins.block.?.change = true;
        },
        .indent, .outdent => try shift(ed, r, o == .indent, times),
        .lower, .upper, .toggle => try mapCase(ed, r, o),
        // gq and = work on the block's lines.
        .format, .format_keep, .reindent => unreachable,
    }
    if (ed.mode == .normal) {
        ed.cursor = ed.buffer.clampPos(topLeft(ed, r));
        ed.clampNormal();
        ed.setWant();
    }
    if (o.isChange()) try ed.commitVisualDot();
    ed.pend = .{};
    ed.finishCtrlO();
}

fn yankBlock(ed: *VimEditor, r: Rect, is_yank: bool) !void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(ed.allocator);
    const width = try blockText(ed, r, &text);
    if (is_yank) {
        try ed.regs.yankKind(ed.pend.reg, text.items, .block, width);
    } else try ed.regs.deleteKind(ed.pend.reg, text.items, .block, width, false);
}

fn deleteBlock(ed: *VimEditor, r: Rect) !void {
    try yankBlock(ed, r, false);
    try splitEdges(ed, r);
    var row = r.top;
    while (row <= r.bot) : (row += 1) {
        const sp = span(ed.buffer.getLine(row), r, ed.opts.tabstop);
        if (sp.b > sp.a) try ed.buffer.deleteRange(.{ .row = row, .col = sp.a }, .{ .row = row, .col = sp.b });
    }
}

/// Insert mode for `I`/`A`/`c`; Esc copies the typed text to the other
/// rows (`finishInsert`).
fn startInsert(ed: *VimEditor, r: Rect, kind: InsertKind, vc: usize, count: u32) !void {
    const ts = ed.opts.tabstop;
    var col: usize = undefined;
    switch (kind) {
        .append_eol => col = ed.buffer.lineLen(r.top),
        .insert, .append => {
            if (kind == .append) try pad(ed, r.top, vc);
            try splitTab(ed, r.top, vc, true);
            col = vcol.byteAtOrEnd(ed.buffer.getLine(r.top), vc, ts);
        },
    }
    ed.cursor = .{ .row = r.top, .col = col };
    try ed.beginInsert(count, false);
    ed.ins.block = .{ .rect = r, .kind = kind, .vc = vc, .col = col, .line_len = ed.buffer.lineLen(r.top) };
}

/// Pads a row with spaces up to display column `vc`.
fn pad(ed: *VimEditor, row: usize, vc: usize) !void {
    const w = vcol.width(ed.buffer.getLine(row), ed.opts.tabstop);
    if (w >= vc) return;
    var tmp: [256]u8 = undefined;
    const n = @min(vc - w, tmp.len);
    @memset(tmp[0..n], ' ');
    _ = try ed.buffer.insertText(.{ .row = row, .col = ed.buffer.lineLen(row) }, tmp[0..n]);
}

/// `I` / `A` on a block (`$A` appends at every line end); `3I` types the
/// text three times on every row.
pub fn insert(ed: *VimEditor, append: bool) !void {
    const r = rect(ed);
    const count = ed.pend.count0();
    const key: u8 = if (append) 'A' else 'I';
    try recordDot(ed, r, &.{});
    if (count > 1) try ed.appendCountKey(count, key) else try ed.dot_build.append(ed.allocator, .{ .char = key });
    ed.exitVisual();
    ed.pend = .{};
    ed.markUndoPos(topLeft(ed, r));
    if (!append) {
        try startInsert(ed, r, .insert, r.left, count);
    } else if (r.to_eol) {
        try startInsert(ed, r, .append_eol, 0, count);
    } else try startInsert(ed, r, .append, r.right + 1, count);
    try ed.commitVisualDot();
}

/// Esc after a block insert: the text typed on the top row goes to the
/// same display column of every other row. False when there is nothing to
/// copy (a line break was typed, or the cursor left the row) or the
/// cursor should step left as after any insert.
pub fn finishInsert(ed: *VimEditor, bi: BlockInsert) !bool {
    const r = bi.rect;
    const ts = ed.opts.tabstop;
    if (ed.cursor.row != r.top) return false;
    const len = ed.buffer.lineLen(r.top);
    if (len < bi.line_len) return false;
    const n = len - bi.line_len;
    if (bi.col + n > len) return false;
    const text = try ed.allocator.dupe(u8, ed.buffer.getLine(r.top)[bi.col..][0..n]);
    defer ed.allocator.free(text);
    // The text goes to the rows below the top one: for `I`/`A` a single
    // such row becomes the "U" line, `c` never sets one (as in Vim).
    const held = holdU(ed, if (bi.change) 2 else r.rows() - 1);
    defer ed.buffer.u_hold = held;
    var row = r.top + 1;
    while (n > 0 and row <= r.bot and row <= ed.buffer.lastRow()) : (row += 1) {
        const w = vcol.width(ed.buffer.getLine(row), ts);
        const col = switch (bi.kind) {
            .append_eol => ed.buffer.lineLen(row),
            .insert, .append => blk: {
                if (bi.kind == .insert and w < bi.vc) continue;
                try pad(ed, row, bi.vc);
                try splitTab(ed, row, bi.vc, true);
                break :blk vcol.byteAtOrEnd(ed.buffer.getLine(row), bi.vc, ts);
            },
        };
        _ = try ed.buffer.insertText(.{ .row = row, .col = col }, text);
    }
    if (bi.change) return false;
    ed.cursor = topLeft(ed, r);
    return true;
}

/// `r{c}`: every cell of the block becomes `c` (`r<CR>` splits each row).
pub fn replace(ed: *VimEditor, c: u8) !void {
    const r = rect(ed);
    try recordDot(ed, r, &.{ .{ .char = 'r' }, if (c == '\r') .enter else .{ .char = c } });
    ed.exitVisual();
    ed.markUndoPos(topLeft(ed, r));
    const held = holdU(ed, r.rows());
    defer ed.buffer.u_hold = held;
    try splitEdges(ed, r);
    const ts = ed.opts.tabstop;
    var row = r.bot + 1;
    while (row > r.top) {
        row -= 1;
        const line = ed.buffer.getLine(row);
        const sp = span(line, r, ts);
        if (sp.b <= sp.a) continue;
        if (c == '\r') {
            try ed.buffer.deleteRange(.{ .row = row, .col = sp.a }, .{ .row = row, .col = sp.b });
            _ = try ed.buffer.insertText(.{ .row = row, .col = sp.a }, "\n");
            continue;
        }
        const cells = vcol.displayCol(line, sp.b, ts) - vcol.displayCol(line, sp.a, ts);
        const tmp = try ed.allocator.alloc(u8, cells);
        defer ed.allocator.free(tmp);
        @memset(tmp, c);
        try ed.buffer.replaceInLine(row, sp.a, sp.b, tmp);
    }
    ed.cursor = if (c == '\r') .{ .row = r.top } else topLeft(ed, r);
    ed.clampNormal();
    ed.setWant();
    try ed.commitVisualDot();
    ed.pend = .{};
}

fn mapCase(ed: *VimEditor, r: Rect, o: Op) !void {
    var row = r.top;
    while (row <= r.bot) : (row += 1) {
        const line = ed.buffer.getLine(row);
        const sp = span(line, r, ed.opts.tabstop);
        if (sp.b <= sp.a) continue;
        const tmp = try ed.allocator.dupe(u8, line[sp.a..sp.b]);
        defer ed.allocator.free(tmp);
        for (tmp) |*ch| ch.* = VimEditor.caseOp(o, ch.*);
        if (!std.mem.eql(u8, tmp, line[sp.a..sp.b])) try ed.buffer.replaceInLine(row, sp.a, sp.b, tmp);
    }
    if (r.rows() > 2) ed.statusFmt("{d} lines changed", .{r.rows()});
}

/// `>` inserts `times` shiftwidths at the block's left edge; `<` removes
/// up to that much white space starting there.
fn shift(ed: *VimEditor, r: Rect, right: bool, times: usize) !void {
    const ts = ed.opts.tabstop;
    const total = @as(usize, ed.opts.shiftwidth) * times;
    var tmp: [512]u8 = undefined;
    var row = r.top;
    while (row <= r.bot) : (row += 1) {
        try splitTab(ed, row, r.left, true);
        const line = ed.buffer.getLine(row);
        const sp = span(line, r, ts);
        if (sp.short or (sp.a >= line.len and !right)) continue;
        if (line.len == 0) continue;
        if (right) {
            const n = @min(total, tmp.len);
            @memset(tmp[0..n], ' ');
            try ed.buffer.replaceInLine(row, sp.a, sp.a, tmp[0..n]);
            continue;
        }
        var e = sp.a;
        while (e < line.len and classify.isBlank(line[e])) e += 1;
        if (e == sp.a) continue;
        const ws = vcol.displayCol(line, e, ts) - vcol.displayCol(line, sp.a, ts);
        const keep = @min(ws - @min(ws, total), tmp.len);
        @memset(tmp[0..keep], ' ');
        try ed.buffer.replaceInLine(row, sp.a, e, tmp[0..keep]);
    }
    if (r.rows() > 2) ed.statusFmt("{d} lines {s}ed {d} time{s}", .{ r.rows(), if (right) ">" else "<", times, if (times == 1) "" else "s" });
}

/// Puts a block register at display column `vc` of `row` and the rows
/// below (adding lines at the end of the buffer), `count` times side by
/// side. Rows are padded to the block width when text follows them.
pub fn putRows(ed: *VimEditor, text: []const u8, width: usize, row0: usize, vc: usize, count: usize) !void {
    const ts = ed.opts.tabstop;
    // Vim saves the line above and below too: never a "U" line.
    const held = holdU(ed, 2);
    defer ed.buffer.u_hold = held;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(ed.allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var row = row0;
    while (it.next()) |piece| : (row += 1) {
        if (row > ed.buffer.lastRow()) try ed.buffer.insertLines(ed.buffer.lineCount(), "");
        const w = vcol.width(ed.buffer.getLine(row), ts);
        const short = w <= vc;
        try pad(ed, row, vc);
        try splitTab(ed, row, vc, true);
        const col = vcol.byteAtOrEnd(ed.buffer.getLine(row), vc, ts);
        out.clearRetainingCapacity();
        const spaces = width -| vcol.width(piece, ts);
        var j: usize = 0;
        while (j < count) : (j += 1) {
            try out.appendSlice(ed.allocator, piece);
            if (j + 1 < count or !short) try out.appendNTimes(ed.allocator, ' ', spaces);
        }
        _ = try ed.buffer.insertText(.{ .row = row, .col = col }, out.items);
    }
}

/// Normal-mode `p`/`P` of a block register.
pub fn put(ed: *VimEditor, text: []const u8, width: usize, count: usize, before: bool) !void {
    const ts = ed.opts.tabstop;
    const line = ed.buffer.getLine(ed.cursor.row);
    const vc = if (before or line.len == 0)
        vcol.displayCol(line, ed.cursor.col, ts)
    else
        vcol.displayEnd(line, ed.cursor.col, ts) + 1;
    try putRows(ed, text, width, ed.cursor.row, vc, count);
    ed.cursor = .{ .row = ed.cursor.row, .col = vcol.byteAtOrEnd(ed.buffer.getLine(ed.cursor.row), vc, ts) };
    ed.clampNormal();
    ed.setWant();
}

/// `p`/`P` over a block selection: the block is deleted (into the unnamed
/// register for `p`), then a block register is put in its place, a
/// one-line charwise register on every row, a linewise one below it.
pub fn visualPut(ed: *VimEditor, keep_reg: bool) !void {
    const reg = ed.pend.reg;
    const src = ed.regs.get(reg) orelse return ed.fail();
    const text = try ed.allocator.dupe(u8, src.slice());
    defer ed.allocator.free(text);
    const kind = src.kind;
    const width = src.width;
    const r = rect(ed);
    try recordDot(ed, r, &.{.{ .char = if (keep_reg) 'P' else 'p' }});
    ed.exitVisual();
    ed.markUndoPos(topLeft(ed, r));
    const saved = ed.pend.reg;
    ed.pend.reg = null;
    if (keep_reg) {
        try splitEdges(ed, r);
        var row = r.top;
        while (row <= r.bot) : (row += 1) {
            const sp = span(ed.buffer.getLine(row), r, ed.opts.tabstop);
            if (sp.b > sp.a) try ed.buffer.deleteRange(.{ .row = row, .col = sp.a }, .{ .row = row, .col = sp.b });
        }
    } else try deleteBlock(ed, r);
    ed.pend.reg = saved;
    const ts = ed.opts.tabstop;
    switch (kind) {
        .line => {
            try ed.buffer.insertLines(r.bot + 1, text);
            ed.gotoLine(r.bot + 1);
        },
        .block => {
            try putRows(ed, text, width, r.top, r.left, 1);
            ed.cursor = topLeft(ed, r);
        },
        .char => {
            if (std.mem.indexOfScalar(u8, text, '\n') == null) {
                var row = r.top;
                while (row <= r.bot) : (row += 1) {
                    try pad(ed, row, r.left);
                    const col = vcol.byteAtOrEnd(ed.buffer.getLine(row), r.left, ts);
                    _ = try ed.buffer.insertText(.{ .row = row, .col = col }, text);
                }
                const tl = topLeft(ed, r);
                ed.cursor = .{ .row = tl.row, .col = tl.col + text.len -| 1 };
            } else {
                _ = try ed.buffer.insertText(topLeft(ed, r), text);
                ed.cursor = topLeft(ed, r);
            }
        },
    }
    ed.clampNormal();
    ed.setWant();
    try ed.commitVisualDot();
    ed.pend = .{};
}

/// `O`: the cursor goes to the other end of its row.
pub fn otherEnd(ed: *VimEditor) void {
    const ts = ed.opts.tabstop;
    const a = ed.vis_anchor;
    const c = ed.cursor;
    const avc = vcol.displayCol(ed.buffer.getLine(a.row), a.col, ts);
    const cvc = vcol.displayCol(ed.buffer.getLine(c.row), c.col, ts);
    ed.cursor.col = vcol.byteAtOrEnd(ed.buffer.getLine(c.row), avc, ts);
    ed.vis_anchor.col = vcol.byteAtOrEnd(ed.buffer.getLine(a.row), cvc, ts);
    ed.setWant();
}

/// Whether byte `col` of `row` is inside the block (in display columns).
pub fn contains(ed: *const VimEditor, r: Rect, row: usize, col: usize) bool {
    if (row < r.top or row > r.bot) return false;
    const line = ed.buffer.getLine(row);
    if (col >= line.len) return false;
    const ts = ed.opts.tabstop;
    const s = vcol.displayCol(line, col, ts);
    const e = vcol.displayEnd(line, col, ts);
    return e >= r.left and (r.to_eol or s <= r.right);
}

/// Corners for `VimEditor.selection()`, in buffer columns.
pub fn corners(ed: *const VimEditor, r: Rect) struct { start: Pos, end: Pos } {
    const ts = ed.opts.tabstop;
    const bl = ed.buffer.getLine(r.bot);
    const end_col = if (r.to_eol) bl.len -| 1 else @min(vcol.byteAtOrEnd(bl, r.right, ts), bl.len -| 1);
    return .{ .start = topLeft(ed, r), .end = .{ .row = r.bot, .col = end_col } };
}
