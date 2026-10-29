//! Result records, personal bests, the run history (`Log`: recent runs,
//! trend, per-key totals), CSV/text exports and config JSON. Pure: no file
//! I/O (works on wasm32-freestanding); the app stores and reads the bytes.

const std = @import("std");

const stats = @import("stats.zig");
const Result = stats.Result;
const types = @import("types.zig");
const Config = types.Config;
const daily = @import("daily.zig");

/// typing: wpm values; drill: strokes as f32.
pub const PbOutcome = union(enum) { none, first, improved: f32, missed: f32 };

/// Personal-best key of a config:
///   words:     "words|<tier>|<w25|t30>|p<0/1>n<0/1>" (+ "|weak" when focus
///              is weak, + "|<layout>" when not qwerty)
///   sentences: "sentences|<w25|t30>" (+ "|<layout>")
///   code:      "code|<lang>|<w25|t30>" (+ "|<layout>"); vim keys:
///              "code|<lang>|vim"
///   vim type:  "vimtype|<lang>"
///   drill:     "drill|<id>"
///   custom:    "custom|<8 hex of custom_hash>|<all|t30>" (+ "|<layout>")
///   daily:     "daily|<yyyy-mm-dd>" (+ "|<layout>")
///   zen:       "zen" (history only, never a PB)
/// Stop-on-error and no-backspace don't change the key.
pub fn pbKey(cfg: Config, buf: []u8) []const u8 {
    var len_buf: [24]u8 = undefined;
    const len = if (cfg.time_limit > 0)
        std.fmt.bufPrint(&len_buf, "t{d}", .{cfg.time_limit}) catch ""
    else
        std.fmt.bufPrint(&len_buf, "w{d}", .{cfg.word_count}) catch "";
    var lay_buf: [16]u8 = undefined;
    const lay = if (cfg.layout == .qwerty) "" else std.fmt.bufPrint(&lay_buf, "|{s}", .{cfg.layout.name()}) catch "";
    var day_buf: [10]u8 = undefined;
    return switch (cfg.mode) {
        .words => std.fmt.bufPrint(buf, "words|{s}|{s}|p{d}n{d}{s}{s}", .{
            cfg.tier.name(),                         len, @intFromBool(cfg.punctuation), @intFromBool(cfg.numbers),
            if (cfg.focus == .weak) "|weak" else "", lay,
        }),
        .sentences => std.fmt.bufPrint(buf, "sentences|{s}{s}", .{ len, lay }),
        .code => if (cfg.code_keys == .vim)
            std.fmt.bufPrint(buf, "code|{s}|vim", .{cfg.lang.name()})
        else
            std.fmt.bufPrint(buf, "code|{s}|{s}{s}", .{ cfg.lang.name(), len, lay }),
        .vim => switch (cfg.vim_kind) {
            .type => std.fmt.bufPrint(buf, "vimtype|{s}", .{cfg.lang.name()}),
            .drills => std.fmt.bufPrint(buf, "drill|{s}", .{cfg.drill_id orelse ""}),
        },
        .arcade => std.fmt.bufPrint(buf, "arcade", .{}),
        .zen => std.fmt.bufPrint(buf, "zen", .{}),
        .custom => if (cfg.time_limit > 0)
            std.fmt.bufPrint(buf, "custom|{x:0>8}|t{d}{s}", .{ cfg.custom_hash, cfg.time_limit, lay })
        else
            std.fmt.bufPrint(buf, "custom|{x:0>8}|all{s}", .{ cfg.custom_hash, lay }),
        .daily => std.fmt.bufPrint(buf, "daily|{s}{s}", .{ daily.format(cfg.day, &day_buf), lay }),
    } catch buf[0..0];
}

/// Writes `s` as a JSON string (with quotes).
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Finite and rounded to one decimal for the record.
fn num(v: f32) f32 {
    return if (std.math.isFinite(v)) v else 0;
}

/// One history record (version 1), a single JSON object without '\n'.
/// Returns an empty slice if `buf` is too small (MAX_RECORD_LEN is always
/// enough: the per-key field is cut to PK_BUDGET bytes).
pub fn recordLine(res: *const Result, cfg: Config, ts_s: i64, seed: u64, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeRecord(&w, res, cfg, ts_s, seed) catch return buf[0..0];
    return w.buffered();
}

fn writeRecord(w: *std.Io.Writer, res: *const Result, cfg: Config, ts_s: i64, seed: u64) !void {
    var key_buf: [160]u8 = undefined;
    const key = pbKey(cfg, &key_buf);
    if (res.kind == .vim_drill) {
        const id = res.drill_id orelse cfg.drill_id orelse "";
        try w.print("{{\"v\":1,\"ts\":{d},\"kind\":\"drill\",\"key\":", .{ts_s});
        var dk_buf: [160]u8 = undefined;
        const dk = std.fmt.bufPrint(&dk_buf, "drill|{s}", .{id}) catch key;
        try writeJsonString(w, dk);
        try w.writeAll(",\"id\":");
        try writeJsonString(w, id);
        try w.print(",\"strokes\":{d},\"par\":{d},\"stars\":{d},\"hinted\":{},\"ms\":{d}}}", .{
            res.strokes, res.par, res.stars, res.hinted, res.duration_ms,
        });
        return;
    }
    const kind = if (res.kind == .vim_type) "vimtype" else "typing";
    try w.print("{{\"v\":1,\"ts\":{d},\"kind\":\"{s}\",\"key\":", .{ ts_s, kind });
    try writeJsonString(w, key);
    try w.print(",\"mode\":\"{s}\",\"wpm\":{d:.1},\"raw\":{d:.1},\"acc\":{d:.1},\"cons\":", .{
        cfg.mode.name(), num(res.wpm), num(res.raw), num(res.acc),
    });
    if (res.consistency) |c| try w.print("{d:.1}", .{num(c)}) else try w.writeAll("null");
    try w.print(",\"chars\":[{d},{d},{d},{d}],\"corrected\":{d},\"ms\":{d},\"seed\":{d}", .{
        res.chars.correct, res.chars.incorrect, res.chars.extra, res.chars.missed,
        res.corrected,     res.duration_ms,     seed,
    });
    if (res.kind == .vim_type) try w.print(",\"keys\":{d},\"eff\":{d:.2}", .{ res.keystrokes, num(res.efficiency) });
    if (cfg.layout != .qwerty and res.kind == .typing) try w.print(",\"layout\":\"{s}\"", .{cfg.layout.name()});
    if (cfg.mode == .daily) {
        var day_buf: [10]u8 = undefined;
        try w.print(",\"day\":\"{s}\"", .{daily.format(cfg.day, &day_buf)});
    }
    if (res.per_key) |pk| {
        var pk_buf: [PK_BUDGET]u8 = undefined;
        const text = pkString(pk, &pk_buf);
        if (text.len > 0) {
            try w.writeAll(",\"pk\":");
            try writeJsonString(w, text);
        }
    }
    try w.writeByte('}');
}

/// A record line never exceeds this many bytes.
pub const MAX_RECORD_LEN: usize = 2048;
/// Bytes of "pk" text at most (entries that don't fit are dropped).
const PK_BUDGET: usize = 1200;

/// "pk": `<key>:<hits>/<misses>/<ms_sum>/<timed>` per key with data,
/// space-separated; the key is byte 0 of each entry.
fn pkString(pk: *const stats.PerKey, buf: []u8) []const u8 {
    var len: usize = 0;
    for (pk.keys, 0..) |k, i| {
        if (k.hits == 0) continue;
        var e: [64]u8 = undefined;
        const entry = std.fmt.bufPrint(&e, "{s}{c}:{d}/{d}/{d}/{d}", .{
            if (len > 0) " " else "", stats.KEYSET[i], k.hits, k.misses, k.ms_sum, k.timed,
        }) catch continue;
        if (len + entry.len > buf.len) break;
        @memcpy(buf[len..][0..entry.len], entry);
        len += entry.len;
    }
    return buf[0..len];
}

