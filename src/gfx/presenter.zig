//! Presenters turn a `Surface` (pixels + text layer) into terminal bytes.
//!
//! Backends:
//!   - `.kitty`: the pixel layer is ONE kitty-graphics image per frame
//!     (`a=T,i=ID,p=1,q=2,C=1,z=Z,c=cols,r=rows`, placed at 1;1 under the
//!     text and, by default, under non-default cell backgrounds), followed
//!     by the diffed text layer whose empty cells use the default
//!     background so the image shows through. Media: shm (t=s) >
//!     temp file (t=t) > direct (t=d, zlib + chunked base64), degrading
//!     automatically when a syscall fails.
//!   - `.halfblock`: `▀` cells, two pixels per cell, diffed (halfblock.zig).
//!   - `.external`: text layer only (the web host draws the pixels).
//!
//! Every `present` output is wrapped in synchronized-update mode
//! (`CSI ?2026h` … `CSI ?2026l`) and ends with an SGR reset. Only CUP is
//! used for cursor movement; cursor visibility is the app's business.

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const kitty = @import("kitty.zig");
const media = @import("media.zig");
const TextLayer = @import("textlayer.zig").TextLayer;
const HalfBlock = @import("halfblock.zig").HalfBlock;
const surface_mod = @import("../fx/surface.zig");
const Surface = surface_mod.Surface;
const Px = surface_mod.Px;

const is_wasm = builtin.target.cpu.arch.isWasm();

pub const Backend = enum { kitty, halfblock, external };

pub const KittyMedia = enum { direct, temp_file, shm };

/// Largest z-index that kitty/Ghostty draw below non-default cell
/// backgrounds (anything < INT32_MIN/2).
pub const z_below_bg: i32 = -1073741825;

pub const Options = struct {
    /// Preferred kitty transmission medium (degrades on failure).
    kitty_media: KittyMedia = .direct,
    /// Send RGB (f=24, alpha dropped) instead of RGBA (f=32).
    rgb24: bool = true,
    /// Direct medium only: send a row-filtered PNG (f=100) instead of
    /// zlib'd raw pixels (f=24/32 + o=z). Much smaller for gradients.
    kitty_png: bool = true,
    /// Kitty image id (also used as the delete target in teardown).
    image_id: u32 = 0x5E000001,
    /// Kitty placement z-index. The default (`z_below_bg`) draws the image
    /// under non-default cell backgrounds, so `TextCell.bg` stays opaque
    /// over the pixels (as in the half-block and web backends); cells with
    /// the default background show the image. -1 would draw the image over
    /// cell backgrounds (only text on top).
    kitty_z: i32 = z_below_bg,
    /// Directory for t=t temp files (e.g. $TMPDIR); null = "/tmp".
    tmpdir: ?[]const u8 = null,
    /// Per-process unique number (e.g. the pid) for temp/shm names.
    unique: u32 = 0,
    /// Half-block: low bits dropped per channel before diffing (0 = exact).
    /// 2 cuts bytes/frame by ~40% on busy scenes with no visible banding at
    /// half-block resolution.
    halfblock_quant_bits: u3 = 2,
};

/// Size of the pixel layer a backend wants for a `cols` × `rows` grid.
/// Half-block: one pixel per cell column, two per row. Kitty/external:
/// half the real pixel resolution (8×16 cells assumed when unknown),
/// clamped to w ≤ 960 (and h ≤ 960 for portrait grids) keeping the aspect
/// ratio.
pub fn pixelSize(backend: Backend, cols: u16, rows: u16, cell_px_w: u16, cell_px_h: u16) struct { w: u32, h: u32 } {
    switch (backend) {
        .halfblock => return .{ .w = cols, .h = @as(u32, rows) * 2 },
        .kitty, .external => {
            const cw: u64 = if (cell_px_w == 0 or cell_px_h == 0) 8 else cell_px_w;
            const ch: u64 = if (cell_px_w == 0 or cell_px_h == 0) 16 else cell_px_h;
            var w: u64 = @as(u64, cols) * cw / 2;
            var h: u64 = @as(u64, rows) * ch / 2;
            const max_w = 960;
            if (w > max_w) {
                h = (h * max_w + w / 2) / w;
                w = max_w;
            }
            // Portrait / narrow-tall grids: bound the long side too, or a
            // tall split would get a multi-megapixel frame.
            const max_h = 960;
            if (h > max_h) {
                w = (w * max_h + h / 2) / h;
                h = max_h;
            }
            return .{ .w = @intCast(@max(w, 1)), .h = @intCast(@max(h, 1)) };
        },
    }
}

