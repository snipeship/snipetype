//! Vim regular expressions ('magic'), matched within one line by a small
//! backtracking machine (leftmost match, first alternative, greedy
//! multis, as Vim's engine):
//!
//! - atoms: literal text, `.`, `[abc]`/`[^a-z]`, `\(…\)` (groups 1-9),
//!   `\%(…\)`, the classes `\s \S \d \D \w \W \a \A \l \L \u \U \x \X \h \k
//!   \p`, `\t` `\e`;
//! - multis: `*`, `\+`, `\=`, `\?`, `\{n,m}` (and `\{-n,m}`, fewest first);
//! - `\|` between alternatives; `^` and `$` at the start/end of one;
//!   `\<` `\>` word boundaries; `\zs` `\ze` set the match start/end;
//! - `\c` / `\C` force case (in)sensitivity;
//! - `\1`..`\9` match what a group matched (empty when it did not take
//!   part);
//! - `\v` (very magic), `\m`, `\M` (nomagic) and `\V` (very nomagic) are
//!   rewritten to 'magic' syntax before compiling.
//!
//! `\n` never matches (a pattern does not span lines).

const std = @import("std");
const classify = @import("classify.zig");

/// A pattern that did not compile (Vim's message is `message()`).
pub const Error = enum {
    unmatched_open,
    unmatched_close,
    too_many_groups,
    too_complex,

    pub fn message(self: Error) []const u8 {
        return switch (self) {
            .unmatched_open => "E54: Unmatched \\(",
            .unmatched_close => "E55: Unmatched \\)",
            .too_many_groups => "E51: Too many \\(",
            .too_complex => "E363: Pattern too complex",
        };
    }
};

const Op = enum(u8) {
    char,
    any,
    set,
    class,
    bol,
    eol,
    bow,
    eow,
    /// Record the column in capture slot `x`.
    save,
    /// Try `x`, then `y`.
    split,
    jmp,
    /// Like split, but an iteration that matched nothing ends the loop
    /// (slot `y2`).
    loop,
    /// The single-char atom at pc+1 repeated x..y times (`lazy`: fewest
    /// first); continue at pc+2.
    rep,
    /// What group `x` matched (`\1`..`\9`).
    backref,
    nomatch,
    match,
};

const Inst = struct {
    op: Op,
    x: u16 = 0,
    y: u16 = 0,
    ch: u8 = 0,
    lazy: bool = false,
};

pub const max_insts = 192;
const max_sets = 12;
const max_loops = 8;
const inf: u16 = std.math.maxInt(u16);
/// Capture slots: 0/1 the `\zs`/`\ze` columns, 2k/2k+1 group k (1-9).
pub const n_slots = 20;
const none = std.math.maxInt(usize);

/// Group k of a match is `line[caps[2k]..caps[2k+1]]` when both are set.
pub const Caps = [n_slots]usize;

pub const Match = struct { start: usize, end: usize };