/// Adds the entries of a "pk" string to `out`; malformed entries skipped.
pub fn parsePk(text: []const u8, out: *stats.PerKey) void {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |entry| {
        if (entry.len < 3 or entry[1] != ':') continue;
        const ki = std.mem.indexOfScalar(u8, stats.KEYSET, entry[0]) orelse continue;
        var nums = std.mem.splitScalar(u8, entry[2..], '/');
        var v: [4]u32 = undefined;
        var ok = true;
        for (&v) |*x| {
            const part = nums.next() orelse {
                ok = false;
                break;
            };
            x.* = std.fmt.parseInt(u32, part, 10) catch {
                ok = false;
                break;
            };
        }
        if (!ok or nums.next() != null) continue;
        out.keys[ki].add(.{ .hits = v[0], .misses = @min(v[1], v[0]), .ms_sum = v[2], .timed = @min(v[3], v[0]) });
    }
}

/// Fields read back from a record line (unknown fields ignored).
const RecordIn = struct {
    v: u32 = 0,
    ts: ?i64 = null,
    kind: []const u8 = "",
    key: []const u8 = "",
    mode: ?[]const u8 = null,
    id: ?[]const u8 = null,
    wpm: ?f32 = null,
    raw: ?f32 = null,
    acc: ?f32 = null,
    cons: ?f32 = null,
    chars: ?[4]u32 = null,
    corrected: ?u32 = null,
    strokes: ?u32 = null,
    keys: ?u32 = null,
    par: ?u32 = null,
    stars: ?u8 = null,
    ms: ?u32 = null,
    pk: ?[]const u8 = null,
    /// A PB line from compaction (PbTable.pbLines): not a run.
    pb: bool = false,
};

/// Parses one record line into `mem`; null for blank, corrupt or
/// unversioned lines.
fn parseRecord(line_raw: []const u8, mem: []u8) ?RecordIn {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0 or line.len > 4096) return null;
    var fba = std.heap.FixedBufferAllocator.init(mem);
    const rec = std.json.parseFromSliceLeaky(RecordIn, fba.allocator(), line, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch return null;
    if (rec.v != 1 or rec.key.len == 0) return null;
    return rec;
}

pub const DrillBest = struct { strokes: u32, stars: u2 };

const Entry = struct {
    wpm: f32 = 0,
    strokes: u32 = 0,
    ms: u32 = 0,
    stars: u2 = 0,
};

pub const PbTable = struct {
    allocator: std.mem.Allocator,
    /// Keys are owned copies.
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) PbTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PbTable) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit(self.allocator);
    }

    /// Reads history JSONL; corrupt or unknown lines are skipped. PB lines
    /// (`"pb":true`) count like ordinary records.
    pub fn loadJsonl(self: *PbTable, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            var mem: [8192]u8 = undefined;
            const rec = parseRecord(raw, &mem) orelse continue;
            if (std.mem.eql(u8, rec.key, "zen")) continue;
            if (std.mem.eql(u8, rec.kind, "drill")) {
                const strokes = rec.strokes orelse continue;
                const stars: u2 = @intCast(@min(rec.stars orelse 0, 3));
                _ = self.offerDrill(rec.key, strokes, rec.ms orelse 0, stars) catch {};
            } else {
                const wpm = rec.wpm orelse continue;
                if (!std.math.isFinite(wpm)) continue;
                _ = self.offerWpm(rec.key, wpm) catch {};
            }
        }
    }

    fn slot(self: *PbTable, key: []const u8) !struct { entry: *Entry, fresh: bool } {
        const gop = try self.map.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch |e| {
                self.map.removeByPtr(gop.key_ptr);
                return e;
            };
            gop.value_ptr.* = .{};
        }
        return .{ .entry = gop.value_ptr, .fresh = !gop.found_existing };
    }

    /// Compares at the record's precision (one decimal), so a run that
    /// only beats a reloaded best by rounding noise is not a new PB.
    fn offerWpm(self: *PbTable, key: []const u8, raw_wpm: f32) !PbOutcome {
        const wpm = @round(raw_wpm * 10) / 10;
        const s = try self.slot(key);
        if (s.fresh) {
            s.entry.wpm = wpm;
            return .first;
        }
        if (wpm > s.entry.wpm) {
            const old = s.entry.wpm;
            s.entry.wpm = wpm;
            return .{ .improved = old };
        }
        return .{ .missed = s.entry.wpm };
    }

    fn offerDrill(self: *PbTable, key: []const u8, strokes: u32, ms: u32, stars: u2) !PbOutcome {
        const s = try self.slot(key);
        if (s.fresh) {
            s.entry.* = .{ .strokes = strokes, .ms = ms, .stars = stars };
            return .first;
        }
        const e = s.entry;
        const old: f32 = @floatFromInt(e.strokes);
        e.stars = @max(e.stars, stars);
        if (strokes < e.strokes or (strokes == e.strokes and ms < e.ms)) {
            e.strokes = strokes;
            e.ms = ms;
            return .{ .improved = old };
        }
        return .{ .missed = old };
    }

    /// Records a finished test. Invalid results (an unsolved drill too) →
    /// .none. Typing: higher wpm wins (`improved`/`missed` carry the
    /// previous best wpm). Drill: fewer strokes, then less time (carry the
    /// previous strokes).
    pub fn submit(self: *PbTable, cfg: Config, res: *const Result) PbOutcome {
        var key_buf: [160]u8 = undefined;
        if (!res.valid) return .none;
        // Zen is history only: there is nothing to beat.
        if (cfg.mode == .zen and res.kind == .typing) return .none;
        if (res.kind == .vim_drill) {
            const id = res.drill_id orelse cfg.drill_id orelse return .none;
            const key = std.fmt.bufPrint(&key_buf, "drill|{s}", .{id}) catch return .none;
            return self.offerDrill(key, res.strokes, res.duration_ms, res.stars) catch .none;
        }
        if (!std.math.isFinite(res.wpm)) return .none;
        return self.offerWpm(pbKey(cfg, &key_buf), res.wpm) catch .none;
    }

    pub fn bestWpm(self: *const PbTable, key: []const u8) ?f32 {
        const e = self.map.get(key) orelse return null;
        return e.wpm;
    }

    pub fn bestDrill(self: *const PbTable, id: []const u8) ?DrillBest {
        var key_buf: [160]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "drill|{s}", .{id}) catch return null;
        const e = self.map.get(key) orelse return null;
        return .{ .strokes = e.strokes, .stars = e.stars };
    }

    /// Every best, sorted by key. Keys are borrowed from the table; the
    /// caller frees the slice.
    pub fn entries(self: *const PbTable, allocator: std.mem.Allocator) ![]PbRow {
        const rows = try allocator.alloc(PbRow, self.map.count());
        var it = self.map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            rows[i] = .{ .key = kv.key_ptr.*, .wpm = kv.value_ptr.wpm, .strokes = kv.value_ptr.strokes, .stars = kv.value_ptr.stars };
        }
        std.mem.sort(PbRow, rows, {}, PbRow.lessThan);
        return rows;
    }

    /// One `"pb":true` v1 record per key, '\n'-terminated, sorted by key:
    /// `loadJsonl(pbLines())` rebuilds an equal table (history compaction).
    pub fn pbLines(self: *const PbTable, allocator: std.mem.Allocator) ![]u8 {
        const rows = try self.entries(allocator);
        defer allocator.free(rows);
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        for (rows) |row| {
            const e = self.map.get(row.key).?;
            const mode = row.key[0 .. std.mem.indexOfScalar(u8, row.key, '|') orelse row.key.len];
            if (std.mem.eql(u8, mode, "drill")) {
                try w.writeAll("{\"v\":1,\"ts\":0,\"kind\":\"drill\",\"key\":");
                try writeJsonString(w, row.key);
                try w.writeAll(",\"id\":");
                try writeJsonString(w, row.key["drill|".len..]);
                try w.print(",\"strokes\":{d},\"stars\":{d},\"ms\":{d},\"pb\":true}}\n", .{ e.strokes, e.stars, e.ms });
            } else {
                const kind = if (std.mem.eql(u8, mode, "vimtype") or std.mem.endsWith(u8, row.key, "|vim")) "vimtype" else "typing";
                try w.print("{{\"v\":1,\"ts\":0,\"kind\":\"{s}\",\"key\":", .{kind});
                try writeJsonString(w, row.key);
                try w.writeAll(",\"mode\":");
                try writeJsonString(w, if (std.mem.eql(u8, mode, "vimtype")) "vim" else mode);
                try w.print(",\"wpm\":{d:.1},\"pb\":true}}\n", .{num(e.wpm)});
            }
        }
        return out.toOwnedSlice();
    }
};