/// Per-frame output statistics.
pub const Stats = struct {
    /// Total bytes returned by the last `present`.
    total: usize = 0,
    /// Bytes of kitty APC commands (0 when the image was skipped).
    image: usize = 0,
    /// Raw pixel bytes of the transmitted image.
    image_raw: usize = 0,
    /// zlib / PNG size (direct medium only).
    image_compressed: usize = 0,
    /// Medium actually used for the last image.
    medium: KittyMedia = .direct,
    /// Cells re-emitted (text layer or half-block cells).
    cells: u32 = 0,
};

const KittyState = struct {
    comp: ?kitty.Compressor = null,
    rgb: []u8 = &.{},
    /// Hash of the last transmitted image (skip identical frames).
    last_hash: u64 = 0,
    last_w: u32 = 0,
    last_h: u32 = 0,
    sent: bool = false,
    /// Medium currently in use (degrades after failures).
    medium: KittyMedia = .direct,
    /// Frame counter for unique temp/shm names.
    seq: u32 = 0,
    name_buf: [1024]u8 = undefined,
};

pub const Presenter = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    opts: Options,
    out: ansi.Buf,
    pen: ansi.Pen = .{},
    cur: ansi.Cursor = .{},
    text: TextLayer,
    hb: HalfBlock,
    kit: KittyState = .{},
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, backend: Backend, opts: Options) !Presenter {
        var p: Presenter = .{
            .allocator = allocator,
            .backend = backend,
            .opts = opts,
            .out = ansi.Buf.init(allocator),
            .text = TextLayer.init(allocator),
            .hb = HalfBlock.init(allocator, @min(opts.halfblock_quant_bits, 4)),
        };
        p.kit.medium = switch (opts.kitty_media) {
            .shm => if (media.shm_supported) .shm else if (media.temp_file_supported) .temp_file else .direct,
            .temp_file => if (media.temp_file_supported) .temp_file else .direct,
            .direct => .direct,
        };
        return p;
    }

    pub fn deinit(self: *Presenter) void {
        self.out.deinit();
        self.text.deinit();
        self.hb.deinit();
        if (self.kit.comp) |*c| c.deinit();
        self.allocator.free(self.kit.rgb);
        self.* = undefined;
    }

    /// Force a full repaint (and image retransmission) on the next present,
    /// e.g. after a resize, a screen clear or a mode switch.
    pub fn invalidate(self: *Presenter) void {
        self.text.invalidate();
        self.hb.invalidate();
        self.kit.sent = false;
    }

    /// Statistics of the last `present`.
    pub fn lastStats(self: *const Presenter) Stats {
        return self.stats;
    }

    /// Bytes produced by the last `present`.
    pub fn lastFrameBytes(self: *const Presenter) usize {
        return self.stats.total;
    }

    /// Kitty medium currently in use (may have degraded from Options).
    pub fn kittyMedium(self: *const Presenter) KittyMedia {
        return self.kit.medium;
    }

    /// Render `s` to terminal bytes. The slice is owned by the presenter
    /// and valid until the next `present`/`teardown`.
    pub fn present(self: *Presenter, s: *const Surface) ![]const u8 {
        self.out.clear();
        self.pen.invalidate();
        self.cur.invalidate();
        self.stats = .{ .medium = self.kit.medium };
        // The diff state may already record cells/the image as shown; the
        // caller drops the bytes on error, so repaint everything next time.
        errdefer self.invalidate();
        try self.out.str(ansi.sync_begin);
        switch (self.backend) {
            .kitty => {
                if (!is_wasm) try self.emitImage(s);
                try self.text.emit(&self.out, &self.pen, &self.cur, s);
                self.stats.cells = self.text.last_cells;
            },
            .external => {
                try self.text.emit(&self.out, &self.pen, &self.cur, s);
                self.stats.cells = self.text.last_cells;
            },
            .halfblock => {
                try self.hb.emit(&self.out, &self.pen, &self.cur, s);
                self.stats.cells = self.hb.last_cells;
            },
        }
        try self.out.str(ansi.sgr_reset);
        try self.out.str(ansi.sync_end);
        self.stats.total = self.out.len();
        return self.out.bytes();
    }

    /// Bytes that remove everything the presenter put on screen that the
    /// app's normal clear can't (the kitty image) and reset SGR. Also
    /// invalidates, so a later `present` repaints fully.
    pub fn teardown(self: *Presenter) []const u8 {
        self.out.clear();
        if (self.backend == .kitty and !is_wasm)
            kitty.writeDelete(&self.out, self.opts.image_id) catch {};
        self.out.str(ansi.sgr_reset) catch {};
        self.invalidate();
        return self.out.bytes();
    }

    // ------------------------------------------------------------------
    // kitty image
    // ------------------------------------------------------------------

    fn emitImage(self: *Presenter, s: *const Surface) !void {
        if (s.w == 0 or s.h == 0 or s.cols == 0 or s.rows == 0) return;
        const k = &self.kit;
        const raw_px: []const u8 = std.mem.sliceAsBytes(s.pixels);
        const hash = std.hash.Wyhash.hash(@as(u64, s.cols) << 16 | s.rows, raw_px);
        if (k.sent and hash == k.last_hash and k.last_w == s.w and k.last_h == s.h) return;

        const data: []const u8 = if (self.opts.rgb24) try self.packRgb(s.pixels) else raw_px;
        const img: kitty.Image = .{ .w = s.w, .h = s.h, .format = if (self.opts.rgb24) .rgb else .rgba };
        const place: kitty.Place = .{ .id = self.opts.image_id, .cols = s.cols, .rows = s.rows, .z = self.opts.kitty_z };

        try self.cur.moveTo(&self.out, 0, 0);
        const cmd_start = self.out.len();
        while (true) {
            switch (k.medium) {
                .shm => {
                    const name = self.shmName() catch {
                        k.medium = .temp_file;
                        continue;
                    };
                    media.writeShm(name, data) catch {
                        k.medium = if (media.temp_file_supported) .temp_file else .direct;
                        continue;
                    };
                    try kitty.writeIndirect(&self.out, img, place, .shm, name, data.len);
                },
                .temp_file => {
                    const path = self.tempPath() catch {
                        k.medium = .direct;
                        continue;
                    };
                    media.writeTempFile(path, data) catch {
                        k.medium = .direct;
                        continue;
                    };
                    try kitty.writeIndirect(&self.out, img, place, .temp_file, path, data.len);
                },
                .direct => {
                    if (k.comp == null) k.comp = try kitty.Compressor.init(self.allocator);
                    if (self.opts.kitty_png) {
                        const png = try k.comp.?.encodePng(data, s.w, s.h, if (self.opts.rgb24) 3 else 4, .paeth);
                        self.stats.image_compressed = png.len;
                        var png_img = img;
                        png_img.format = .png;
                        try kitty.writeDirect(&self.out, png_img, place, png, false);
                    } else {
                        const z = try k.comp.?.compress(data);
                        self.stats.image_compressed = z.len;
                        try kitty.writeDirect(&self.out, img, place, z, true);
                    }
                },
            }
            break;
        }
        self.stats.image = self.out.len() - cmd_start;
        self.stats.image_raw = data.len;
        self.stats.medium = k.medium;
        k.seq +%= 1;
        k.sent = true;
        k.last_hash = hash;
        k.last_w = s.w;
        k.last_h = s.h;
    }

    fn packRgb(self: *Presenter, px: []const Px) ![]const u8 {
        const k = &self.kit;
        const need = px.len * 3;
        if (k.rgb.len != need) {
            self.allocator.free(k.rgb);
            k.rgb = &.{};
            k.rgb = try self.allocator.alloc(u8, need);
        }
        const out = k.rgb;
        for (px, 0..) |p, i| {
            out[i * 3 + 0] = p.r;
            out[i * 3 + 1] = p.g;
            out[i * 3 + 2] = p.b;
        }
        return out;
    }

    /// "<tmpdir>/snipetype-tty-graphics-protocol-<unique>-<seq>.rgb"
    fn tempPath(self: *Presenter) ![:0]const u8 {
        var dir: []const u8 = self.opts.tmpdir orelse "/tmp";
        while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
        if (dir.len == 0) dir = "/tmp";
        return std.mem.printSentinel(&self.kit.name_buf, "{s}/snipetype-tty-graphics-protocol-{d}-{d}.{s}", .{
            dir, self.opts.unique, self.kit.seq, if (self.opts.rgb24) "rgb" else "rgba",
        }, 0);
    }

    /// "/snt<unique hex><seq hex>" — at most 20 chars (macOS limit is 31).
    fn shmName(self: *Presenter) ![:0]const u8 {
        return std.mem.printSentinel(&self.kit.name_buf, "/snt{x}-{x}", .{ self.opts.unique, self.kit.seq }, 0);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Color = @import("../ui/color.zig").Color;

test "pixelSize" {
    const hb = pixelSize(.halfblock, 160, 45, 9, 18);
    try testing.expectEqual(@as(u32, 160), hb.w);
    try testing.expectEqual(@as(u32, 90), hb.h);
    const k = pixelSize(.kitty, 80, 24, 0, 0);
    try testing.expectEqual(@as(u32, 320), k.w);
    try testing.expectEqual(@as(u32, 192), k.h);
    const k2 = pixelSize(.kitty, 160, 45, 8, 16);
    try testing.expectEqual(@as(u32, 640), k2.w);
    try testing.expectEqual(@as(u32, 360), k2.h);
    // clamp: 300 cols * 10 px / 2 = 1500 -> 960, aspect kept
    const big = pixelSize(.external, 300, 80, 10, 20);
    try testing.expectEqual(@as(u32, 960), big.w);
    try testing.expectEqual(@as(u32, 512), big.h);
    // portrait: the long side is bounded too
    const tall = pixelSize(.kitty, 80, 150, 16, 32);
    try testing.expectEqual(@as(u32, 256), tall.w);
    try testing.expectEqual(@as(u32, 960), tall.h);
    const absurd = pixelSize(.kitty, 1, 65535, 65535, 65535);
    try testing.expect(absurd.w >= 1 and absurd.w <= 960 and absurd.h == 960);
}

test "external: sync-wrapped, SGR reset at end, diffed" {
    var s = try Surface.init(testing.allocator, 4, 2, 16, 16);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .external, .{});
    defer p.deinit();
    const first = try p.present(&s);
    try testing.expect(std.mem.startsWith(u8, first, "\x1b[?2026h"));
    try testing.expect(std.mem.endsWith(u8, first, "\x1b[0m\x1b[?2026l"));
    try testing.expect(std.mem.indexOf(u8, first, "\x1b_G") == null);
    try testing.expect(std.mem.indexOf(u8, first, "\x1b[2J") == null);
    try testing.expectEqual(@as(u32, 8), p.lastStats().cells);

    const second = try p.present(&s);
    try testing.expectEqualStrings("\x1b[?2026h\x1b[0m\x1b[?2026l", second);

    s.putText(1, 1, "ok", Color.rgb(243, 238, 228), null, false);
    const third = try p.present(&s);
    try testing.expectEqualStrings("\x1b[?2026h\x1b[2;2H\x1b[0;38;2;243;238;228mok\x1b[0m\x1b[?2026l", third);
    try testing.expectEqual(third.len, p.lastFrameBytes());

    p.invalidate();
    _ = try p.present(&s);
    try testing.expectEqual(@as(u32, 8), p.lastStats().cells);
    try testing.expectEqualStrings("\x1b[0m", p.teardown());
}

