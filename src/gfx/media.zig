//! Platform side of kitty's indirect media: temp files (t=t) and POSIX
//! shared memory (t=s).
//!
//! The presenter has no `std.Io`, so this uses raw `open/write/close`
//! through `std.posix.system` (libc on macOS, direct syscalls on static
//! Linux). Shared memory needs libc's `shm_open` and is only available when
//! libc is linked (always on macOS). On wasm everything reports
//! `error.Unsupported` and compiles to nothing.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch.isWasm();
const posix = std.posix;

pub const Error = error{ Unsupported, NameTooLong, SystemFailure };

/// Temp files work wherever we have POSIX syscalls.
pub const temp_file_supported = !is_wasm and builtin.target.os.tag != .windows;

/// shm_open requires libc (macOS always links it).
pub const shm_supported = !is_wasm and builtin.link_libc and
    (builtin.target.os.tag.isDarwin() or builtin.target.os.tag == .linux or builtin.target.os.tag == .freebsd);

/// Write `data` to a new file at `path` (mode 0600). The terminal deletes
/// it after reading because the name contains "tty-graphics-protocol".
/// The file is created exclusively without following symlinks (the name is
/// predictable and /tmp is shared); a stale entry is unlinked and the
/// create retried once.
pub fn writeTempFile(path: [:0]const u8, data: []const u8) Error!void {
    if (comptime !temp_file_supported) return error.Unsupported;
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true };
    const fd = posix.openatZ(posix.AT.FDCWD, path.ptr, flags, 0o600) catch |e| switch (e) {
        error.NameTooLong => return error.NameTooLong,
        error.PathAlreadyExists => retry: {
            unlinkFile(path);
            break :retry posix.openatZ(posix.AT.FDCWD, path.ptr, flags, 0o600) catch return error.SystemFailure;
        },
        else => return error.SystemFailure,
    };
    defer _ = posix.system.close(fd);
    try writeAllFd(fd, data);
}

fn writeAllFd(fd: posix.fd_t, data: []const u8) Error!void {
    var rest = data;
    while (rest.len > 0) {
        const rc = posix.system.write(fd, rest.ptr, rest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.SystemFailure;
                rest = rest[n..];
            },
            .INTR => continue,
            else => return error.SystemFailure,
        }
    }
}

/// Create the shm object `name` (exclusive, 0600), size it to `data.len`,
/// copy `data` in and close it. The terminal shm_unlinks it after reading.
/// On any failure the object is unlinked again.
pub fn writeShm(name: [:0]const u8, data: []const u8) Error!void {
    if (comptime !shm_supported) return error.Unsupported;
    if (data.len == 0) return error.SystemFailure;
    const c = std.c;
    const oflag: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })));
    // Darwin's shm_open is variadic: the mode must be passed as c_uint.
    const fd = if (comptime builtin.target.os.tag.isDarwin())
        c.shm_open(name.ptr, oflag, @as(c_uint, 0o600))
    else
        c.shm_open(name.ptr, oflag, 0o600);
    if (fd < 0) return error.SystemFailure;
    var ok = false;
    defer {
        _ = c.close(fd);
        if (!ok) _ = c.shm_unlink(name.ptr);
    }
    if (c.ftruncate(fd, @intCast(data.len)) != 0) return error.SystemFailure;
    const map = posix.mmap(null, data.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch
        return error.SystemFailure;
    @memcpy(map[0..data.len], data);
    posix.munmap(map);
    ok = true;
}

/// Remove an shm object we created (used by tests / cleanup).
pub fn unlinkShm(name: [:0]const u8) void {
    if (comptime !shm_supported) return;
    _ = std.c.shm_unlink(name.ptr);
}

/// Remove a file (used by tests / cleanup).
pub fn unlinkFile(path: [:0]const u8) void {
    if (comptime !temp_file_supported) return;
    if (comptime builtin.link_libc) {
        _ = std.c.unlink(path.ptr);
    } else if (builtin.target.os.tag == .linux) {
        _ = std.os.linux.unlinkat(posix.AT.FDCWD, path.ptr, 0);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Read a file back with raw syscalls (test helper).
fn readFile(path: [:0]const u8, out: []u8) !usize {
    const fd = try posix.openatZ(posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer _ = posix.system.close(fd);
    return posix.read(fd, out);
}

test "temp file write" {
    if (!temp_file_supported) return error.SkipZigTest;
    var name_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&name_buf, "/tmp/snipetype-gfx-test-{d}.rgb", .{@intFromPtr(&name_buf) & 0xffffff}, 0);
    defer unlinkFile(path);
    try writeTempFile(path, "hello pixels");
    var back: [64]u8 = undefined;
    const n = try readFile(path, &back);
    try testing.expectEqualStrings("hello pixels", back[0..n]);
    // a stale file of the same name is replaced
    try writeTempFile(path, "hi");
    const m = try readFile(path, &back);
    try testing.expectEqualStrings("hi", back[0..m]);
}

test "temp file never follows a planted symlink" {
    if (!temp_file_supported or !builtin.link_libc) return error.SkipZigTest;
    var target_buf: [128]u8 = undefined;
    const target = try std.mem.printSentinel(&target_buf, "/tmp/snipetype-gfx-victim-{d}", .{@intFromPtr(&target_buf) & 0xffffff}, 0);
    var link_buf: [128]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buf, "/tmp/snipetype-gfx-link-{d}.rgb", .{@intFromPtr(&link_buf) & 0xffffff}, 0);
    defer unlinkFile(target);
    defer unlinkFile(link);
    try writeTempFile(target, "precious");
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(target.ptr, link.ptr));
    try writeTempFile(link, "pixels");
    var back: [64]u8 = undefined;
    const n = try readFile(target, &back);
    try testing.expectEqualStrings("precious", back[0..n]);
    const m = try readFile(link, &back);
    try testing.expectEqualStrings("pixels", back[0..m]);
}

test "shm write and read back" {
    if (!shm_supported) return error.SkipZigTest;
    var name_buf: [32]u8 = undefined;
    const name = try std.mem.printSentinel(&name_buf, "/snttest{x}", .{@intFromPtr(&name_buf) & 0xffffff}, 0);
    defer unlinkShm(name);
    const rows: [100][9]u8 = @splat("rgbrgbrgb".*);
    const data: []const u8 = std.mem.sliceAsBytes(&rows);
    try writeShm(name, data);
    // exclusive create: a second write with the same name fails
    try testing.expectError(error.SystemFailure, writeShm(name, data));
    // read back like the terminal would
    const c = std.c;
    const fd = c.shm_open(name.ptr, @bitCast(@as(u32, @bitCast(posix.O{ .ACCMODE = .RDONLY }))), @as(c_uint, 0));
    try testing.expect(fd >= 0);
    defer _ = c.close(fd);
    const map = try posix.mmap(null, data.len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(map);
    try testing.expectEqualStrings(data, map[0..data.len]);
}