/// A personal best for listings (keys borrowed from the PbTable).
pub const PbRow = struct {
    key: []const u8,
    wpm: f32,
    strokes: u32,
    stars: u2,

    fn lessThan(_: void, a: PbRow, b: PbRow) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

// ---- run history ----

pub const RunKind = enum { typing, vimtype, drill };

/// One finished run read back from the history.
pub const Run = struct {
    /// Unix seconds.
    ts: i64,
    kind: RunKind,
    key_buf: [80]u8 = undefined,
    key_len: u8 = 0,
    mode_buf: [12]u8 = undefined,
    mode_len: u8 = 0,
    wpm: f32 = 0,
    raw: f32 = 0,
    acc: f32 = 0,
    ms: u32 = 0,
    /// Drills: strokes; vim type: keystrokes.
    strokes: u32 = 0,
    par: u16 = 0,
    stars: u2 = 0,

    pub fn key(self: *const Run) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    /// "words", "code", ..., "drill" for drills.
    pub fn modeName(self: *const Run) []const u8 {
        return self.mode_buf[0..self.mode_len];
    }

    fn fromRecord(rec: RecordIn) ?Run {
        const kind: RunKind = if (std.mem.eql(u8, rec.kind, "drill"))
            .drill
        else if (std.mem.eql(u8, rec.kind, "vimtype"))
            .vimtype
        else if (std.mem.eql(u8, rec.kind, "typing"))
            .typing
        else
            return null;
        var r: Run = .{ .ts = rec.ts orelse 0, .kind = kind };
        r.key_len = @intCast(@min(rec.key.len, r.key_buf.len));
        @memcpy(r.key_buf[0..r.key_len], rec.key[0..r.key_len]);
        const mode = if (kind == .drill) "drill" else rec.mode orelse rec.key[0 .. std.mem.indexOfScalar(u8, rec.key, '|') orelse rec.key.len];
        r.mode_len = @intCast(@min(mode.len, r.mode_buf.len));
        @memcpy(r.mode_buf[0..r.mode_len], mode[0..r.mode_len]);
        r.wpm = finite(rec.wpm orelse 0);
        r.raw = finite(rec.raw orelse 0);
        r.acc = finite(rec.acc orelse 0);
        r.ms = rec.ms orelse 0;
        r.strokes = rec.strokes orelse rec.keys orelse 0;
        r.par = @intCast(@min(rec.par orelse 0, std.math.maxInt(u16)));
        r.stars = @intCast(@min(rec.stars orelse 0, 3));
        if (kind == .typing and rec.wpm == null) return null;
        return r;
    }
};

fn finite(v: f32) f32 {
    return if (std.math.isFinite(v)) v else 0;
}

/// The run history: the newest MAX_RUNS runs, totals over every run and
/// the summed per-key stats. Load it chunk by chunk (whole lines, or a
/// partial last line that the next chunk completes).
pub const Log = struct {
    pub const MAX_RUNS = 500;

    allocator: std.mem.Allocator,
    /// The newest runs at the end; trimmed back to MAX_RUNS whenever it
    /// reaches twice that (amortized O(1) per run).
    buf: std.ArrayList(Run) = .empty,
    total_runs: u32 = 0,
    total_ms: u64 = 0,
    per_key: stats.PerKey = .{},
    /// An unterminated last line of the previous chunk.
    carry: [4096]u8 = undefined,
    carry_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Log {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Log) void {
        self.buf.deinit(self.allocator);
    }

    /// Additive; call it repeatedly with consecutive chunks. Corrupt lines
    /// are skipped; PB lines ("pb":true) are not runs.
    pub fn loadJsonl(self: *Log, bytes: []const u8) void {
        var rest = bytes;
        if (self.carry_len > 0) {
            // Complete the carried line with this chunk's first line.
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const head = rest[0 .. nl orelse rest.len];
            if (self.carry_len + head.len <= self.carry.len) {
                @memcpy(self.carry[self.carry_len..][0..head.len], head);
                self.carry_len += head.len;
            } else self.carry_len = self.carry.len + 1; // too long: drop it
            if (nl == null) {
                if (self.carry_len <= self.carry.len and self.tryLine(self.carry[0..self.carry_len])) self.carry_len = 0;
                return;
            }
            if (self.carry_len <= self.carry.len) self.addLine(self.carry[0..self.carry_len]);
            self.carry_len = 0;
            rest = rest[nl.? + 1 ..];
        }
        var lines = std.mem.splitScalar(u8, rest, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null and line.len > 0) {
                // An unterminated last line: keep it unless it is complete.
                if (!self.tryLine(line) and line.len <= self.carry.len) {
                    @memcpy(self.carry[0..line.len], line);
                    self.carry_len = line.len;
                }
                return;
            }
            self.addLine(line);
        }
    }

    /// A record line the App just wrote (or one read back).
    pub fn addLine(self: *Log, line: []const u8) void {
        _ = self.tryLine(line);
    }

    /// True when `line` parsed as a record (run or PB line).
    fn tryLine(self: *Log, line: []const u8) bool {
        var mem: [8192]u8 = undefined;
        const rec = parseRecord(line, &mem) orelse return false;
        if (rec.pb) return true;
        const run = Run.fromRecord(rec) orelse return true;
        self.total_runs +|= 1;
        self.total_ms += run.ms;
        if (rec.pk) |pk| parsePk(pk, &self.per_key);
        self.buf.append(self.allocator, run) catch return true;
        if (self.buf.items.len >= 2 * MAX_RUNS) {
            const keep = self.buf.items[self.buf.items.len - MAX_RUNS ..];
            std.mem.copyForwards(Run, self.buf.items[0..MAX_RUNS], keep);
            self.buf.shrinkRetainingCapacity(MAX_RUNS);
        }
        return true;
    }

    /// The newest ≤ MAX_RUNS runs, oldest first.
    pub fn runs(self: *const Log) []const Run {
        const items = self.buf.items;
        return items[items.len - @min(items.len, MAX_RUNS) ..];
    }

    /// Every run ever loaded or added.
    pub fn count(self: *const Log) u32 {
        return self.total_runs;
    }

    pub fn totalMs(self: *const Log) u64 {
        return self.total_ms;
    }

    /// The last ≤ out.len wpm values of `key` (null: every typing run),
    /// oldest first.
    pub fn trend(self: *const Log, key: ?[]const u8, out: []f32) []const f32 {
        const all = self.runs();
        var n: usize = 0;
        var i = all.len;
        while (i > 0 and n < out.len) {
            i -= 1;
            const r = &all[i];
            const match = if (key) |k| r.kind != .drill and std.mem.eql(u8, r.key(), k) else r.kind == .typing;
            if (!match) continue;
            out[n] = r.wpm;
            n += 1;
        }
        std.mem.reverse(f32, out[0..n]);
        return out[0..n];
    }

    /// Sum of every record's "pk".
    pub fn perKey(self: *const Log) *const stats.PerKey {
        return &self.per_key;
    }

    /// Weak-key weights from perKey(); false with < 100 timed hits.
    pub fn weakWeights(self: *const Log, out: *stats.KeyWeights) bool {
        return stats.weakWeights(&self.per_key, out);
    }
};

