//! Kitty graphics protocol encoding (pure computation, wasm-safe).
//!
//! Builds the APC commands the kitty presenter sends each frame:
//!   - direct (t=d): zlib (o=z) + base64, split into ≤4096-char chunks
//!     (`m=1` on all but the last, which carries `m=0`); the first chunk
//!     holds every key, continuation chunks only `m` and `q`.
//!   - temp file (t=t) / shared memory (t=s): the payload is the base64 of
//!     the path / shm name; `S` is the exact byte count to read.
//! Every command uses q=2 (never reply) so nothing comes back on stdin.

const std = @import("std");
const ansi = @import("ansi.zig");
const flate = std.compress.flate;

/// Raw bytes per direct chunk: 3072 bytes encode to exactly 4096 base64
/// characters, and every non-final chunk is a multiple of 4.
pub const chunk_raw = 3072;
pub const chunk_b64 = 4096;

pub const Format = enum(u8) { rgb = 24, rgba = 32, png = 100 };

pub const Medium = enum {
    direct,
    temp_file,
    shm,

    fn key(m: Medium) u8 {
        return switch (m) {
            .direct => 'd',
            .temp_file => 't',
            .shm => 's',
        };
    }
};

/// Pixel data description.
pub const Image = struct {
    w: u32,
    h: u32,
    format: Format,
};

/// Where and how the image is displayed (a=T, transmit + put).
pub const Place = struct {
    id: u32,
    placement: u32 = 1,
    cols: u16,
    rows: u16,
    z: i32 = -1,
};

fn writeKeys(buf: *ansi.Buf, img: Image, place: Place, medium: Medium, compressed: bool) !void {
    try buf.str("\x1b_Ga=T,f=");
    try buf.uint(@backingInt(img.format));
    try buf.str(",t=");
    try buf.byte(medium.key());
    if (compressed) try buf.str(",o=z");
    if (img.format != .png) { // PNG carries its own size
        try buf.str(",s=");
        try buf.uint(img.w);
        try buf.str(",v=");
        try buf.uint(img.h);
    }
    try buf.str(",i=");
    try buf.uint(place.id);
    try buf.str(",p=");
    try buf.uint(place.placement);
    try buf.str(",q=2,C=1,z=");
    try buf.int(place.z);
    try buf.str(",c=");
    try buf.uint(place.cols);
    try buf.str(",r=");
    try buf.uint(place.rows);
}

/// Direct transmission of `data` (already zlib-compressed when
/// `compressed`), chunked per the spec.
pub fn writeDirect(buf: *ansi.Buf, img: Image, place: Place, data: []const u8, compressed: bool) !void {
    var off: usize = 0;
    var first = true;
    while (true) {
        const end = @min(off + chunk_raw, data.len);
        const more = end < data.len;
        if (first) {
            try writeKeys(buf, img, place, .direct, compressed);
            try buf.str(if (more) ",m=1;" else ";");
            first = false;
        } else {
            try buf.str(if (more) "\x1b_Gm=1,q=2;" else "\x1b_Gm=0,q=2;");
        }
        try buf.base64(data[off..end]);
        try buf.str("\x1b\\");
        if (!more) break;
        off = end;
    }
}

/// Indirect transmission: `name` is the temp-file path (t=t) or the POSIX
/// shm object name (t=s); `size` is the number of bytes to read.
pub fn writeIndirect(buf: *ansi.Buf, img: Image, place: Place, medium: Medium, name: []const u8, size: usize) !void {
    std.debug.assert(medium != .direct);
    try writeKeys(buf, img, place, medium, false);
    try buf.str(",S=");
    try buf.uint(size);
    try buf.byte(';');
    try buf.base64(name);
    try buf.str("\x1b\\");
}

/// Delete image `id` and free its data.
pub fn writeDelete(buf: *ansi.Buf, id: u32) !void {
    try buf.str("\x1b_Ga=d,d=I,i=");
    try buf.uint(id);
    try buf.str(",q=2\x1b\\");
}

/// PNG scanline filter used by `Compressor.encodePng`.
pub const PngFilter = enum(u8) { none = 0, sub = 1, up = 2, paeth = 4 };

const png_signature = "\x89PNG\r\n\x1a\n";
/// Bytes before the IDAT data: signature, IHDR chunk, IDAT length + type.
const png_head_len = 8 + 25 + 8;

