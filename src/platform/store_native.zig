//! Native persistence: where the config and history files live, and the
//! file I/O behind `App.loadSaved` / `takeRecordLine` / `takeConfigJson`.
//!
//! Paths (macOS uses the same XDG layout):
//! - `$SNIPETYPE_HOME/config.json` and `$SNIPETYPE_HOME/history.jsonl` when
//!   `SNIPETYPE_HOME` is set;
//! - else `${XDG_CONFIG_HOME:-~/.config}/snipetype/config.json` and
//!   `${XDG_STATE_HOME:-~/.local/state}/snipetype/history.jsonl`.
//!
//! The config (and `custom.txt`, the custom-mode text, next to it) is
//! rewritten atomically (temp file + rename). A symlinked config stays a
//! symlink: the link is resolved and its target is replaced. History is
//! append-only JSONL, read in chunks of whole lines (no size cap); a file
//! over `compact_threshold` is compacted to the personal-best lines plus
//! the newest `compact_keep` runs. Every operation reports failure as a
//! bool/null so the caller can show one toast and carry on; nothing here
//! panics on I/O. Native only (`std.Io` file APIs); the formats live in
//! core/history.zig.

const std = @import("std");
const Io = std.Io;

pub const config_name = "config.json";
pub const history_name = "history.jsonl";
pub const custom_name = "custom.txt";
/// Whole-file reads larger than this are refused (config, custom text).
pub const max_read_bytes: usize = 16 << 20;
/// Custom text cap (TypingTest keeps at most 64 KiB of it).
pub const max_custom_bytes: usize = 1 << 20;
/// History is streamed in chunks of about this size (cut at a newline).
pub const history_chunk: usize = 1 << 20;
/// History files larger than this are compacted at startup.
pub const compact_threshold_default: u64 = 16 << 20;
/// Runs kept by compaction (plus one line per personal best).
pub const compact_keep_default: usize = 5000;
/// Symlink hops followed when saving.
const max_link_depth = 8;

/// Resolved file locations (absolute or relative paths, owned by `buf`).
pub const Paths = struct {
    config_dir: []const u8,
    state_dir: []const u8,
    buf: [3 * Io.Dir.max_path_bytes]u8 = undefined,

    config_path_buf: [Io.Dir.max_path_bytes]u8 = undefined,
    history_path_buf: [Io.Dir.max_path_bytes]u8 = undefined,
    custom_path_buf: [Io.Dir.max_path_bytes]u8 = undefined,

    pub fn configPath(self: *Paths) []const u8 {
        return join(&self.config_path_buf, self.config_dir, config_name);
    }

    pub fn historyPath(self: *Paths) []const u8 {
        return join(&self.history_path_buf, self.state_dir, history_name);
    }

    pub fn customPath(self: *Paths) []const u8 {
        return join(&self.custom_path_buf, self.config_dir, custom_name);
    }
};

fn join(buf: []u8, dir: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch buf[0..0];
}

/// Resolve the directories from an environment map (anything with
/// `get(key) ?[]const u8`). Null when neither SNIPETYPE_HOME, the XDG
/// variables nor HOME are set.
pub fn resolve(env: anytype, out: *Paths) ?void {
    var used: usize = 0;
    const put = struct {
        fn f(p: *Paths, n: *usize, comptime fmt: []const u8, args: anytype) ?[]const u8 {
            const s = std.fmt.bufPrint(p.buf[n.*..], fmt, args) catch return null;
            n.* += s.len;
            return s;
        }
    }.f;
    if (nonEmpty(env.get("SNIPETYPE_HOME"))) |home| {
        out.config_dir = put(out, &used, "{s}", .{trimSlash(home)}) orelse return null;
        out.state_dir = out.config_dir;
        return;
    }
    const home = nonEmpty(env.get("HOME"));
    out.config_dir = if (xdgDir(env.get("XDG_CONFIG_HOME"))) |x|
        put(out, &used, "{s}/snipetype", .{trimSlash(x)}) orelse return null
    else if (home) |h|
        put(out, &used, "{s}/.config/snipetype", .{trimSlash(h)}) orelse return null
    else
        return null;
    out.state_dir = if (xdgDir(env.get("XDG_STATE_HOME"))) |x|
        put(out, &used, "{s}/snipetype", .{trimSlash(x)}) orelse return null
    else if (home) |h|
        put(out, &used, "{s}/.local/state/snipetype", .{trimSlash(h)}) orelse return null
    else
        return null;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

/// XDG base directories must be absolute; relative ones are ignored (spec).
fn xdgDir(v: ?[]const u8) ?[]const u8 {
    const s = nonEmpty(v) orelse return null;
    return if (s[0] == '/') s else null;
}

fn trimSlash(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, "/");
    return if (t.len == 0) "/" else t;
}