// ---- exports ----

const CSV_HEADER = "ts,date,kind,key,mode,wpm,raw,acc,cons,correct,incorrect,extra,missed,corrected,ms,strokes,par,stars";

pub fn writeCsvHeader(w: *std.Io.Writer) !void {
    try w.writeAll(CSV_HEADER ++ "\n");
}

fn writeCsvField(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, ",\"\n\r") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"') try w.writeByte('"');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// One CSV row for a record line (empty cells for fields its kind lacks);
/// false (nothing written) for corrupt and PB lines.
pub fn writeCsvLine(w: *std.Io.Writer, line: []const u8) !bool {
    var mem: [8192]u8 = undefined;
    const rec = parseRecord(line, &mem) orelse return false;
    if (rec.pb) return false;
    const run = Run.fromRecord(rec) orelse return false;
    var date_buf: [10]u8 = undefined;
    try w.print("{d},{s},{s},", .{ run.ts, daily.format(daily.dayFromUnix(run.ts), &date_buf), @tagName(run.kind) });
    try writeCsvField(w, run.key());
    try w.writeByte(',');
    try writeCsvField(w, run.modeName());
    if (run.kind == .drill) {
        try w.print(",,,,,,,,,,{d},{d},{d},{d}\n", .{ run.ms, run.strokes, run.par, run.stars });
        return true;
    }
    try w.print(",{d:.1},{d:.1},{d:.1},", .{ run.wpm, run.raw, run.acc });
    if (rec.cons) |c| try w.print("{d:.1}", .{finite(c)});
    if (rec.chars) |c| {
        try w.print(",{d},{d},{d},{d}", .{ c[0], c[1], c[2], c[3] });
    } else try w.writeAll(",,,,");
    try w.writeByte(',');
    if (rec.corrected) |c| try w.print("{d}", .{c});
    try w.print(",{d},", .{run.ms});
    if (run.kind == .vimtype) try w.print("{d}", .{run.strokes});
    try w.writeAll(",,\n");
    return true;
}

/// ASCII sparkline of `values` (`_.-'^` from low to high).
pub fn sparkline(values: []const f32, out: []u8) []const u8 {
    const glyphs = "_.-'^";
    const n = @min(values.len, out.len);
    if (n == 0) return out[0..0];
    const vs = values[values.len - n ..];
    var lo = vs[0];
    var hi = vs[0];
    for (vs) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    for (vs, 0..) |v, i| {
        const t = if (hi > lo) (v - lo) / (hi - lo) else 0.5;
        out[i] = glyphs[@min(glyphs.len - 1, @as(usize, @intFromFloat(t * glyphs.len)))];
    }
    return out[0..n];
}

fn writeDuration(w: *std.Io.Writer, ms: u64) !void {
    const s = ms / 1000;
    if (s >= 3600) return w.print("{d}h {d:0>2}m", .{ s / 3600, s / 60 % 60 });
    if (s >= 60) return w.print("{d}m {d:0>2}s", .{ s / 60, s % 60 });
    return w.print("{d}s", .{s});
}

fn weakerThan(pk: *const stats.PerKey, a: usize, b: usize) bool {
    const ka = pk.keys[a];
    const kb = pk.keys[b];
    const ea = 100 - (ka.accuracy() orelse 100);
    const eb = 100 - (kb.accuracy() orelse 100);
    if (ea != eb) return ea > eb;
    return (ka.avgMs() orelse 0) > (kb.avgMs() orelse 0);
}

/// `snipetype stats`: totals, the last `limit` runs, PBs per setup, a wpm
/// sparkline of the last 30 typing runs and the 5 weakest keys. Plain
/// ASCII for a terminal or a pipe.
pub fn writeStatsText(w: *std.Io.Writer, log: *const Log, pbs: *const PbTable, limit: usize) !void {
    const all = log.runs();
    var typing_n: usize = 0;
    var wpm_sum: f64 = 0;
    var wpm_best: f32 = 0;
    for (all) |r| {
        if (r.kind != .typing) continue;
        typing_n += 1;
        wpm_sum += r.wpm;
        wpm_best = @max(wpm_best, r.wpm);
    }
    try w.writeAll("snipetype stats\n\n");
    try w.print("runs        {d}\ntime typed  ", .{log.count()});
    try writeDuration(w, log.totalMs());
    try w.writeByte('\n');
    if (typing_n > 0) {
        try w.print("average     {d:.1} wpm (last {d} typing runs)\nbest        {d:.1} wpm\n", .{
            wpm_sum / @as(f64, @floatFromInt(typing_n)), typing_n, wpm_best,
        });
    }

    try w.print("\nrecent runs\n", .{});
    if (all.len == 0) try w.writeAll("  (none yet)\n");
    const shown = all[all.len - @min(all.len, limit) ..];
    var i = shown.len;
    while (i > 0) {
        i -= 1;
        const r = &shown[i];
        var date_buf: [10]u8 = undefined;
        try w.print("  {s}  {s: <34}", .{ daily.format(daily.dayFromUnix(r.ts), &date_buf), r.key()[0..@min(r.key().len, 34)] });
        switch (r.kind) {
            .drill => try w.print("  {d} strokes (par {d}) {s}\n", .{ r.strokes, r.par, ("***")[0..r.stars] }),
            else => try w.print("  {d: >6.1} wpm  {d: >5.1}% acc\n", .{ r.wpm, r.acc }),
        }
    }

    try w.writeAll("\nbests per setup\n");
    var drills: usize = 0;
    var starred: usize = 0;
    var any = false;
    var it = pbs.map.iterator();
    var rows_buf: [256]PbRow = undefined;
    var rows_n: usize = 0;
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "drill|")) {
            drills += 1;
            if (kv.value_ptr.stars == 3) starred += 1;
            continue;
        }
        if (rows_n < rows_buf.len) {
            rows_buf[rows_n] = .{ .key = kv.key_ptr.*, .wpm = kv.value_ptr.wpm, .strokes = 0, .stars = 0 };
            rows_n += 1;
        }
    }
    std.mem.sort(PbRow, rows_buf[0..rows_n], {}, PbRow.lessThan);
    for (rows_buf[0..rows_n]) |row| {
        any = true;
        try w.print("  {s: <40}  {d: >6.1} wpm\n", .{ row.key[0..@min(row.key.len, 40)], row.wpm });
    }
    if (drills > 0) {
        any = true;
        try w.print("  vim drills: {d} of {d} 3-starred\n", .{ starred, drills });
    }
    if (!any) try w.writeAll("  (none yet)\n");

    var vals: [30]f32 = undefined;
    const tr = log.trend(null, &vals);
    if (tr.len >= 2) {
        var spark: [30]u8 = undefined;
        var lo = tr[0];
        var hi = tr[0];
        for (tr) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        try w.print("\nwpm trend (last {d})\n  {s}  {d:.0}..{d:.0} wpm\n", .{ tr.len, sparkline(tr, &spark), lo, hi });
    }

    const pk = log.perKey();
    var order: [stats.KEYSET.len]usize = undefined;
    var n: usize = 0;
    for (pk.keys, 0..) |k, ki| {
        if (k.hits >= stats.WEAK_MIN_HITS) {
            order[n] = ki;
            n += 1;
        }
    }
    if (n > 0) {
        std.mem.sort(usize, order[0..n], pk, weakerThan);
        try w.writeAll("\nweakest keys\n");
        for (order[0..@min(n, 5)]) |ki| {
            const k = pk.keys[ki];
            try w.print("  {c}  {d: >5.1}% acc", .{ stats.KEYSET[ki], k.accuracy() orelse 100 });
            if (k.avgMs()) |ms| try w.print("  {d: >4.0} ms", .{ms});
            try w.print("  ({d} hits)\n", .{k.hits});
        }
    }
}

