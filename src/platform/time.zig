//! Unified time wrapper for native and WASM builds.

const std = @import("std");
const builtin = @import("builtin");

pub fn milliTimestamp() i64 {
    if (comptime builtin.cpu.arch == .wasm32) {
        return @intFromFloat(js_now_ms());
    }
    return std.time.milliTimestamp();
}

pub fn nanoTimestamp() i128 {
    if (comptime builtin.cpu.arch == .wasm32) {
        // Convert ms to ns
        return @as(i128, @intFromFloat(js_now_ms())) * 1_000_000;
    }
    return std.time.nanoTimestamp();
}

// JS import for WASM builds
extern "env" fn js_now_ms() f64;
