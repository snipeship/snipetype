//! Native stdout write helper.
//!
//! Zig 0.16 removed `std.posix.write`; the idiomatic replacement is
//! `std.Io.File.stdout().writeStreamingAll(io, bytes)`, which needs an `Io`.
//! The renderers have no `Io` handle, so this issues the raw `write(2)`
//! (libc on Darwin, direct syscall on non-libc Linux) via `std.posix.system`.

const std = @import("std");
const posix = std.posix;

pub fn writeAll(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const rc = posix.system.write(posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return;
                remaining = remaining[n..];
            },
            .INTR => continue,
            else => return,
        }
    }
}