test "kitty direct: image before text, CUP 1;1, skip unchanged image, teardown deletes" {
    var s = try Surface.init(testing.allocator, 4, 2, 32, 16);
    defer s.deinit();
    for (s.pixels, 0..) |*px, i| px.* = .{ .r = @truncate(i), .g = 3, .b = 200 };
    s.putText(0, 0, "A", Color.WHITE, null, true);
    var p = try Presenter.init(testing.allocator, .kitty, .{ .image_id = 42, .kitty_png = false });
    defer p.deinit();
    const out = try p.present(&s);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h\x1b[1;1H\x1b_Ga=T,f=24,t=d,o=z,s=32,v=16,i=42,p=1,q=2,C=1,z=-1073741825,c=4,r=2;"));
    const img_end = std.mem.indexOf(u8, out, "\x1b\\").?;
    // text follows the image; cursor still at 1;1 thanks to C=1 → no extra CUP
    try testing.expect(std.mem.startsWith(u8, out[img_end + 2 ..], "\x1b[0;1;38;2;255;255;255mA"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b[0m\x1b[?2026l"));
    const st = p.lastStats();
    try testing.expectEqual(@as(usize, 32 * 16 * 3), st.image_raw);
    try testing.expect(st.image > 0 and st.image_compressed > 0);

    // Decode the payload and check it round-trips to RGB.
    const payload_start = std.mem.indexOfScalar(u8, out, ';').?;
    const b64 = out[std.mem.indexOfScalarPos(u8, out, payload_start + 1, ';').? + 1 .. img_end];
    const z = try testing.allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
    defer testing.allocator.free(z);
    try std.base64.standard.Decoder.decode(z, b64);
    var in: std.Io.Reader = .fixed(z);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const rgb = try d.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(rgb);
    try testing.expectEqual(@as(usize, 32 * 16 * 3), rgb.len);
    try testing.expectEqual(@as(u8, 5), rgb[5 * 3]);
    try testing.expectEqual(@as(u8, 200), rgb[5 * 3 + 2]);

    // unchanged pixels: no image retransmission
    const again = try p.present(&s);
    try testing.expectEqualStrings("\x1b[?2026h\x1b[0m\x1b[?2026l", again);
    // change a pixel: image resent, text untouched
    s.pixels[0].g = 99;
    const changed = try p.present(&s);
    try testing.expect(std.mem.indexOf(u8, changed, "\x1b_Ga=T") != null);
    try testing.expectEqual(@as(u32, 0), p.lastStats().cells);
    // invalidate resends the image too
    p.invalidate();
    try testing.expect(std.mem.indexOf(u8, try p.present(&s), "\x1b_Ga=T") != null);

    try testing.expectEqualStrings("\x1b_Ga=d,d=I,i=42,q=2\x1b\\\x1b[0m", p.teardown());
}

test "kitty z option" {
    var s = try Surface.init(testing.allocator, 2, 1, 4, 2);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .kitty, .{ .kitty_z = -1 });
    defer p.deinit();
    try testing.expect(std.mem.indexOf(u8, try p.present(&s), ",C=1,z=-1,c=2,r=1;") != null);
}

test "kitty rgba32 sends f=32 with raw alpha" {
    var s = try Surface.init(testing.allocator, 2, 1, 4, 2);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .kitty, .{ .rgb24 = false, .kitty_png = false });
    defer p.deinit();
    const out = try p.present(&s);
    try testing.expect(std.mem.indexOf(u8, out, "a=T,f=32,") != null);
    try testing.expectEqual(@as(usize, 4 * 2 * 4), p.lastStats().image_raw);
}

test "kitty temp_file medium writes the file and references it" {
    if (!media.temp_file_supported) return error.SkipZigTest;
    var s = try Surface.init(testing.allocator, 2, 1, 4, 2);
    defer s.deinit();
    @memset(s.pixels, .{ .r = 1, .g = 2, .b = 3 });
    var p = try Presenter.init(testing.allocator, .kitty, .{ .kitty_media = .temp_file, .tmpdir = "/tmp/", .unique = 4242 });
    defer p.deinit();
    const out = try p.present(&s);
    try testing.expectEqual(KittyMedia.temp_file, p.lastStats().medium);
    const path = "/tmp/snipetype-tty-graphics-protocol-4242-0.rgb";
    defer media.unlinkFile(path);
    var enc_buf: [128]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&enc_buf, path);
    var want_buf: [256]u8 = undefined;
    const want = try std.mem.print(&want_buf, "\x1b_Ga=T,f=24,t=t,s=4,v=2,i=1577058305,p=1,q=2,C=1,z=-1073741825,c=2,r=1,S=24;{s}\x1b\\", .{enc});
    try testing.expect(std.mem.indexOf(u8, out, want) != null);
}

test "kitty temp_file falls back to direct when the directory is unusable" {
    if (!media.temp_file_supported) return error.SkipZigTest;
    var s = try Surface.init(testing.allocator, 2, 1, 4, 2);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .kitty, .{ .kitty_media = .temp_file, .tmpdir = "/nonexistent-snipetype-dir" });
    defer p.deinit();
    const out = try p.present(&s);
    try testing.expect(std.mem.indexOf(u8, out, "a=T,f=100,t=d,i=") != null);
    try testing.expectEqual(KittyMedia.direct, p.kittyMedium());
}

test "kitty shm medium" {
    if (!media.shm_supported) return error.SkipZigTest;
    var s = try Surface.init(testing.allocator, 2, 1, 4, 2);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .kitty, .{ .kitty_media = .shm, .unique = 0xbeef });
    defer p.deinit();
    const out = try p.present(&s);
    // nobody reads it in tests: unlink ourselves
    defer media.unlinkShm("/sntbeef-0");
    try testing.expectEqual(KittyMedia.shm, p.lastStats().medium);
    try testing.expect(std.mem.indexOf(u8, out, ",t=s,") != null);
    try testing.expect(std.mem.indexOf(u8, out, ",S=24;L3NudGJlZWYtMA==\x1b\\") != null);
}