pub const Pattern = struct {
    err: ?Error = null,
    prog: [max_insts]Inst = undefined,
    n: usize = 0,
    sets: [max_sets][32]u8 = undefined,
    n_sets: usize = 0,
    n_loops: usize = 0,
    /// Only matches at column 0 (every alternative starts with `^`).
    bol: bool = false,
    icase: bool = false,
    empty: bool = true,

    /// `smartcase`: ignore case unless the pattern has an uppercase letter.
    pub fn compile(src0: []const u8, smartcase: bool) Pattern {
        var p = Pattern{};
        var magic_buf: [512]u8 = undefined;
        const src = toMagic(src0, &magic_buf) orelse {
            p.err = .too_complex;
            return p;
        };
        var c = Compiler{ .src = src, .p = &p };
        p.empty = src.len == 0;
        const root = c.parseAlt() catch |e| {
            p.err = switch (e) {
                error.UnmatchedOpen => .unmatched_open,
                error.UnmatchedClose => .unmatched_close,
                error.TooManyGroups => .too_many_groups,
                error.TooComplex => .too_complex,
            };
            p.n = 0;
            return p;
        };
        if (c.i < src.len) {
            p.err = .unmatched_close;
            return p;
        }
        c.emit(root) catch {
            p.err = .too_complex;
            p.n = 0;
            return p;
        };
        c.push(.{ .op = .match }) catch {
            p.err = .too_complex;
            p.n = 0;
            return p;
        };
        p.bol = c.startsBol(root);
        p.icase = c.forced orelse (smartcase and !c.has_upper);
        return p;
    }

    pub fn isEmpty(self: *const Pattern) bool {
        return self.empty or self.err != null;
    }

    /// End (exclusive) of a match tried at `col` (ignores `\zs`/`\ze`).
    pub fn matchAt(self: *const Pattern, line: []const u8, col: usize) ?usize {
        var caps: Caps = @splat(none);
        return self.run(line, col, &caps);
    }

    /// A match tried at `col`, with `\zs`/`\ze` applied and the groups.
    pub fn matchCaps(self: *const Pattern, line: []const u8, col: usize, caps: *Caps) ?Match {
        caps.* = @splat(none);
        const e = self.run(line, col, caps) orelse return null;
        const s = if (caps[0] != none) caps[0] else col;
        const end = if (caps[1] != none) caps[1] else e;
        return .{ .start = s, .end = @max(end, s) };
    }

    fn run(self: *const Pattern, line: []const u8, col: usize, caps: *Caps) ?usize {
        if (self.err != null or self.n == 0) return null;
        if (self.bol and col != 0) return null;
        var m = Machine{ .p = self, .line = line, .caps = caps };
        return m.exec(0, col, 0);
    }

    /// First match tried at or after `from` on the line.
    pub fn find(self: *const Pattern, line: []const u8, from: usize) ?Match {
        var caps: Caps = undefined;
        return self.findCaps(line, from, &caps);
    }

    pub fn findCaps(self: *const Pattern, line: []const u8, from: usize, caps: *Caps) ?Match {
        var col = from;
        while (col <= line.len) : (col += 1) {
            if (self.matchCaps(line, col, caps)) |m| return m;
            if (self.bol) return null;
        }
        return null;
    }

    /// Last match starting before `before` on the line.
    pub fn findLast(self: *const Pattern, line: []const u8, before: usize) ?Match {
        var best: ?Match = null;
        var caps: Caps = undefined;
        var col: usize = 0;
        while (col <= line.len) : (col += 1) {
            if (self.matchCaps(line, col, &caps)) |m| {
                if (m.start < before) best = m;
            }
            if (self.bol) break;
        }
        return best;
    }

    fn single(self: *const Pattern, in: Inst, c: u8) bool {
        return switch (in.op) {
            .char => if (self.icase) std.ascii.toLower(in.ch) == std.ascii.toLower(c) else in.ch == c,
            .any => true,
            .set => blk: {
                const bits = &self.sets[in.x];
                var hit = bits[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0;
                if (!hit and self.icase) {
                    const o = if (std.ascii.isLower(c)) std.ascii.toUpper(c) else std.ascii.toLower(c);
                    hit = bits[o >> 3] & (@as(u8, 1) << @intCast(o & 7)) != 0;
                }
                break :blk hit != in.lazy;
            },
            .class => classMatch(in.ch, c),
            else => false,
        };
    }
};

/// Vim's walk over the matches on a line (with 'cpoptions' c): each next
/// match is tried from the end of the previous one, one further after an
/// empty match, and never from the line end.
pub const Iter = struct {
    pat: *const Pattern,
    line: []const u8,
    col: usize = 0,
    done: bool = false,

    pub fn next(it: *Iter) ?Match {
        if (it.done) return null;
        const m = it.pat.find(it.line, it.col) orelse {
            it.done = true;
            return null;
        };
        var c = @max(m.end, m.start);
        if (c == m.start and c < it.line.len) c += 1;
        it.col = c;
        it.done = c >= it.line.len;
        return m;
    }
};

/// A search offset (`/pat/e+1`, `?pat?s-2`, `/pat/+3`), Vim's `soffset`.
pub const Offset = struct {
    /// `[+-]N`: N lines down/up, at column 0 (a linewise motion).
    line: bool = false,
    /// `e[+-N]`: from the last char of the match (an inclusive motion).
    end: bool = false,
    /// Lines (`line`) or chars (`e`, `s`, `b`) to move.
    off: isize = 0,

    pub const Parsed = struct { off: Offset, rest: []const u8 };

    /// Parses the offset at the start of `s` (after the closing `/` or `?`).
    pub fn parse(s: []const u8) Parsed {
        var o = Offset{};
        var i: usize = 0;
        if (i < s.len and (s[i] == '+' or s[i] == '-' or std.ascii.isDigit(s[i]))) {
            o.line = true;
        } else if (i < s.len and (s[i] == 'e' or s[i] == 's' or s[i] == 'b')) {
            o.end = s[i] == 'e';
            i += 1;
        }
        if (i < s.len and (s[i] == '+' or s[i] == '-' or std.ascii.isDigit(s[i]))) {
            const neg = s[i] == '-';
            var j = i + @intFromBool(!std.ascii.isDigit(s[i]));
            if (j < s.len and std.ascii.isDigit(s[j])) {
                var v: isize = 0;
                while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) v = v *| 10 +| (s[j] - '0');
                o.off = if (neg) -v else v;
                i = j;
            } else {
                o.off = if (neg) -1 else 1;
                i += 1;
            }
        }
        return .{ .off = o, .rest = s[i..] };
    }
};