/// Reusable zlib compressor (std.compress.flate, level .fastest) and PNG
/// encoder. The 64 KiB window and the ~220 KB compressor state are
/// heap-allocated once.
pub const Compressor = struct {
    gpa: std.mem.Allocator,
    window: []u8,
    state: *flate.Compress,
    out: std.ArrayList(u8) = .empty,
    /// Two filtered-row scratch buffers for PNG.
    rows: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Compressor {
        const window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(window);
        const state = try gpa.create(flate.Compress);
        return .{ .gpa = gpa, .window = window, .state = state };
    }

    pub fn deinit(self: *Compressor) void {
        self.out.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.gpa.destroy(self.state);
        self.gpa.free(self.window);
    }

    /// Compress `data` as a zlib stream. The result stays valid until the
    /// next call.
    pub fn compress(self: *Compressor, data: []const u8) ![]const u8 {
        self.out.clearRetainingCapacity();
        // Compress.init asserts the output buffer has > 8 bytes.
        try self.out.ensureTotalCapacity(self.gpa, @max(4096, data.len / 8));
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.out);
        errdefer self.out = aw.toArrayList();
        self.state.* = flate.Compress.init(&aw.writer, self.window, .zlib, .fastest) catch return error.OutOfMemory;
        self.state.writer.writeAll(data) catch return error.OutOfMemory;
        // finish() writes the final block + adler32; flush() would not.
        self.state.finish() catch return error.OutOfMemory;
        self.out = aw.toArrayList();
        return self.out.items;
    }

    /// Encode 8-bit RGB (`channels` 3) or RGBA (4) pixels as a PNG with a
    /// single IDAT chunk. Row filtering makes smooth gradients compress far
    /// better than plain zlib of the raw bytes. Valid until the next call.
    pub fn encodePng(self: *Compressor, px: []const u8, w: u32, h: u32, channels: u8, filter: PngFilter) ![]const u8 {
        std.debug.assert(channels == 3 or channels == 4);
        const stride = @as(usize, w) * channels;
        std.debug.assert(px.len == stride * h);
        self.out.clearRetainingCapacity();
        try self.out.ensureTotalCapacity(self.gpa, @max(4096, px.len / 8));
        try self.rows.resize(self.gpa, stride + 1);

        // Signature + IHDR + IDAT header (length patched below).
        var head: [png_head_len]u8 = undefined;
        @memcpy(head[0..8], png_signature);
        std.mem.writeInt(u32, head[8..12], 13, .big);
        @memcpy(head[12..16], "IHDR");
        std.mem.writeInt(u32, head[16..20], w, .big);
        std.mem.writeInt(u32, head[20..24], h, .big);
        head[24] = 8; // bit depth
        head[25] = if (channels == 4) 6 else 2; // color type RGBA / RGB
        head[26] = 0; // deflate
        head[27] = 0; // adaptive filtering
        head[28] = 0; // no interlace
        std.mem.writeInt(u32, head[29..33], std.hash.Crc32.hash(head[12..29]), .big);
        @memcpy(head[37..41], "IDAT");
        self.out.appendSliceAssumeCapacity(&head);

        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.out);
        errdefer self.out = aw.toArrayList();
        self.state.* = flate.Compress.init(&aw.writer, self.window, .zlib, .fastest) catch return error.OutOfMemory;
        const row = self.rows.items;
        for (0..h) |y| {
            const cur = px[y * stride ..][0..stride];
            const prev: ?[]const u8 = if (y > 0) px[(y - 1) * stride ..][0..stride] else null;
            filterRow(row, cur, prev, channels, filter);
            self.state.writer.writeAll(row) catch return error.OutOfMemory;
        }
        self.state.finish() catch return error.OutOfMemory;
        self.out = aw.toArrayList();

        const idat_len = self.out.items.len - png_head_len;
        std.mem.writeInt(u32, self.out.items[33..37], @intCast(idat_len), .big);
        const crc = std.hash.Crc32.hash(self.out.items[37..]);
        var tail: [16]u8 = undefined;
        std.mem.writeInt(u32, tail[0..4], crc, .big);
        std.mem.writeInt(u32, tail[4..8], 0, .big);
        @memcpy(tail[8..12], "IEND");
        std.mem.writeInt(u32, tail[12..16], std.hash.Crc32.hash("IEND"), .big);
        try self.out.appendSlice(self.gpa, &tail);
        return self.out.items;
    }
};

