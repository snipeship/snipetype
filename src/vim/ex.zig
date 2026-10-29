//! Ex command line (`:`): ranges (`N`, `.`, `$`, `%`, `'x`, `'<,'>`,
//! `+N`/`-N`), `:N`, `:s`, `:&`, `:d`, `:y`, `:m`, `:t`/`:co`, `:>`/`:<`,
//! `:j`, `:p`, `:g`/`:v`, `:norm`, `:noh`, `:u`/`:red`, and the commands the
//! app acts on (`:w`, `:wq`, `:x`, `:q`, `:q!`, `:e!`, `:hint`). `|`
//! separates commands, except after `:g`, `:v` and `:norm`, which take the
//! rest of the line.

const std = @import("std");
const editor_mod = @import("editor.zig");
const VimEditor = editor_mod.VimEditor;
const Pos = editor_mod.Pos;
const jumps = @import("jumps.zig");
const search = @import("search.zig");
const global_cmd = @import("global.zig");

const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(self: *const Scanner) u8 {
        return if (self.i < self.s.len) self.s[self.i] else 0;
    }

    fn skipSpaces(self: *Scanner) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
    }

    fn number(self: *Scanner) ?i64 {
        const start = self.i;
        while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
        if (self.i == start) return null;
        return std.fmt.parseInt(i64, self.s[start..self.i], 10) catch std.math.maxInt(i32);
    }

    fn rest(self: *const Scanner) []const u8 {
        return std.mem.trim(u8, self.s[@min(self.i, self.s.len)..], " \t");
    }
};

const AddrError = error{ BadMark, NoPattern, NotFound };

/// One address (1-based line number, may be 0), or null when none.
fn parseAddr(ed: *VimEditor, s: *Scanner) AddrError!?i64 {
    var base: i64 = undefined;
    const c = s.peek();
    if (std.ascii.isDigit(c)) {
        base = s.number().?;
    } else if (c == '.') {
        s.i += 1;
        base = @intCast(ed.cursor.row + 1);
    } else if (c == '$') {
        s.i += 1;
        base = @intCast(ed.buffer.lineCount());
    } else if (c == '\'') {
        s.i += 1;
        const m = s.peek();
        s.i += 1;
        const row: usize = switch (m) {
            '<' => if (ed.last_visual) |v| @min(v.anchor.row, v.cursor.row) else return error.BadMark,
            '>' => if (ed.last_visual) |v| @max(v.anchor.row, v.cursor.row) else return error.BadMark,
            'a'...'z' => if (jumps.Lists.mark(&ed.buffer, m)) |p| p.row else return error.BadMark,
            '\'' => if (jumps.Lists.pcmark(&ed.buffer)) |p| p.row else return error.BadMark,
            else => return error.BadMark,
        };
        base = @intCast(row + 1);
    } else if (c == '/' or c == '?') {
        // `/pat/` and `?pat?`: the next line down (up) that matches,
        // wrapping around the buffer; an empty pattern is the last one.
        s.i += 1;
        const body = s.s[s.i..];
        const e = splitAt(body, c);
        s.i += @min(e + 1, body.len);
        const src = if (e > 0) body[0..e] else ed.lastPattern() orelse return error.NoPattern;
        ed.setPattern(src);
        const pat = ed.compile(ed.lastPattern().?);
        const n = ed.buffer.lineCount();
        var row = ed.cursor.row;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            row = if (c == '/') (row + 1) % n else (row + n - 1) % n;
            if (pat.find(ed.buffer.getLine(row), 0) != null) break;
        } else {
            ed.statusFmt("E486: Pattern not found: {s}", .{ed.lastPattern().?});
            return error.NotFound;
        }
        base = @intCast(row + 1);
    } else if (c == '+' or c == '-') {
        base = @intCast(ed.cursor.row + 1);
    } else return null;
    while (s.peek() == '+' or s.peek() == '-') {
        const neg = s.peek() == '-';
        s.i += 1;
        const n = s.number() orelse 1;
        base = if (neg) base - n else base + n;
    }
    return base;
}