/// File-backed store for one run.
pub const Store = struct {
    io: Io,
    paths: Paths,
    /// `--no-save`: reads still happen, writes are skipped.
    read_only: bool = false,
    /// Directories were created (lazily, on the first write).
    dirs_ready: bool = false,
    /// History compaction bounds (tests lower them).
    compact_threshold: u64 = compact_threshold_default,
    compact_keep: usize = compact_keep_default,

    /// Read a whole file; null when missing or unreadable.
    pub fn read(self: *Store, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, path, gpa, .limited(max_read_bytes)) catch null;
    }

    pub fn readConfig(self: *Store, gpa: std.mem.Allocator) ?[]u8 {
        return self.read(gpa, self.paths.configPath());
    }

    pub fn readHistory(self: *Store, gpa: std.mem.Allocator) ?[]u8 {
        return self.read(gpa, self.paths.historyPath());
    }

    /// The saved custom text (null when missing or empty).
    pub fn readCustom(self: *Store, gpa: std.mem.Allocator) ?[]u8 {
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, self.paths.customPath(), gpa, .limited(max_custom_bytes)) catch return null;
        if (bytes.len == 0) {
            gpa.free(bytes);
            return null;
        }
        return bytes;
    }

    /// Replace `custom.txt` atomically (symlinks kept).
    pub fn writeCustom(self: *Store, text: []const u8) bool {
        if (self.read_only) return true;
        if (!self.ensureDirs()) return false;
        return self.writeAtomic(self.paths.customPath(), text);
    }

    /// Size of the history file (null when missing).
    pub fn historySize(self: *Store) ?u64 {
        const st = Io.Dir.cwd().statFile(self.io, self.paths.historyPath(), .{}) catch return null;
        return st.size;
    }

    /// Feed the whole history to `sink.chunk(bytes)` in chunks of whole
    /// lines (about `history_chunk` bytes each; a line longer than a chunk
    /// is skipped). False when the file is missing or unreadable.
    pub fn streamHistory(self: *Store, gpa: std.mem.Allocator, sink: anytype) bool {
        const file = Io.Dir.cwd().openFile(self.io, self.paths.historyPath(), .{}) catch return false;
        defer file.close(self.io);
        const buf = gpa.alloc(u8, history_chunk) catch return false;
        defer gpa.free(buf);
        var offset: u64 = 0;
        // Bytes at buf[0..carry] are the unfinished line of the last read.
        var carry: usize = 0;
        while (true) {
            const n = file.readPositionalAll(self.io, buf[carry..], offset) catch return false;
            offset += n;
            const filled = carry + n;
            if (n == 0) {
                if (filled > 0) sink.chunk(buf[0..filled]);
                return true;
            }
            if (std.mem.lastIndexOfScalar(u8, buf[0..filled], '\n')) |nl| {
                sink.chunk(buf[0 .. nl + 1]);
                carry = filled - (nl + 1);
                std.mem.copyForwards(u8, buf[0..carry], buf[nl + 1 .. filled]);
            } else if (filled == buf.len) {
                // One line longer than the buffer: drop it up to its end.
                carry = 0;
                offset = self.skipLine(file, offset) orelse return true;
            } else {
                carry = filled;
            }
        }
    }

    /// Offset just after the next '\n' at or after `offset` (null at EOF).
    fn skipLine(self: *Store, file: Io.File, offset: u64) ?u64 {
        var b: [4096]u8 = undefined;
        var off = offset;
        while (true) {
            const n = file.readPositionalAll(self.io, &b, off) catch return null;
            if (n == 0) return null;
            if (std.mem.indexOfScalar(u8, b[0..n], '\n')) |i| return off + i + 1;
            off += n;
        }
    }

    /// True when the history should be compacted (over the threshold and
    /// writable).
    pub fn needsCompaction(self: *Store) bool {
        if (self.read_only) return false;
        const size = self.historySize() orelse return false;
        return size > self.compact_threshold;
    }

    /// Rewrite the history as `pb_lines` (one `"pb":true` record per
    /// personal best, '\n'-terminated) plus the newest `compact_keep`
    /// lines, under the same lock `appendHistory` takes. Old PB lines in
    /// the kept tail are dropped (the fresh ones replace them).
    pub fn compactHistory(self: *Store, gpa: std.mem.Allocator, pb_lines: []const u8) bool {
        if (self.read_only) return true;
        var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const target = self.resolveLink(self.paths.historyPath(), &link_buf);
        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(self.io, target, .{ .mode = .read_write, .lock = .exclusive }) catch return false;
        defer file.close(self.io);
        const size = file.length(self.io) catch return false;
        // The newest lines: at most 2 KiB each (a record line's cap).
        const want: u64 = @min(size, @as(u64, self.compact_keep) * 2048 + 1);
        const tail = gpa.alloc(u8, @intCast(want)) catch return false;
        defer gpa.free(tail);
        const n = file.readPositionalAll(self.io, tail, size - want) catch return false;
        var lines = tail[0..n];
        // Drop a partial first line (unless the tail is the whole file).
        if (want < size) {
            const nl = std.mem.indexOfScalar(u8, lines, '\n') orelse return false;
            lines = lines[nl + 1 ..];
        }
        // Keep the last `compact_keep` non-PB lines.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        out.appendSlice(gpa, pb_lines) catch return false;
        if (pb_lines.len > 0 and pb_lines[pb_lines.len - 1] != '\n') out.append(gpa, '\n') catch return false;
        var start = lines.len;
        var kept: usize = 0;
        while (start > 0 and kept < self.compact_keep) {
            const prev = std.mem.lastIndexOfScalar(u8, lines[0 .. start - 1], '\n');
            const ls = if (prev) |p| p + 1 else 0;
            const line = std.mem.trim(u8, lines[ls..start], " \t\r\n");
            if (line.len > 0 and !isPbLine(line)) kept += 1;
            start = ls;
        }
        var it = std.mem.splitScalar(u8, lines[start..], '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or isPbLine(line)) continue;
            out.appendSlice(gpa, line) catch return false;
            out.append(gpa, '\n') catch return false;
        }
        var tmp_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{target}) catch return false;
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = out.items }) catch return false;
        cwd.rename(tmp, cwd, target, self.io) catch {
            cwd.deleteFile(self.io, tmp) catch {};
            return false;
        };
        return true;
    }

    fn ensureDirs(self: *Store) bool {
        if (self.dirs_ready) return true;
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, self.paths.config_dir) catch return false;
        cwd.createDirPath(self.io, self.paths.state_dir) catch return false;
        self.dirs_ready = true;
        return true;
    }

    /// Append one JSON line (a '\n' is added). False on failure. The file
    /// is locked while appending (two instances never overwrite each
    /// other's record), and a last line without its '\n' (a hand edit, a
    /// crash) gets one first so the new record stays on its own line.
    pub fn appendHistory(self: *Store, line: []const u8) bool {
        if (self.read_only) return true;
        if (!self.ensureDirs()) return false;
        const file = self.lockHistory() orelse return false;
        defer file.close(self.io);
        const end = file.length(self.io) catch return false;
        var last: [1]u8 = .{'\n'};
        if (end > 0) _ = file.readPositionalAll(self.io, &last, end - 1) catch return false;
        const sep: usize = @intFromBool(last[0] != '\n');
        // One write so a crash never leaves half a record without its '\n'.
        var buf: [4096]u8 = undefined;
        if (sep + line.len + 1 <= buf.len) {
            buf[0] = '\n';
            @memcpy(buf[sep..][0..line.len], line);
            buf[sep + line.len] = '\n';
            file.writePositionalAll(self.io, buf[0 .. sep + line.len + 1], end) catch return false;
        } else {
            if (sep == 1) file.writePositionalAll(self.io, "\n", end) catch return false;
            file.writePositionalAll(self.io, line, end + sep) catch return false;
            file.writePositionalAll(self.io, "\n", end + sep + line.len) catch return false;
        }
        return true;
    }

    /// Open the history for appending under its exclusive lock. A
    /// compaction in another instance renames a new file over the path
    /// while we wait for the lock, so the locked file is checked against
    /// the path and reopened when it was replaced (else the record would
    /// go to the deleted file).
    fn lockHistory(self: *Store) ?Io.File {
        const cwd = Io.Dir.cwd();
        for (0..8) |_| {
            const file = cwd.createFile(self.io, self.paths.historyPath(), .{
                .truncate = false,
                .read = true,
                .lock = .exclusive,
            }) catch return null;
            const mine = file.stat(self.io) catch {
                file.close(self.io);
                return null;
            };
            const now = cwd.statFile(self.io, self.paths.historyPath(), .{}) catch null;
            if (now != null and now.?.inode == mine.inode) return file;
            file.close(self.io);
        }
        return null;
    }

    /// Replace the config atomically (write `config.json.tmp`, rename).
    pub fn writeConfig(self: *Store, json: []const u8) bool {
        if (self.read_only) return true;
        if (!self.ensureDirs()) return false;
        return self.writeAtomic(self.paths.configPath(), json);
    }

    /// Write `data` to `path` atomically: a temp file next to the real file
    /// (the symlink's target when `path` is a symlink, so the link stays),
    /// then a rename onto it.
    fn writeAtomic(self: *Store, path: []const u8, data: []const u8) bool {
        var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const final = self.resolveLink(path, &link_buf);
        var tmp_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{final}) catch return false;
        const cwd = Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = data }) catch return false;
        cwd.rename(tmp, cwd, final, self.io) catch {
            cwd.deleteFile(self.io, tmp) catch {};
            return false;
        };
        return true;
    }

    /// Follow symlinks from `path` (relative targets are relative to the
    /// link's directory; at most `max_link_depth` hops). Returns `path`
    /// itself when it is not a symlink (or on any error).
    pub fn resolveLink(self: *Store, path: []const u8, out: *[Io.Dir.max_path_bytes]u8) []const u8 {
        var cur_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        if (path.len > cur_buf.len) return path;
        @memcpy(cur_buf[0..path.len], path);
        var cur: []const u8 = cur_buf[0..path.len];
        var depth: usize = 0;
        while (depth < max_link_depth) : (depth += 1) {
            var target_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().readLink(self.io, cur, &target_buf) catch break;
            const target = target_buf[0..n];
            var next_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const next = if (target.len > 0 and target[0] == '/')
                target
            else if (std.fs.path.dirname(cur)) |dir|
                std.fmt.bufPrint(&next_buf, "{s}/{s}", .{ dir, target }) catch break
            else
                target;
            @memcpy(cur_buf[0..next.len], next);
            cur = cur_buf[0..next.len];
        }
        if (depth == 0) return path;
        @memcpy(out[0..cur.len], cur);
        return out[0..cur.len];
    }
};

