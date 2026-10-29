//! `:g/pat/cmd`, `:g!`/`:v` and `:normal`. `:g` marks the matching lines
//! first (as tracked positions, so deleted lines drop out), then runs
//! `cmd` on each marked line that still exists with the cursor on it. The
//! whole command is one undo step.

const std = @import("std");
const editor_mod = @import("editor.zig");
const VimEditor = editor_mod.VimEditor;
const ex = @import("ex.zig");
const jumps = @import("jumps.zig");

/// `:[range]g[!]/pat/[cmd]` (`invert`: `:g!` and `:v`). The default range
/// is the whole buffer and the default command `:p` (go to the line).
pub fn global(ed: *VimEditor, a: usize, b: usize, args: []const u8, invert: bool) !void {
    if (ed.in_global) {
        ed.setStatus("E147: Cannot do :global recursive");
        return ed.fail();
    }
    if (args.len == 0) {
        ed.setStatus("E35: No previous regular expression");
        return ed.fail();
    }
    const delim = args[0];
    if (std.ascii.isAlphanumeric(delim) or delim == '\\' or delim == '"' or delim == '|') {
        ed.setStatus("E146: Regular expressions can't be delimited by letters");
        return ed.fail();
    }
    const body = args[1..];
    const pe = ex.splitAt(body, delim);
    const cmd = if (pe < body.len) body[pe + 1 ..] else "";
    var pat_buf: [256]u8 = undefined;
    const src = if (pe > 0) body[0..pe] else ed.lastPattern() orelse {
        ed.setStatus("E35: No previous regular expression");
        return ed.fail();
    };
    const n = @min(src.len, pat_buf.len);
    @memcpy(pat_buf[0..n], src[0..n]);
    const pat_src = pat_buf[0..n];
    ed.setPattern(pat_src);
    const pat = ed.compile(pat_src);
    if (pat.err) |e| {
        ed.setStatus(e.message());
        return ed.fail();
    }

    try jumps.Lists.ensure(&ed.buffer);
    const tracked = &ed.buffer.tracked;
    const base = tracked.items.len;
    defer tracked.shrinkRetainingCapacity(base);
    var row = a;
    while (row <= b) : (row += 1) {
        if ((pat.find(ed.buffer.getLine(row), 0) != null) != invert) {
            try tracked.append(ed.allocator, .{ .pos = .{ .row = row }, .live = true });
        }
    }
    if (tracked.items.len == base) {
        if (invert) {
            ed.statusFmt("Pattern found in every line: {s}", .{pat_src});
        } else ed.statusFmt("Pattern not found: {s}", .{pat_src});
        return;
    }

    try ed.setPcmark();
    const lines0 = ed.buffer.lineCount();
    ed.in_global = true;
    ed.g_subs = 0;
    ed.g_sub_lines = 0;
    defer ed.in_global = false;
    ed.status = "";
    var i = base;
    while (i < tracked.items.len) : (i += 1) {
        const t = tracked.items[i];
        if (!t.live) continue;
        ed.cursor = .{ .row = @min(t.pos.row, ed.buffer.lastRow()) };
        if (std.mem.trim(u8, cmd, " \t").len == 0) {
            ed.gotoLine(ed.cursor.row);
        } else {
            try ex.execute(ed, cmd);
            if (ed.failed) break;
        }
    }
    if (ed.mode == .normal) {
        // Vim's global_exe: after a :s the cursor goes to the first
        // non-blank (whatever ran after it on that line).
        if (ed.g_subs > 0) ed.cursor.col = ed.buffer.firstNonBlank(ed.cursor.row);
        ed.clampNormal();
    }
    ed.setWant();
    // Vim reports the total, not each command's message.
    if (ed.g_subs > 2 or ed.g_sub_lines > 2) {
        ed.statusFmt("{d} substitution{s} on {d} line{s}", .{ ed.g_subs, if (ed.g_subs == 1) "" else "s", ed.g_sub_lines, if (ed.g_sub_lines == 1) "" else "s" });
    } else if (!ed.failed) {
        const lines1 = ed.buffer.lineCount();
        if (lines1 + 2 < lines0) {
            ed.statusFmt("{d} fewer lines", .{lines0 - lines1});
        } else if (lines0 + 2 < lines1) {
            ed.statusFmt("{d} more lines", .{lines1 - lines0});
        } else ed.status = "";
    }
}

/// `:[range]norm[al][!] {keys}`: the keys run in NORMAL on each line of
/// the range (cursor at column 0), or once where the cursor is.
pub fn normal(ed: *VimEditor, a: usize, b: usize, given: bool, raw: []const u8) !void {
    var keys = raw;
    while (keys.len > 0 and (keys[0] == ' ' or keys[0] == '\t')) keys = keys[1..];
    if (keys.len == 0) {
        ed.setStatus("E471: Argument required");
        return ed.fail();
    }
    // The keys may fail without failing `:normal` itself.
    defer ed.failed = false;
    if (!given) return ed.runNormal(keys);
    try jumps.Lists.ensure(&ed.buffer);
    const tracked = &ed.buffer.tracked;
    const base = tracked.items.len;
    defer tracked.shrinkRetainingCapacity(base);
    var row = a;
    while (row <= b) : (row += 1) try tracked.append(ed.allocator, .{ .pos = .{ .row = row }, .live = true });
    var i = base;
    while (i < tracked.items.len) : (i += 1) {
        const t = tracked.items[i];
        if (!t.live) continue;
        ed.cursor = .{ .row = @min(t.pos.row, ed.buffer.lastRow()) };
        try ed.runNormal(keys);
    }
}