fn clampRow(ed: *const VimEditor, line1: i64) usize {
    if (line1 <= 1) return 0;
    return @min(@as(usize, @intCast(line1 - 1)), ed.buffer.lastRow());
}

/// Runs a command line: `|`-separated commands, stopping at the first
/// that fails.
pub fn execute(ed: *VimEditor, line: []const u8) anyerror!void {
    var rest = line;
    while (true) {
        const end = commandEnd(rest);
        ed.failed = false;
        try executeOne(ed, rest[0..end]);
        if (end >= rest.len or ed.failed) return;
        rest = rest[end + 1 ..];
    }
}

/// End of the first command of `s`: the first unescaped `|`, or the end of
/// the line for commands that take it all (`:g`, `:v`, `:norm`).
fn commandEnd(s: []const u8) usize {
    var i: usize = 0;
    // Skip the range: addresses, marks, patterns and separators.
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\'' and i + 1 < s.len) {
            i += 1;
        } else if (c == '/' or c == '?') {
            i += 1 + splitAt(s[i + 1 ..], c);
        } else if (!(std.ascii.isDigit(c) or c == ':' or c == ' ' or c == '.' or c == '$' or c == '%' or c == ',' or c == ';' or c == '+' or c == '-')) break;
    }
    var e = i;
    while (e < s.len and std.ascii.isAlphabetic(s[e])) e += 1;
    const name = s[i..e];
    if (is(name, "g", "global") or is(name, "v", "vglobal") or is(name, "norm", "normal")) return s.len;
    var j = e;
    // `:s` sees a `|` in its pattern and replacement as text (Vim's do_sub
    // skips both before looking for the next command).
    if (is(name, "s", "substitute") and j < s.len and !std.ascii.isAlphanumeric(s[j]) and std.mem.indexOfScalar(u8, " \t\\\"|&", s[j]) == null) {
        const d = s[j];
        j += 1;
        j += splitAt(s[j..], d);
        if (j < s.len) j += 1 + splitAt(s[j + 1 ..], d);
    }
    while (j < s.len) : (j += 1) {
        if (s[j] == '\\' and j + 1 < s.len) {
            j += 1;
        } else if (s[j] == '|') return j;
    }
    return s.len;
}