/// A compaction PB line (`"pb":true`).
fn isPbLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"pb\":true") != null;
}

// ----------------------------------------------------------------------------
// Tests (no writes to the real home: everything goes to a tmp dir)

const TestEnv = struct {
    pairs: []const [2][]const u8,
    pub fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

test "paths: SNIPETYPE_HOME wins, then XDG, then HOME" {
    const t = std.testing;
    var p: Paths = undefined;

    try t.expect(resolve(TestEnv{ .pairs = &.{ .{ "SNIPETYPE_HOME", "/tmp/st/" }, .{ "HOME", "/home/u" } } }, &p) != null);
    try t.expectEqualStrings("/tmp/st/config.json", p.configPath());
    try t.expectEqualStrings("/tmp/st/history.jsonl", p.historyPath());

    try t.expect(resolve(TestEnv{ .pairs = &.{.{ "HOME", "/home/u" }} }, &p) != null);
    try t.expectEqualStrings("/home/u/.config/snipetype/config.json", p.configPath());
    try t.expectEqualStrings("/home/u/.local/state/snipetype/history.jsonl", p.historyPath());

    try t.expect(resolve(TestEnv{ .pairs = &.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "/xc" }, .{ "XDG_STATE_HOME", "/xs/" }, .{ "SNIPETYPE_HOME", "" } } }, &p) != null);
    try t.expectEqualStrings("/xc/snipetype/config.json", p.configPath());
    try t.expectEqualStrings("/xs/snipetype/history.jsonl", p.historyPath());

    // Relative XDG paths are invalid and ignored.
    try t.expect(resolve(TestEnv{ .pairs = &.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "rel/cfg" } } }, &p) != null);
    try t.expectEqualStrings("/home/u/.config/snipetype/config.json", p.configPath());

    try t.expect(resolve(TestEnv{ .pairs = &.{} }, &p) == null);
}