/// Write filter byte + filtered scanline into `out` (len stride + 1).
fn filterRow(out: []u8, cur: []const u8, prev: ?[]const u8, bpp: usize, filter: PngFilter) void {
    out[0] = @backingInt(filter);
    const dst = out[1..];
    switch (filter) {
        .none => @memcpy(dst, cur),
        .sub => {
            for (0..@min(bpp, cur.len)) |i| dst[i] = cur[i];
            for (bpp..cur.len) |i| dst[i] = cur[i] -% cur[i - bpp];
        },
        .up => if (prev) |up| {
            for (dst, cur, up) |*d, c, u| d.* = c -% u;
        } else @memcpy(dst, cur),
        .paeth => if (prev) |up| {
            for (0..@min(bpp, cur.len)) |i| dst[i] = cur[i] -% up[i]; // paeth(0, b, 0) = b
            for (bpp..cur.len) |i| dst[i] = cur[i] -% paeth(cur[i - bpp], up[i], up[i - bpp]);
        } else {
            // first row: paeth(a, 0, 0) = a, i.e. Sub
            for (0..@min(bpp, cur.len)) |i| dst[i] = cur[i];
            for (bpp..cur.len) |i| dst[i] = cur[i] -% cur[i - bpp];
        },
    }
}

inline fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Split APC commands out of a byte stream (test helper).
fn apcs(gpa: std.mem.Allocator, bytes: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "\x1b_G")) |start| {
        const end = std.mem.indexOfPos(u8, bytes, start, "\x1b\\") orelse return error.Unterminated;
        try list.append(gpa, bytes[start + 3 .. end]);
        i = end + 2;
    }
    return list;
}

test "direct chunking: ≤4096 chars, multiples of 4, m flags, keys only on first" {
    const gpa = testing.allocator;
    var buf = ansi.Buf.init(gpa);
    defer buf.deinit();
    const data = try gpa.alloc(u8, chunk_raw * 2 + 100);
    defer gpa.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31);
    const img: Image = .{ .w = 64, .h = 48, .format = .rgb };
    try writeDirect(&buf, img, .{ .id = 0x5E000001, .cols = 80, .rows = 24 }, data, true);

    var cmds = try apcs(gpa, buf.bytes());
    defer cmds.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), cmds.items.len);
    try testing.expectEqualStrings(
        "a=T,f=24,t=d,o=z,s=64,v=48,i=1577058305,p=1,q=2,C=1,z=-1,c=80,r=24,m=1",
        cmds.items[0][0..std.mem.indexOfScalar(u8, cmds.items[0], ';').?],
    );
    try testing.expect(std.mem.startsWith(u8, cmds.items[1], "m=1,q=2;"));
    try testing.expect(std.mem.startsWith(u8, cmds.items[2], "m=0,q=2;"));

    // Reassemble the payload and compare.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (cmds.items, 0..) |cmd, k| {
        const payload = cmd[std.mem.indexOfScalar(u8, cmd, ';').? + 1 ..];
        try testing.expect(payload.len <= chunk_b64);
        if (k + 1 < cmds.items.len) {
            try testing.expectEqual(@as(usize, chunk_b64), payload.len);
            try testing.expect(payload.len % 4 == 0);
        }
        const n = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const old = joined.items.len;
        try joined.resize(gpa, old + n);
        try std.base64.standard.Decoder.decode(joined.items[old..], payload);
    }
    try testing.expectEqualSlices(u8, data, joined.items);
}

test "direct chunking: exact multiple and single small chunk" {
    const gpa = testing.allocator;
    var buf = ansi.Buf.init(gpa);
    defer buf.deinit();
    const place: Place = .{ .id = 7, .cols = 2, .rows = 1 };
    const img: Image = .{ .w = 1, .h = 1, .format = .rgba };

    try writeDirect(&buf, img, place, "abc", false);
    try testing.expectEqualStrings("\x1b_Ga=T,f=32,t=d,s=1,v=1,i=7,p=1,q=2,C=1,z=-1,c=2,r=1;YWJj\x1b\\", buf.bytes());

    buf.clear();
    const data = try gpa.alloc(u8, chunk_raw * 2);
    defer gpa.free(data);
    @memset(data, 0);
    try writeDirect(&buf, img, place, data, false);
    var cmds = try apcs(gpa, buf.bytes());
    defer cmds.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), cmds.items.len);
    try testing.expect(std.mem.endsWith(u8, cmds.items[0][0..std.mem.indexOfScalar(u8, cmds.items[0], ';').?], ",m=1"));
    try testing.expect(std.mem.startsWith(u8, cmds.items[1], "m=0,q=2;"));
    try testing.expectEqual(@as(usize, chunk_b64), cmds.items[1].len - "m=0,q=2;".len);
}

