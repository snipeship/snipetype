//! The vim engine facade. Every key goes through `feed`; a small parser
//! (count → "x register → operator → count → motion/object/char-arg) turns
//! keys into commands that act on the buffer. Dot repeat and macros replay
//! keys through the same parser, and undo snapshots the buffer once per
//! change group (a command, a whole insert, a macro or a dot repeat).

const std = @import("std");
const constants = @import("../core/constants.zig");
const buffer_mod = @import("buffer.zig");
const key_mod = @import("key.zig");
const classify = @import("classify.zig");
const motion = @import("motion.zig");
const textobj = @import("textobj.zig");
const search = @import("search.zig");
const ex = @import("ex.zig");
const vcol = @import("vcol.zig");
const jumps = @import("jumps.zig");
const block = @import("block.zig");
const sentence = @import("sentence.zig");
const tag = @import("tag.zig");
const format = @import("format.zig");
const LegacyKey = @import("../platform/keys.zig").Key;

pub const Buffer = buffer_mod.Buffer;
pub const Pos = @import("cursor.zig").Cursor;
pub const Mode = @import("mode.zig").Mode;
pub const VimKey = key_mod.VimKey;
pub const Notation = key_mod.Notation;
pub const Op = @import("operator.zig").Operator;
pub const Registers = @import("register.zig").Registers;
const History = @import("undo.zig").History;

pub const Options = struct {
    shiftwidth: u8 = 4,
    expandtab: bool = true,
    autoindent: bool = true,
    smartcase: bool = true,
    wrapscan: bool = true,
    /// Display width of a tab (`displayCol`, j/k, `|`, visual block).
    tabstop: u8 = 8,
    /// `gq` breaks lines longer than this.
    textwidth: u8 = 79,
};

/// :w :wq/:x :q :q! :e! :hint — the app decides what they do.
pub const ExCommand = enum { write, write_quit, quit, quit_force, restart, hint };

pub const FeedResult = struct {
    /// Buffer text changed.
    changed: bool = false,
    /// An ex command the app must act on.
    ex: ?ExCommand = null,
    /// Ctrl+C in NORMAL with nothing pending.
    interrupt: bool = false,
    /// Drill: key forbidden, not executed or counted.
    rejected: bool = false,
};

pub const EditStats = struct { keystrokes: u32 = 0, inserted: u32 = 0, undos: u32 = 0 };

/// Normalized, `end` inclusive. A charwise selection that includes the
/// line break of its last row (`v$`) has `end.col == lineLen(end.row)`.
/// For a block, start/end are the top-left and bottom-right corners in
/// buffer columns; `isInSelection` works in display columns (tabs), so
/// renderers only need `isInSelection`.
pub const Selection = struct {
    start: Pos,
    end: Pos,
    kind: enum { char, line, block },
    /// block: `$` was pressed; every row extends to its line end.
    to_eol: bool = false,
};

/// `curswant` after `$`: stick to the line end.
pub const max_col = std.math.maxInt(usize);
const max_count: u32 = @intCast(constants.MAX_VIM_COUNT);
const max_macro_depth = 100;
const scrolloff = 2;
const keylog_cap = 1024;

const Kind = textobj.Kind;

/// Where a motion lands and how an operator treats the range.
const Target = struct {
    pos: Pos,
    kind: Kind,
    /// j/k keep the remembered column; others set it from `pos`.
    keep_want: bool = false,
    want_max: bool = false,
    /// Moved but hit the buffer edge (Vim beeps; a macro aborts).
    beep: bool = false,
    jump: bool = false,
    /// Visual `l` may step onto the end of line (selecting the line break).
    past_eol: bool = false,
};

/// Charwise ranges are half-open; linewise ranges cover start.row..end.row.
const OpRange = struct { start: Pos, end: Pos, linewise: bool };

const Mo = enum { h, l, j, k, bs, space, w, W, b, B, e, E, ge, gE, zero, caret, dollar, g_, bar, gg, G, plus, minus, underscore, percent, para_fwd, para_back, sent_fwd, sent_back, semicolon, comma, H, M, L, n, N, star, hash };

const Await = enum { none, register, g, z, Z, obj_i, obj_a, find, replace, mark_set, mark_line, mark_exact, q_reg, at_reg };

const Pending = struct {
    count1: u32 = 0,
    count2: u32 = 0,
    reg: ?u8 = null,
    op: ?Op = null,
    await_: Await = .none,
    find_kind: motion.FindKind = .f,
    /// Command keys without counts and register (for dot repeat).
    keys: [24]VimKey = undefined,
    n_keys: usize = 0,
    /// showcmd text.
    shown: [24]u8 = undefined,
    n_shown: usize = 0,

    fn active(self: *const Pending) bool {
        return self.count1 != 0 or self.count2 != 0 or self.reg != null or self.op != null or self.await_ != .none;
    }

    pub fn count0(self: *const Pending) u32 {
        if (self.count1 == 0 and self.count2 == 0) return 0;
        const c = @as(u64, @max(self.count1, 1)) * @max(self.count2, 1);
        return @intCast(@min(c, max_count));
    }

    fn pushKey(self: *Pending, k: VimKey) void {
        if (self.n_keys < self.keys.len) {
            self.keys[self.n_keys] = k;
            self.n_keys += 1;
        }
    }

    fn show(self: *Pending, k: VimKey) void {
        var tmp: [8]u8 = undefined;
        const s = switch (k) {
            .ctrl => |c| blk: {
                tmp[0] = '^';
                tmp[1] = std.ascii.toUpper(c);
                break :blk tmp[0..2];
            },
            else => k.format(&tmp),
        };
        if (self.n_shown + s.len <= self.shown.len) {
            @memcpy(self.shown[self.n_shown..][0..s.len], s);
            self.n_shown += s.len;
        }
    }
};

const InsertState = struct {
    /// Where this insert (or the part after an arrow key) started.
    start: Pos = .{},
    /// Where the insert command started; arrows don't move it (Vim's
    /// Insstart_orig): <C-w>/<C-u> stop here once.
    orig: Pos = .{},
    count: u32 = 1,
    /// o/O: a count repeat opens new lines.
    open_line: bool = false,
    /// Keys typed in this session (for the count repeat).
    keys: std.ArrayList(VimKey) = .empty,
    repeating: bool = false,
    /// Row whose indent was inserted automatically, nothing typed since.
    ai_row: ?usize = null,
    await_reg: bool = false,
    /// <C-o>: one normal-mode command, then back to insert.
    ctrl_o: bool = false,
    ctrl_o_eol: bool = false,
    /// Replace mode: the original char of each typed char (-1 appended,
    /// -2 line break).
    replaced: std.ArrayList(i16) = .empty,
    /// I/A/c on a visual block: Esc copies the text to the other rows.
    block: ?block.BlockInsert = null,
};

const LeaveBy = enum { esc, ctrl_c, internal };

pub const VisualMem = struct { anchor: Pos, cursor: Pos, mode: Mode, eol: bool };

pub const Sub = struct {
    pat: std.ArrayList(u8) = .empty,
    rep: std.ArrayList(u8) = .empty,
    global: bool = false,
    valid: bool = false,
};