test "store: atomic config rewrite, history append, read-only" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "{s}/nested/home", .{base_buf[0..base_len]});

    var store: Store = .{ .io = io, .paths = undefined };
    try t.expect(resolve(TestEnv{ .pairs = &.{.{ "SNIPETYPE_HOME", home }} }, &store.paths) != null);

    try t.expect(store.readConfig(t.allocator) == null);
    try t.expect(store.writeConfig("{\"v\":1}"));
    try t.expect(store.writeConfig("{\"v\":1,\"mode\":\"code\"}"));
    const cfg = store.readConfig(t.allocator).?;
    defer t.allocator.free(cfg);
    try t.expectEqualStrings("{\"v\":1,\"mode\":\"code\"}", cfg);

    try t.expect(store.appendHistory("{\"a\":1}"));
    try t.expect(store.appendHistory("{\"a\":2}"));
    store.read_only = true;
    try t.expect(store.appendHistory("{\"a\":3}"));
    try t.expect(store.writeConfig("{}"));
    const hist = store.readHistory(t.allocator).?;
    defer t.allocator.free(hist);
    try t.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", hist);

    // A last line without its newline (hand edit) keeps its own line.
    store.read_only = false;
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/home/history.jsonl", .data = "{\"a\":1}" });
    try t.expect(store.appendHistory("{\"a\":2}"));
    const fixed = store.readHistory(t.allocator).?;
    defer t.allocator.free(fixed);
    try t.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", fixed);
}