test "indirect and delete command strings" {
    const gpa = testing.allocator;
    var buf = ansi.Buf.init(gpa);
    defer buf.deinit();
    const place: Place = .{ .id = 0x5E000001, .cols = 160, .rows = 45 };
    const img: Image = .{ .w = 640, .h = 360, .format = .rgb };
    try writeIndirect(&buf, img, place, .shm, "/snt1", 691200);
    try testing.expectEqualStrings(
        "\x1b_Ga=T,f=24,t=s,s=640,v=360,i=1577058305,p=1,q=2,C=1,z=-1,c=160,r=45,S=691200;L3NudDE=\x1b\\",
        buf.bytes(),
    );
    buf.clear();
    try writeIndirect(&buf, img, place, .temp_file, "/tmp/a", 3);
    try testing.expect(std.mem.indexOf(u8, buf.bytes(), ",t=t,") != null);
    try testing.expect(std.mem.endsWith(u8, buf.bytes(), ",S=3;L3RtcC9h\x1b\\"));
    buf.clear();
    try writeDelete(&buf, 0x5E000001);
    try testing.expectEqualStrings("\x1b_Ga=d,d=I,i=1577058305,q=2\x1b\\", buf.bytes());
}

test "zlib round trip via flate.Decompress, compressor reuse" {
    const gpa = testing.allocator;
    var comp = try Compressor.init(gpa);
    defer comp.deinit();
    const data = try gpa.alloc(u8, 200_000);
    defer gpa.free(data);
    for (data, 0..) |*b, i| b.* = @truncate((i / 7) ^ (i >> 9));

    for (0..2) |_| {
        const z = try comp.compress(data);
        try testing.expect(z.len < data.len);
        try testing.expectEqual(@as(u8, 0x78), z[0]); // zlib header
        var in: std.Io.Reader = .fixed(z);
        var window: [flate.max_window_len]u8 = undefined;
        var d: flate.Decompress = .init(&in, .zlib, &window);
        const back = try d.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
    // tiny input still yields a valid stream
    const z = try comp.compress("x");
    var in: std.Io.Reader = .fixed(z);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &window);
    const back = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try testing.expectEqualStrings("x", back);
}

/// Minimal PNG decoder for our own output (test helper): checks chunk
/// layout + CRCs, inflates IDAT and undoes the filters.
fn decodePngForTest(gpa: std.mem.Allocator, png: []const u8, channels: u8) ![]u8 {
    try testing.expectEqualSlices(u8, png_signature, png[0..8]);
    try testing.expectEqualStrings("IHDR", png[12..16]);
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    try testing.expectEqual(std.hash.Crc32.hash(png[12..29]), std.mem.readInt(u32, png[29..33], .big));
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try testing.expectEqualStrings("IDAT", png[37..41]);
    const idat = png[41..][0..idat_len];
    try testing.expectEqual(std.hash.Crc32.hash(png[37 .. 41 + idat_len]), std.mem.readInt(u32, png[41 + idat_len ..][0..4], .big));
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00IEND\xaeB`\x82", png[45 + idat_len ..]);

    var in: std.Io.Reader = .fixed(idat);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &window);
    const raw = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    const stride = @as(usize, w) * channels;
    try testing.expectEqual((stride + 1) * h, raw.len);
    const out = try gpa.alloc(u8, stride * h);
    for (0..h) |y| {
        const f = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const cur = out[y * stride ..][0..stride];
        for (0..stride) |i| {
            const a: u8 = if (i >= channels) cur[i - channels] else 0;
            const b: u8 = if (y > 0) out[(y - 1) * stride + i] else 0;
            const c: u8 = if (y > 0 and i >= channels) out[(y - 1) * stride + i - channels] else 0;
            cur[i] = src[i] +% switch (f) {
                0 => 0,
                1 => a,
                2 => b,
                4 => paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
    }
    return out;
}

test "png encode round trip for every filter, RGB and RGBA" {
    const gpa = testing.allocator;
    var comp = try Compressor.init(gpa);
    defer comp.deinit();
    const w = 37;
    const h = 23;
    inline for (.{ 3, 4 }) |ch| {
        var px: [w * h * ch]u8 = undefined;
        for (&px, 0..) |*b, i| b.* = @truncate(i * 7 + (i / (w * ch)) * 13);
        inline for (.{ PngFilter.none, .sub, .up, .paeth }) |f| {
            const png = try comp.encodePng(&px, w, h, ch, f);
            const back = try decodePngForTest(gpa, png, ch);
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, &px, back);
        }
    }
}

test "png direct command omits s/v" {
    var buf = ansi.Buf.init(testing.allocator);
    defer buf.deinit();
    try writeDirect(&buf, .{ .w = 9, .h = 9, .format = .png }, .{ .id = 1, .cols = 3, .rows = 2 }, "x", false);
    try testing.expectEqualStrings("\x1b_Ga=T,f=100,t=d,i=1,p=1,q=2,C=1,z=-1,c=3,r=2;eA==\x1b\\", buf.bytes());
}