/// Config JSON (version 1), e.g.
/// {"v":1,"theme":"one-dark","mode":"words","words":25,"time":0,"lang":"mixed","tier":"common","punct":false,"num":false,"vim":"drills",
///  "keys":"plain","pace":"pb","pace_wpm":80,"stop":"off","nobs":false,"layout":"qwerty","focus":"normal","syntax":true,"sounds":false}
/// `day` and `custom_hash` are runtime only and never written.
pub fn configToJson(cfg: Config, theme: []const u8, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeConfig(&w, cfg, theme) catch return buf[0..0];
    return w.buffered();
}

fn writeConfig(w: *std.Io.Writer, cfg: Config, theme: []const u8) !void {
    try w.writeAll("{\"v\":1,\"theme\":");
    try writeJsonString(w, theme);
    try w.print(",\"mode\":\"{s}\",\"words\":{d},\"time\":{d},\"lang\":\"{s}\",\"tier\":\"{s}\",\"punct\":{},\"num\":{},\"vim\":\"{s}\"}}", .{
        cfg.mode.name(), cfg.word_count,  cfg.time_limit, cfg.lang.name(),
        cfg.tier.name(), cfg.punctuation, cfg.numbers,    cfg.vim_kind.name(),
    });
    w.undo(1);
    try w.print(",\"keys\":\"{s}\",\"pace\":\"{s}\",\"pace_wpm\":{d},\"stop\":\"{s}\",\"nobs\":{},\"layout\":\"{s}\",\"focus\":\"{s}\",\"syntax\":{},\"sounds\":{}}}", .{
        cfg.code_keys.name(), cfg.caret_pace.name(), cfg.caret_wpm, cfg.stop_on_error.name(), cfg.no_backspace,
        cfg.layout.name(),    cfg.focus.name(),      cfg.syntax,    cfg.sounds,
    });
}

const ConfigIn = struct {
    v: u32 = 0,
    theme: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    words: ?i64 = null,
    time: ?i64 = null,
    lang: ?[]const u8 = null,
    tier: ?[]const u8 = null,
    punct: ?bool = null,
    num: ?bool = null,
    vim: ?[]const u8 = null,
    keys: ?[]const u8 = null,
    pace: ?[]const u8 = null,
    pace_wpm: ?i64 = null,
    stop: ?[]const u8 = null,
    nobs: ?bool = null,
    layout: ?[]const u8 = null,
    focus: ?[]const u8 = null,
    syntax: ?bool = null,
    sounds: ?bool = null,
};

/// Applies the valid fields of a config JSON to `cfg` (unknown or bad
/// values are ignored). Returns the theme slug (copied into `theme_out`)
/// if present; null also when the JSON is unreadable.
pub fn configFromJson(bytes: []const u8, cfg: *Config, theme_out: *[32]u8) ?[]const u8 {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const in = std.json.parseFromSliceLeaky(ConfigIn, fba.allocator(), bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch return null;
    if (in.v != 1) return null;
    if (in.mode) |s| if (types.Mode.fromString(s)) |m| {
        cfg.mode = m;
    };
    if (in.words) |n| cfg.word_count = @intCast(std.math.clamp(n, @as(i64, types.MIN_WORDS), @as(i64, types.MAX_WORDS)));
    if (in.time) |n| if (n >= 0 and n <= 3600) {
        cfg.time_limit = @intCast(n);
    };
    if (in.lang) |s| if (types.Lang.fromString(s)) |l| {
        cfg.lang = l;
    };
    if (in.tier) |s| if (types.WordTier.fromString(s)) |t| {
        cfg.tier = t;
    };
    if (in.punct) |b| cfg.punctuation = b;
    if (in.num) |b| cfg.numbers = b;
    if (in.vim) |s| if (types.VimKind.fromString(s)) |k| {
        cfg.vim_kind = k;
    };
    if (in.keys) |s| if (types.CodeKeys.fromString(s)) |k| {
        cfg.code_keys = k;
    };
    if (in.pace) |s| if (types.CaretPace.fromString(s)) |p| {
        cfg.caret_pace = p;
    };
    if (in.pace_wpm) |n| cfg.caret_wpm = @intCast(std.math.clamp(n, types.CARET_WPM_MIN, types.CARET_WPM_MAX));
    if (in.stop) |s| if (types.StopOnError.fromString(s)) |p| {
        cfg.stop_on_error = p;
    };
    if (in.nobs) |b| cfg.no_backspace = b;
    if (in.layout) |s| if (types.Layout.fromString(s)) |l| {
        cfg.layout = l;
    };
    if (in.focus) |s| if (types.Focus.fromString(s)) |f| {
        cfg.focus = f;
    };
    if (in.syntax) |b| cfg.syntax = b;
    if (in.sounds) |b| cfg.sounds = b;
    const theme = in.theme orelse return null;
    if (theme.len == 0 or theme.len > theme_out.len) return null;
    @memcpy(theme_out[0..theme.len], theme);
    return theme_out[0..theme.len];
}

// ---- tests ----

const testing = std.testing;

fn typingRes(wpm: f32, valid: bool) Result {
    return .{
        .kind = .typing,
        .wpm = wpm,
        .raw = wpm + 4.7,
        .acc = 96.3,
        .consistency = 78.2,
        .chars = .{ .correct = 120, .incorrect = 3, .extra = 1, .missed = 0 },
        .corrected = 5,
        .keystrokes = 140,
        .duration_ms = 17234,
        .series = &.{},
        .missed_words = &.{},
        .slow_words = &.{},
        .valid = valid,
    };
}

test "pbKey formats" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("words|common|w25|p0n0", pbKey(.{ .word_count = 25 }, &buf));
    try testing.expectEqualStrings("words|easy|t30|p1n1", pbKey(.{ .tier = .easy, .time_limit = 30, .punctuation = true, .numbers = true }, &buf));
    try testing.expectEqualStrings("sentences|w10", pbKey(.{ .mode = .sentences }, &buf));
    try testing.expectEqualStrings("code|ts|t60", pbKey(.{ .mode = .code, .lang = .typescript, .time_limit = 60 }, &buf));
    try testing.expectEqualStrings("vimtype|zig", pbKey(.{ .mode = .vim, .vim_kind = .type, .lang = .zig }, &buf));
    try testing.expectEqualStrings("drill|textobj/ci-paren-01", pbKey(.{ .mode = .vim, .drill_id = "textobj/ci-paren-01" }, &buf));
}

test "recordLine matches the v1 format" {
    var buf: [512]u8 = undefined;
    const r = typingRes(87.4, true);
    const line = recordLine(&r, .{ .word_count = 25 }, 1761650000, 123, &buf);
    try testing.expectEqualStrings(
        \\{"v":1,"ts":1761650000,"kind":"typing","key":"words|common|w25|p0n0","mode":"words","wpm":87.4,"raw":92.1,"acc":96.3,"cons":78.2,"chars":[120,3,1,0],"corrected":5,"ms":17234,"seed":123}
    , line);
    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.strokes = 6;
    d.par = 5;
    d.stars = 2;
    d.duration_ms = 4210;
    d.drill_id = "textobj/ci-paren-01";
    try testing.expectEqualStrings(
        \\{"v":1,"ts":1761650000,"kind":"drill","key":"drill|textobj/ci-paren-01","id":"textobj/ci-paren-01","strokes":6,"par":5,"stars":2,"hinted":false,"ms":4210}
    , recordLine(&d, .{ .mode = .vim }, 1761650000, 0, &buf));
    try testing.expectEqual(@as(usize, 0), recordLine(&r, .{}, 0, 0, buf[0..10]).len);
}