fn classMatch(k: u8, c: u8) bool {
    return switch (k) {
        's' => classify.isBlank(c),
        'S' => !classify.isBlank(c),
        'd' => std.ascii.isDigit(c),
        'D' => !std.ascii.isDigit(c),
        'w' => std.ascii.isAlphanumeric(c) or c == '_',
        'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
        'a' => std.ascii.isAlphabetic(c),
        'A' => !std.ascii.isAlphabetic(c),
        'l' => std.ascii.isLower(c),
        'L' => !std.ascii.isLower(c),
        'u' => std.ascii.isUpper(c),
        'U' => !std.ascii.isUpper(c),
        'x' => std.ascii.isHex(c),
        'X' => !std.ascii.isHex(c),
        'o' => c >= '0' and c <= '7',
        'O' => !(c >= '0' and c <= '7'),
        'h' => std.ascii.isAlphabetic(c) or c == '_',
        'H' => !(std.ascii.isAlphabetic(c) or c == '_'),
        'k', 'i' => classify.isKeyword(c),
        'K', 'I' => classify.isKeyword(c) and !std.ascii.isDigit(c),
        'p' => c >= 0x20 and c != 0x7f,
        'P' => c >= 0x20 and c != 0x7f and !std.ascii.isDigit(c),
        else => false,
    };
}

/// Runs the program. Recursion happens only at choice points, and a step
/// budget bounds pathological patterns (they then fail to match).
const Machine = struct {
    p: *const Pattern,
    line: []const u8,
    caps: *Caps,
    steps: usize = 0,
    loop_col: [max_loops]usize = @splat(none),

    const budget = 100_000;
    const max_depth = 400;

    fn exec(self: *Machine, pc0: usize, col0: usize, depth: usize) ?usize {
        if (depth > max_depth) return null;
        var pc = pc0;
        var col = col0;
        const line = self.line;
        while (true) {
            self.steps += 1;
            if (self.steps > budget) return null;
            const in = self.p.prog[pc];
            switch (in.op) {
                .char, .any, .set, .class => {
                    if (col >= line.len or !self.p.single(in, line[col])) return null;
                    col += 1;
                    pc += 1;
                },
                .bol => {
                    if (col != 0) return null;
                    pc += 1;
                },
                .eol => {
                    if (col != line.len) return null;
                    pc += 1;
                },
                .bow => {
                    const ok = col < line.len and classify.isKeyword(line[col]) and (col == 0 or !classify.isKeyword(line[col - 1]));
                    if (!ok) return null;
                    pc += 1;
                },
                .eow => {
                    const ok = col > 0 and classify.isKeyword(line[col - 1]) and (col == line.len or !classify.isKeyword(line[col]));
                    if (!ok) return null;
                    pc += 1;
                },
                .save => {
                    const old = self.caps[in.x];
                    self.caps[in.x] = col;
                    if (self.exec(pc + 1, col, depth + 1)) |e| return e;
                    self.caps[in.x] = old;
                    return null;
                },
                .split => {
                    if (self.exec(in.x, col, depth + 1)) |e| return e;
                    pc = in.y;
                },
                .jmp => pc = in.x,
                .loop => {
                    const slot = in.ch;
                    const body: usize = pc + 1;
                    const exit: usize = in.y;
                    // An iteration that matched nothing ends the loop.
                    if (self.loop_col[slot] == col) {
                        pc = exit;
                        continue;
                    }
                    const old = self.loop_col[slot];
                    self.loop_col[slot] = col;
                    const first = if (in.lazy) exit else body;
                    const second = if (in.lazy) body else exit;
                    const r = self.exec(first, col, depth + 1);
                    self.loop_col[slot] = old;
                    if (r) |e| return e;
                    pc = second;
                },
                .rep => {
                    const atom = self.p.prog[pc + 1];
                    var count: usize = 0;
                    const max: usize = if (in.y == inf) line.len else in.y;
                    while (count < max and col + count < line.len and self.p.single(atom, line[col + count])) count += 1;
                    if (count < in.x) return null;
                    if (in.lazy) {
                        var k: usize = in.x;
                        while (k <= count) : (k += 1) {
                            if (self.exec(pc + 2, col + k, depth + 1)) |e| return e;
                        }
                    } else {
                        var k = count + 1;
                        while (k > in.x) {
                            k -= 1;
                            if (self.exec(pc + 2, col + k, depth + 1)) |e| return e;
                        }
                    }
                    return null;
                },
                .backref => {
                    const a = self.caps[2 * in.x];
                    const b = self.caps[2 * in.x + 1];
                    if (a != none and b != none and a <= b) {
                        const len = b - a;
                        if (col + len > line.len) return null;
                        for (line[a..b], line[col..][0..len]) |x, y| {
                            const same = if (self.p.icase) std.ascii.toLower(x) == std.ascii.toLower(y) else x == y;
                            if (!same) return null;
                        }
                        col += len;
                    }
                    pc += 1;
                },
                .nomatch => return null,
                .match => return col,
            }
        }
    }
};