/// One command (no `|`).
pub fn executeOne(ed: *VimEditor, cmd: []const u8) !void {
    var s = Scanner{ .s = cmd };
    while (s.peek() == ':' or s.peek() == ' ') s.i += 1;
    if (s.i >= s.s.len) return;

    var a1: i64 = @intCast(ed.cursor.row + 1);
    var b1: i64 = a1;
    var given = false;
    if (s.peek() == '%') {
        s.i += 1;
        a1 = 1;
        b1 = @intCast(ed.buffer.lineCount());
        given = true;
    } else {
        const first = parseAddr(ed, &s) catch |e| return addrError(ed, e);
        if (first) |a| {
            a1 = a;
            b1 = a;
            given = true;
        }
        if (s.peek() == ',' or s.peek() == ';') {
            // ';' moves the cursor to the first line before the second
            // address is read, so `:1;+1` is lines 1-2.
            if (s.peek() == ';') {
                ed.cursor.row = clampRow(ed, a1);
                ed.clampNormal();
            }
            s.i += 1;
            const second = parseAddr(ed, &s) catch |e| return addrError(ed, e);
            b1 = second orelse a1;
            given = true;
        }
    }
    if (b1 < a1) std.mem.swap(i64, &a1, &b1);
    s.skipSpaces();

    // Command name: letters (plus '!'), or a run of one symbol.
    const name_start = s.i;
    if (std.ascii.isAlphabetic(s.peek())) {
        while (std.ascii.isAlphabetic(s.peek())) s.i += 1;
    } else if (s.peek() == '>' or s.peek() == '<') {
        const sym = s.peek();
        while (s.peek() == sym) s.i += 1;
    } else if (s.peek() == '&') {
        // `:&&`: the command `&` with the flag `&` (keep the flags).
        s.i += 1;
    }
    const name = s.s[name_start..s.i];
    var bang = false;
    if (s.peek() == '!') {
        bang = true;
        s.i += 1;
    }
    const args = s.rest();
    const n_lines: i64 = @intCast(ed.buffer.lineCount());

    if (name.len == 0) {
        if (bang or args.len > 0) return unknown(ed, cmd);
        // Not a jump: `''` and Ctrl-O do not come back here (as in Vim).
        if (given) ed.gotoLine(clampRow(ed, b1));
        return;
    }
    if (b1 > n_lines and given) {
        ed.setStatus("E16: Invalid range");
        return ed.fail();
    }
    const a = clampRow(ed, a1);
    const b = clampRow(ed, b1);

    if (is(name, "g", "global") or is(name, "v", "vglobal")) {
        const all = !given;
        return global_cmd.global(ed, if (all) 0 else a, if (all) ed.buffer.lastRow() else b, args, bang or name[0] == 'v');
    }
    if (is(name, "norm", "normal")) return global_cmd.normal(ed, a, b, given, s.s[@min(name_start + name.len + @intFromBool(bang), s.s.len)..]);
    if (is(name, "p", "print") or is(name, "P", "Print")) {
        ed.gotoLine(b);
        return;
    }
    if (is(name, "s", "substitute")) return substitute(ed, a, b, args, false);
    if (name[0] == '&') return substitute(ed, a, b, args, true);
    if (is(name, "d", "delete") or is(name, "y", "yank")) {
        const yank = name[0] == 'y';
        var rs = Scanner{ .s = args };
        var reg: ?u8 = null;
        if (rs.peek() != 0 and !std.ascii.isDigit(rs.peek())) {
            reg = rs.peek();
            rs.i += 1;
            rs.skipSpaces();
        }
        var lo = a;
        var hi = b;
        if (rs.number()) |cnt| {
            lo = b;
            hi = @min(b + @as(usize, @intCast(@max(cnt, 1))) - 1, ed.buffer.lastRow());
        }
        const text = try ed.buffer.copyLines(ed.allocator, lo, hi);
        defer ed.allocator.free(text);
        if (yank) {
            try ed.regs.yank(reg, text, true);
        } else {
            try ed.regs.delete(reg, text, true, false);
            // Vim's ex_operators: :d :> :< set the previous-context mark.
            if (!ed.in_global) try ed.setPcmark();
            ed.markUndoPos(.{ .row = lo, .col = ed.buffer.firstNonBlank(lo) });
            try ed.buffer.deleteLines(lo, hi);
            ed.gotoLine(lo);
        }
        return;
    }
    if (is(name, "m", "move") or is(name, "t", "t") or is(name, "co", "copy")) {
        var ts = Scanner{ .s = args };
        const dest1 = (parseAddr(ed, &ts) catch |e| return addrError(ed, e)) orelse {
            ed.setStatus("E14: Invalid address");
            return ed.fail();
        };
        const dest: usize = @intCast(std.math.clamp(dest1, 0, n_lines));
        const n = b - a + 1;
        const text = try ed.buffer.copyLines(ed.allocator, a, b);
        defer ed.allocator.free(text);
        if (name[0] == 'm') {
            if (dest >= a + 1 and dest < b + 1) {
                ed.setStatus("E134: Cannot move a range of lines into itself");
                return ed.fail();
            }
            if (dest == b + 1 or dest == a) {
                ed.gotoLine(b);
                return;
            }
            try ed.buffer.deleteLines(a, b);
            const at = if (dest > b) dest - n else dest;
            try ed.buffer.insertLines(at, text);
            ed.gotoLine(at + n - 1);
        } else {
            try ed.buffer.insertLines(dest, text);
            ed.gotoLine(dest + n - 1);
        }
        ed.buffer.clearLine();
        return;
    }
    if (name[0] == '>' or name[0] == '<') {
        if (!ed.in_global) try ed.setPcmark();
        var row = a;
        while (row <= b) : (row += 1) try ed.shiftLine(row, name[0] == '>', name.len);
        ed.gotoLine(b);
        return;
    }
    if (is(name, "j", "join")) {
        const hi = if (a == b) b + 1 else b;
        if (!try ed.joinLines(a, hi - a + 1, !bang)) return ed.fail();
        // Unlike J, :join leaves the cursor on the first non-blank.
        ed.cursor.col = ed.buffer.firstNonBlank(ed.cursor.row);
        ed.clampNormal();
        ed.setWant();
        return;
    }
    if (is(name, "noh", "nohlsearch")) {
        ed.hl_active = false;
        return;
    }
    if (is(name, "u", "undo")) return ed.undoRedo(true);
    if (is(name, "red", "redo")) return ed.undoRedo(false);
    if (is(name, "ea", "earlier") or is(name, "lat", "later")) {
        // A count of changes; time units (10s, 1f) are not kept.
        const arg = std.mem.trim(u8, args, " ");
        const n = if (arg.len == 0) 1 else std.fmt.parseInt(usize, arg, 10) catch {
            ed.setStatus("E475: Invalid argument");
            return ed.fail();
        };
        return ed.undoTravel(name[0] == 'e', n);
    }
    if (is(name, "w", "write") or is(name, "up", "update")) {
        ed.result.ex = .write;
        return;
    }
    if (is(name, "wq", "wq") or is(name, "x", "xit") or is(name, "exi", "exit") or is(name, "wqa", "wqall") or is(name, "xa", "xall")) {
        ed.result.ex = .write_quit;
        return;
    }
    if (is(name, "q", "quit") or is(name, "qa", "qall") or is(name, "quita", "quitall")) {
        ed.result.ex = if (bang) .quit_force else .quit;
        return;
    }
    if (is(name, "e", "edit")) {
        if (!bang) return unknown(ed, cmd);
        ed.result.ex = .restart;
        return;
    }
    if (std.mem.eql(u8, name, "hint")) {
        ed.result.ex = .hint;
        return;
    }
    return unknown(ed, cmd);
}