test "kitty direct png (default)" {
    var s = try Surface.init(testing.allocator, 4, 2, 8, 4);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .kitty, .{});
    defer p.deinit();
    const out = try p.present(&s);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h\x1b[1;1H\x1b_Ga=T,f=100,t=d,i=1577058305,p=1,q=2,C=1,z=-1073741825,c=4,r=2;iVBORw0KGgo"));
    try testing.expectEqual(@as(usize, 8 * 4 * 3), p.lastStats().image_raw);
}

test "halfblock presenter end to end" {
    var s = try Surface.init(testing.allocator, 2, 1, 2, 2);
    defer s.deinit();
    var p = try Presenter.init(testing.allocator, .halfblock, .{ .halfblock_quant_bits = 0 });
    defer p.deinit();
    s.pixels[0] = .{ .r = 255, .g = 0, .b = 0 };
    const out = try p.present(&s);
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0;38;2;255;0;0;48;2;0;0;0m\u{2580} \x1b[0m\x1b[?2026l",
        out,
    );
}

test "allocation failure mid-frame forces a full repaint next frame" {
    var s = try Surface.init(testing.allocator, 40, 10, 40, 20);
    defer s.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var p = try Presenter.init(failing.allocator(), .external, .{});
    defer p.deinit();
    _ = try p.present(&s); // blank frame: small output buffer
    // Per-cell colors make the next diff far larger, so the buffer must
    // grow mid-frame, after some cells were already recorded as shown.
    for (s.text, 0..) |*tc, i| tc.* = .{ .cp = 'a' + @as(u21, @intCast(i % 26)), .fg = Color.rgb(@truncate(i), 7, 9) };
    // Fail both fresh allocations and in-place growth: std.testing.allocator
    // (SafeAllocator since Zig 0.17) can satisfy growth via resize/remap.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, p.present(&s));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = try p.present(&s);
    try testing.expectEqual(@as(u32, 400), p.lastStats().cells);
}