// -- magic levels -----------------------------------------------------------

const Magic = enum { very, magic, nomagic, none };

/// End (exclusive) of the `[...]` collection opening at `s[i]`, or null
/// when it is not closed (the `[` is then a literal).
fn setEnd(s: []const u8, i: usize) ?usize {
    var j = i + 1;
    if (j < s.len and s[j] == '^') j += 1;
    if (j < s.len and s[j] == ']') j += 1;
    while (j < s.len) : (j += 1) {
        if (s[j] == '\\' and j + 1 < s.len) {
            j += 1;
        } else if (s[j] == ']') return j + 1;
    }
    return null;
}

/// Rewrites `\v` `\m` `\M` `\V` parts of a pattern in 'magic' syntax
/// (the only one the compiler reads). Null when it does not fit `buf`.
fn toMagic(src: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, src, '\\') == null) return src;
    var mode: Magic = .magic;
    var n: usize = 0;
    const W = struct {
        fn put(b: []u8, len: *usize, bytes: []const u8) bool {
            if (len.* + bytes.len > b.len) return false;
            @memcpy(b[len.*..][0..bytes.len], bytes);
            len.* += bytes.len;
            return true;
        }
    };
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            const e = src[i + 1];
            i += 2;
            switch (e) {
                'v' => mode = .very,
                'm' => mode = .magic,
                'M' => mode = .nomagic,
                'V' => mode = .none,
                else => {
                    const plain: []const u8 = switch (mode) {
                        // `\(` in very magic is a literal '(' (plain in magic).
                        .very => if (std.mem.indexOfScalar(u8, "(){}|+?=@<>%&", e) != null) src[i - 1 .. i] else src[i - 2 .. i],
                        // `\.` in nomagic is the magic '.'.
                        .nomagic => if (std.mem.indexOfScalar(u8, ".*[~", e) != null) src[i - 1 .. i] else src[i - 2 .. i],
                        .none => if (std.mem.indexOfScalar(u8, ".*[~^$", e) != null) src[i - 1 .. i] else src[i - 2 .. i],
                        .magic => src[i - 2 .. i],
                    };
                    if (!W.put(buf, &n, plain)) return null;
                    // A collection opened by `\[` (nomagic) is copied whole.
                    if (e == '[' and mode != .magic and mode != .very) {
                        if (setEnd(src, i - 1)) |end| {
                            if (!W.put(buf, &n, src[i..end])) return null;
                            i = end;
                        }
                    }
                },
            }
            continue;
        }
        i += 1;
        var out: []const u8 = src[i - 1 .. i];
        switch (mode) {
            .magic, .very => if (c == '[') {
                if (setEnd(src, i - 1)) |end| {
                    out = src[i - 1 .. end];
                    i = end;
                }
            } else if (mode == .very) switch (c) {
                '(', ')', '|', '+', '?', '=', '@', '<', '>', '&' => {
                    if (!W.put(buf, &n, "\\")) return null;
                },
                '%' => {
                    if (!W.put(buf, &n, "\\")) return null;
                    // `%(` is one token: `\%(`.
                    if (i < src.len and src[i] == '(') {
                        i += 1;
                        out = "%(";
                    }
                },
                '{' => {
                    // `{n,m}`: `\{n,m}`, the body copied as it is.
                    const close = std.mem.indexOfScalarPos(u8, src, i, '}') orelse src.len - 1;
                    if (!W.put(buf, &n, "\\")) return null;
                    out = src[i - 1 .. @min(close + 1, src.len)];
                    i = @min(close + 1, src.len);
                },
                else => {},
            },
            .nomagic, .none => if (std.mem.indexOfScalar(u8, if (mode == .none) ".*[~^$" else ".*[~", c) != null) {
                if (!W.put(buf, &n, "\\")) return null;
            },
        }
        if (!W.put(buf, &n, out)) return null;
    }
    return buf[0..n];
}

// -- compiler ---------------------------------------------------------------