/// `name` is an abbreviation of `full` at least as long as `min`.
fn is(name: []const u8, min: []const u8, full: []const u8) bool {
    return name.len >= min.len and name.len <= full.len and std.mem.startsWith(u8, full, name);
}

fn unknown(ed: *VimEditor, cmd: []const u8) void {
    ed.statusFmt("E492: Not an editor command: {s}", .{std.mem.trim(u8, cmd, " ")});
    ed.fail();
}

fn addrError(ed: *VimEditor, e: AddrError) void {
    switch (e) {
        error.BadMark => ed.setStatus("E20: Mark not set"),
        error.NoPattern => ed.setStatus("E35: No previous regular expression"),
        error.NotFound => {},
    }
    ed.fail();
}

/// Index of the next unescaped `delim` in `s` (or s.len).
pub fn splitAt(s: []const u8, delim: u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == delim) return i;
    }
    return s.len;
}

fn substitute(ed: *VimEditor, a: usize, b: usize, args: []const u8, repeat: bool) !void {
    var global = false;
    var icase: ?bool = null;
    var silent = false;
    var count_only = false;
    var flags: []const u8 = "";
    if (repeat or args.len == 0 or std.ascii.isAlphanumeric(args[0]) or args[0] == '&') {
        if (!ed.sub.valid) {
            ed.setStatus("E35: No previous regular expression");
            return ed.fail();
        }
        flags = args;
        if (flags.len > 0 and flags[0] == '&') {
            global = ed.sub.global;
            flags = flags[1..];
        }
    } else {
        const delim = args[0];
        const body = args[1..];
        const pe = splitAt(body, delim);
        const pat = body[0..pe];
        var rep: []const u8 = "";
        if (pe < body.len) {
            const after = body[pe + 1 ..];
            const re = splitAt(after, delim);
            rep = after[0..re];
            if (re < after.len) flags = after[re + 1 ..];
        }
        const real_pat = if (pat.len > 0) pat else ed.lastPattern() orelse {
            ed.setStatus("E35: No previous regular expression");
            return ed.fail();
        };
        var pat_tmp: [256]u8 = undefined;
        const pn = @min(real_pat.len, pat_tmp.len);
        @memcpy(pat_tmp[0..pn], real_pat[0..pn]);
        ed.sub.pat.clearRetainingCapacity();
        try ed.sub.pat.appendSlice(ed.allocator, pat_tmp[0..pn]);
        // `~` is the previous replacement string (Vim's regtilde).
        var new_rep = std.ArrayList(u8).empty;
        defer new_rep.deinit(ed.allocator);
        var k: usize = 0;
        while (k < rep.len) : (k += 1) {
            if (rep[k] == '\\' and k + 1 < rep.len) {
                try new_rep.appendSlice(ed.allocator, rep[k .. k + 2]);
                k += 1;
            } else if (rep[k] == '~') {
                try new_rep.appendSlice(ed.allocator, ed.sub.rep.items);
            } else try new_rep.append(ed.allocator, rep[k]);
        }
        ed.sub.rep.clearRetainingCapacity();
        try ed.sub.rep.appendSlice(ed.allocator, new_rep.items);
        ed.sub.valid = true;
    }
    // `:s/x/y/g 3`: a count after the flags is that many lines from the
    // last line of the range.
    var fl_end: usize = 0;
    while (fl_end < flags.len and !std.ascii.isDigit(flags[fl_end])) fl_end += 1;
    var lo = a;
    var hi = b;
    if (fl_end < flags.len) {
        const cnt = std.fmt.parseInt(usize, std.mem.trim(u8, flags[fl_end..], " "), 10) catch {
            ed.setStatus("E488: Trailing characters");
            return ed.fail();
        };
        if (cnt == 0) {
            ed.setStatus("E939: Positive count required");
            return ed.fail();
        }
        lo = b;
        hi = @min(b +| (cnt - 1), ed.buffer.lastRow());
        flags = flags[0..fl_end];
    }
    for (flags) |f| switch (f) {
        'g' => global = !global,
        'i' => icase = true,
        'I' => icase = false,
        'e' => silent = true,
        'n' => count_only = true,
        'c', ' ' => {},
        else => {
            ed.setStatus("E488: Trailing characters");
            return ed.fail();
        },
    };
    ed.sub.global = global;
    const pat_src = ed.sub.pat.items;
    ed.setPattern(pat_src);
    ed.hl_active = true;
    var pat = ed.compile(pat_src);
    if (pat.err) |e| {
        ed.setStatus(e.message());
        return ed.fail();
    }
    if (icase) |ic| pat.icase = ic;
    var caps: search.Caps = undefined;

    var total: usize = 0;
    var lines: usize = 0;
    var last_row: usize = lo;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(ed.allocator);
    var row = lo;
    var last = hi;
    while (row <= last and row <= ed.buffer.lastRow()) : (row += 1) {
        const line = ed.buffer.getLine(row);
        out.clearRetainingCapacity();
        // Vim's do_sub loop: search on from the end of the previous match;
        // an empty match where that one ended does not count, and nothing
        // is tried at the end of the line after a match.
        var col: usize = 0;
        var matchcol: usize = 0;
        var prev: usize = std.math.maxInt(usize);
        var n: usize = 0;
        var next = pat.findCaps(line, 0, &caps);
        while (next) |m| {
            if (matchcol == prev and m.end == matchcol) {
                if (matchcol >= line.len) break;
                matchcol += 1;
            } else {
                try out.appendSlice(ed.allocator, line[col..m.start]);
                try expandReplacement(ed.allocator, &out, ed.sub.rep.items, line, m, &caps);
                col = m.end;
                matchcol = m.end;
                prev = matchcol;
                n += 1;
                if (!global) break;
            }
            if (matchcol >= line.len) break;
            next = pat.findCaps(line, matchcol, &caps);
        }
        if (n == 0) continue;
        total += n;
        lines += 1;
        last_row = row;
        if (count_only) continue;
        if (col < line.len) try out.appendSlice(ed.allocator, line[col..]);
        ed.markUndoPos(.{ .row = row });
        // `\r` in the replacement splits the line.
        const nl = std.mem.indexOfScalar(u8, out.items, '\n') orelse {
            try ed.buffer.setLine(row, out.items);
            continue;
        };
        const added = std.mem.count(u8, out.items, "\n");
        try ed.buffer.insertLines(row + 1, out.items[nl + 1 ..]);
        try ed.buffer.setLine(row, out.items[0..nl]);
        row += added;
        last += added;
        last_row = row;
    }
    if (ed.in_global) {
        // :g reports the total; a line without a match is not an error.
        ed.g_subs += total;
        ed.g_sub_lines += lines;
        if (total > 0 and !count_only) ed.gotoLine(last_row);
        return;
    }
    if (total == 0) {
        if (!silent) {
            ed.statusFmt("E486: Pattern not found: {s}", .{pat_src});
            ed.fail();
        }
        return;
    }
    if (count_only) {
        // :s///n only reports; the cursor stays on its line.
        ed.gotoLine(ed.cursor.row);
        ed.statusFmt("{d} match{s} on {d} line{s}", .{ total, if (total == 1) "" else "es", lines, if (lines == 1) "" else "s" });
        return;
    }
    // A substitute is a jump.
    try ed.setPcmark();
    ed.gotoLine(last_row);
    if (total > 2 or lines > 2) {
        ed.statusFmt("{d} substitution{s} on {d} line{s}", .{ total, if (total == 1) "" else "s", lines, if (lines == 1) "" else "s" });
    }
}