pub const VimEditor = struct {
    /// Read-only for other modules.
    buffer: Buffer,
    /// Read-only for other modules.
    cursor: Pos = .{},
    /// Read-only for other modules.
    mode: Mode = .normal,
    allocator: std.mem.Allocator,
    opts: Options,

    pend: Pending = .{},
    /// Remembered column for j/k (max_col after `$`).
    curswant: usize = 0,

    vis_anchor: Pos = .{},
    last_visual: ?VisualMem = null,

    last_find: ?struct { kind: motion.FindKind, c: u8 } = null,

    // search
    pat_buf: [256]u8 = undefined,
    pat_len: usize = 0,
    has_pat: bool = false,
    search_back: bool = false,
    /// The offset of the latest `/` or `?` (`/pat/e`), used by n and N.
    search_off: search.Offset = .{},
    /// g* / g#: search for the word without \< \>.
    star_partial: bool = false,
    /// Inside a `.` repeat.
    in_dot: bool = false,
    hl_active: bool = false,
    hl_pat: search.Pattern = .{},
    sub: Sub = .{},

    // command line
    cmd_buf: [256]u8 = @splat(':'),
    cmd_len: usize = 0,
    cmd_prev: Mode = .normal,
    cmd_pend: Pending = .{},
    cmd_origin: Pos = .{},
    cmd_top: usize = 0,
    cmd_await_reg: bool = false,

    ins: InsertState = .{},
    last_insert: ?Pos = null,

    regs: Registers,
    history: History,

    // dot repeat
    dot_keys: std.ArrayList(VimKey) = .empty,
    dot_count: u32 = 0,
    dot_reg: ?u8 = null,
    dot_build: std.ArrayList(VimKey) = .empty,
    dot_build_count: u32 = 0,
    dot_build_reg: ?u8 = null,
    dot_rec: bool = false,

    // macros
    rec_reg: ?u8 = null,
    rec_buf: std.ArrayList(u8) = .empty,
    last_macro: ?u8 = null,
    /// The last `:` command line (`@:` runs it again).
    last_ex: [256]u8 = undefined,
    last_ex_len: usize = 0,
    replay_depth: u32 = 0,
    abort: bool = false,
    /// Set by `fail`; ex.zig clears it per command to stop a `|` chain or
    /// a `:g` after an error.
    failed: bool = false,
    /// Inside `:g` (no nesting; `:s` reports its total at the end).
    in_global: bool = false,
    g_subs: usize = 0,
    g_sub_lines: usize = 0,

    /// Marks a-z, `''`, the jump list and the change list.
    lists: jumps.Lists = .{},

    view_rows: usize = 0,
    view_top: usize = 0,

    st: EditStats = .{},
    log_buf: [keylog_cap]u8 = undefined,
    log_len: usize = 0,
    status: []const u8 = "",
    status_buf: [160]u8 = undefined,
    showcmd_buf: [24]u8 = undefined,
    showcmd_len: usize = 0,
    result: FeedResult = .{},
    /// Cursor saved with the next undo entry (Vim's uh_cursor): the cursor
    /// before the key that first changes the buffer, or an operator's start.
    undo_pos: Pos = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) VimEditor {
        return .{
            .buffer = Buffer.init(allocator),
            .allocator = allocator,
            .opts = opts,
            .regs = Registers.init(allocator),
            .history = History.init(allocator),
        };
    }

    pub fn deinit(self: *VimEditor) void {
        self.buffer.deinit();
        self.regs.deinit();
        self.history.deinit();
        self.ins.keys.deinit(self.allocator);
        self.ins.replaced.deinit(self.allocator);
        self.dot_keys.deinit(self.allocator);
        self.dot_build.deinit(self.allocator);
        self.rec_buf.deinit(self.allocator);
        self.sub.pat.deinit(self.allocator);
        self.sub.rep.deinit(self.allocator);
    }

    /// Empty buffer, NORMAL; clears registers, undo, search, macros, stats.
    pub fn reset(self: *VimEditor) void {
        self.buffer.clear();
        self.regs.clear();
        self.has_pat = false;
        self.hl_active = false;
        self.hl_pat = .{};
        self.sub.valid = false;
        self.last_find = null;
        self.dot_keys.clearRetainingCapacity();
        self.dot_count = 0;
        self.dot_reg = null;
        self.last_macro = null;
        self.last_ex_len = 0;
        self.last_visual = null;
        self.last_insert = null;
        self.resetSession();
    }

    /// Replaces the buffer; NORMAL; clears undo, pending state and stats.
    pub fn load(self: *VimEditor, text: []const u8, cursor: Pos) !void {
        try self.buffer.setText(text);
        self.resetSession();
        self.cursor = self.buffer.clampPos(cursor);
        self.clampNormal();
        self.setWant();
    }

    fn resetSession(self: *VimEditor) void {
        self.buffer.dropSnapshot();
        self.history.clear();
        self.cursor = .{};
        self.mode = .normal;
        self.pend = .{};
        self.curswant = 0;
        self.ins.keys.clearRetainingCapacity();
        self.ins.replaced.clearRetainingCapacity();
        self.ins.ai_row = null;
        self.ins.await_reg = false;
        self.ins.ctrl_o = false;
        self.dot_build.clearRetainingCapacity();
        self.dot_rec = false;
        self.rec_reg = null;
        self.rec_buf.clearRetainingCapacity();
        self.replay_depth = 0;
        self.abort = false;
        self.cmd_len = 0;
        self.cmd_await_reg = false;
        self.view_top = 0;
        self.st = .{};
        self.log_len = 0;
        self.status = "";
        self.showcmd_len = 0;
        self.lists.clear(&self.buffer);
    }

    // -- public facade ------------------------------------------------------

    /// Feeds one key. All input goes through here.
    pub fn feed(self: *VimEditor, key: VimKey) FeedResult {
        const v0 = self.buffer.version;
        self.result = .{};
        self.st.keystrokes +|= 1;
        if (self.log_len < keylog_cap) key_mod.appendNotation(&self.log_buf, &self.log_len, key);
        if (self.rec_reg != null) {
            var tmp: [8]u8 = undefined;
            self.rec_buf.appendSlice(self.allocator, key.format(&tmp)) catch {};
        }
        if (self.mode != .cmdline) self.status = "";
        if (self.buffer.snapshot == null) self.undo_pos = self.cursor;
        self.buffer.u_cursor = self.cursor;
        const e0 = self.buffer.edits;
        self.process(key) catch {
            self.setStatus("E342: Out of memory!");
            self.pend = .{};
        };
        if (self.buffer.edits != e0) self.lists.noteChange(&self.buffer, self.buffer.last_change) catch {};
        self.settle();
        var r = self.result;
        r.changed = self.buffer.version != v0;
        return r;
    }

    /// Legacy shim: terminal byte → VimKey → feed.
    pub fn handleKey(self: *VimEditor, byte: u8) void {
        const k = VimKey.fromByte(byte) orelse return;
        _ = self.feed(k);
    }

    /// Legacy shim for the old arrow-key union.
    pub fn handleArrow(self: *VimEditor, key: LegacyKey) void {
        const k: VimKey = switch (key) {
            .Byte => |b| return self.handleKey(b),
            .ArrowUp => .up,
            .ArrowDown => .down,
            .ArrowLeft => .left,
            .ArrowRight => .right,
            .ShiftArrowLeft, .AltArrowLeft, .CtrlArrowLeft => .word_left,
            .ShiftArrowRight, .AltArrowRight, .CtrlArrowRight => .word_right,
            .CtrlArrowUp => .doc_top,
            .CtrlArrowDown => .doc_bottom,
            .Delete => .delete,
            .AltBackspace => .{ .ctrl = 'w' },
            .AltDelete => return,
        };
        _ = self.feed(k);
    }

    /// Pending count/register/operator, e.g. "2d", "\"a", "ci"; in visual
    /// mode with nothing pending, the size of the selection.
    pub fn showcmd(self: *const VimEditor) []const u8 {
        return self.showcmd_buf[0..self.showcmd_len];
    }

    /// ":s/a/b" or "/foo" while in COMMAND mode, else null.
    pub fn cmdline(self: *const VimEditor) ?[]const u8 {
        if (self.mode != .cmdline) return null;
        return self.cmd_buf[0 .. self.cmd_len + 1];
    }

    pub fn statusMsg(self: *const VimEditor) []const u8 {
        return self.status;
    }

    /// Count/operator/register/char-argument pending.
    pub fn isPending(self: *const VimEditor) bool {
        return self.pend.active() or self.ins.await_reg or self.cmd_await_reg;
    }

    pub fn selection(self: *const VimEditor) ?Selection {
        if (!self.mode.isVisual()) return null;
        if (self.mode == .visual_block) {
            const r = block.rect(self);
            const c = block.corners(self, r);
            return .{ .start = c.start, .end = c.end, .kind = .block, .to_eol = r.to_eol };
        }
        const a = Pos.min(self.vis_anchor, self.cursor);
        var b = Pos.max(self.vis_anchor, self.cursor);
        if (self.mode == .visual_line) {
            return .{ .start = .{ .row = a.row }, .end = .{ .row = b.row, .col = self.buffer.lineLen(b.row) -| 1 }, .kind = .line };
        }
        if (self.curswant == max_col and self.cursor.row == b.row) b.col = self.buffer.lineLen(b.row);
        return .{ .start = a, .end = b, .kind = .char };
    }

    pub fn isInSelection(self: *const VimEditor, row: usize, col: usize) bool {
        if (self.mode == .visual_block) return block.contains(self, block.rect(self), row, col);
        const s = self.selection() orelse return false;
        if (row < s.start.row or row > s.end.row) return false;
        if (s.kind == .line) return true;
        if (row == s.start.row and col < s.start.col) return false;
        if (row == s.end.row and col > s.end.col) return false;
        return true;
    }

    /// Highlighted search match (hlsearch until :noh; incsearch while typing).
    pub fn isSearchMatch(self: *const VimEditor, row: usize, col: usize) bool {
        const typing = self.mode == .cmdline and self.cmd_buf[0] != ':' and self.cmd_len > 0;
        if (!typing and !self.hl_active) return false;
        if (self.hl_pat.isEmpty()) return false;
        const line = self.buffer.getLine(row);
        var s: usize = 0;
        while (s <= line.len) {
            const m = self.hl_pat.find(line, s) orelse return false;
            if (col < m.start) return false;
            if (col < m.end) return true;
            s = @max(m.end, m.start + 1);
        }
        return false;
    }

    /// Display column of byte `col` on `row` (tabs expand to
    /// `Options.tabstop`). `col` may be past the line end (one cell each).
    pub fn displayCol(self: *const VimEditor, row: usize, col: usize) usize {
        return vcol.displayCol(self.buffer.getLine(row), col, self.opts.tabstop);
    }

    pub fn recording(self: *const VimEditor) ?u8 {
        return self.rec_reg;
    }

    pub fn stats(self: *const VimEditor) EditStats {
        return self.st;
    }

    /// Notation of the keys fed since load/reset (truncated at 1 KiB).
    pub fn keylog(self: *const VimEditor) []const u8 {
        return self.log_buf[0..self.log_len];
    }

    pub fn setViewport(self: *VimEditor, rows: usize) void {
        self.view_rows = rows;
        self.scrollToCursor();
    }

    pub fn viewTop(self: *const VimEditor) usize {
        return self.view_top;
    }

    pub fn setStatus(self: *VimEditor, msg: []const u8) void {
        self.status = msg;
    }

    /// True when the next key is read as a command or motion (not typed
    /// text or a char argument such as the `x` of `fx`).
    pub fn acceptsMotion(self: *const VimEditor) bool {
        if (self.mode != .normal and !self.mode.isVisual()) return false;
        return switch (self.pend.await_) {
            .none, .g, .z, .Z => true,
            else => false,
        };
    }

    // -- internals shared with ex.zig ---------------------------------------

    pub fn statusFmt(self: *VimEditor, comptime fmt: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(&self.status_buf, fmt, args) catch "";
    }

    pub fn lastPattern(self: *const VimEditor) ?[]const u8 {
        return if (self.has_pat) self.pat_buf[0..self.pat_len] else null;
    }

    pub fn setPattern(self: *VimEditor, pat: []const u8) void {
        const n = @min(pat.len, self.pat_buf.len);
        std.mem.copyForwards(u8, self.pat_buf[0..n], pat[0..n]);
        self.pat_len = n;
        self.has_pat = true;
        self.hl_pat = self.compile(self.pat_buf[0..n]);
    }

    pub fn compile(self: *const VimEditor, pat: []const u8) search.Pattern {
        return search.Pattern.compile(pat, self.opts.smartcase);
    }

    /// Keeps the cursor on a character (NORMAL mode rules).
    pub fn clampNormal(self: *VimEditor) void {
        self.cursor = self.buffer.clampPos(self.cursor);
        const len = self.buffer.lineLen(self.cursor.row);
        if (len > 0 and self.cursor.col >= len) self.cursor.col = len - 1;
    }

    /// Remembers the cursor's display column for j/k. Vim's getvcol: outside
    /// Insert, a cursor on a tab sits on the tab's last cell (in Visual only
    /// when it is past the anchor), and that is the column j/k keep.
    pub fn setWant(self: *VimEditor) void {
        const line = self.buffer.getLine(self.cursor.row);
        const c = self.cursor.col;
        const on_end = c < line.len and line[c] == '\t' and switch (self.mode) {
            .insert, .replace => false,
            .visual, .visual_line, .visual_block => self.vis_anchor.lessThan(self.cursor),
            .normal, .cmdline => true,
        };
        self.curswant = if (on_end) vcol.displayEnd(line, c, self.opts.tabstop) else vcol.displayCol(line, c, self.opts.tabstop);
    }

    /// Cursor to the first non-blank of a row.
    pub fn gotoLine(self: *VimEditor, row: usize) void {
        self.cursor.row = @min(row, self.buffer.lastRow());
        self.cursor.col = self.buffer.firstNonBlank(self.cursor.row);
        self.clampNormal();
        self.setWant();
    }

    /// Vim's setpcmark: remember the cursor for `''` and the jump list.
    pub fn setPcmark(self: *VimEditor) !void {
        try self.lists.pushJump(&self.buffer, self.cursor);
    }

    /// A command failed: drop pending keys; a running macro aborts.
    pub fn fail(self: *VimEditor) void {
        self.pend = .{};
        self.failed = true;
        if (self.replay_depth > 0) self.abort = true;
    }

    /// `:normal {keys}`: feeds the bytes of `keys` literally (no <> notation)
    /// in NORMAL. A failing command drops the rest, and an unfinished one
    /// is ended as if by Esc (an insert is completed, a pending operator or
    /// the command line is cancelled).
    pub fn runNormal(self: *VimEditor, keys: []const u8) !void {
        if (self.replay_depth >= max_macro_depth) {
            self.setStatus("E169: Command too recursive");
            return self.fail();
        }
        const saved_abort = self.abort;
        self.abort = false;
        self.replay_depth += 1;
        defer {
            self.replay_depth -= 1;
            self.abort = saved_abort;
        }
        for (keys) |b| {
            const k = VimKey.fromByte(b) orelse continue;
            try self.process(k);
            if (self.abort) break;
        }
        switch (self.mode) {
            .insert, .replace => try self.leaveInsert(.internal),
            .cmdline => self.cmdlineCancel(),
            .visual, .visual_line, .visual_block => self.exitVisual(),
            .normal => {},
        }
        self.pend = .{};
        self.ins.ctrl_o = false;
    }

    // -- key dispatch -------------------------------------------------------

    fn process(self: *VimEditor, key0: VimKey) anyerror!void {
        const key: VimKey = if (key0.isCtrl('[')) .esc else key0;
        if (self.dot_rec) try self.dot_build.append(self.allocator, key);
        switch (self.mode) {
            .insert, .replace => try self.insertKey(key),
            .cmdline => try self.cmdlineKey(key),
            .normal, .visual, .visual_line, .visual_block => try self.normalKey(key),
        }
    }

    /// After a top-level key: close the undo group when the command is
    /// complete, keep the cursor visible, refresh showcmd.
    fn settle(self: *VimEditor) void {
        if ((self.mode == .normal or self.mode.isVisual()) and !self.pend.active()) self.commitUndo();
        self.scrollToCursor();
        self.updateShowcmd();
    }

    fn commitUndo(self: *VimEditor) void {
        if (self.buffer.takeSnapshot()) |snap| _ = self.history.commitMarks(&self.buffer, snap, self.undo_pos, self.buffer.snapshot_marks);
    }

    /// Sets the cursor saved with the undo entry, unless the change group
    /// already started.
    pub fn markUndoPos(self: *VimEditor, p: Pos) void {
        if (self.buffer.snapshot == null) self.undo_pos = p;
    }

    fn updateShowcmd(self: *VimEditor) void {
        if (self.pend.n_shown > 0) {
            @memcpy(self.showcmd_buf[0..self.pend.n_shown], self.pend.shown[0..self.pend.n_shown]);
            self.showcmd_len = self.pend.n_shown;
            return;
        }
        if (self.ins.await_reg or self.cmd_await_reg) {
            self.showcmd_buf[0..2].* = "^R".*;
            self.showcmd_len = 2;
            return;
        }
        if (self.mode == .visual_block) {
            const r = block.rect(self);
            var cols = r.cols();
            if (r.to_eol) {
                cols = 0;
                var row = r.top;
                while (row <= r.bot) : (row += 1) cols = @max(cols, vcol.width(self.buffer.getLine(row), self.opts.tabstop) -| r.left);
            }
            const out = std.fmt.bufPrint(&self.showcmd_buf, "{d}x{d}", .{ r.rows(), cols }) catch "";
            self.showcmd_len = out.len;
            return;
        }
        if (self.selection()) |s| {
            const n = if (s.start.row != s.end.row or s.kind == .line) s.end.row - s.start.row + 1 else s.end.col - s.start.col + 1;
            const out = std.fmt.bufPrint(&self.showcmd_buf, "{d}", .{n}) catch "";
            self.showcmd_len = out.len;
            return;
        }
        self.showcmd_len = 0;
    }

    fn viewRows(self: *const VimEditor) usize {
        return if (self.view_rows == 0) 20 else self.view_rows;
    }

    fn margin(self: *const VimEditor) usize {
        return @min(scrolloff, (self.viewRows() - 1) / 2);
    }

    fn scrollToCursor(self: *VimEditor) void {
        const rows = self.viewRows();
        const so = self.margin();
        const row = self.cursor.row;
        if (row < self.view_top + so) self.view_top = row -| so;
        const low = @min(row + so, self.buffer.lastRow());
        if (low >= self.view_top + rows) self.view_top = low + 1 - rows;
        if (self.view_top > self.buffer.lastRow()) self.view_top = self.buffer.lastRow();
        if (self.buffer.lineCount() <= rows) self.view_top = 0;
    }

    // -- normal and visual mode ---------------------------------------------

    fn normalKey(self: *VimEditor, key: VimKey) !void {
        if (self.pend.await_ != .none) return self.awaitKey(key);
        switch (key) {
            .char => |c| return self.normalChar(c),
            .ctrl => |c| return self.normalCtrl(c),
            .esc => {
                if (self.mode.isVisual() and !self.pend.active()) self.exitVisual();
                self.pend = .{};
                self.finishCtrlO();
            },
            .enter => return self.motionCmd(.plus, key),
            .backspace => return self.motionCmd(.bs, key),
            .delete => {
                if (self.pend.op != null) return self.fail();
                return self.normalChar('x');
            },
            // Tab is Ctrl+I in a terminal: jump forward.
            .tab => return self.normalCtrl('i'),
            .up, .down, .left, .right, .word_left, .word_right, .doc_top, .doc_bottom => {
                // Arrows cancel a pending operator or count.
                self.pend = .{};
                const m: Mo = switch (key) {
                    .up => .k,
                    .down => .j,
                    .left => .h,
                    .right => .l,
                    .word_left => .b,
                    .word_right => .w,
                    .doc_top => .gg,
                    else => .G,
                };
                return self.motionCmd(m, key);
            },
            .home => return self.motionCmd(.zero, key),
            .end => return self.motionCmd(.dollar, key),
            .page_up => return self.normalCtrl('b'),
            .page_down => return self.normalCtrl('f'),
            .f => {},
        }
    }

    fn curCount(self: *const VimEditor) u32 {
        return if (self.pend.op != null) self.pend.count2 else self.pend.count1;
    }

    fn normalChar(self: *VimEditor, c: u8) !void {
        const p = &self.pend;
        const k = VimKey{ .char = c };
        if ((c >= '1' and c <= '9') or (c == '0' and self.curCount() > 0)) {
            const slot = if (p.op != null) &p.count2 else &p.count1;
            slot.* = @min(slot.* * 10 + (c - '0'), max_count);
            p.show(k);
            return;
        }
        // Doubled g-operators: g~~ guu gUU.
        if (p.op) |op| {
            if ((op == .toggle and c == '~') or (op == .lower and c == 'u') or (op == .upper and c == 'U') or
                (op == .format and c == 'q') or (op == .format_keep and c == 'w'))
            {
                p.pushKey(k);
                return self.lineOp(op);
            }
        }
        switch (c) {
            '"' => {
                if (p.op != null) return self.fail();
                p.await_ = .register;
                p.show(k);
                return;
            },
            'd', 'c', 'y', '>', '<', '=' => {
                const op: Op = switch (c) {
                    'd' => .delete,
                    'c' => .change,
                    'y' => .yank,
                    '>' => .indent,
                    '=' => .reindent,
                    else => .outdent,
                };
                p.pushKey(k);
                p.show(k);
                return self.operatorKey(op);
            },
            'g', 'z', 'Z' => {
                if (c != 'g' and (p.op != null or self.mode.isVisual())) return self.fail();
                p.await_ = switch (c) {
                    'g' => .g,
                    'z' => .z,
                    else => .Z,
                };
                p.pushKey(k);
                p.show(k);
                return;
            },
            'i', 'a' => if (p.op != null or self.mode.isVisual()) {
                p.await_ = if (c == 'i') .obj_i else .obj_a;
                p.pushKey(k);
                p.show(k);
                return;
            },
            'f', 'F', 't', 'T' => {
                p.await_ = .find;
                p.find_kind = switch (c) {
                    'f' => .f,
                    'F' => .F,
                    't' => .t,
                    else => .T,
                };
                p.pushKey(k);
                p.show(k);
                return;
            },
            '\'', '`' => {
                p.await_ = if (c == '\'') .mark_line else .mark_exact;
                p.pushKey(k);
                p.show(k);
                return;
            },
            '/', '?' => {
                self.startCmdline(c, "");
                return;
            },
            else => {},
        }
        if (motionOf(c)) |m| return self.motionCmd(m, k);
        if (p.op != null) return self.fail();
        if (self.mode.isVisual()) return self.visualChar(c);
        return self.commandChar(c);
    }

    fn motionOf(c: u8) ?Mo {
        return switch (c) {
            'h' => .h,
            'l' => .l,
            'j' => .j,
            'k' => .k,
            ' ' => .space,
            'w' => .w,
            'W' => .W,
            'b' => .b,
            'B' => .B,
            'e' => .e,
            'E' => .E,
            '0' => .zero,
            '^' => .caret,
            '$' => .dollar,
            '|' => .bar,
            'G' => .G,
            '+' => .plus,
            '-' => .minus,
            '_' => .underscore,
            '%' => .percent,
            '}' => .para_fwd,
            '{' => .para_back,
            ')' => .sent_fwd,
            '(' => .sent_back,
            ';' => .semicolon,
            ',' => .comma,
            'H' => .H,
            'M' => .M,
            'L' => .L,
            'n' => .n,
            'N' => .N,
            '*' => .star,
            '#' => .hash,
            else => null,
        };
    }

    fn operatorKey(self: *VimEditor, op: Op) !void {
        if (self.mode.isVisual()) return self.visualOp(op, false);
        const p = &self.pend;
        if (p.op == null) {
            p.op = op;
            return;
        }
        if (p.op.? == op) return self.lineOp(op);
        self.fail();
    }

    /// dd cc yy >> << g~~ guu gUU with a count of lines.
    fn lineOp(self: *VimEditor, op: Op) !void {
        const n: usize = @max(self.pend.count0(), 1);
        const row = self.cursor.row;
        if (n > 1 and row >= self.buffer.lastRow()) return self.fail();
        const end = @min(row + n - 1, self.buffer.lastRow());
        self.markUndoPos(Pos.min(self.cursor, .{ .row = end, .col = self.buffer.firstNonBlank(end) }));
        try self.applyOp(op, .{ .start = .{ .row = row }, .end = .{ .row = end }, .linewise = true }, .{});
        self.finishCmd(op.isChange());
    }

    fn awaitKey(self: *VimEditor, key: VimKey) !void {
        const p = &self.pend;
        const which = p.await_;
        p.await_ = .none;
        if (key == .esc or key.isCtrl('c')) {
            self.pend = .{};
            self.finishCtrlO();
            return;
        }
        const c: u8 = switch (key) {
            .char => |ch| ch,
            .enter => if (which == .replace or which == .z) '\r' else return self.fail(),
            else => return self.fail(),
        };
        const k = VimKey{ .char = c };
        switch (which) {
            .none => unreachable,
            .register => {
                if (!Registers.isValidName(c)) return self.fail();
                p.reg = c;
                p.show(k);
            },
            .g => {
                p.pushKey(k);
                return self.gCommand(c);
            },
            .z => return self.zCommand(c),
            .Z => {
                if (c == 'Z') self.result.ex = .write_quit else if (c == 'Q') self.result.ex = .quit_force else return self.fail();
                self.pend = .{};
            },
            .obj_i, .obj_a => {
                p.pushKey(k);
                return self.textObject(c, which == .obj_a);
            },
            .find => {
                p.pushKey(k);
                const kind = p.find_kind;
                self.last_find = .{ .kind = kind, .c = c };
                const t = self.findTarget(kind, c, false) orelse return self.fail();
                return self.applyMotion(t, false);
            },
            .replace => {
                if (self.mode.isVisual()) return self.visualReplace(c);
                p.pushKey(if (c == '\r') .enter else k);
                return self.replaceChars(c);
            },
            .mark_set => {
                if (c >= 'a' and c <= 'z') try jumps.Lists.setMark(&self.buffer, c, self.cursor) else return self.fail();
                self.pend = .{};
                self.finishCtrlO();
            },
            .mark_line, .mark_exact => {
                p.pushKey(k);
                const pos = self.markPos(c) orelse {
                    self.setStatus("E20: Mark not set");
                    return self.fail();
                };
                const row = @min(pos.row, self.buffer.lastRow());
                const t: Target = if (which == .mark_line)
                    .{ .pos = .{ .row = row, .col = self.buffer.firstNonBlank(row) }, .kind = .linewise, .jump = true }
                else
                    .{ .pos = self.buffer.clampPos(pos), .kind = .exclusive, .jump = true };
                return self.applyMotion(t, false);
            },
            .q_reg => {
                self.pend = .{};
                if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '"')) return self.fail();
                self.rec_reg = c;
                self.rec_buf.clearRetainingCapacity();
            },
            .at_reg => return self.runMacro(c),
        }
    }

    fn markPos(self: *const VimEditor, c: u8) ?Pos {
        return switch (c) {
            'a'...'z' => jumps.Lists.mark(&self.buffer, c),
            '\'', '`' => jumps.Lists.pcmark(&self.buffer),
            '<' => if (self.last_visual) |v| Pos.min(v.anchor, v.cursor) else null,
            '>' => if (self.last_visual) |v| Pos.max(v.anchor, v.cursor) else null,
            '.' => self.lists.lastChange(&self.buffer),
            '^' => self.last_insert,
            else => null,
        };
    }

    fn gCommand(self: *VimEditor, c: u8) !void {
        const p = &self.pend;
        switch (c) {
            'g' => return self.motionCmd(.gg, null),
            '&' => {
                // g& = :%s//~/& (last substitute, same flags, every line).
                self.pend = .{};
                try ex.execute(self, "%&&");
                self.finishCmd(false);
                return;
            },
            '*', '#' => {
                self.star_partial = true;
                defer self.star_partial = false;
                return self.motionCmd(if (c == '*') .star else .hash, null);
            },
            'n', 'N' => return self.gnCmd(c == 'n'),
            'e' => return self.motionCmd(.ge, null),
            'E' => return self.motionCmd(.gE, null),
            '_' => return self.motionCmd(.g_, null),
            'j' => return self.motionCmd(.j, null),
            'k' => return self.motionCmd(.k, null),
            '0', '^' => return self.motionCmd(if (c == '0') .zero else .caret, null),
            '$' => return self.motionCmd(.dollar, null),
            '~', 'u', 'U', 'q', 'w' => {
                const op: Op = switch (c) {
                    '~' => .toggle,
                    'u' => .lower,
                    'q' => .format,
                    'w' => .format_keep,
                    else => .upper,
                };
                p.show(.{ .char = c });
                if (self.mode.isVisual()) return self.visualOp(op, false);
                if (p.op) |cur| {
                    if (cur == op) return self.lineOp(op);
                    return self.fail();
                }
                p.op = op;
                return;
            },
            else => {},
        }
        if (p.op != null) return self.fail();
        switch (c) {
            'J' => {
                if (self.mode.isVisual()) return self.visualJoin(false);
                const n = @max(self.pend.count0(), 2);
                if (!try self.joinLines(self.cursor.row, n, false)) return self.fail();
                self.finishCmd(true);
            },
            'v' => {
                const v = self.last_visual orelse return self.fail();
                if (self.mode.isVisual()) {
                    self.last_visual = .{ .anchor = self.vis_anchor, .cursor = self.cursor, .mode = self.mode, .eol = self.curswant == max_col };
                }
                self.mode = v.mode;
                self.vis_anchor = self.buffer.clampPos(v.anchor);
                self.cursor = self.clampToText(self.buffer.clampPos(v.cursor));
                if (v.eol) {
                    self.curswant = max_col;
                } else self.setWant();
                self.pend = .{};
            },
            'i' => {
                if (self.mode.isVisual()) return self.fail();
                if (self.last_insert) |li| self.cursor = self.buffer.clampPos(li);
                try self.beginInsert(1, false);
                self.finishCmd(true);
            },
            'I' => {
                if (self.mode.isVisual()) return self.fail();
                self.cursor.col = 0;
                try self.beginInsert(self.pend.count0(), false);
                self.finishCmd(true);
            },
            ';', ',' => {
                const n: isize = @intCast(@max(self.pend.count0(), 1));
                const pos = self.lists.change(&self.buffer, if (c == ';') -n else n) catch |e| {
                    self.setStatus(switch (e) {
                        error.ChangelistEmpty => "E664: Changelist is empty",
                        error.AtStart => "E662: At start of changelist",
                        error.AtEnd => "E663: At end of changelist",
                    });
                    return self.fail();
                };
                self.cursor = self.buffer.clampPos(pos);
                if (!self.mode.isVisual()) self.clampNormal();
                self.setWant();
                self.finishCmd(false);
            },
            'm' => {
                const len = self.buffer.lineLen(self.cursor.row);
                self.cursor.col = @min(len / 2, len -| 1);
                self.setWant();
                self.finishCmd(false);
            },
            '-', '+' => {
                if (self.mode.isVisual()) return self.fail();
                try self.undoTravel(c == '-', self.pend.count0());
                self.finishCtrlO();
            },
            else => self.fail(),
        }
    }

    /// The match of `pat` on `row` that contains `col`, if any.
    fn matchContaining(pat: *const search.Pattern, line: []const u8, col: usize) ?search.Match {
        var from: usize = 0;
        var caps: search.Caps = undefined;
        while (from <= line.len) {
            const m = pat.findCaps(line, from, &caps) orelse return null;
            if (m.start > col) return null;
            if (col < m.end) return m;
            from = @max(m.start + 1, from + 1);
        }
        return null;
    }

    /// `gn` / `gN`: select the match under the cursor or the next (previous)
    /// one; after an operator, act on it (`cgn` then `.` changes the next
    /// match). In Visual mode the selection extends to the next match.
    fn gnCmd(self: *VimEditor, forward: bool) !void {
        const count: usize = @max(self.pend.count0(), 1);
        const src = self.lastPattern() orelse {
            self.setStatus("E35: No previous regular expression");
            return self.fail();
        };
        var tmp: [256]u8 = undefined;
        const pat_src = tmp[0..src.len];
        @memcpy(pat_src, src);
        const pat = self.compile(pat_src);
        if (pat.err) |e| {
            self.setStatus(e.message());
            return self.fail();
        }
        const visual = self.mode.isVisual();
        var from = self.cursor;
        if (visual) {
            var w = motion.Walker{ .buf = &self.buffer, .p = from };
            _ = if (forward) w.incl() else w.decl();
            from = w.p;
        }
        var row = from.row;
        var m: search.Match = undefined;
        if (matchContaining(&pat, self.buffer.getLine(row), from.col)) |hit| {
            m = hit;
        } else {
            const p = self.searchFrom(pat_src, from, !forward, 1) orelse return self.fail();
            row = p.row;
            m = .{ .start = p.col, .end = pat.matchAt(self.buffer.getLine(p.row), p.col) orelse p.col };
            var caps: search.Caps = undefined;
            if (pat.matchCaps(self.buffer.getLine(p.row), p.col, &caps)) |mm| m = mm;
        }
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const p = self.searchFrom(pat_src, .{ .row = row, .col = m.start }, !forward, 1) orelse return self.fail();
            row = p.row;
            var caps: search.Caps = undefined;
            m = pat.matchCaps(self.buffer.getLine(p.row), p.col, &caps) orelse .{ .start = p.col, .end = p.col };
        }
        const start = Pos{ .row = row, .col = m.start };
        const last = Pos{ .row = row, .col = if (m.end > m.start) m.end - 1 else m.start };
        if (self.pend.op) |op| {
            self.markUndoPos(start);
            try self.applyOp(op, .{ .start = start, .end = .{ .row = row, .col = @max(m.end, m.start) }, .linewise = false }, .{ .motion = true });
            return self.finishCmd(op.isChange());
        }
        if (!visual) {
            self.vis_anchor = start;
            self.mode = .visual;
        } else if (self.mode != .visual) self.mode = .visual;
        self.cursor = if (forward or !visual) last else start;
        if (!forward and !visual) {
            self.vis_anchor = last;
            self.cursor = start;
        }
        self.setWant();
        self.pend = .{};
    }

    fn zCommand(self: *VimEditor, c: u8) !void {
        const rows = self.viewRows();
        const so = self.margin();
        const row = self.cursor.row;
        switch (c) {
            'z', '.' => self.view_top = row -| (rows / 2),
            't', '\r' => self.view_top = row -| so,
            'b', '-' => self.view_top = (row + so + 1) -| rows,
            else => return self.fail(),
        }
        if (c == '.' or c == '\r' or c == '-') self.gotoLine(row);
        self.pend = .{};
        self.finishCtrlO();
    }

    fn normalCtrl(self: *VimEditor, c: u8) !void {
        const p = &self.pend;
        switch (c) {
            'c' => {
                if (self.ins.ctrl_o and !self.mode.isVisual()) {
                    // Ctrl+C in a <C-o> command ends the insert for good
                    // (Vim resets restart_edit); the cursor stays put.
                    self.pend = .{};
                    self.cursor.col += 1;
                    return self.leaveInsert(.ctrl_c);
                }
                if (self.mode.isVisual()) {
                    self.exitVisual();
                } else if (!p.active() and !self.ins.ctrl_o) {
                    self.result.interrupt = true;
                }
                self.pend = .{};
                self.finishCtrlO();
                return;
            },
            'h' => return self.motionCmd(.bs, null),
            'n', 'j' => return self.motionCmd(.j, null),
            'p' => return self.motionCmd(.k, null),
            'm' => return self.motionCmd(.plus, null),
            else => {},
        }
        if (p.op != null) return self.fail();
        switch (c) {
            'r' => {
                if (self.mode.isVisual()) return self.fail();
                try self.undoRedo(false);
                self.finishCtrlO();
            },
            'a', 'x' => {
                if (self.mode.isVisual()) return self.fail();
                p.pushKey(.{ .ctrl = c });
                const n: i64 = @max(p.count0(), 1);
                // An empty line is a silent no-op in Vim (no beep, no macro abort).
                const empty = self.buffer.lineLen(self.cursor.row) == 0;
                if (!try self.addNumber(if (c == 'a') n else -n) and !empty) return self.fail();
                self.finishCmd(true);
            },
            'd', 'u' => {
                const rows = self.viewRows();
                const amount: usize = if (p.count0() > 0) p.count0() else @max(rows / 2, 1);
                const last = self.buffer.lastRow();
                const so = self.margin();
                if (c == 'd') {
                    if (self.cursor.row >= last) return self.fail();
                    self.view_top = @min(self.view_top + amount, last);
                    self.cursor.row = @min(@max(self.cursor.row + amount, self.view_top + so), last);
                } else {
                    if (self.cursor.row == 0) return self.fail();
                    self.view_top -|= amount;
                    self.cursor.row = @min(self.cursor.row -| amount, (self.view_top + rows) -| (so + 1));
                }
                self.gotoLine(self.cursor.row);
                self.finishCmd(false);
            },
            'e', 'y' => {
                const n: usize = @max(p.count0(), 1);
                const rows = self.viewRows();
                const so = self.margin();
                const last = self.buffer.lastRow();
                if (c == 'e') {
                    self.view_top = @min(self.view_top + n, last);
                    if (self.cursor.row < self.view_top + so) self.cursor.row = @min(self.view_top + so, last);
                } else {
                    self.view_top -|= n;
                    if (self.cursor.row + so >= self.view_top + rows) self.cursor.row = (self.view_top + rows) -| (so + 1);
                }
                self.cursor.col = self.wantCol(self.cursor.row);
                self.finishCmd(false);
            },
            'f', 'b' => {
                const rows = self.viewRows();
                const n: usize = @max(p.count0(), 1);
                const page = @max(rows -| 2, 1) * n;
                const so = self.margin();
                const last = self.buffer.lastRow();
                if (c == 'f') {
                    if (self.view_top >= last) return self.fail();
                    self.view_top = @min(self.view_top + page, last);
                    self.cursor.row = @max(self.cursor.row, @min(self.view_top + so, last));
                } else {
                    if (self.view_top == 0) return self.fail();
                    self.view_top -|= page;
                    self.cursor.row = @min(self.cursor.row, (self.view_top + rows) -| (so + 1));
                }
                self.gotoLine(self.cursor.row);
                self.finishCmd(false);
            },
            'v' => {
                if (self.mode == .visual_block) {
                    self.exitVisual();
                } else {
                    if (!self.mode.isVisual()) self.vis_anchor = self.cursor;
                    self.mode = .visual_block;
                }
                self.pend = .{};
            },
            'g' => {
                self.statusFmt("line {d} of {d}", .{ self.cursor.row + 1, self.buffer.lineCount() });
                self.finishCmd(false);
            },
            'o', 'i' => {
                if (self.mode.isVisual()) return self.fail();
                const n: isize = @intCast(@max(p.count0(), 1));
                const pos = try self.lists.jump(&self.buffer, self.cursor, if (c == 'o') -n else n) orelse return self.fail();
                self.cursor = self.buffer.clampPos(pos);
                self.clampNormal();
                self.setWant();
                self.finishCmd(false);
            },
            'l' => self.finishCmd(false),
            else => self.fail(),
        }
    }

    // -- motions --------------------------------------------------------------

    /// The byte under the remembered display column on `row` (Vim's
    /// coladvance): j/k keep the screen column across tabs.
    fn wantCol(self: *const VimEditor, row: usize) usize {
        const len = self.buffer.lineLen(row);
        if (len == 0) return 0;
        if (self.curswant == max_col) return len - 1;
        return vcol.byteAt(self.buffer.getLine(row), self.curswant, self.opts.tabstop);
    }

    pub fn clampToText(self: *const VimEditor, p: Pos) Pos {
        const len = self.buffer.lineLen(p.row);
        return .{ .row = p.row, .col = if (len == 0) 0 else @min(p.col, len - 1) };
    }

    fn motionCmd(self: *VimEditor, m: Mo, key: ?VimKey) !void {
        const p = &self.pend;
        if (key) |k| p.pushKey(k);
        const count0 = p.count0();
        // cw/cW on non-blank text act like ce/cE.
        if (p.op == .change and (m == .w or m == .W)) {
            const c = self.buffer.charAt(self.cursor);
            if (c != 0 and !classify.isBlank(c)) {
                const r = motion.endWord(&self.buffer, self.cursor, @max(count0, 1), m == .W, true, false);
                return self.applyMotion(.{ .pos = self.clampToText(r.pos), .kind = .inclusive }, false);
            }
        }
        const t = self.motionTarget(m, count0, p.op != null) orelse return self.fail();
        const ring = switch (m) {
            .percent, .para_fwd, .para_back, .sent_fwd, .sent_back, .n, .N, .star, .hash => true,
            else => false,
        };
        return self.applyMotion(t, ring);
    }

    fn motionTarget(self: *VimEditor, m: Mo, count0: u32, has_op: bool) ?Target {
        const buf = &self.buffer;
        const cur = self.cursor;
        const n: usize = @max(count0, 1);
        const len = buf.lineLen(cur.row);
        const last = buf.lastRow();
        switch (m) {
            .h => {
                // With an operator Vim doesn't beep at the line start (an
                // empty range), so `X`/`dh` there don't abort a macro.
                if (cur.col == 0) return if (has_op) .{ .pos = cur, .kind = .exclusive } else null;
                return .{ .pos = .{ .row = cur.row, .col = cur.col - @min(n, cur.col) }, .kind = .exclusive };
            },
            .l => {
                if (has_op) {
                    return .{ .pos = .{ .row = cur.row, .col = @min(cur.col + n, len) }, .kind = .exclusive };
                }
                // In Visual mode (selection=inclusive) Vim lets `l` move onto
                // the end of line, so the selection takes the line break.
                if (self.mode.isVisual()) {
                    if (cur.col >= len) return null;
                    return .{ .pos = .{ .row = cur.row, .col = @min(cur.col + n, len) }, .kind = .exclusive, .past_eol = true };
                }
                if (cur.col + 1 >= len) return null;
                return .{ .pos = .{ .row = cur.row, .col = @min(cur.col + n, len - 1) }, .kind = .exclusive };
            },
            .bs, .space => {
                var w = motion.Walker{ .buf = buf, .p = cur };
                var i: usize = 0;
                var moved = false;
                while (i < n) : (i += 1) {
                    if (m == .bs) {
                        if (w.dec() == -1) break;
                        if (w.p.col > 0 and w.p.col >= buf.lineLen(w.p.row)) _ = w.dec();
                    } else {
                        const r = w.inc();
                        if (r == -1) break;
                        if (r == 2 and w.inc() == -1) {
                            _ = w.dec();
                            break;
                        }
                    }
                    moved = true;
                }
                if (!moved) return null;
                return .{ .pos = w.p, .kind = .exclusive };
            },
            .j, .k => {
                if (m == .j and cur.row >= last) return null;
                if (m == .k and cur.row == 0) return null;
                const row = if (m == .j) @min(cur.row + n, last) else cur.row - @min(n, cur.row);
                return .{ .pos = .{ .row = row, .col = self.wantCol(row) }, .kind = .linewise, .keep_want = true };
            },
            .w, .W => {
                const r = motion.fwdWord(buf, cur, n, m == .W, has_op);
                const pos = if (has_op) r.pos else self.clampToText(r.pos);
                return .{ .pos = pos, .kind = .exclusive, .beep = !r.ok };
            },
            .b, .B => {
                const r = motion.bckWord(buf, cur, n, m == .B, false);
                if (!r.ok and r.pos.equals(cur)) return null;
                return .{ .pos = r.pos, .kind = .exclusive, .beep = !r.ok };
            },
            .e, .E => {
                const r = motion.endWord(buf, cur, n, m == .E, false, false);
                if (!r.ok) {
                    const p = self.clampToText(r.pos);
                    if (p.equals(cur)) return null;
                    return .{ .pos = p, .kind = .inclusive, .beep = true };
                }
                return .{ .pos = r.pos, .kind = .inclusive };
            },
            .ge, .gE => {
                const r = motion.bckendWord(buf, cur, n, m == .gE, false);
                if (!r.ok and r.pos.equals(cur)) return null;
                return .{ .pos = self.clampToText(r.pos), .kind = .inclusive, .beep = !r.ok };
            },
            .zero => return .{ .pos = .{ .row = cur.row, .col = 0 }, .kind = .exclusive },
            .caret => return .{ .pos = .{ .row = cur.row, .col = buf.firstNonBlank(cur.row) }, .kind = .exclusive },
            .dollar, .g_ => {
                const row = cur.row + n - 1;
                if (row > last) return null;
                const l = buf.getLine(row);
                var col = l.len -| 1;
                if (m == .g_) {
                    while (col > 0 and classify.isBlank(l[col])) col -= 1;
                }
                return .{ .pos = .{ .row = row, .col = col }, .kind = .inclusive, .want_max = m == .dollar };
            },
            .bar => return .{ .pos = .{ .row = cur.row, .col = if (len == 0) 0 else vcol.byteAt(buf.getLine(cur.row), n - 1, self.opts.tabstop) }, .kind = .exclusive },
            .gg, .G => {
                const row = if (count0 > 0) @min(count0 - 1, last) else if (m == .gg) 0 else last;
                return .{ .pos = .{ .row = row, .col = buf.firstNonBlank(row) }, .kind = .linewise, .jump = true };
            },
            .plus, .minus, .underscore => {
                const row: usize = switch (m) {
                    .plus => if (cur.row + n > last) return null else cur.row + n,
                    .minus => if (n > cur.row) return null else cur.row - n,
                    else => if (cur.row + n - 1 > last) return null else cur.row + n - 1,
                };
                return .{ .pos = .{ .row = row, .col = buf.firstNonBlank(row) }, .kind = .linewise };
            },
            .percent => {
                if (count0 > 0) {
                    if (count0 > 100) return null;
                    const row = (count0 * buf.lineCount() + 99) / 100 -| 1;
                    return .{ .pos = .{ .row = row, .col = buf.firstNonBlank(row) }, .kind = .linewise, .jump = true };
                }
                const p = motion.matchPair(buf, cur) orelse return null;
                return .{ .pos = p, .kind = .inclusive, .jump = true };
            },
            .para_fwd, .para_back => {
                const r = motion.paragraph(buf, cur, n, m == .para_fwd) orelse return null;
                return .{ .pos = r.pos, .kind = if (r.inclusive) .inclusive else .exclusive, .jump = true };
            },
            .sent_fwd, .sent_back => {
                const p = sentence.find(buf, cur, n, m == .sent_fwd) orelse return null;
                return .{ .pos = p, .kind = .exclusive, .jump = true };
            },
            .semicolon, .comma => {
                const lf = self.last_find orelse return null;
                const kind = if (m == .comma) lf.kind.reversed() else lf.kind;
                return self.findTarget(kind, lf.c, true);
            },
            .H, .M, .L => {
                const rows = self.viewRows();
                const top = self.view_top;
                const bottom = @min(top + rows - 1, last);
                const so = self.margin();
                const row: usize = switch (m) {
                    .H => @min(@max(top + n - 1, if (top > 0) top + so else 0), bottom),
                    .L => @max(bottom -| (n - 1), top) -| (if (bottom < last) so else 0),
                    else => top + (bottom - top) / 2,
                };
                return .{ .pos = .{ .row = row, .col = buf.firstNonBlank(row) }, .kind = .linewise, .jump = true };
            },
            .n, .N => {
                const pat = self.lastPattern() orelse {
                    self.setStatus("E35: No previous regular expression");
                    return null;
                };
                var tmp: [256]u8 = undefined;
                const copy = tmp[0..pat.len];
                @memcpy(copy, pat);
                const back = self.search_back != (m == .N);
                self.hl_active = true;
                return self.searchOffset(copy, cur, back, n);
            },
            .star, .hash => {
                const line = buf.getLine(cur.row);
                var s = @min(cur.col, line.len);
                while (s < line.len and !classify.isKeyword(line[s])) s += 1;
                if (s >= line.len) {
                    self.setStatus("E348: No string under cursor");
                    return null;
                }
                while (s > 0 and classify.isKeyword(line[s - 1])) s -= 1;
                var e = s;
                while (e < line.len and classify.isKeyword(line[e])) e += 1;
                var tmp: [256]u8 = undefined;
                const pat = (if (self.star_partial)
                    std.fmt.bufPrint(&tmp, "{s}", .{line[s..e]})
                else
                    std.fmt.bufPrint(&tmp, "\\<{s}\\>", .{line[s..e]})) catch return null;
                self.setPattern(pat);
                self.search_back = m == .hash;
                self.search_off = .{};
                self.hl_active = true;
                const p = self.searchFrom(pat, .{ .row = cur.row, .col = s }, m == .hash, n) orelse return null;
                return .{ .pos = p, .kind = .exclusive, .jump = true };
            },
        }
    }

    fn findTarget(self: *VimEditor, kind: motion.FindKind, c: u8, repeat: bool) ?Target {
        const n: usize = @max(self.pend.count0(), 1);
        const line = self.buffer.getLine(self.cursor.row);
        const col = motion.findChar(line, self.cursor.col, c, kind, n, repeat) orelse return null;
        return .{ .pos = .{ .row = self.cursor.row, .col = col }, .kind = if (kind.forward()) .inclusive else .exclusive };
    }

    /// Moves the cursor, or applies the pending operator, for a motion.
    fn applyMotion(self: *VimEditor, t: Target, force_ring: bool) !void {
        if (t.jump) try self.setPcmark();
        if (self.pend.op) |op| {
            try self.opMotion(op, t, force_ring);
            self.finishCmd(op.isChange());
            return;
        }
        if (self.mode.isVisual()) {
            // Visual mode (selection=inclusive) lets the cursor sit on the end
            // of line: `l` past the last char, `$`, and j/k with a column
            // wanted beyond the line end.
            var p = t.pos;
            const len = self.buffer.lineLen(p.row);
            if (t.want_max) {
                p.col = len;
            } else if (t.keep_want) {
                p.col = if (self.curswant == max_col) len else vcol.byteAtOrEnd(self.buffer.getLine(p.row), self.curswant, self.opts.tabstop);
            } else if (!t.past_eol) p = self.clampToText(p);
            self.cursor = p;
        } else {
            self.cursor = t.pos;
            self.clampNormal();
        }
        if (!t.keep_want) {
            if (t.want_max) self.curswant = max_col else self.setWant();
        }
        if (t.beep and self.replay_depth > 0) self.abort = true;
        self.finishCmd(false);
    }

    fn opMotion(self: *VimEditor, op: Op, t: Target, force_ring: bool) !void {
        var a = self.cursor;
        var b = t.pos;
        self.markUndoPos(Pos.min(a, b));
        if (t.kind == .linewise) {
            const r = OpRange{ .start = .{ .row = @min(a.row, b.row) }, .end = .{ .row = @max(a.row, b.row) }, .linewise = true };
            return self.applyOp(op, r, .{ .force_ring = force_ring, .motion = true });
        }
        if (b.lessThan(a)) std.mem.swap(Pos, &a, &b);
        return self.applyOp(op, self.charRange(a, b, t.kind), .{ .force_ring = force_ring, .motion = true });
    }

    /// Converts a motion range to an OpRange, applying Vim's rule for an
    /// exclusive motion that ends in column 0 of a later line.
    fn charRange(self: *const VimEditor, a: Pos, b0: Pos, kind0: Kind) OpRange {
        var b = b0;
        var kind = kind0;
        if (kind == .exclusive and b.col == 0 and b.row > a.row) {
            if (a.col <= self.buffer.firstNonBlank(a.row)) {
                return .{ .start = .{ .row = a.row }, .end = .{ .row = b.row - 1 }, .linewise = true };
            }
            b.row -= 1;
            b.col = self.buffer.lineLen(b.row);
            if (b.col > 0) {
                b.col -= 1;
                kind = .inclusive;
            }
        }
        if (kind == .inclusive) b.col = @min(b.col + 1, self.buffer.lineLen(b.row));
        return .{ .start = a, .end = b, .linewise = false };
    }

    // -- text objects -----------------------------------------------------

    fn textObject(self: *VimEditor, c: u8, around: bool) !void {
        const buf = &self.buffer;
        const count = @max(self.pend.count0(), 1);
        const visual = self.mode.isVisual();
        const extend = visual and self.vis_anchor.lessThan(self.cursor);
        if (visual and c == 'p' and self.vis_anchor.row != self.cursor.row) return self.extendParagraph(count, around);
        if (c == 't') {
            const r = try tag.object(self.allocator, buf, self.cursor, if (visual) self.vis_anchor else null, count, around) orelse return self.fail();
            if (visual) {
                self.vis_anchor = r.anchor;
                self.mode = .visual;
                self.cursor = r.cursor;
                if (r.cursor.col >= buf.lineLen(r.cursor.row) and r.cursor.col > 0) {
                    self.curswant = max_col;
                } else self.setWant();
                self.pend = .{};
                return;
            }
            const op = self.pend.op.?;
            self.markUndoPos(r.obj.start);
            // An exclusive end at a closing tag on its own line keeps the
            // line break before it (no end adjustment, as in Vim).
            const tr: OpRange = if (r.obj.kind == .exclusive)
                .{ .start = r.obj.start, .end = r.obj.end, .linewise = false }
            else
                self.charRange(r.obj.start, r.obj.end, r.obj.kind);
            try self.applyOp(op, tr, .{ .motion = true });
            return self.finishCmd(op.isChange());
        }
        if (c == 's') {
            if (visual and !self.vis_anchor.equals(self.cursor)) {
                self.cursor = self.clampToText(sentence.extend(buf, self.vis_anchor, self.cursor, count, around));
                self.setWant();
                self.pend = .{};
                return;
            }
            const so = sentence.object(buf, self.cursor, count, around);
            if (visual) {
                self.vis_anchor = so.obj.start;
                if (self.mode != .visual) self.mode = .visual;
                self.cursor = self.clampToText(so.last);
                self.setWant();
                self.pend = .{};
                return;
            }
            const op = self.pend.op.?;
            self.markUndoPos(so.obj.start);
            try self.applyOp(op, self.charRange(so.obj.start, so.obj.end, so.obj.kind), .{ .motion = true });
            return self.finishCmd(op.isChange());
        }
        // A Visual selection of more than one char grows block objects.
        const sel: ?[2]Pos = if (visual and !self.vis_anchor.equals(self.cursor))
            .{ Pos.min(self.vis_anchor, self.cursor), Pos.max(self.vis_anchor, self.cursor) }
        else
            null;
        const obj: ?textobj.Obj = switch (c) {
            'w' => textobj.word(buf, self.cursor, count, around, false, extend),
            'W' => textobj.word(buf, self.cursor, count, around, true, extend),
            '"', '\'', '`' => textobj.quote(buf, self.cursor, count, around, c),
            '(', ')', 'b' => textobj.blockSel(buf, self.cursor, count, around, '(', ')', sel),
            '[', ']' => textobj.blockSel(buf, self.cursor, count, around, '[', ']', sel),
            '{', '}', 'B' => textobj.blockSel(buf, self.cursor, count, around, '{', '}', sel),
            '<', '>' => textobj.blockSel(buf, self.cursor, count, around, '<', '>', sel),
            'p' => textobj.paragraph(buf, self.cursor, count, around),
            else => null,
        };
        var o = obj orelse return self.fail();
        // `iw` on an empty last line ends before it starts (Vim's
        // current_word backs up a line); the operator takes the range
        // between the two, as in Vim.
        if (o.end.lessThan(o.start)) std.mem.swap(Pos, &o.start, &o.end);
        if (visual) {
            // Vipip: a one-line area at the cursor extends instead.
            if (c == 'p' and self.mode == .visual_line and o.start.row == self.cursor.row) return self.extendParagraph(count, around);
            if (o.kind == .linewise) {
                self.mode = .visual_line;
                self.vis_anchor = .{ .row = o.start.row };
                self.cursor = .{ .row = o.end.row };
                self.curswant = 0;
            } else {
                const is_block = std.mem.indexOfScalar(u8, "()b[]{}B<>", c) != null;
                if (!extend or (is_block and sel != null)) self.vis_anchor = o.start;
                if (self.mode == .visual_line) self.mode = .visual;
                var e = o.end;
                var eol = false;
                if (o.kind == .exclusive and !e.equals(o.start)) {
                    if (e.col == 0 and e.row > o.start.row) {
                        // The line break is selected: the cursor sits on the
                        // end of the previous line, as in Vim. (Via a temp:
                        // `e = .{ .row = e.row - 1, .. e.row ..}` would read
                        // the row it just wrote.)
                        const prev = e.row - 1;
                        e = .{ .row = prev, .col = buf.lineLen(prev) };
                        eol = true;
                    } else e.col -= 1;
                }
                self.cursor = if (eol) e else self.clampToText(e);
                if (eol) self.curswant = max_col else self.setWant();
            }
            self.pend = .{};
            return;
        }
        const op = self.pend.op.?;
        self.markUndoPos(o.start);
        const r: OpRange = switch (o.kind) {
            .linewise => .{ .start = o.start, .end = o.end, .linewise = true },
            else => self.charRange(o.start, o.end, o.kind),
        };
        try self.applyOp(op, r, .{ .motion = true });
        self.finishCmd(op.isChange());
    }

    fn extendParagraph(self: *VimEditor, count: usize, around: bool) !void {
        const r = textobj.paragraphExtend(&self.buffer, self.cursor.row, self.vis_anchor.row, count, around);
        self.cursor = .{ .row = r.row };
        self.curswant = 0;
        self.pend = .{};
        if (!r.ok) self.fail();
    }

    // -- operators --------------------------------------------------------

    const OpFlags = struct { force_ring: bool = false, motion: bool = false, times: usize = 1 };

    fn applyOp(self: *VimEditor, op: Op, r0: OpRange, flags: OpFlags) !void {
        var r = r0;
        const buf = &self.buffer;
        const hold = buf.u_hold;
        buf.u_hold = hold or r.end.row > r.start.row;
        defer buf.u_hold = hold;
        const reg = self.pend.reg;
        // d{motion} across lines with only blanks around becomes linewise.
        if (op == .delete and flags.motion and !r.linewise and r.end.row > r.start.row and
            r.start.col <= buf.firstNonBlank(r.start.row) and
            isBlankFrom(buf.getLine(r.end.row), r.end.col))
        {
            const rows = .{ r.start.row, r.end.row };
            r = .{ .start = .{ .row = rows[0] }, .end = .{ .row = rows[1] }, .linewise = true };
        }
        switch (op) {
            .yank => {
                const text = try self.rangeText(r);
                defer self.allocator.free(text);
                if (!r.linewise and text.len == 0) return;
                try self.regs.yank(reg, text, r.linewise);
                if (r.linewise) {
                    self.cursor.row = r.start.row;
                    self.clampNormal();
                } else self.cursor = r.start;
                if (r.linewise and r.end.row - r.start.row >= 2) self.statusFmt("{d} lines yanked", .{r.end.row - r.start.row + 1});
            },
            .delete => {
                const text = try self.rangeText(r);
                defer self.allocator.free(text);
                if (!r.linewise and text.len == 0) return;
                try self.regs.delete(reg, text, r.linewise, flags.force_ring);
                if (r.linewise) {
                    try buf.deleteLines(r.start.row, r.end.row);
                    self.gotoLine(r.start.row);
                    if (r.end.row - r.start.row >= 2) self.statusFmt("{d} fewer lines", .{r.end.row - r.start.row + 1});
                } else {
                    try buf.deleteRange(r.start, r.end);
                    self.cursor = r.start;
                }
            },
            .change => {
                const text = try self.rangeText(r);
                defer self.allocator.free(text);
                var ai: ?usize = null;
                if (r.linewise) {
                    try self.regs.delete(reg, text, true, flags.force_ring);
                    var indent_buf: [256]u8 = undefined;
                    const ind = if (self.opts.autoindent) copyIndent(&indent_buf, buf.indent(r.start.row)) else "";
                    if (r.end.row > r.start.row) try buf.deleteLines(r.start.row + 1, r.end.row);
                    try buf.setLine(r.start.row, ind);
                    self.cursor = .{ .row = r.start.row, .col = ind.len };
                    if (ind.len > 0) ai = r.start.row;
                } else {
                    if (text.len > 0) try self.regs.delete(reg, text, false, flags.force_ring);
                    try buf.deleteRange(r.start, r.end);
                    self.cursor = r.start;
                }
                try self.beginInsert(1, false);
                self.ins.ai_row = ai;
                return;
            },
            .indent, .outdent => {
                const last = lastRowOf(r);
                var row = r.start.row;
                while (row <= last) : (row += 1) try self.shiftLine(row, op == .indent, flags.times);
                self.gotoLine(r.start.row);
                const nlines = last - r.start.row + 1;
                if (nlines >= 3) self.statusFmt("{d} lines {s}ed {d} time{s}", .{ nlines, if (op == .indent) ">" else "<", flags.times, if (flags.times == 1) "" else "s" });
            },
            .format, .format_keep => {
                const keep = format.textIndex(&self.buffer, self.cursor);
                const first = r.start.row;
                const end_row = try format.format(self, first, lastRowOf(r));
                // gq: on the last formatted line; gw: where the cursor was.
                if (op == .format) self.gotoLine(end_row) else {
                    self.cursor = format.textPos(&self.buffer, keep);
                    self.clampNormal();
                }
            },
            .reindent => {
                const last = lastRowOf(r);
                try format.reindent(self, r.start.row, last);
                self.gotoLine(r.start.row);
            },
            .lower, .upper, .toggle => {
                const start = if (r.linewise) Pos{ .row = r.start.row } else r.start;
                const end = if (r.linewise) Pos{ .row = r.end.row, .col = buf.lineLen(r.end.row) } else r.end;
                var row = start.row;
                while (row <= end.row and row <= buf.lastRow()) : (row += 1) {
                    const line = buf.getLine(row);
                    const a = if (row == start.row) start.col else 0;
                    const b = if (row == end.row) @min(end.col, line.len) else line.len;
                    if (a >= b) continue;
                    const tmp = try self.allocator.dupe(u8, line[a..b]);
                    defer self.allocator.free(tmp);
                    for (tmp) |*ch| ch.* = caseOp(op, ch.*);
                    if (!std.mem.eql(u8, tmp, line[a..b])) try buf.replaceInLine(row, a, b, tmp);
                }
                // Linewise: Vim leaves the cursor at the start of the operated
                // range, which for g~~ is the first non-blank if that is left of it.
                const col = if (r.start.row == r.end.row) @min(self.cursor.col, buf.firstNonBlank(r.start.row)) else self.cursor.col;
                self.cursor = if (r.linewise) .{ .row = r.start.row, .col = col } else r.start;
            },
        }
        // After <C-o>{op} the cursor may stay past the end (Vim's restart_edit).
        if (self.ins.ctrl_o) self.cursor = buf.clampPos(self.cursor) else self.clampNormal();
        self.setWant();
    }

    fn rangeText(self: *VimEditor, r: OpRange) ![]u8 {
        if (r.linewise) return self.buffer.copyLines(self.allocator, r.start.row, @min(r.end.row, self.buffer.lastRow()));
        return self.buffer.copyRange(self.allocator, r.start, r.end);
    }

    fn lastRowOf(r: OpRange) usize {
        if (r.linewise) return r.end.row;
        if (r.end.col == 0 and r.end.row > r.start.row) return r.end.row - 1;
        return r.end.row;
    }

    fn isBlankFrom(line: []const u8, col: usize) bool {
        if (col >= line.len) return true;
        for (line[col..]) |c| if (!classify.isBlank(c)) return false;
        return true;
    }

    fn copyIndent(out: *[256]u8, ind: []const u8) []const u8 {
        const n = @min(ind.len, out.len);
        @memcpy(out[0..n], ind[0..n]);
        return out[0..n];
    }

    pub fn caseOp(op: Op, c: u8) u8 {
        return switch (op) {
            .lower => std.ascii.toLower(c),
            .upper => std.ascii.toUpper(c),
            else => if (std.ascii.isLower(c)) std.ascii.toUpper(c) else if (std.ascii.isUpper(c)) std.ascii.toLower(c) else c,
        };
    }

    fn indentWidth(ind: []const u8) usize {
        var w: usize = 0;
        for (ind) |c| w = if (c == '\t') (w / 8 + 1) * 8 else w + 1;
        return w;
    }

    pub fn makeIndent(self: *const VimEditor, out: []u8, width: usize) []const u8 {
        var n: usize = 0;
        var w = width;
        if (!self.opts.expandtab) {
            while (w >= 8 and n < out.len) : (w -= 8) {
                out[n] = '\t';
                n += 1;
            }
        }
        while (w > 0 and n < out.len) : (w -= 1) {
            out[n] = ' ';
            n += 1;
        }
        return out[0..n];
    }

    /// >> / << on one row, `times` shiftwidths (empty rows are left alone).
    pub fn shiftLine(self: *VimEditor, row: usize, right: bool, times: usize) !void {
        const line = self.buffer.getLine(row);
        if (line.len == 0) return;
        const fnb = self.buffer.firstNonBlank(row);
        const sw = self.opts.shiftwidth;
        const w = indentWidth(line[0..fnb]);
        const nw = if (right) w + sw * times else w -| sw * times;
        return self.setIndentWidth(row, nw);
    }

    /// Insert-mode <C-t>/<C-d>: one shiftwidth, rounded to a multiple of it.
    fn shiftLineRound(self: *VimEditor, row: usize, right: bool) !void {
        const sw = self.opts.shiftwidth;
        const w = indentWidth(self.buffer.indent(row));
        const nw = if (right) (w / sw + 1) * sw else if (w % sw != 0) w / sw * sw else w -| sw;
        return self.setIndentWidth(row, nw);
    }

    fn setIndentWidth(self: *VimEditor, row: usize, nw: usize) !void {
        const line = self.buffer.getLine(row);
        const fnb = self.buffer.firstNonBlank(row);
        var tmp: [512]u8 = undefined;
        const ind = self.makeIndent(&tmp, nw);
        if (std.mem.eql(u8, ind, line[0..fnb])) return;
        try self.buffer.replaceInLine(row, 0, fnb, ind);
    }

    // -- simple commands ----------------------------------------------------

    fn commandChar(self: *VimEditor, c: u8) !void {
        const p = &self.pend;
        const k = VimKey{ .char = c };
        const count0 = p.count0();
        const n: usize = @max(count0, 1);
        switch (c) {
            'x', 'X', 's', 'D', 'C', 'Y', 'S' => {
                p.pushKey(k);
                p.op = switch (c) {
                    'x', 'X', 'D' => .delete,
                    's', 'C', 'S' => .change,
                    else => .yank,
                };
                if (c == 'S') return self.lineOp(.change);
                const m: Mo = switch (c) {
                    'x', 's' => .l,
                    'X' => .h,
                    else => .dollar,
                };
                return self.motionCmd(m, null);
            },
            'i', 'a', 'I', 'A', 'o', 'O' => {
                p.pushKey(k);
                const len = self.buffer.lineLen(self.cursor.row);
                switch (c) {
                    'a' => if (len > 0) {
                        self.cursor.col = @min(self.cursor.col + 1, len);
                    },
                    'I' => self.cursor.col = self.buffer.firstNonBlank(self.cursor.row),
                    'A' => self.cursor.col = len,
                    'o', 'O' => {
                        try self.openLine(c == 'o');
                        const ai = self.ins.ai_row;
                        try self.beginInsert(count0, true);
                        self.ins.ai_row = ai;
                        return self.finishCmd(true);
                    },
                    else => {},
                }
                try self.beginInsert(count0, false);
                self.finishCmd(true);
            },
            'R' => {
                p.pushKey(k);
                try self.beginInsert(count0, false);
                self.mode = .replace;
                self.finishCmd(true);
            },
            'v', 'V' => {
                self.vis_anchor = self.cursor;
                self.mode = if (c == 'v') .visual else .visual_line;
                self.pend = .{};
            },
            'p', 'P' => {
                p.pushKey(k);
                if (!try self.put(p.reg, n, c == 'P')) return self.fail();
                self.finishCmd(true);
            },
            'J' => {
                p.pushKey(k);
                if (!try self.joinLines(self.cursor.row, @max(count0, 2), true)) return self.fail();
                self.finishCmd(true);
            },
            '~' => {
                p.pushKey(k);
                const len = self.buffer.lineLen(self.cursor.row);
                if (len == 0) return self.fail();
                const a = self.cursor.col;
                const b = @min(a + n, len);
                const tmp = try self.allocator.dupe(u8, self.buffer.getLine(self.cursor.row)[a..b]);
                defer self.allocator.free(tmp);
                for (tmp) |*ch| ch.* = caseOp(.toggle, ch.*);
                try self.buffer.replaceInLine(self.cursor.row, a, b, tmp);
                self.cursor.col = @min(b, len - 1);
                self.setWant();
                self.finishCmd(true);
            },
            'r' => {
                p.await_ = .replace;
                p.pushKey(k);
                p.show(k);
            },
            'm' => {
                p.await_ = .mark_set;
                p.show(k);
            },
            'u' => {
                try self.undoRedo(true);
                self.finishCtrlO();
            },
            'U' => {
                try self.lineUndo();
                self.finishCtrlO();
            },
            '.' => {
                try self.dotRepeat();
                self.finishCtrlO();
            },
            'q' => {
                if (self.rec_reg) |r| {
                    // The 'q' that stops recording was logged; drop it.
                    if (self.rec_buf.items.len > 0) _ = self.rec_buf.pop();
                    try self.regs.set(r, self.rec_buf.items, false);
                    self.rec_reg = null;
                    self.pend = .{};
                    return;
                }
                p.await_ = .q_reg;
                p.show(k);
            },
            '@' => {
                p.await_ = .at_reg;
                p.show(k);
            },
            ':' => {
                var tmp: [24]u8 = undefined;
                const pre = if (count0 > 1) std.fmt.bufPrint(&tmp, ".,.+{d}", .{count0 - 1}) catch "" else "";
                self.startCmdline(':', pre);
            },
            '&' => {
                self.pend = .{};
                try ex.execute(self, "s");
                self.finishCmd(false);
            },
            else => self.fail(),
        }
    }

    /// g- / g+ (and :earlier / :later): through the undo states in the
    /// order they were made, across branches.
    pub fn undoTravel(self: *VimEditor, back: bool, count: usize) !void {
        const n: isize = @intCast(@max(count, 1));
        self.pend = .{};
        self.commitUndo();
        const p = try self.history.travel(&self.buffer, if (back) -n else n) orelse {
            self.setStatus(if (back) "Already at oldest change" else "Already at newest change");
            return self.fail();
        };
        if (back) self.st.undos +|= 1;
        self.cursor = p;
        self.clampNormal();
        self.setWant();
    }

    /// U: undo the latest changes on the last changed line. It is a change
    /// itself (u undoes it, U again redoes them).
    fn lineUndo(self: *VimEditor) !void {
        self.pend = .{};
        const row = self.buffer.u_row orelse return self.fail();
        if (row > self.buffer.lastRow()) return self.fail();
        const saved = try self.allocator.dupe(u8, self.buffer.u_text.items);
        defer self.allocator.free(saved);
        const col = self.buffer.u_col;
        if (self.cursor.row == row) self.buffer.u_col = self.cursor.col;
        self.buffer.u_text.clearRetainingCapacity();
        try self.buffer.u_text.appendSlice(self.allocator, self.buffer.getLine(row));
        try self.buffer.setLine(row, saved);
        self.cursor = .{ .row = row, .col = col };
        self.clampNormal();
        self.setWant();
    }

    pub fn undoRedo(self: *VimEditor, is_undo: bool) !void {
        const n: usize = @max(self.pend.count0(), 1);
        self.pend = .{};
        self.commitUndo();
        var i: usize = 0;
        var pos: ?Pos = null;
        while (i < n) : (i += 1) {
            const p = (if (is_undo) try self.history.undo(&self.buffer) else try self.history.redo(&self.buffer)) orelse break;
            pos = p;
            if (is_undo) self.st.undos +|= 1;
        }
        if (pos) |p| {
            self.cursor = p;
            self.clampNormal();
            self.setWant();
        } else {
            self.setStatus(if (is_undo) "Already at oldest change" else "Already at newest change");
            self.fail();
        }
    }

    /// p / P. Returns false when the register is empty.
    pub fn put(self: *VimEditor, reg: ?u8, count: usize, before: bool) !bool {
        const r = self.regs.get(reg) orelse return false;
        if (r.kind == .block) {
            const text = try self.allocator.dupe(u8, r.slice());
            defer self.allocator.free(text);
            try block.put(self, text, r.width, count, before);
            return true;
        }
        const linewise = r.isLinewise();
        if (!linewise and r.slice().len == 0) {
            self.setStatus("E353: Nothing in register");
            return false;
        }
        var all = std.ArrayList(u8).empty;
        defer all.deinit(self.allocator);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (linewise and i > 0) try all.append(self.allocator, '\n');
            try all.appendSlice(self.allocator, r.slice());
        }
        if (linewise) {
            const row = if (before) self.cursor.row else self.cursor.row + 1;
            try self.buffer.insertLines(row, all.items);
            self.gotoLine(row);
            const nl = std.mem.count(u8, all.items, "\n") + 1;
            if (nl >= 3) self.statusFmt("{d} more lines", .{nl});
            return true;
        }
        const len = self.buffer.lineLen(self.cursor.row);
        const col = if (before or len == 0) self.cursor.col else self.cursor.col + 1;
        const start = Pos{ .row = self.cursor.row, .col = @min(col, len) };
        const end = try self.buffer.insertText(start, all.items);
        self.cursor = if (std.mem.indexOfScalar(u8, all.items, '\n') == null) .{ .row = end.row, .col = end.col - 1 } else start;
        self.clampNormal();
        self.setWant();
        return true;
    }

    /// J / gJ over `n0` lines starting at `row`.
    pub fn joinLines(self: *VimEditor, row: usize, n0: usize, spaces: bool) !bool {
        self.buffer.u_hold = true;
        defer self.buffer.u_hold = false;
        const last = self.buffer.lastRow();
        var n = @max(n0, 2);
        if (row + n - 1 > last) {
            if (row >= last) return false;
            n = last - row + 1;
        }
        var col: usize = 0;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const cur = self.buffer.getLine(row);
            const next = self.buffer.getLine(row + 1);
            var rest = next;
            var sep: []const u8 = "";
            if (spaces) {
                rest = next[firstNonBlankOf(next)..];
                if (rest.len > 0 and rest[0] != ')' and cur.len > 0 and !classify.isBlank(cur[cur.len - 1])) sep = " ";
            }
            col = cur.len;
            const strip = next.len - rest.len;
            try self.buffer.deleteRange(.{ .row = row, .col = cur.len }, .{ .row = row + 1, .col = strip });
            if (sep.len > 0) _ = try self.buffer.insertText(.{ .row = row, .col = col }, sep);
            if (sep.len == 0 and rest.len == 0 and col > 0) col -= 1;
        }
        self.cursor = .{ .row = row, .col = col };
        self.clampNormal();
        self.setWant();
        return true;
    }

    fn firstNonBlankOf(line: []const u8) usize {
        var i: usize = 0;
        while (i < line.len and classify.isBlank(line[i])) i += 1;
        return i;
    }

    /// r{c} with a count; r<CR> replaces the chars with one line break.
    fn replaceChars(self: *VimEditor, c: u8) !void {
        const n: usize = @max(self.pend.count0(), 1);
        const row = self.cursor.row;
        const len = self.buffer.lineLen(row);
        const col = self.cursor.col;
        if (col + n > len) return self.fail();
        if (c == '\r') {
            try self.buffer.deleteRange(.{ .row = row, .col = col }, .{ .row = row, .col = col + n });
            var tmp: [256]u8 = undefined;
            const ind = if (self.opts.autoindent) copyIndent(&tmp, self.buffer.indent(row)) else "";
            // Blanks after the break are replaced by the indent.
            const line = self.buffer.getLine(row);
            var e = col;
            while (e < line.len and classify.isBlank(line[e])) e += 1;
            if (e > col) try self.buffer.deleteRange(.{ .row = row, .col = col }, .{ .row = row, .col = e });
            _ = try self.buffer.insertText(.{ .row = row, .col = col }, "\n");
            if (ind.len > 0) _ = try self.buffer.insertText(.{ .row = row + 1 }, ind);
            // Vim runs r<CR> as an insert, so the closing Esc steps left.
            self.cursor = .{ .row = row + 1, .col = ind.len -| 1 };
        } else {
            var tmp: [constants.MAX_VIM_COUNT]u8 = undefined;
            @memset(tmp[0..n], c);
            try self.buffer.replaceInLine(row, col, col + n, tmp[0..n]);
            self.cursor.col = col + n - 1;
        }
        self.clampNormal();
        self.setWant();
        self.finishCmd(true);
    }

    /// <C-a>/<C-x>: add to the (decimal or 0x hex) number at or after the
    /// cursor.
    fn addNumber(self: *VimEditor, delta: i64) !bool {
        const row = self.cursor.row;
        const line = self.buffer.getLine(row);
        if (line.len == 0) return false;
        var col = @min(self.cursor.col, line.len - 1);
        var hex = false;
        var start: usize = 0;
        if (std.ascii.isHex(line[col])) {
            var h = col;
            while (h > 0 and std.ascii.isHex(line[h - 1])) h -= 1;
            if (h >= 2 and (line[h - 1] == 'x' or line[h - 1] == 'X') and line[h - 2] == '0') {
                hex = true;
                start = h;
            }
        } else if ((line[col] == 'x' or line[col] == 'X') and col > 0 and line[col - 1] == '0' and col + 1 < line.len and std.ascii.isHex(line[col + 1])) {
            hex = true;
            start = col + 1;
        }
        if (!hex) {
            if (!std.ascii.isDigit(line[col])) {
                while (col < line.len and !std.ascii.isDigit(line[col])) col += 1;
                if (col >= line.len) return false;
            }
            start = col;
            while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
            if (line[start] == '0' and start + 2 < line.len and (line[start + 1] == 'x' or line[start + 1] == 'X') and std.ascii.isHex(line[start + 2])) {
                hex = true;
                start += 2;
            }
        }
        var end = start;
        if (hex) {
            while (end < line.len and std.ascii.isHex(line[end])) end += 1;
            const v = std.fmt.parseInt(u64, line[start..end], 16) catch return false;
            const nv: u64 = if (delta >= 0) v +% @as(u64, @intCast(delta)) else v -% @as(u64, @intCast(-delta));
            var upper = false;
            for (line[start..end]) |ch| {
                if (ch >= 'A' and ch <= 'F') upper = true;
            }
            var tmp: [32]u8 = undefined;
            var out: []const u8 = if (upper) std.fmt.bufPrint(&tmp, "{X}", .{nv}) catch return false else std.fmt.bufPrint(&tmp, "{x}", .{nv}) catch return false;
            var padded: [32]u8 = undefined;
            const width = end - start;
            if (out.len < width) {
                @memset(padded[0 .. width - out.len], '0');
                @memcpy(padded[width - out.len .. width], out);
                out = padded[0..width];
            }
            try self.buffer.replaceInLine(row, start, end, out);
            self.cursor.col = start + out.len - 1;
        } else {
            while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
            const neg = start > 0 and line[start - 1] == '-';
            const v = std.fmt.parseInt(i64, line[start..end], 10) catch std.math.maxInt(i64);
            const nv = (if (neg) -v else v) +| delta;
            var tmp: [48]u8 = undefined;
            // Leading zeros keep the digit count (Vim, nrformats without octal).
            const width = if (line[start] == '0') end - start else 0;
            const mag = @abs(nv);
            const out = (if (nv < 0)
                std.fmt.bufPrint(&tmp, "-{d:0>[1]}", .{ mag, width })
            else
                std.fmt.bufPrint(&tmp, "{d:0>[1]}", .{ mag, width })) catch return false;
            const s = if (neg) start - 1 else start;
            try self.buffer.replaceInLine(row, s, end, out);
            self.cursor.col = s + out.len - 1;
        }
        self.setWant();
        return true;
    }

    // -- visual mode -------------------------------------------------------

    pub fn exitVisual(self: *VimEditor) void {
        self.last_visual = .{ .anchor = self.vis_anchor, .cursor = self.cursor, .mode = self.mode, .eol = self.curswant == max_col };
        self.mode = .normal;
        self.clampNormal();
    }

    pub fn visualRange(self: *const VimEditor) OpRange {
        const a = Pos.min(self.vis_anchor, self.cursor);
        const b = Pos.max(self.vis_anchor, self.cursor);
        if (self.mode == .visual_line) return .{ .start = .{ .row = a.row }, .end = .{ .row = b.row }, .linewise = true };
        const len = self.buffer.lineLen(b.row);
        const eol = (self.curswant == max_col and self.cursor.row == b.row) or b.col >= len;
        const end: Pos = if (eol)
            (if (b.row < self.buffer.lastRow()) Pos{ .row = b.row + 1 } else Pos{ .row = b.row, .col = len })
        else
            .{ .row = b.row, .col = b.col + 1 };
        return .{ .start = a, .end = end, .linewise = false };
    }

    /// Records a visual change for `.` as an equivalent selection + keys.
    fn visualDot(self: *VimEditor, r: OpRange, keys: []const VimKey) !void {
        self.dot_build.clearRetainingCapacity();
        const lines = r.end.row - r.start.row;
        if (r.linewise) {
            try self.dot_build.append(self.allocator, .{ .char = 'V' });
            if (lines > 0) try self.appendCountKey(lines, 'j');
        } else {
            try self.dot_build.append(self.allocator, .{ .char = 'v' });
            if (r.end.row > r.start.row and r.end.col == 0) {
                if (lines > 1) try self.appendCountKey(lines - 1, 'j');
                try self.dot_build.append(self.allocator, .{ .char = '$' });
            } else if (lines > 0) {
                try self.appendCountKey(lines, 'j');
            } else if (r.end.col > r.start.col + 1) {
                try self.appendCountKey(r.end.col - r.start.col - 1, 'l');
            }
        }
        try self.dot_build.appendSlice(self.allocator, keys);
        self.dot_build_count = 0;
        self.dot_build_reg = self.pend.reg;
    }

    pub fn appendCountKey(self: *VimEditor, n: usize, k: u8) !void {
        var tmp: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
        for (s) |d| try self.dot_build.append(self.allocator, .{ .char = d });
        try self.dot_build.append(self.allocator, .{ .char = k });
    }

    pub fn commitVisualDot(self: *VimEditor) !void {
        if (self.mode == .insert or self.mode == .replace) {
            self.dot_rec = true;
            return;
        }
        std.mem.swap(std.ArrayList(VimKey), &self.dot_keys, &self.dot_build);
        self.dot_build.clearRetainingCapacity();
        self.dot_count = 0;
        self.dot_reg = self.dot_build_reg;
    }

    fn visualOp(self: *VimEditor, op: Op, force_line: bool) !void {
        if (self.mode == .visual_block and !force_line and op != .format and op != .format_keep and op != .reindent) return block.op(self, op);
        var r = self.visualRange();
        if (force_line) {
            const first = r.start.row;
            const last = lastRowOf(r);
            r = .{ .start = .{ .row = first }, .end = .{ .row = last }, .linewise = true };
        }
        const times: usize = @max(self.pend.count0(), 1);
        // Vim's operator start: the anchor (column 0 in V mode) or the cursor.
        const anchor: Pos = if (self.mode == .visual_line) .{ .row = self.vis_anchor.row } else self.vis_anchor;
        self.markUndoPos(if (self.cursor.lessThan(anchor)) self.cursor else anchor);
        if (op.isChange()) {
            const key: []const VimKey = switch (op) {
                .delete => &.{.{ .char = 'd' }},
                .change => &.{.{ .char = 'c' }},
                .indent => &.{.{ .char = '>' }},
                .outdent => &.{.{ .char = '<' }},
                .lower => &.{.{ .char = 'u' }},
                .upper => &.{.{ .char = 'U' }},
                .reindent => &.{.{ .char = '=' }},
                .format => &.{ .{ .char = 'g' }, .{ .char = 'q' } },
                .format_keep => &.{ .{ .char = 'g' }, .{ .char = 'w' } },
                else => &.{.{ .char = '~' }},
            };
            var ks: [16]VimKey = undefined;
            var n: usize = 0;
            if (force_line) {
                ks[0] = .{ .char = 'V' };
                ks[1] = .{ .char = 'V' };
                n = 2;
            } else if (times > 1) {
                var tmp: [12]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{times}) catch "";
                for (s) |d| {
                    ks[n] = .{ .char = d };
                    n += 1;
                }
            }
            @memcpy(ks[n..][0..key.len], key);
            try self.visualDot(r, ks[0 .. n + key.len]);
        }
        self.exitVisual();
        try self.applyOp(op, r, .{ .times = times });
        if (op == .yank) self.cursor = if (r.linewise) .{ .row = r.start.row, .col = 0 } else r.start;
        if (op.isChange()) try self.commitVisualDot();
        self.pend = .{};
        if (self.mode == .normal) self.clampNormal();
        self.finishCtrlO();
    }

    fn visualJoin(self: *VimEditor, spaces: bool) !void {
        const r = self.visualRange();
        try self.visualDot(r, if (spaces) &.{.{ .char = 'J' }} else &.{ .{ .char = 'g' }, .{ .char = 'J' } });
        self.exitVisual();
        const last = lastRowOf(r);
        _ = try self.joinLines(r.start.row, @max(last - r.start.row + 1, 2), spaces);
        try self.commitVisualDot();
        self.pend = .{};
    }

    fn visualChar(self: *VimEditor, c: u8) !void {
        const p = &self.pend;
        switch (c) {
            'v', 'V' => {
                const want: Mode = if (c == 'v') .visual else .visual_line;
                if (self.mode == want) self.exitVisual() else self.mode = want;
                self.pend = .{};
            },
            'o', 'O' => {
                if (c == 'O' and self.mode == .visual_block) {
                    block.otherEnd(self);
                } else {
                    std.mem.swap(Pos, &self.vis_anchor, &self.cursor);
                    self.setWant();
                }
                self.pend = .{};
            },
            // In a block, C and D act from the block to each line end, X and
            // Y on the block (Vim's v_visop).
            'X', 'D', 'C', 'Y' => if (self.mode == .visual_block) {
                if (c == 'C' or c == 'D') self.curswant = max_col;
                return self.visualOp(switch (c) {
                    'C' => .change,
                    'Y' => .yank,
                    else => .delete,
                }, false);
            } else return self.visualOp(switch (c) {
                'C' => .change,
                'Y' => .yank,
                else => .delete,
            }, true),
            'x' => return self.visualOp(.delete, false),
            's' => return self.visualOp(.change, false),
            'S', 'R' => return self.visualOp(.change, true),
            '~' => return self.visualOp(.toggle, false),
            'u' => return self.visualOp(.lower, false),
            'U' => return self.visualOp(.upper, false),
            'J' => return self.visualJoin(true),
            'r' => {
                p.await_ = .replace;
                p.show(.{ .char = 'r' });
            },
            'p', 'P' => return self.visualPut(c == 'P'),
            ':' => {
                self.exitVisual();
                self.pend = .{};
                self.startCmdline(':', "'<,'>");
            },
            'I', 'A' => {
                if (self.mode == .visual_block) return block.insert(self, c == 'A');
                const r = self.visualRange();
                self.exitVisual();
                if (c == 'I') {
                    self.cursor = if (r.linewise) .{ .row = r.start.row, .col = self.buffer.firstNonBlank(r.start.row) } else r.start;
                } else {
                    const lr = lastRowOf(r);
                    self.cursor = if (r.linewise) .{ .row = lr, .col = self.buffer.lineLen(lr) } else r.end;
                }
                self.cursor = self.buffer.clampPos(self.cursor);
                self.pend = .{};
                try self.beginInsert(0, false);
            },
            else => self.fail(),
        }
    }

    fn visualReplace(self: *VimEditor, c: u8) !void {
        if (self.mode == .visual_block) return block.replace(self, c);
        const r = self.visualRange();
        try self.visualDot(r, &.{ .{ .char = 'r' }, if (c == '\r') .enter else .{ .char = c } });
        self.exitVisual();
        const start = if (r.linewise) Pos{ .row = r.start.row } else r.start;
        const end = if (r.linewise) Pos{ .row = r.end.row, .col = self.buffer.lineLen(r.end.row) } else r.end;
        var row = start.row;
        while (row <= end.row and row <= self.buffer.lastRow()) : (row += 1) {
            const len = self.buffer.lineLen(row);
            const a = if (row == start.row) start.col else 0;
            const b = if (row == end.row) @min(end.col, len) else len;
            if (a >= b) continue;
            const tmp = try self.allocator.alloc(u8, b - a);
            defer self.allocator.free(tmp);
            @memset(tmp, if (c == '\r') ' ' else c);
            try self.buffer.replaceInLine(row, a, b, tmp);
        }
        self.cursor = start;
        self.clampNormal();
        try self.commitVisualDot();
        self.pend = .{};
    }

    fn visualPut(self: *VimEditor, keep_reg: bool) !void {
        if (self.mode == .visual_block) return block.visualPut(self, keep_reg);
        const reg = self.pend.reg;
        const src = self.regs.get(reg) orelse return self.fail();
        const text = try self.allocator.dupe(u8, src.slice());
        defer self.allocator.free(text);
        const text_lw = src.isLinewise();
        const r = self.visualRange();
        try self.visualDot(r, &.{.{ .char = if (keep_reg) 'P' else 'p' }});
        self.exitVisual();
        const sel = try self.rangeText(r);
        defer self.allocator.free(sel);
        const whole = r.linewise and r.start.row == 0 and r.end.row >= self.buffer.lastRow();
        if (r.linewise) try self.buffer.deleteLines(r.start.row, r.end.row) else try self.buffer.deleteRange(r.start, r.end);
        if (!keep_reg) try self.regs.delete(null, sel, r.linewise, false);
        if (r.linewise and !text_lw and text.len == 0) {
            // An empty register only deletes the selection (Vim).
            self.gotoLine(@min(r.start.row, self.buffer.lastRow()));
        } else if (r.linewise) {
            if (whole) {
                _ = try self.buffer.insertText(.{}, text);
            } else try self.buffer.insertLines(r.start.row, text);
            self.gotoLine(r.start.row);
        } else if (text_lw) {
            _ = try self.buffer.insertText(r.start, "\n");
            try self.buffer.insertLines(r.start.row + 1, text);
            self.gotoLine(r.start.row + 1);
        } else {
            const end = try self.buffer.insertText(r.start, text);
            self.cursor = if (std.mem.indexOfScalar(u8, text, '\n') == null and text.len > 0) .{ .row = end.row, .col = end.col - 1 } else r.start;
            self.clampNormal();
        }
        try self.commitVisualDot();
        self.pend = .{};
    }

    // -- dot repeat and macros ---------------------------------------------

    /// Called when a normal-mode command completes: records it for `.`
    /// when it changed text, clears pending state, ends a <C-o> command.
    pub fn finishCmd(self: *VimEditor, change: bool) void {
        const p = self.pend;
        if (change and !self.ins.ctrl_o) {
            if (self.mode == .insert or self.mode == .replace) {
                self.dot_build.clearRetainingCapacity();
                self.dot_build.appendSlice(self.allocator, p.keys[0..p.n_keys]) catch {};
                self.dot_build_count = p.count0();
                self.dot_build_reg = p.reg;
                self.dot_rec = true;
            } else {
                self.dot_keys.clearRetainingCapacity();
                self.dot_keys.appendSlice(self.allocator, p.keys[0..p.n_keys]) catch {};
                self.dot_count = p.count0();
                self.dot_reg = p.reg;
            }
        }
        self.pend = .{};
        self.finishCtrlO();
    }

    pub fn finishCtrlO(self: *VimEditor) void {
        if (!self.ins.ctrl_o or self.mode != .normal or self.pend.active()) return;
        self.ins.ctrl_o = false;
        if (self.ins.ctrl_o_eol and self.cursor.col + 1 == self.buffer.lineLen(self.cursor.row)) self.cursor.col += 1;
        self.mode = .insert;
        self.ins.start = self.cursor;
        self.ins.orig = self.cursor;
    }

    fn dotRepeat(self: *VimEditor) !void {
        const count = self.pend.count0();
        self.pend = .{};
        if (self.dot_keys.items.len == 0) return self.fail();
        // A recorded change can contain `.` itself (i<C-o>.): don't recurse.
        if (self.in_dot) return self.fail();
        self.in_dot = true;
        defer self.in_dot = false;
        const keys = try self.allocator.dupe(VimKey, self.dot_keys.items);
        defer self.allocator.free(keys);
        const use_count = if (count > 0) count else self.dot_count;
        // Vim's "1p... : repeating with a numbered register uses the next one.
        if (self.dot_reg) |r| {
            if (r >= '1' and r < '9') self.dot_reg = r + 1;
        }
        const reg = self.dot_reg;
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        if (reg) |r| {
            try self.process(.{ .char = '"' });
            try self.process(.{ .char = r });
        }
        if (use_count > 0) {
            var tmp: [12]u8 = undefined;
            const digits = std.fmt.bufPrint(&tmp, "{d}", .{use_count}) catch "";
            // A visual repeat takes the count on its operator (after the
            // selection keys), not in front of `v`.
            if (!keys[0].eql(.{ .char = 'v' }) and !keys[0].eql(.{ .char = 'V' }) and !keys[0].eql(.{ .ctrl = 'v' })) {
                for (digits) |d| try self.process(.{ .char = d });
            }
        }
        for (keys) |k| try self.process(k);
        // An insert the repeat left open ends here.
        if (self.mode == .insert or self.mode == .replace) try self.leaveInsert(.internal);
    }

    fn runMacro(self: *VimEditor, c0: u8) !void {
        const count: usize = @max(self.pend.count0(), 1);
        self.pend = .{};
        const c = if (c0 == '@') self.last_macro orelse return self.fail() else c0;
        if (c == ':') {
            // `@:` repeats the last command line (and `@@` then does too).
            if (self.last_ex_len == 0) {
                self.setStatus("E30: No previous command line");
                return self.fail();
            }
            self.last_macro = ':';
            var buf: [256]u8 = undefined;
            const line = buf[0..self.last_ex_len];
            @memcpy(line, self.last_ex[0..self.last_ex_len]);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try ex.execute(self, line);
                if (self.failed) break;
            }
            if (self.mode == .normal) self.clampNormal();
            return self.finishCmd(false);
        }
        const r = self.regs.get(std.ascii.toLower(c)) orelse return self.fail();
        if (self.replay_depth >= max_macro_depth) {
            self.setStatus("E169: Command too recursive");
            return self.fail();
        }
        self.last_macro = c;
        const text = try self.allocator.dupe(u8, r.slice());
        defer self.allocator.free(text);
        const linewise = r.isLinewise();
        if (self.replay_depth == 0) self.abort = false;
        self.replay_depth += 1;
        defer self.replay_depth -= 1;
        var i: usize = 0;
        outer: while (i < count) : (i += 1) {
            var it = Notation.init(text);
            while (it.next()) |k| {
                try self.process(k);
                if (self.abort) break :outer;
            }
            if (linewise and self.mode == .normal) {
                try self.process(.enter);
                if (self.abort) break :outer;
            }
        }
        if (self.replay_depth == 1) self.abort = false;
    }

    // -- insert and replace mode -------------------------------------------

    fn openLine(self: *VimEditor, below: bool) !void {
        const row = self.cursor.row;
        var tmp: [256]u8 = undefined;
        const ind = if (self.opts.autoindent) copyIndent(&tmp, self.buffer.indent(row)) else "";
        const at = if (below) row + 1 else row;
        try self.buffer.insertLines(at, ind);
        self.buffer.clearLine();
        self.cursor = .{ .row = at, .col = ind.len };
        self.ins.ai_row = if (ind.len > 0) at else null;
    }

    pub fn beginInsert(self: *VimEditor, count: u32, open_line: bool) !void {
        self.mode = .insert;
        self.ins.start = self.cursor;
        self.ins.orig = self.cursor;
        self.ins.count = @max(count, 1);
        self.ins.open_line = open_line;
        self.ins.keys.clearRetainingCapacity();
        self.ins.replaced.clearRetainingCapacity();
        self.ins.await_reg = false;
        self.ins.ctrl_o = false;
        self.ins.ai_row = null;
        self.ins.block = null;
    }

    fn insertKey(self: *VimEditor, key0: VimKey) anyerror!void {
        const ins = &self.ins;
        if (ins.await_reg) {
            ins.await_reg = false;
            if (!ins.repeating) try ins.keys.append(self.allocator, key0);
            const c: u8 = switch (key0) {
                .char => |ch| ch,
                else => return,
            };
            const r = self.regs.get(c) orelse return;
            const text = try self.allocator.dupe(u8, r.slice());
            defer self.allocator.free(text);
            self.cursor = try self.buffer.insertText(self.cursor, text);
            if (r.isLinewise()) self.cursor = try self.buffer.insertText(self.cursor, "\n");
            ins.ai_row = null;
            return;
        }
        const key: VimKey = switch (key0) {
            .ctrl => |c| switch (c) {
                'c' => return self.leaveInsert(.ctrl_c),
                'h' => .backspace,
                'i' => .tab,
                'm', 'j' => .enter,
                else => key0,
            },
            .esc => return self.leaveInsert(.esc),
            else => key0,
        };
        const arrow = switch (key) {
            .up, .down, .left, .right, .home, .end, .word_left, .word_right, .doc_top, .doc_bottom, .page_up, .page_down => true,
            else => false,
        };
        if (arrow) return self.insertArrow(key);
        if (!ins.repeating) try ins.keys.append(self.allocator, key);
        switch (key) {
            .char => |c| {
                if (self.replay_depth == 0 and !ins.repeating) self.st.inserted +|= 1;
                try self.typeChar(c);
            },
            .tab => {
                if (self.opts.expandtab) {
                    const sw = self.opts.shiftwidth;
                    const w = indentWidth(self.buffer.getLine(self.cursor.row)[0..self.cursor.col]);
                    var tmp: [16]u8 = undefined;
                    const nsp = sw - (w % sw);
                    @memset(tmp[0..nsp], ' ');
                    self.cursor = try self.buffer.insertText(self.cursor, tmp[0..nsp]);
                } else self.cursor = try self.buffer.insertText(self.cursor, "\t");
                ins.ai_row = null;
            },
            .enter => try self.insertNewline(),
            .backspace => try self.backspace(.char),
            .delete => {
                const len = self.buffer.lineLen(self.cursor.row);
                if (self.cursor.col < len) {
                    try self.buffer.deleteRange(self.cursor, .{ .row = self.cursor.row, .col = self.cursor.col + 1 });
                } else if (self.cursor.row < self.buffer.lastRow()) {
                    try self.buffer.deleteRange(self.cursor, .{ .row = self.cursor.row + 1 });
                }
            },
            .ctrl => |c| switch (c) {
                'w' => try self.backspace(.word),
                'u' => try self.backspace(.line),
                't', 'd' => {
                    const row = self.cursor.row;
                    const old_fnb = self.buffer.firstNonBlank(row);
                    if (self.buffer.lineLen(row) == 0) {
                        if (c == 't') {
                            var tmp: [64]u8 = undefined;
                            _ = try self.buffer.insertText(.{ .row = row }, self.makeIndent(&tmp, self.opts.shiftwidth));
                        }
                    } else try self.shiftLineRound(row, c == 't');
                    const new_fnb = self.buffer.firstNonBlank(row);
                    const col = if (self.cursor.col >= old_fnb) self.cursor.col - old_fnb + new_fnb else new_fnb;
                    self.cursor.col = @min(col, self.buffer.lineLen(row));
                },
                'r' => ins.await_reg = true,
                'o' => {
                    ins.ctrl_o = true;
                    ins.ctrl_o_eol = self.cursor.col > 0 and self.cursor.col == self.buffer.lineLen(self.cursor.row);
                    self.mode = .normal;
                    if (ins.ctrl_o_eol) self.cursor.col -= 1;
                },
                'e', 'y' => {
                    const other = if (c == 'e') self.cursor.row + 1 else self.cursor.row -% 1;
                    if (other > self.buffer.lastRow()) return;
                    const l = self.buffer.getLine(other);
                    if (self.cursor.col >= l.len) return;
                    try self.typeChar(l[self.cursor.col]);
                },
                else => {},
            },
            else => {},
        }
    }

    fn typeChar(self: *VimEditor, c: u8) !void {
        const ins = &self.ins;
        ins.ai_row = null;
        if (self.mode == .replace) {
            const len = self.buffer.lineLen(self.cursor.row);
            if (self.cursor.col < len) {
                const orig = self.buffer.getLine(self.cursor.row)[self.cursor.col];
                try ins.replaced.append(self.allocator, orig);
                try self.buffer.replaceInLine(self.cursor.row, self.cursor.col, self.cursor.col + 1, &.{c});
                self.cursor.col += 1;
                return;
            }
            try ins.replaced.append(self.allocator, -1);
        }
        self.cursor = try self.buffer.insertText(self.cursor, &.{c});
    }

    fn insertNewline(self: *VimEditor) !void {
        const row = self.cursor.row;
        var tmp: [256]u8 = undefined;
        const line = self.buffer.getLine(row);
        const ind = if (self.opts.autoindent) copyIndent(&tmp, line[0..@min(firstNonBlankOf(line), self.cursor.col)]) else "";
        if (self.ins.ai_row == row and self.buffer.isBlankLine(row)) {
            try self.buffer.setLine(row, "");
            self.cursor.col = 0;
        }
        if (self.opts.autoindent) {
            const l = self.buffer.getLine(row);
            var e = self.cursor.col;
            while (e < l.len and classify.isBlank(l[e])) e += 1;
            if (e > self.cursor.col) try self.buffer.deleteRange(self.cursor, .{ .row = row, .col = e });
        }
        if (self.mode == .replace) try self.ins.replaced.append(self.allocator, -2);
        self.cursor = try self.buffer.insertText(self.cursor, "\n");
        if (ind.len > 0) {
            self.cursor = try self.buffer.insertText(self.cursor, ind);
            self.ins.ai_row = self.cursor.row;
        } else self.ins.ai_row = null;
    }

    const BsMode = enum { char, word, line };

    /// <BS>/<C-h>, <C-w> and <C-u> with backspace=indent,eol,start.
    fn backspace(self: *VimEditor, bs: BsMode) !void {
        const ins = &self.ins;
        const row = self.cursor.row;
        const col = self.cursor.col;
        if (col == 0) {
            if (row == 0) return;
            if (self.mode == .replace) {
                const items = ins.replaced.items;
                if (items.len == 0 or items[items.len - 1] != -2) {
                    self.cursor = .{ .row = row - 1, .col = self.buffer.lineLen(row - 1) };
                    return;
                }
                _ = ins.replaced.pop();
            }
            const prev_len = self.buffer.lineLen(row - 1);
            try self.buffer.deleteRange(.{ .row = row - 1, .col = prev_len }, .{ .row = row });
            self.cursor = .{ .row = row - 1, .col = prev_len };
            if (ins.start.row >= row) ins.start = self.cursor;
            if (ins.orig.row >= row) ins.orig = self.cursor;
            return;
        }
        if (self.mode == .replace and bs == .char) {
            self.cursor.col -= 1;
            const orig = ins.replaced.pop() orelse return;
            const at = Pos{ .row = row, .col = self.cursor.col };
            if (orig >= 0) {
                const ch: u8 = @intCast(orig);
                try self.buffer.replaceInLine(row, at.col, at.col + 1, &.{ch});
            } else try self.buffer.deleteRange(at, .{ .row = row, .col = at.col + 1 });
            return;
        }
        const line = self.buffer.getLine(row);
        var c = col;
        switch (bs) {
            .char => {
                // smarttab: in the indent, delete back to a shiftwidth stop.
                if (firstNonBlankOf(line) >= col and line[col - 1] == ' ') {
                    const sw = self.opts.shiftwidth;
                    const want = ((indentWidth(line[0..col]) - 1) / sw) * sw;
                    while (c > 0 and line[c - 1] == ' ' and indentWidth(line[0..c]) > want) c -= 1;
                } else c -= 1;
            },
            .word, .line => {
                var mincol: usize = 0;
                if (bs == .line and self.opts.autoindent) {
                    const fnb = firstNonBlankOf(line);
                    if (fnb < col) mincol = fnb;
                }
                var not_space = false;
                var kw = false;
                while (true) {
                    const ch = line[c - 1];
                    if (bs == .word) {
                        const space = classify.isBlank(ch);
                        if (!not_space and !space) {
                            not_space = true;
                            kw = classify.isKeyword(ch);
                        } else if (not_space and (space or classify.isKeyword(ch) != kw)) break;
                    }
                    c -= 1;
                    if (!(c > mincol and !(row == ins.orig.row and c == ins.orig.col))) break;
                }
            },
        }
        if (c == col) return;
        try self.buffer.deleteRange(.{ .row = row, .col = c }, .{ .row = row, .col = col });
        self.cursor.col = c;
        if (row == ins.start.row and c < ins.start.col) ins.start.col = c;
        if (row == ins.orig.row and c < ins.orig.col) ins.orig.col = c;
    }

    fn insertArrow(self: *VimEditor, key: VimKey) !void {
        const buf = &self.buffer;
        var p = self.cursor;
        const page = self.viewRows() -| 2;
        switch (key) {
            .left => p.col -|= 1,
            .right => p.col = @min(p.col + 1, buf.lineLen(p.row)),
            .up => p.row -|= 1,
            .page_up => p.row -|= page,
            .down => p.row = @min(p.row + 1, buf.lastRow()),
            .page_down => p.row = @min(p.row + page, buf.lastRow()),
            .home => p.col = 0,
            .end => p.col = buf.lineLen(p.row),
            .word_left => p = motion.bckWord(buf, p, 1, false, false).pos,
            .word_right => p = motion.fwdWord(buf, p, 1, false, false).pos,
            .doc_top => p = .{},
            .doc_bottom => p = .{ .row = buf.lastRow(), .col = buf.lineLen(buf.lastRow()) },
            else => {},
        }
        const vertical = key == .up or key == .down or key == .page_up or key == .page_down;
        if (vertical) {
            if (p.row != self.cursor.row) p.col = @min(if (self.curswant == max_col) max_col else self.cursor.col, buf.lineLen(p.row));
        }
        self.cursor = buf.clampPos(p);
        if (!vertical) {
            if (key == .end) self.curswant = max_col else self.setWant();
        }
        // Arrows start a new undo step and a new insert.
        self.commitUndo();
        self.ins.start = self.cursor;
        self.ins.ai_row = null;
        self.ins.count = 1;
    }

    fn leaveInsert(self: *VimEditor, by: LeaveBy) anyerror!void {
        const ins = &self.ins;
        ins.await_reg = false;
        if (by != .ctrl_c and ins.count > 1 and !ins.repeating) {
            const keys = try self.allocator.dupe(VimKey, ins.keys.items);
            defer self.allocator.free(keys);
            ins.repeating = true;
            defer ins.repeating = false;
            var i: u32 = 1;
            while (i < ins.count) : (i += 1) {
                if (ins.open_line) try self.openLine(true);
                for (keys) |k| try self.insertKey(k);
            }
        }
        if (ins.ai_row == self.cursor.row and self.buffer.isBlankLine(self.cursor.row)) {
            try self.buffer.setLine(self.cursor.row, "");
            self.cursor.col = 0;
        }
        ins.ai_row = null;
        ins.ctrl_o = false;
        self.last_insert = self.cursor;
        self.mode = .normal;
        const bi = ins.block;
        ins.block = null;
        // A block insert copies the text to the other rows and leaves the
        // cursor on the block's top-left corner.
        const copied = if (bi) |b| try block.finishInsert(self, b) else false;
        if (!copied and self.cursor.col > 0) self.cursor.col -= 1;
        self.clampNormal();
        self.setWant();
        if (self.dot_rec) {
            self.dot_rec = false;
            switch (by) {
                .esc => {},
                .ctrl_c => {
                    _ = self.dot_build.pop();
                    try self.dot_build.append(self.allocator, .esc);
                },
                .internal => try self.dot_build.append(self.allocator, .esc),
            }
            std.mem.swap(std.ArrayList(VimKey), &self.dot_keys, &self.dot_build);
            self.dot_build.clearRetainingCapacity();
            self.dot_count = self.dot_build_count;
            self.dot_reg = self.dot_build_reg;
        }
    }

    // -- command line, search -----------------------------------------------

    fn startCmdline(self: *VimEditor, kind: u8, prefill: []const u8) void {
        self.cmd_buf[0] = kind;
        const n = @min(prefill.len, self.cmd_buf.len - 1);
        @memcpy(self.cmd_buf[1..][0..n], prefill[0..n]);
        self.cmd_len = n;
        self.cmd_prev = if (self.mode.isVisual()) self.mode else .normal;
        self.cmd_pend = self.pend;
        self.cmd_pend.pushKey(.{ .char = kind });
        self.cmd_origin = self.cursor;
        self.cmd_top = self.view_top;
        self.cmd_await_reg = false;
        self.mode = .cmdline;
        self.pend = .{};
    }

    fn cmdText(self: *const VimEditor) []const u8 {
        return self.cmd_buf[1 .. self.cmd_len + 1];
    }

    fn cmdAppend(self: *VimEditor, s: []const u8) void {
        for (s) |c| {
            if (c == '\n') continue;
            if (self.cmd_len + 1 >= self.cmd_buf.len) return;
            self.cmd_buf[self.cmd_len + 1] = c;
            self.cmd_len += 1;
        }
    }

    fn cmdlineKey(self: *VimEditor, key: VimKey) !void {
        if (self.cmd_await_reg) {
            self.cmd_await_reg = false;
            switch (key) {
                .char => |c| if (self.regs.get(c)) |r| self.cmdAppend(r.slice()),
                .ctrl => |c| if (c == 'w') {
                    const line = self.buffer.getLine(self.cmd_origin.row);
                    var s = @min(self.cmd_origin.col, line.len);
                    while (s > 0 and classify.isKeyword(line[s - 1])) s -= 1;
                    var e = s;
                    while (e < line.len and classify.isKeyword(line[e])) e += 1;
                    self.cmdAppend(line[s..e]);
                },
                else => {},
            }
            return self.incsearch();
        }
        switch (key) {
            .esc => return self.cmdlineCancel(),
            .enter => return self.cmdlineExecute(),
            .backspace => {
                if (self.cmd_len == 0) return self.cmdlineCancel();
                self.cmd_len -= 1;
            },
            .char => |c| self.cmdAppend(&.{c}),
            .tab => self.cmdAppend(" "),
            .ctrl => |c| switch (c) {
                'c' => return self.cmdlineCancel(),
                'h' => {
                    if (self.cmd_len == 0) return self.cmdlineCancel();
                    self.cmd_len -= 1;
                },
                'w' => {
                    const t = self.cmdText();
                    var e = t.len;
                    while (e > 0 and t[e - 1] == ' ') e -= 1;
                    if (e > 0 and classify.isKeyword(t[e - 1])) {
                        while (e > 0 and classify.isKeyword(t[e - 1])) e -= 1;
                    } else if (e > 0) e -= 1;
                    self.cmd_len = e;
                },
                'u' => self.cmd_len = 0,
                'r' => self.cmd_await_reg = true,
                'm', 'j' => return self.cmdlineExecute(),
                else => {},
            },
            else => {},
        }
        self.incsearch();
    }

    fn incsearch(self: *VimEditor) void {
        const kind = self.cmd_buf[0];
        if (kind == ':') return;
        self.cursor = self.cmd_origin;
        self.view_top = self.cmd_top;
        const full = self.cmdText();
        const t = full[0..ex.splitAt(full, kind)];
        if (t.len == 0) {
            if (self.lastPattern()) |p| self.hl_pat = self.compile(p);
            return;
        }
        self.hl_pat = self.compile(t);
        var tmp: [256]u8 = undefined;
        const copy = tmp[0..t.len];
        @memcpy(copy, t);
        if (self.searchFrom(copy, self.cmd_origin, kind == '?', @max(self.cmd_pend.count0(), 1))) |p| self.cursor = p;
        self.status = "";
    }

    fn cmdlineCancel(self: *VimEditor) void {
        self.cursor = self.cmd_origin;
        self.view_top = self.cmd_top;
        self.mode = self.cmd_prev;
        self.pend = .{};
        if (self.lastPattern()) |p| self.hl_pat = self.compile(p) else self.hl_pat = .{};
        self.status = "";
        self.finishCtrlO();
    }

    fn cmdlineExecute(self: *VimEditor) !void {
        const kind = self.cmd_buf[0];
        var text_buf: [256]u8 = undefined;
        const t = self.cmdText();
        const text = text_buf[0..t.len];
        @memcpy(text, t);
        self.cursor = self.cmd_origin;
        self.view_top = self.cmd_top;
        self.mode = self.cmd_prev;
        self.status = "";
        if (kind == ':') {
            self.pend = .{};
            if (text.len > 0) {
                @memcpy(self.last_ex[0..text.len], text);
                self.last_ex_len = text.len;
            }
            try ex.execute(self, text);
            if (self.mode == .normal) self.clampNormal();
            self.finishCmd(false);
            return;
        }
        self.pend = self.cmd_pend;
        for (text) |c| self.pend.pushKey(.{ .char = c });
        self.pend.pushKey(.enter);
        self.hl_active = true;
        // `/pat/off;?pat2?off2`: each search starts where the previous one
        // landed; the count applies to the first.
        var dir = kind;
        var rest: []const u8 = text;
        var from = self.cursor;
        var n: usize = @max(self.pend.count0(), 1);
        var hit: Target = undefined;
        while (true) {
            const pe = ex.splitAt(rest, dir);
            var pat_buf: [256]u8 = undefined;
            // `/<CR>` keeps the offset; `//<CR>` drops it.
            if (rest.len > 0) {
                const parsed = search.Offset.parse(if (pe < rest.len) rest[pe + 1 ..] else "");
                self.search_off = parsed.off;
                const src = if (pe > 0) rest[0..pe] else self.lastPattern() orelse "";
                rest = parsed.rest;
                if (src.len == 0) {
                    self.setStatus("E35: No previous regular expression");
                    return self.fail();
                }
                @memcpy(pat_buf[0..src.len], src);
                self.setPattern(pat_buf[0..src.len]);
            } else if (!self.has_pat) {
                self.setStatus("E35: No previous regular expression");
                return self.fail();
            }
            const pat = self.lastPattern().?;
            @memcpy(pat_buf[0..pat.len], pat);
            self.search_back = dir == '?';
            hit = self.searchOffset(pat_buf[0..pat.len], from, dir == '?', n) orelse return self.fail();
            if (rest.len == 0 or rest[0] != ';') break;
            if (rest.len < 2 or (rest[1] != '/' and rest[1] != '?')) {
                self.setStatus("E386: Expected '?' or '/'  after ';'");
                return self.fail();
            }
            dir = rest[1];
            rest = rest[2..];
            from = hit.pos;
            n = 1;
        }
        try self.applyMotion(hit, true);
    }

    /// Vim's do_search(): the n-th match with the remembered offset applied.
    /// A character offset is first undone from `from`, so that n after
    /// `/pat/e+1` or `/pat/s-2` does not find the same match again.
    fn searchOffset(self: *VimEditor, pat_src: []const u8, from: Pos, backward: bool, n: usize) ?Target {
        const o = self.search_off;
        var start = from;
        var whole = false;
        if (!o.line and o.off != 0) {
            var w = motion.Walker{ .buf = &self.buffer, .p = from };
            var c = o.off;
            while (c != 0) {
                const r = if (c > 0) w.decl() else w.incl();
                if (r == -1) break;
                c += if (c > 0) -1 else 1;
            }
            start = w.p;
            // Ran into the buffer edge: search the whole buffer.
            if (c != 0) {
                whole = true;
                start = if (backward) .{ .row = self.buffer.lastRow() } else .{};
            }
        }
        const found = self.searchFromEx(pat_src, start, backward, n, o.end, whole) orelse return null;
        if (o.line) {
            const row: isize = @as(isize, @intCast(found.row)) + o.off;
            const last: isize = @intCast(self.buffer.lastRow());
            return .{ .pos = .{ .row = @intCast(std.math.clamp(row, 0, last)) }, .kind = .linewise, .jump = true };
        }
        var w = motion.Walker{ .buf = &self.buffer, .p = found };
        var c = o.off;
        while (c != 0) {
            const r = if (c > 0) w.incl() else w.decl();
            if (r == -1) break;
            c += if (c > 0) -1 else 1;
        }
        return .{ .pos = w.p, .kind = if (o.end) .inclusive else .exclusive, .jump = true };
    }

    /// The n-th match after (or before) `from`, wrapping around. Sets the
    /// wrap / not-found message.
    pub fn searchFrom(self: *VimEditor, pat_src: []const u8, from: Pos, backward: bool, n: usize) ?Pos {
        return self.searchFromEx(pat_src, from, backward, n, false, false);
    }

    /// searchFrom() landing on the last char of each match (`end`), and
    /// taking any match on the first line (`whole`: searching from before
    /// the buffer start, or after its end).
    fn searchFromEx(self: *VimEditor, pat_src: []const u8, from: Pos, backward: bool, n: usize, end: bool, whole: bool) ?Pos {
        const pat = self.compile(pat_src);
        if (pat.err) |e| {
            self.setStatus(e.message());
            return null;
        }
        var p = from;
        var wrapped = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = self.searchOnce(&pat, p, backward, end, whole and i == 0) orelse {
                self.statusFmt("E486: Pattern not found: {s}", .{pat_src});
                return null;
            };
            p = r.pos;
            wrapped = wrapped or r.wrapped;
        }
        if (wrapped) self.setStatus(if (backward) "search hit TOP, continuing at BOTTOM" else "search hit BOTTOM, continuing at TOP");
        return p;
    }

    /// Vim's searchit() for one match. Forward: the first match after
    /// `from` (with `end`: whose last char is after it); backward: the last
    /// one before it. Matches on a line are walked as Vim does (no overlaps).
    fn searchOnce(self: *const VimEditor, pat: *const search.Pattern, from: Pos, backward: bool, end: bool, whole: bool) ?struct { pos: Pos, wrapped: bool } {
        const buf = &self.buffer;
        const nrows = buf.lineCount();
        const col: isize = @intCast(from.col);
        var step: usize = 0;
        while (step <= nrows) : (step += 1) {
            const row = if (backward) (from.row + nrows * 2 - step) % nrows else (from.row + step) % nrows;
            const wrapped = if (backward) step > from.row else from.row + step >= nrows;
            if (wrapped and !self.opts.wrapscan) return null;
            const line = buf.getLine(row);
            // On the cursor line only matches past (before) the cursor count;
            // back on it after wrapping around, any match does.
            const first = step == 0 and !whole;
            if (first and backward and from.col == 0) continue;
            var it = search.Iter{ .pat = pat, .line = line };
            var hit: ?search.Match = null;
            while (it.next()) |m| {
                const key: isize = if (end)
                    @as(isize, @intCast(m.end)) - 1
                else
                    @as(isize, @intCast(m.start)) - @intFromBool(m.start == line.len and m.start > 0);
                if (backward) {
                    if (first and key >= col) break;
                    hit = m;
                } else if (!first or key > col) {
                    hit = m;
                    break;
                }
            }
            const m = hit orelse continue;
            var pos = Pos{ .row = row, .col = m.start };
            if (end) {
                pos.col = m.end -| 1;
                if (m.end == 0 and row > 0) pos = .{ .row = row - 1, .col = buf.lineLen(row - 1) };
            }
            return .{ .pos = pos, .wrapped = wrapped and step > 0 };
        }
        return null;
    }
};

test {
    _ = @import("classify.zig");
    _ = @import("motion.zig");
    _ = @import("textobj.zig");
    _ = @import("search.zig");
    _ = @import("register.zig");
    _ = @import("undo.zig");
    _ = @import("buffer.zig");
    _ = @import("ex.zig");
    _ = @import("key.zig");
    _ = @import("vcol.zig");
    _ = @import("jumps.zig");
    _ = @import("block.zig");
    _ = @import("global.zig");
    _ = @import("sentence.zig");
    _ = @import("tag.zig");
    _ = @import("format.zig");
}
