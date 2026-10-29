//! Unified time wrapper for native and WASM builds.
//!
//! Zig 0.16 removed `std.time.milliTimestamp`/`nanoTimestamp`; clocks are now
//! read through an `std.Io` instance (`std.Io.Clock.now(clock, io)`). Native
//! `main` passes its `Io` via `setIo`; tests and other callers that never set
//! one fall back to the std-provided single-threaded instance.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

var native_io: ?std.Io = null;

/// Install the process `Io` (from `std.process.Init.io`). No-op on WASM.
pub fn setIo(io: std.Io) void {
    native_io = io;
}

fn getIo() std.Io {
    return native_io orelse std.Io.Threaded.global_single_threaded.io();
}

/// Monotonic milliseconds (unspecified epoch). Only use for differences.
pub fn milliTimestamp() i64 {
    if (comptime is_wasm) {
        return @intFromFloat(js_now_ms());
    }
    return std.Io.Clock.awake.now(getIo()).toMilliseconds();
}

/// Wall-clock nanoseconds since the Unix epoch (used for RNG seeding).
pub fn nanoTimestamp() i128 {
    if (comptime is_wasm) {
        // Convert ms to ns
        return @as(i128, @intFromFloat(js_now_ms())) * 1_000_000;
    }
    return std.Io.Clock.real.now(getIo()).nanoseconds;
}

/// Wall-clock seconds since the Unix epoch (history timestamps).
pub fn unixSeconds() i64 {
    if (comptime is_wasm) {
        return @intFromFloat(@divFloor(js_unix_ms(), 1000));
    }
    return @intCast(@divFloor(std.Io.Clock.real.now(getIo()).nanoseconds, std.time.ns_per_s));
}

// JS imports for WASM builds
extern "env" fn js_now_ms() f64;
/// `Date.now()` (wall clock; `js_now_ms` is `performance.now()`).
extern "env" fn js_unix_ms() f64;