fn tmpHome(t: anytype, tmp: *std.testing.TmpDir, buf: *[Io.Dir.max_path_bytes]u8) ![]const u8 {
    var base_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(t.io, &base_buf);
    return std.fmt.bufPrint(buf, "{s}/home", .{base_buf[0..base_len]});
}

test "store: saving through a symlinked config keeps the link" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(t, &tmp, &home_buf);
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "dotfiles");
    try tmp.dir.writeFile(io, .{ .sub_path = "dotfiles/snipetype.json", .data = "{}" });
    // A relative link, as dotfile managers make them.
    try tmp.dir.symLink(io, "../dotfiles/snipetype.json", "home/config.json", .{});

    var store: Store = .{ .io = io, .paths = undefined };
    try t.expect(resolve(TestEnv{ .pairs = &.{.{ "SNIPETYPE_HOME", home }} }, &store.paths) != null);
    try t.expect(store.writeConfig("{\"v\":1}"));
    // Still a link, and the target has the new content.
    var lb: [64]u8 = undefined;
    const n = try tmp.dir.readLink(io, "home/config.json", &lb);
    try t.expectEqualStrings("../dotfiles/snipetype.json", lb[0..n]);
    const got = try tmp.dir.readFileAlloc(io, "dotfiles/snipetype.json", t.allocator, .limited(64));
    defer t.allocator.free(got);
    try t.expectEqualStrings("{\"v\":1}", got);
}

