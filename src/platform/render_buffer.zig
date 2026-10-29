//! Buffered terminal output helper.
//! Platform-specific flush is selected at compile time.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const RenderBuffer = if (is_wasm) WasmRenderBuffer else NativeRenderBuffer;

/// WASM RenderBuffer - flushes to JavaScript
const WasmRenderBuffer = struct {
    extern "env" fn js_write(ptr: [*]const u8, len: usize) void;

    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WasmRenderBuffer {
        return .{ .data = std.ArrayList(u8).empty, .allocator = allocator };
    }

    pub fn deinit(self: *WasmRenderBuffer) void {
        self.data.deinit(self.allocator);
    }

    pub fn clear(self: *WasmRenderBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn write(self: *WasmRenderBuffer, s: []const u8) void {
        self.data.appendSlice(self.allocator, s) catch {};
    }

    pub fn writeByte(self: *WasmRenderBuffer, b: u8) void {
        self.data.append(self.allocator, b) catch {};
    }

    pub fn print(self: *WasmRenderBuffer, comptime fmt: []const u8, args: anytype) void {
        self.data.print(self.allocator, fmt, args) catch {};
    }

    pub fn moveTo(self: *WasmRenderBuffer, x: usize, y: usize) void {
        self.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    pub fn flush(self: *WasmRenderBuffer) void {
        if (self.data.items.len == 0) return;
        js_write(self.data.items.ptr, self.data.items.len);
    }
};

/// Native RenderBuffer - flushes to stdout
const NativeRenderBuffer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NativeRenderBuffer {
        return .{ .data = std.ArrayList(u8).empty, .allocator = allocator };
    }

    pub fn deinit(self: *NativeRenderBuffer) void {
        self.data.deinit(self.allocator);
    }

    pub fn clear(self: *NativeRenderBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn write(self: *NativeRenderBuffer, s: []const u8) void {
        self.data.appendSlice(self.allocator, s) catch {};
    }

    pub fn writeByte(self: *NativeRenderBuffer, b: u8) void {
        self.data.append(self.allocator, b) catch {};
    }

    pub fn print(self: *NativeRenderBuffer, comptime fmt: []const u8, args: anytype) void {
        self.data.print(self.allocator, fmt, args) catch {};
    }

    pub fn moveTo(self: *NativeRenderBuffer, x: usize, y: usize) void {
        self.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    pub fn flush(self: *NativeRenderBuffer) void {
        @import("stdout.zig").writeAll(self.data.items);
    }
};