test "records round-trip through loadJsonl; corrupt lines are skipped" {
    var buf: [512]u8 = undefined;
    var jsonl: std.ArrayList(u8) = .empty;
    defer jsonl.deinit(testing.allocator);
    const cfg: Config = .{ .word_count = 25 };
    for ([_]f32{ 80, 91.5, 85 }) |wpm| {
        const r = typingRes(wpm, true);
        try jsonl.appendSlice(testing.allocator, recordLine(&r, cfg, 1, 2, &buf));
        try jsonl.appendSlice(testing.allocator, "\n");
    }
    try jsonl.appendSlice(testing.allocator, "{\"v\":1,\"kind\":\"typing\",\"key\":\"words|common|w25|p0n0\",\"wpm\":999\n");
    try jsonl.appendSlice(testing.allocator, "garbage\n{\"v\":2,\"key\":\"x\",\"wpm\":1}\n\n");
    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.strokes = 7;
    d.stars = 2;
    d.drill_id = "basics/x";
    try jsonl.appendSlice(testing.allocator, recordLine(&d, .{ .mode = .vim }, 1, 0, &buf));

    var pb = PbTable.init(testing.allocator);
    defer pb.deinit();
    pb.loadJsonl(jsonl.items);
    try testing.expectApproxEqAbs(@as(f32, 91.5), pb.bestWpm("words|common|w25|p0n0").?, 0.01);
    try testing.expect(pb.bestWpm("x") == null);
    const db = pb.bestDrill("basics/x").?;
    try testing.expectEqual(@as(u32, 7), db.strokes);
    try testing.expectEqual(@as(u2, 2), db.stars);
}

test "PB outcomes: first, improved, missed, none" {
    var pb = PbTable.init(testing.allocator);
    defer pb.deinit();
    const cfg: Config = .{ .time_limit = 30 };
    try testing.expectEqual(PbOutcome.none, pb.submit(cfg, &typingRes(120, false)));
    try testing.expectEqual(PbOutcome.first, pb.submit(cfg, &typingRes(80, true)));
    try testing.expectEqual(PbOutcome{ .improved = 80 }, pb.submit(cfg, &typingRes(90, true)));
    try testing.expectEqual(PbOutcome{ .missed = 90 }, pb.submit(cfg, &typingRes(85, true)));

    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.drill_id = "a/b";
    d.strokes = 9;
    d.duration_ms = 5000;
    const dcfg: Config = .{ .mode = .vim };
    try testing.expectEqual(PbOutcome.first, pb.submit(dcfg, &d));
    d.strokes = 7;
    try testing.expectEqual(PbOutcome{ .improved = 9 }, pb.submit(dcfg, &d));
    d.duration_ms = 4000;
    try testing.expectEqual(PbOutcome{ .improved = 7 }, pb.submit(dcfg, &d));
    d.strokes = 8;
    try testing.expectEqual(PbOutcome{ .missed = 7 }, pb.submit(dcfg, &d));
    try testing.expectEqual(@as(u32, 7), pb.bestDrill("a/b").?.strokes);
}

test "a PB is compared at the recorded precision" {
    var buf: [512]u8 = undefined;
    const cfg: Config = .{ .time_limit = 30 };
    const prev = typingRes(87.44, true);
    var pb = PbTable.init(testing.allocator);
    defer pb.deinit();
    // The saved line holds 87.4; a later 87.42 is no improvement.
    pb.loadJsonl(recordLine(&prev, cfg, 1, 1, &buf));
    try testing.expectEqual(PbOutcome{ .missed = 87.4 }, pb.submit(cfg, &typingRes(87.42, true)));
    try testing.expectEqual(PbOutcome{ .improved = 87.4 }, pb.submit(cfg, &typingRes(87.46, true)));
    try testing.expectEqual(PbOutcome{ .missed = 87.5 }, pb.submit(cfg, &typingRes(87.44, true)));
}

test "config JSON round trip" {
    var buf: [512]u8 = undefined;
    const cfg: Config = .{ .mode = .code, .word_count = 50, .time_limit = 30, .lang = .rust, .tier = .full, .punctuation = true, .numbers = true, .vim_kind = .type };
    const json = configToJson(cfg, "one-dark", &buf);
    try testing.expectEqualStrings(
        \\{"v":1,"theme":"one-dark","mode":"code","words":50,"time":30,"lang":"rust","tier":"full","punct":true,"num":true,"vim":"type","keys":"plain","pace":"pb","pace_wpm":80,"stop":"off","nobs":false,"layout":"qwerty","focus":"normal","syntax":true,"sounds":false}
    , json);
    var back: Config = .{};
    var theme: [32]u8 = undefined;
    try testing.expectEqualStrings("one-dark", configFromJson(json, &back, &theme).?);
    try testing.expectEqual(cfg.mode, back.mode);
    try testing.expectEqual(cfg.word_count, back.word_count);
    try testing.expectEqual(cfg.time_limit, back.time_limit);
    try testing.expectEqual(cfg.lang, back.lang);
    try testing.expectEqual(cfg.tier, back.tier);
    try testing.expectEqual(cfg.punctuation, back.punctuation);
    try testing.expectEqual(cfg.numbers, back.numbers);
    try testing.expectEqual(cfg.vim_kind, back.vim_kind);

    // Bad values are ignored, counts clamped, garbage rejected.
    var c2: Config = .{};
    try testing.expect(configFromJson("{\"v\":1,\"mode\":\"nope\",\"words\":9999,\"tier\":\"nope\"}", &c2, &theme) == null);
    try testing.expectEqual(types.Mode.words, c2.mode);
    try testing.expectEqual(types.MAX_WORDS, c2.word_count);
    try testing.expect(configFromJson("not json", &c2, &theme) == null);
}

test "pbKey: new modes, focus, layout, code keys" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("words|5k|t30|p0n0|weak|dvorak", pbKey(.{ .tier = .k5, .time_limit = 30, .focus = .weak, .layout = .dvorak }, &buf));
    try testing.expectEqualStrings("sentences|w10|colemak-dh", pbKey(.{ .mode = .sentences, .layout = .colemak_dh }, &buf));
    try testing.expectEqualStrings("code|bash|w10|colemak", pbKey(.{ .mode = .code, .lang = .bash, .layout = .colemak }, &buf));
    try testing.expectEqualStrings("code|sql|vim", pbKey(.{ .mode = .code, .lang = .sql, .code_keys = .vim, .layout = .dvorak }, &buf));
    try testing.expectEqualStrings("custom|0000beef|all", pbKey(.{ .mode = .custom, .custom_hash = 0xbeef }, &buf));
    try testing.expectEqualStrings("custom|deadbeef|t60|dvorak", pbKey(.{ .mode = .custom, .custom_hash = 0xdeadbeef, .time_limit = 60, .layout = .dvorak }, &buf));
    try testing.expectEqualStrings("daily|2026-10-28", pbKey(.{ .mode = .daily, .day = 20754, .time_limit = 30 }, &buf));
    try testing.expectEqualStrings("zen", pbKey(.{ .mode = .zen, .layout = .dvorak }, &buf));
    // Strict policies don't change the key.
    try testing.expectEqualStrings("words|common|w10|p0n0", pbKey(.{ .stop_on_error = .letter, .no_backspace = true }, &buf));
}