test "store: custom.txt round trip" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(t, &tmp, &home_buf);
    var store: Store = .{ .io = t.io, .paths = undefined };
    try t.expect(resolve(TestEnv{ .pairs = &.{.{ "SNIPETYPE_HOME", home }} }, &store.paths) != null);
    try t.expect(store.readCustom(t.allocator) == null);
    try t.expect(store.writeCustom("my own\ntext"));
    const got = store.readCustom(t.allocator).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("my own\ntext", got);
}

const ChunkSink = struct {
    all: std.ArrayList(u8) = .empty,
    chunks: usize = 0,
    whole_lines: bool = true,
    fn chunk(self: *ChunkSink, bytes: []const u8) void {
        self.chunks += 1;
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') self.whole_lines = false;
        self.all.appendSlice(std.testing.allocator, bytes) catch {};
    }
};

test "store: history streams in chunks of whole lines; compaction keeps PBs" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(t, &tmp, &home_buf);
    var store: Store = .{ .io = io, .paths = undefined, .compact_threshold = 1000, .compact_keep = 3 };
    try t.expect(resolve(TestEnv{ .pairs = &.{.{ "SNIPETYPE_HOME", home }} }, &store.paths) != null);

    // ~2.5 chunks of lines.
    var i: usize = 0;
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(t.allocator);
    var line_buf: [64]u8 = undefined;
    while (expected.items.len < history_chunk * 5 / 2) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "{{\"v\":1,\"n\":{d}}}\n", .{i});
        try expected.appendSlice(t.allocator, line);
    }
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/history.jsonl", .data = expected.items });
    var sink: ChunkSink = .{};
    defer sink.all.deinit(t.allocator);
    try t.expect(store.streamHistory(t.allocator, &sink));
    try t.expect(sink.chunks >= 3 and sink.whole_lines);
    try t.expectEqualStrings(expected.items, sink.all.items);

    // Compaction: fresh PB lines first, then the newest 3 runs (old PB
    // lines in the tail are dropped).
    try tmp.dir.writeFile(io, .{ .sub_path = "home/history.jsonl", .data = expected.items });
    try t.expect(store.appendHistory("{\"v\":1,\"pb\":true,\"old\":1}"));
    try t.expect(store.appendHistory("{\"v\":1,\"n\":\"last\"}"));
    try t.expect(store.needsCompaction());
    try t.expect(store.compactHistory(t.allocator, "{\"v\":1,\"pb\":true,\"key\":\"k\"}\n"));
    const got = store.readHistory(t.allocator).?;
    defer t.allocator.free(got);
    var want_buf: [256]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{{\"v\":1,\"pb\":true,\"key\":\"k\"}}\n{{\"v\":1,\"n\":{d}}}\n{{\"v\":1,\"n\":{d}}}\n{{\"v\":1,\"n\":\"last\"}}\n", .{ i - 2, i - 1 });
    try t.expectEqualStrings(want, got);
    try t.expect(!store.needsCompaction());
    store.read_only = true;
    try t.expect(!store.needsCompaction());
}

test "store: an append waiting on a compaction's lock lands in the new file" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(t, &tmp, &home_buf);
    var store: Store = .{ .io = io, .paths = undefined };
    try t.expect(resolve(TestEnv{ .pairs = &.{.{ "SNIPETYPE_HOME", home }} }, &store.paths) != null);
    try t.expect(store.appendHistory("{\"n\":1}"));

    // Another instance compacting: it holds the old file's lock, renames a
    // new file over the path, then lets go.
    const cwd = Io.Dir.cwd();
    const old = try cwd.openFile(io, store.paths.historyPath(), .{ .mode = .read_write, .lock = .exclusive });
    const Appender = struct {
        fn run(s: *Store, ok: *bool) void {
            ok.* = s.appendHistory("{\"n\":2}");
        }
    };
    var ok = false;
    const th = try std.Thread.spawn(.{}, Appender.run, .{ &store, &ok });
    try io.sleep(.fromMilliseconds(50), .awake);
    var tmp_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{store.paths.historyPath()});
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = "{\"pb\":true}\n" });
    try cwd.rename(tmp_path, cwd, store.paths.historyPath(), io);
    old.close(io);
    th.join();
    try t.expect(ok);
    const got = store.readHistory(t.allocator).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("{\"pb\":true}\n{\"n\":2}\n", got);
}