const NodeKind = enum { inst, concat, alt, group, repeat };

const Node = struct {
    kind: NodeKind,
    /// .inst: the instruction.
    inst: Inst = .{ .op = .nomatch },
    /// First child (concat/alt/group/repeat).
    child: u16 = nil,
    /// Next sibling in a concat/alt list.
    next: u16 = nil,
    /// group: capture number (0 = none). repeat: min/max/lazy.
    group: u8 = 0,
    min: u16 = 0,
    max: u16 = 0,
    lazy: bool = false,
};

const nil = std.math.maxInt(u16);
const max_nodes = 160;

const CompileError = error{ UnmatchedOpen, UnmatchedClose, TooManyGroups, TooComplex };

const Compiler = struct {
    src: []const u8,
    i: usize = 0,
    p: *Pattern,
    nodes: [max_nodes]Node = undefined,
    n_nodes: usize = 0,
    groups: u8 = 0,
    depth: usize = 0,
    forced: ?bool = null,
    has_upper: bool = false,

    fn node(self: *Compiler, n: Node) CompileError!u16 {
        if (self.n_nodes >= max_nodes) return error.TooComplex;
        self.nodes[self.n_nodes] = n;
        self.n_nodes += 1;
        return @intCast(self.n_nodes - 1);
    }

    fn peekEsc(self: *const Compiler, c: u8) bool {
        return self.i + 1 < self.src.len and self.src[self.i] == '\\' and self.src[self.i + 1] == c;
    }

    /// branch (\| branch)*
    fn parseAlt(self: *Compiler) CompileError!u16 {
        const first = try self.parseBranch();
        if (!self.peekEsc('|')) return first;
        const alt = try self.node(.{ .kind = .alt, .child = first });
        var last = first;
        while (self.peekEsc('|')) {
            self.i += 2;
            const b = try self.parseBranch();
            self.nodes[last].next = b;
            last = b;
        }
        return alt;
    }

    fn atBranchEnd(self: *const Compiler) bool {
        return self.i >= self.src.len or self.peekEsc('|') or self.peekEsc(')');
    }

    fn parseBranch(self: *Compiler) CompileError!u16 {
        const cat = try self.node(.{ .kind = .concat });
        var last: u16 = nil;
        var at_start = true;
        while (!self.atBranchEnd()) {
            const piece = try self.parsePiece(at_start) orelse {
                at_start = false;
                continue;
            };
            at_start = false;
            if (last == nil) self.nodes[cat].child = piece else self.nodes[last].next = piece;
            last = piece;
        }
        return cat;
    }

    fn instNode(self: *Compiler, in: Inst) CompileError!u16 {
        return self.node(.{ .kind = .inst, .inst = in });
    }

    /// An atom and its multi; null for a flag (`\c`).
    fn parsePiece(self: *Compiler, at_start: bool) CompileError!?u16 {
        const atom = try self.parseAtom(at_start) orelse return null;
        // Anchors and \zs/\ze take no multi.
        const k = self.nodes[atom];
        if (k.kind == .inst and switch (k.inst.op) {
            .bol, .eol, .bow, .eow, .save => true,
            else => false,
        }) return atom;
        var min: u16 = 1;
        var max: u16 = 1;
        var lazy = false;
        if (self.i < self.src.len and self.src[self.i] == '*') {
            self.i += 1;
            min = 0;
            max = inf;
        } else if (self.peekEsc('+')) {
            self.i += 2;
            max = inf;
        } else if (self.peekEsc('=') or self.peekEsc('?')) {
            self.i += 2;
            min = 0;
        } else if (self.peekEsc('{')) {
            self.i += 2;
            const r = self.parseBrace();
            min = r.min;
            max = r.max;
            lazy = r.lazy;
        } else return atom;
        return try self.node(.{ .kind = .repeat, .child = atom, .min = min, .max = max, .lazy = lazy });
    }

    /// `\{n,m}` after the `\{`: n, m, `-` (lazy), closed by `}` or `\}`.
    fn parseBrace(self: *Compiler) struct { min: u16, max: u16, lazy: bool } {
        var lazy = false;
        if (self.i < self.src.len and self.src[self.i] == '-') {
            lazy = true;
            self.i += 1;
        }
        const a = self.number();
        var min: u16 = a orelse 0;
        var max: u16 = a orelse inf;
        if (self.i < self.src.len and self.src[self.i] == ',') {
            self.i += 1;
            max = self.number() orelse inf;
        }
        if (self.peekEsc('}')) self.i += 1;
        if (self.i < self.src.len and self.src[self.i] == '}') self.i += 1;
        if (max != inf and min > max) std.mem.swap(u16, &min, &max);
        return .{ .min = min, .max = max, .lazy = lazy };
    }

    fn number(self: *Compiler) ?u16 {
        const start = self.i;
        while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.i += 1;
        if (self.i == start) return null;
        return std.fmt.parseInt(u16, self.src[start..self.i], 10) catch 255;
    }

    fn parseAtom(self: *Compiler, at_start: bool) CompileError!?u16 {
        const src = self.src;
        const c = src[self.i];
        self.i += 1;
        switch (c) {
            '^' => if (at_start) return try self.instNode(.{ .op = .bol }),
            '$' => if (self.atBranchEnd()) return try self.instNode(.{ .op = .eol }),
            '.' => return try self.instNode(.{ .op = .any }),
            '*' => if (at_start) return try self.instNode(.{ .op = .char, .ch = '*' }),
            '[' => {
                if (try self.parseSet()) |n| return n;
                return try self.instNode(.{ .op = .char, .ch = '[' });
            },
            '\\' => return self.parseEscape(),
            else => {},
        }
        if (c >= 'A' and c <= 'Z') self.has_upper = true;
        return try self.instNode(.{ .op = .char, .ch = c });
    }

    fn parseEscape(self: *Compiler) CompileError!?u16 {
        if (self.i >= self.src.len) return try self.instNode(.{ .op = .char, .ch = '\\' });
        const e = self.src[self.i];
        self.i += 1;
        switch (e) {
            '(' => return try self.parseGroup(true),
            '%' => {
                if (self.i < self.src.len and self.src[self.i] == '(') {
                    self.i += 1;
                    return try self.parseGroup(false);
                }
                return try self.instNode(.{ .op = .char, .ch = '%' });
            },
            ')' => return error.UnmatchedClose,
            '<' => return try self.instNode(.{ .op = .bow }),
            '>' => return try self.instNode(.{ .op = .eow }),
            'z' => {
                if (self.i < self.src.len and (self.src[self.i] == 's' or self.src[self.i] == 'e')) {
                    const slot: u16 = if (self.src[self.i] == 's') 0 else 1;
                    self.i += 1;
                    return try self.instNode(.{ .op = .save, .x = slot });
                }
                return try self.instNode(.{ .op = .char, .ch = 'z' });
            },
            'c', 'C' => {
                self.forced = e == 'c';
                return null;
            },
            't' => return try self.instNode(.{ .op = .char, .ch = '\t' }),
            'e' => return try self.instNode(.{ .op = .char, .ch = 0x1b }),
            'r' => return try self.instNode(.{ .op = .char, .ch = '\r' }),
            'n' => return try self.instNode(.{ .op = .nomatch }),
            '1'...'9' => return try self.instNode(.{ .op = .backref, .x = e - '0' }),
            's', 'S', 'd', 'D', 'w', 'W', 'a', 'A', 'l', 'L', 'u', 'U', 'x', 'X', 'o', 'O', 'h', 'H', 'k', 'K', 'i', 'I', 'p', 'P' => return try self.instNode(.{ .op = .class, .ch = e }),
            else => {
                if (e >= 'A' and e <= 'Z') self.has_upper = true;
                return try self.instNode(.{ .op = .char, .ch = e });
            },
        }
    }

    fn parseGroup(self: *Compiler, capture: bool) CompileError!u16 {
        var num: u8 = 0;
        if (capture) {
            if (self.groups >= 9) return error.TooManyGroups;
            self.groups += 1;
            num = self.groups;
        }
        self.depth += 1;
        if (self.depth > 20) return error.TooComplex;
        const inner = try self.parseAlt();
        self.depth -= 1;
        if (!self.peekEsc(')')) return error.UnmatchedOpen;
        self.i += 2;
        return self.node(.{ .kind = .group, .child = inner, .group = num });
    }

    /// `[...]` after the '['; null (a literal '[') without a closing ']'.
    fn parseSet(self: *Compiler) CompileError!?u16 {
        const src = self.src;
        var j = self.i;
        var bits: [32]u8 = @splat(0);
        var negate = false;
        if (j < src.len and src[j] == '^') {
            negate = true;
            j += 1;
        }
        var first = true;
        while (j < src.len) {
            var c = src[j];
            if (c == ']' and !first) {
                if (self.p.n_sets >= max_sets) return error.TooComplex;
                self.p.sets[self.p.n_sets] = bits;
                self.p.n_sets += 1;
                self.i = j + 1;
                // `lazy` marks a negated set.
                return try self.instNode(.{ .op = .set, .x = @intCast(self.p.n_sets - 1), .lazy = negate });
            }
            first = false;
            if (c == '\\' and j + 1 < src.len) {
                j += 1;
                c = switch (src[j]) {
                    't' => '\t',
                    'e' => 0x1b,
                    else => src[j],
                };
            }
            if (c >= 'A' and c <= 'Z') self.has_upper = true;
            if (j + 2 < src.len and src[j + 1] == '-' and src[j + 2] != ']') {
                const hi = src[j + 2];
                var x: usize = c;
                while (x <= hi) : (x += 1) bits[x >> 3] |= @as(u8, 1) << @intCast(x & 7);
                j += 3;
            } else {
                bits[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
                j += 1;
            }
        }
        return null;
    }

    fn startsBol(self: *const Compiler, n: u16) bool {
        const nd = self.nodes[n];
        return switch (nd.kind) {
            .inst => nd.inst.op == .bol,
            .concat => nd.child != nil and self.startsBol(nd.child),
            .group => self.startsBol(nd.child),
            .alt => blk: {
                var c = nd.child;
                while (c != nil) : (c = self.nodes[c].next) {
                    if (!self.startsBol(c)) break :blk false;
                }
                break :blk true;
            },
            .repeat => false,
        };
    }

    fn push(self: *Compiler, in: Inst) error{TooComplex}!void {
        if (self.p.n >= max_insts) return error.TooComplex;
        self.p.prog[self.p.n] = in;
        self.p.n += 1;
    }

    fn here(self: *const Compiler) u16 {
        return @intCast(self.p.n);
    }

    fn emit(self: *Compiler, n: u16) error{TooComplex}!void {
        const nd = self.nodes[n];
        switch (nd.kind) {
            .inst => try self.push(nd.inst),
            .concat => {
                var c = nd.child;
                while (c != nil) : (c = self.nodes[c].next) try self.emit(c);
            },
            .group => {
                if (nd.group > 0) try self.push(.{ .op = .save, .x = @as(u16, nd.group) * 2 });
                try self.emit(nd.child);
                if (nd.group > 0) try self.push(.{ .op = .save, .x = @as(u16, nd.group) * 2 + 1 });
            },
            .alt => {
                // split L1 L2; L1: a; jmp end; L2: split …; last: z; end:
                var jumps: [32]u16 = undefined;
                var nj: usize = 0;
                var c = nd.child;
                while (c != nil) : (c = self.nodes[c].next) {
                    const last = self.nodes[c].next == nil;
                    if (last) {
                        try self.emit(c);
                        break;
                    }
                    const sp = self.here();
                    try self.push(.{ .op = .split, .x = sp + 1 });
                    try self.emit(c);
                    if (nj >= jumps.len) return error.TooComplex;
                    jumps[nj] = self.here();
                    nj += 1;
                    try self.push(.{ .op = .jmp });
                    self.p.prog[sp].y = self.here();
                }
                for (jumps[0..nj]) |j| self.p.prog[j].x = self.here();
            },
            .repeat => try self.emitRepeat(nd),
        }
    }

    fn emitRepeat(self: *Compiler, nd: Node) error{TooComplex}!void {
        const child = self.nodes[nd.child];
        const one_char = child.kind == .inst and switch (child.inst.op) {
            .char, .any, .set, .class => true,
            else => false,
        };
        if (one_char) {
            try self.push(.{ .op = .rep, .x = nd.min, .y = nd.max, .lazy = nd.lazy });
            try self.push(child.inst);
            return;
        }
        var k: usize = 0;
        while (k < nd.min) : (k += 1) try self.emit(nd.child);
        if (nd.max == inf) {
            if (self.p.n_loops >= max_loops) return error.TooComplex;
            const slot: u8 = @intCast(self.p.n_loops);
            self.p.n_loops += 1;
            const head = self.here();
            try self.push(.{ .op = .loop, .ch = slot, .lazy = nd.lazy });
            try self.emit(nd.child);
            try self.push(.{ .op = .jmp, .x = head });
            self.p.prog[head].y = self.here();
            return;
        }
        // Optional copies: split body, end; body; …; end.
        var splits: [16]u16 = undefined;
        var ns: usize = 0;
        while (k < nd.max) : (k += 1) {
            if (ns >= splits.len) return error.TooComplex;
            splits[ns] = self.here();
            ns += 1;
            try self.push(.{ .op = .split });
            try self.emit(nd.child);
        }
        const end = self.here();
        for (splits[0..ns]) |sp| {
            if (nd.lazy) {
                self.p.prog[sp].x = end;
                self.p.prog[sp].y = sp + 1;
            } else {
                self.p.prog[sp].x = sp + 1;
                self.p.prog[sp].y = end;
            }
        }
    }
};

const testing = std.testing;

test "pattern basics" {
    var p = Pattern.compile("foo", true);
    try testing.expectEqual(@as(?usize, 5), p.matchAt("a foo", 2));
    try testing.expect(p.find("xx FOO", 0) != null);
    p = Pattern.compile("Foo", true);
    try testing.expect(p.find("xx foo", 0) == null);
    p = Pattern.compile("\\<is\\>", true);
    try testing.expectEqual(@as(usize, 5), p.find("this is", 0).?.start);
    p = Pattern.compile("^ *$", true);
    try testing.expect(p.find("   ", 0) != null);
    try testing.expect(p.find(" a ", 0) == null);
    p = Pattern.compile("a.c", false);
    try testing.expect(p.find("xabcx", 0) != null);
    p = Pattern.compile("[0-9]\\+", false);
    try testing.expectEqual(Match{ .start = 4, .end = 7 }, p.find("abc 123 x", 0).?);
    p = Pattern.compile("x\\c", false);
    try testing.expect(p.find("X", 0) != null);
}

fn expectFind(pat: []const u8, line: []const u8, want: ?[]const u8) !void {
    const p = Pattern.compile(pat, false);
    try testing.expect(p.err == null);
    const m = p.find(line, 0);
    if (want) |w| {
        try testing.expect(m != null);
        try testing.expectEqualStrings(w, line[m.?.start..m.?.end]);
    } else try testing.expect(m == null);
}

test "pattern: groups, alternation, braces, \\zs \\ze" {
    try expectFind("\\(ab\\)\\+", "xababy", "abab");
    try expectFind("foo\\|bar", "a bar foo", "bar");
    try expectFind("\\%(a\\|b\\)c", "xbc", "bc");
    try expectFind("a\\{2,3}", "aaaa", "aaa");
    try expectFind("a\\{-1,}", "aaaa", "a");
    try expectFind("x\\{2}", "xx", "xx");
    try expectFind("x\\{3}", "xx", null);
    try expectFind("foo\\zsbar", "foobar", "bar");
    try expectFind("foo\\zebar", "foobar foobaz", "foo");
    try expectFind("^a\\|b$", "cab", "b");
    try expectFind("\\(a*\\)*b", "aab", "aab");
    try expectFind("a\\nb", "a b", null);
    var p = Pattern.compile("\\(\\w\\+\\) = \\(\\w\\+\\)", false);
    var caps: Caps = undefined;
    const m = p.findCaps("let x = y;", 0, &caps).?;
    try testing.expectEqual(Match{ .start = 4, .end = 9 }, m);
    try testing.expectEqual(@as(usize, 4), caps[2]);
    try testing.expectEqual(@as(usize, 5), caps[3]);
    try testing.expectEqual(@as(usize, 8), caps[4]);
    p = Pattern.compile("\\(a", false);
    try testing.expectEqual(Error.unmatched_open, p.err.?);
    p = Pattern.compile("a\\)", false);
    try testing.expectEqual(Error.unmatched_close, p.err.?);
    try testing.expect(p.find("a)", 0) == null);
}

test "match walk skips overlaps; search offsets parse like Vim's" {
    const p = Pattern.compile("aa", false);
    var it = Iter{ .pat = &p, .line = "aaaaa" };
    try testing.expectEqual(@as(usize, 0), it.next().?.start);
    try testing.expectEqual(@as(usize, 2), it.next().?.start);
    try testing.expect(it.next() == null);
    const e = Pattern.compile("x*", false);
    var it2 = Iter{ .pat = &e, .line = "ab" };
    try testing.expectEqual(@as(usize, 0), it2.next().?.start);
    try testing.expectEqual(@as(usize, 1), it2.next().?.start);
    try testing.expect(it2.next() == null);

    const cases = .{
        .{ "", Offset{}, "" },
        .{ "e", Offset{ .end = true }, "" },
        .{ "e+1", Offset{ .end = true, .off = 1 }, "" },
        .{ "e-", Offset{ .end = true, .off = -1 }, "" },
        .{ "s+2", Offset{ .off = 2 }, "" },
        .{ "b-1", Offset{ .off = -1 }, "" },
        .{ "+", Offset{ .line = true, .off = 1 }, "" },
        .{ "3", Offset{ .line = true, .off = 3 }, "" },
        .{ "-12;/x", Offset{ .line = true, .off = -12 }, ";/x" },
        .{ " e", Offset{}, " e" },
    };
    inline for (cases) |c| {
        const r = Offset.parse(c[0]);
        try testing.expectEqual(c[1], r.off);
        try testing.expectEqualStrings(c[2], r.rest);
    }
}