test "record lines carry pk, layout and day; pk round-trips" {
    var pk: stats.PerKey = .{};
    pk.note('a', true, 120);
    pk.note('a', false, null);
    pk.note('/', true, 180);
    pk.note('\\', true, 90);
    pk.note(';', false, 10);
    var r = typingRes(70, true);
    r.per_key = &pk;
    var buf: [MAX_RECORD_LEN]u8 = undefined;
    const line = recordLine(&r, .{ .mode = .daily, .day = 20754, .layout = .dvorak }, 5, 6, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "\"layout\":\"dvorak\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"day\":\"2026-10-28\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"pk\":\"a:2/1/120/1 \\\\:1/0/90/1 ;:1/1/0/0 /:1/0/180/1\"") != null);
    var log = Log.init(testing.allocator);
    defer log.deinit();
    log.addLine(line);
    try testing.expectEqualDeep(pk, log.perKey().*);
    log.addLine(line);
    try testing.expectEqual(@as(u32, 4), log.perKey().get('a').?.hits);
    try testing.expectEqualStrings("daily", log.runs()[0].modeName());
    // Worst case: every key with huge numbers still fits a record line.
    var big: stats.PerKey = .{};
    for (&big.keys) |*k| k.* = .{ .hits = std.math.maxInt(u32), .misses = std.math.maxInt(u32), .ms_sum = std.math.maxInt(u32), .timed = std.math.maxInt(u32) };
    r.per_key = &big;
    var key_cfg: Config = .{ .mode = .custom, .time_limit = 3600, .layout = .colemak_dh };
    key_cfg.custom_hash = 1;
    const long = recordLine(&r, key_cfg, std.math.maxInt(i64), std.math.maxInt(u64), &buf);
    try testing.expect(long.len > 0 and long.len <= MAX_RECORD_LEN);
    // Malformed pk entries are skipped.
    var junk: stats.PerKey = .{};
    parsePk("a:1/2 b:x/1/1/1 :1/1/1/1 c:3/1/50/2 d:1/1/1/1/1 é:1/1/1/1", &junk);
    try testing.expectEqual(@as(u32, 3), junk.total().hits);
}

fn runLine(buf: []u8, wpm: f32, cfg: Config, ts: i64) []const u8 {
    var r = typingRes(wpm, true);
    r.duration_ms = 1000;
    return recordLine(&r, cfg, ts, 0, buf);
}

test "Log: chunked loading equals one-shot; pb lines are not runs" {
    var jsonl: std.ArrayList(u8) = .empty;
    defer jsonl.deinit(testing.allocator);
    var buf: [MAX_RECORD_LEN]u8 = undefined;
    for (0..40) |i| {
        const cfg: Config = if (i % 3 == 0) .{ .mode = .code, .lang = .go } else .{};
        try jsonl.appendSlice(testing.allocator, runLine(&buf, @floatFromInt(40 + i), cfg, @intCast(1000 + i)));
        try jsonl.append(testing.allocator, '\n');
        if (i % 7 == 0) try jsonl.appendSlice(testing.allocator, "garbage\n{\"v\":1,\"ts\":3,\"kind\":\"typing\",\"key\":\"words|x\",\"wpm\":999,\"pb\":true}\n");
    }
    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.strokes = 9;
    d.par = 7;
    d.stars = 2;
    d.drill_id = "basics/x";
    try jsonl.appendSlice(testing.allocator, recordLine(&d, .{ .mode = .vim }, 5000, 0, &buf));
    // No trailing newline on the last line.

    var one = Log.init(testing.allocator);
    defer one.deinit();
    one.loadJsonl(jsonl.items);
    try testing.expectEqual(@as(u32, 41), one.count());
    try testing.expectEqual(@as(u64, 40 * 1000 + 17234), one.totalMs());
    const last = one.runs()[one.runs().len - 1];
    try testing.expectEqual(RunKind.drill, last.kind);
    try testing.expectEqualStrings("drill", last.modeName());
    try testing.expectEqual(@as(u32, 9), last.strokes);
    try testing.expectEqual(@as(u16, 7), last.par);

    var rng = @import("rng.zig").Rng.init(5);
    for (0..30) |_| {
        var chunked = Log.init(testing.allocator);
        defer chunked.deinit();
        var pos: usize = 0;
        while (pos < jsonl.items.len) {
            const n = @min(jsonl.items.len - pos, 1 + rng.range(700));
            chunked.loadJsonl(jsonl.items[pos..][0..n]);
            pos += n;
        }
        try testing.expectEqual(one.count(), chunked.count());
        try testing.expectEqual(one.totalMs(), chunked.totalMs());
        for (one.runs(), chunked.runs()) |a, b| {
            try testing.expectEqualStrings(a.key(), b.key());
            try testing.expectEqual(a.wpm, b.wpm);
            try testing.expectEqual(a.ts, b.ts);
        }
    }
}

test "Log: ring keeps the newest MAX_RUNS; trend filters by key" {
    var log = Log.init(testing.allocator);
    defer log.deinit();
    var buf: [MAX_RECORD_LEN]u8 = undefined;
    const n = Log.MAX_RUNS * 3 + 17;
    for (0..n) |i| {
        const cfg: Config = if (i % 2 == 0) .{ .time_limit = 30 } else .{ .mode = .sentences };
        log.addLine(runLine(&buf, @floatFromInt(i % 200), cfg, @intCast(i)));
    }
    try testing.expectEqual(@as(u32, n), log.count());
    try testing.expectEqual(@as(usize, Log.MAX_RUNS), log.runs().len);
    try testing.expectEqual(@as(i64, n - Log.MAX_RUNS), log.runs()[0].ts);
    try testing.expectEqual(@as(i64, n - 1), log.runs()[Log.MAX_RUNS - 1].ts);
    var out: [5]f32 = undefined;
    const all = log.trend(null, &out);
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqual(@as(f32, @floatFromInt((n - 1) % 200)), all[4]);
    try testing.expectEqual(@as(f32, @floatFromInt((n - 5) % 200)), all[0]);
    const words = log.trend("words|common|t30|p0n0", &out);
    for (words, 0..) |v, i| try testing.expectEqual(@as(f32, @floatFromInt((n - 1 - 2 * (4 - i)) % 200)), v);
    try testing.expectEqual(@as(usize, 0), log.trend("nope", &out).len);
}

test "weak weights need enough data; slow and error-prone keys weigh more" {
    var pk: stats.PerKey = .{};
    var w: stats.KeyWeights = undefined;
    try testing.expect(!stats.weakWeights(&pk, &w));
    for ("abcdefghij") |c| {
        for (0..15) |_| pk.note(c, true, 150);
    }
    try testing.expect(stats.weakWeights(&pk, &w)); // 150 timed hits
    for (0..10) |_| pk.note('c', false, null); // c: error-prone
    for (0..15) |_| pk.note('d', true, 900); // d: slow
    try testing.expect(stats.weakWeights(&pk, &w));
    const a = w[stats.keyIndex('a').?];
    try testing.expect(w[stats.keyIndex('c').?] > a + 2);
    try testing.expect(w[stats.keyIndex('d').?] > a + 1);
    try testing.expectEqual(@as(f32, 0), w[stats.keyIndex('z').?]); // no data
    var few: stats.PerKey = .{};
    for (0..99) |_| few.note('a', true, 100);
    try testing.expect(!stats.weakWeights(&few, &w));
}