/// Vim's sub-replace-special: `&` and `\0` insert the match, `\1`..`\9` a
/// group; `\u` `\l` change the case of the next char, `\U` `\L` of the
/// rest (up to `\E` or `\e`); `\r` and `\n` break the line (Vim inserts a
/// NUL for `\n`); `\t` is a tab; `\&` is a literal '&'; `\x` is `x`.
fn expandReplacement(allocator: std.mem.Allocator, out: *std.ArrayList(u8), rep: []const u8, line: []const u8, m: search.Match, caps: *const search.Caps) !void {
    const Case = enum { none, upper, lower };
    var one: Case = .none;
    var all: Case = .none;
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        var text: []const u8 = rep[i .. i + 1];
        var nl = false;
        if (rep[i] == '&') {
            text = line[m.start..m.end];
        } else if (rep[i] == '\\' and i + 1 < rep.len) {
            i += 1;
            const e = rep[i];
            switch (e) {
                '0' => text = line[m.start..m.end],
                '1'...'9' => {
                    const k: usize = e - '0';
                    const a = caps[2 * k];
                    const b = caps[2 * k + 1];
                    text = if (a != std.math.maxInt(usize) and b != std.math.maxInt(usize) and a <= b) line[a..b] else "";
                },
                'u', 'l' => {
                    one = if (e == 'u') .upper else .lower;
                    continue;
                },
                'U', 'L' => {
                    all = if (e == 'U') .upper else .lower;
                    continue;
                },
                'E', 'e' => {
                    all = .none;
                    continue;
                },
                'r', 'n' => nl = true,
                't' => text = "\t",
                else => text = rep[i .. i + 1],
            }
        }
        if (nl) {
            try out.append(allocator, '\n');
            continue;
        }
        for (text) |c0| {
            var c = c0;
            if (all == .upper) c = std.ascii.toUpper(c) else if (all == .lower) c = std.ascii.toLower(c);
            if (one != .none) {
                c = if (one == .upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
                one = .none;
            }
            try out.append(allocator, c);
        }
    }
}