test "pbLines round-trip; entries are sorted" {
    var pb = PbTable.init(testing.allocator);
    defer pb.deinit();
    _ = pb.submit(.{ .time_limit = 30 }, &typingRes(87.44, true));
    _ = pb.submit(.{ .mode = .code, .lang = .lua, .code_keys = .vim }, &typingRes(41, true));
    _ = pb.submit(.{ .mode = .daily, .day = 20754 }, &typingRes(77.7, true));
    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.drill_id = "a/b";
    d.strokes = 9;
    d.stars = 3;
    d.duration_ms = 4321;
    _ = pb.submit(.{ .mode = .vim }, &d);
    try testing.expectEqual(PbOutcome.none, pb.submit(.{ .mode = .zen }, &typingRes(200, true)));

    const rows = try pb.entries(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("code|lua|vim", rows[0].key);
    try testing.expectEqualStrings("daily|2026-10-28", rows[1].key);
    try testing.expectEqualStrings("drill|a/b", rows[2].key);
    try testing.expectEqual(@as(u32, 9), rows[2].strokes);
    try testing.expectEqualStrings("words|common|t30|p0n0", rows[3].key);

    const lines = try pb.pbLines(testing.allocator);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, lines, "\n"));
    try testing.expect(std.mem.endsWith(u8, lines, "\n"));
    var back = PbTable.init(testing.allocator);
    defer back.deinit();
    back.loadJsonl(lines);
    try testing.expectEqual(pb.map.count(), back.map.count());
    var it = pb.map.iterator();
    while (it.next()) |kv| try testing.expectEqual(kv.value_ptr.*, back.map.get(kv.key_ptr.*).?);
    // The Log ignores them; CSV skips them.
    var log = Log.init(testing.allocator);
    defer log.deinit();
    log.loadJsonl(lines);
    try testing.expectEqual(@as(u32, 0), log.count());
    var csv_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&csv_buf);
    try testing.expect(!try writeCsvLine(&w, lines[0..std.mem.indexOfScalar(u8, lines, '\n').?]));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "CSV header and rows" {
    var out: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeCsvHeader(&w);
    var buf: [MAX_RECORD_LEN]u8 = undefined;
    const r = typingRes(87.4, true);
    try testing.expect(try writeCsvLine(&w, recordLine(&r, .{ .word_count = 25 }, 1793145600, 1, &buf)));
    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.strokes = 6;
    d.par = 5;
    d.stars = 2;
    d.duration_ms = 4210;
    d.drill_id = "textobj/ci-paren-01";
    try testing.expect(try writeCsvLine(&w, recordLine(&d, .{ .mode = .vim }, 0, 0, &buf)));
    var v = typingRes(50, true);
    v.kind = .vim_type;
    v.keystrokes = 120;
    try testing.expect(try writeCsvLine(&w, recordLine(&v, .{ .mode = .code, .code_keys = .vim, .lang = .c }, 86400, 0, &buf)));
    try testing.expect(!try writeCsvLine(&w, "garbage"));
    try testing.expectEqualStrings(
        \\ts,date,kind,key,mode,wpm,raw,acc,cons,correct,incorrect,extra,missed,corrected,ms,strokes,par,stars
        \\1793145600,2026-10-28,typing,words|common|w25|p0n0,words,87.4,92.1,96.3,78.2,120,3,1,0,5,17234,,,
        \\0,1970-01-01,drill,drill|textobj/ci-paren-01,drill,,,,,,,,,,4210,6,5,2
        \\86400,1970-01-02,vimtype,code|c|vim,code,50.0,54.7,96.3,78.2,120,3,1,0,5,17234,120,,
        \\
    , w.buffered());
}

test "stats text has every section" {
    var log = Log.init(testing.allocator);
    defer log.deinit();
    var pb = PbTable.init(testing.allocator);
    defer pb.deinit();
    var empty_out: [1024]u8 = undefined;
    var ew = std.Io.Writer.fixed(&empty_out);
    try writeStatsText(&ew, &log, &pb, 10);
    try testing.expect(std.mem.indexOf(u8, ew.buffered(), "(none yet)") != null);

    var buf: [MAX_RECORD_LEN]u8 = undefined;
    var pk: stats.PerKey = .{};
    for ("etaoinshrd") |c| {
        for (0..20) |_| pk.note(c, true, 140);
    }
    for (0..6) |_| pk.note('q', false, null);
    for (0..6) |_| pk.note('q', true, 400);
    for (0..12) |i| {
        var r = typingRes(@floatFromInt(50 + i), true);
        r.per_key = &pk;
        const line = recordLine(&r, .{ .time_limit = 30 }, @intCast(1793145600 + i * 60), 0, &buf);
        log.addLine(line);
        pb.loadJsonl(line);
    }
    var d = typingRes(0, true);
    d.kind = .vim_drill;
    d.drill_id = "a/b";
    d.strokes = 4;
    d.stars = 3;
    const dl = recordLine(&d, .{ .mode = .vim }, 1793145600, 0, &buf);
    log.addLine(dl);
    pb.loadJsonl(dl);
    var out: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeStatsText(&w, &log, &pb, 10);
    const text = w.buffered();
    for ([_][]const u8{ "runs        13", "recent runs", "bests per setup", "words|common|t30|p0n0", "61.0 wpm", "vim drills: 1 of 1 3-starred", "wpm trend (last 12)", "weakest keys", "  q   50.0% acc" }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
            return error.TestExpectedEqual;
        }
    }
    for (text) |c| try testing.expect(c == '\n' or (c >= 0x20 and c < 0x7f));
    try testing.expectEqual(@as(usize, 10), std.mem.count(u8, text[std.mem.indexOf(u8, text, "recent runs").?..std.mem.indexOf(u8, text, "bests per setup").?], "\n") - 2);
}

test "config JSON: every new key round-trips; bad values ignored" {
    var buf: [512]u8 = undefined;
    const cfg: Config = .{ .mode = .daily, .code_keys = .vim, .caret_pace = .fixed, .caret_wpm = 123, .stop_on_error = .word, .no_backspace = true, .layout = .colemak_dh, .focus = .weak, .syntax = false, .sounds = true, .tier = .k5, .lang = .yaml, .day = 77, .custom_hash = 5 };
    const json = configToJson(cfg, "one-dark", &buf);
    try testing.expect(std.mem.indexOf(u8, json, "\"day\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "custom") == null);
    var back: Config = .{};
    var theme: [32]u8 = undefined;
    _ = configFromJson(json, &back, &theme).?;
    var want = cfg;
    want.day = 0;
    want.custom_hash = 0;
    try testing.expectEqualDeep(want, back);
    // Worst case stays under 512 bytes.
    var worst: Config = .{ .mode = .sentences, .word_count = types.MAX_WORDS, .time_limit = 3600, .lang = .typescript, .tier = .common, .punctuation = true, .numbers = true, .vim_kind = .drills, .code_keys = .plain, .caret_pace = .fixed, .caret_wpm = 300, .stop_on_error = .letter, .no_backspace = false, .layout = .colemak_dh, .focus = .normal };
    worst.syntax = false;
    worst.sounds = false;
    try testing.expect(configToJson(worst, "abcdefghijklmnopqrstuvwxyzabcdef", &buf).len < 512);
    // pace_wpm clamps; reading never sets day or custom_hash.
    var c: Config = .{ .day = 9, .custom_hash = 9 };
    _ = configFromJson("{\"v\":1,\"pace_wpm\":5000,\"keys\":\"nope\",\"layout\":\"azerty\",\"day\":3,\"custom_hash\":4,\"stop\":\"letter\"}", &c, &theme);
    try testing.expectEqual(types.CARET_WPM_MAX, c.caret_wpm);
    try testing.expectEqual(types.CodeKeys.plain, c.code_keys);
    try testing.expectEqual(types.Layout.qwerty, c.layout);
    try testing.expectEqual(types.StopOnError.letter, c.stop_on_error);
    try testing.expectEqual(@as(u32, 9), c.day);
    try testing.expectEqual(@as(u32, 9), c.custom_hash);
    _ = configFromJson("{\"v\":1,\"pace_wpm\":-3}", &c, &theme);
    try testing.expectEqual(types.CARET_WPM_MIN, c.caret_wpm);
}
