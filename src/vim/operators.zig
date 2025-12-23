const std = @import("std");

const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const VimMode = @import("mode.zig").VimMode;
const Operator = @import("operator.zig").Operator;
const Register = @import("register.zig").Register;
const motions = @import("motions.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    buffer: *Buffer,
    cursor: *Cursor,
    mode: *VimMode,
    visual_start: *Cursor,
    register: *Register,
    status_msg: *([]const u8),
};

pub fn opLineRange(ctx: *Context, op: Operator, from_row: usize, to_row: usize) void {
    const from = @min(from_row, ctx.buffer.lineCount() -| 1);
    const to = @min(to_row, ctx.buffer.lineCount() -| 1);

    var content = std.ArrayList(u8){};
    defer content.deinit(ctx.allocator);
    for (from..to + 1) |row| {
        const line = ctx.buffer.getLine(row);
        content.appendSlice(ctx.allocator, line) catch {
            ctx.status_msg.* = "out of memory";
            return;
        };
        if (row < to) content.append(ctx.allocator, '\n') catch {
            ctx.status_msg.* = "out of memory";
            return;
        };
    }
    ctx.register.set(content.items, true) catch {
        ctx.status_msg.* = "out of memory";
        return;
    };

    if (op == .delete or op == .change) {
        // Delete lines from bottom up
        var row = to;
        while (row >= from) : (row -|= 1) {
            ctx.buffer.deleteLine(row);
            if (row == 0) break;
        }
        ctx.cursor.row = from;
        ctx.cursor.col = 0;
        motions.clampCursor(ctx.buffer, ctx.cursor, ctx.mode.*);
        if (op == .change) {
            if (ctx.buffer.lineCount() == 0 or (ctx.cursor.row == 0 and ctx.buffer.lineLen(0) == 0)) {
                // Line was cleared
            } else {
                ctx.buffer.insertLine(ctx.cursor.row, "");
            }
            ctx.mode.* = .insert;
        }
    }
}

pub fn opCharRange(ctx: *Context, op: Operator, start: Cursor, end: Cursor) void {
    var from = start;
    var to = end;
    if (!Cursor.lessThan(from, to)) {
        const tmp = from;
        from = to;
        to = tmp;
    }

    // Single line for now
    if (from.row == to.row) {
        const content = switch (op) {
            .delete, .change => ctx.buffer.deleteRange(from, .{ .row = to.row, .col = to.col + 1 }),
            .yank => ctx.buffer.copyRange(from, .{ .row = to.row, .col = to.col + 1 }),
            .none => return,
        } catch {
            ctx.status_msg.* = "out of memory";
            return;
        };
        defer ctx.allocator.free(content);
        ctx.register.set(content, false) catch {
            ctx.status_msg.* = "out of memory";
            return;
        };
        ctx.cursor.* = from;
        motions.clampCursor(ctx.buffer, ctx.cursor, ctx.mode.*);
        if (op == .change) ctx.mode.* = .insert;
    }
}

pub fn deleteVisualSelection(ctx: *Context) void {
    if (ctx.mode.* == .visual_line) {
        const from = @min(ctx.visual_start.row, ctx.cursor.row);
        const to = @max(ctx.visual_start.row, ctx.cursor.row);
        opLineRange(ctx, .delete, from, to);
        return;
    }

    var from = ctx.visual_start.*;
    var to = ctx.cursor.*;
    if (!Cursor.lessThan(from, to)) {
        const tmp = from;
        from = to;
        to = tmp;
    }
    if (from.row != to.row) return;

    const content = ctx.buffer.deleteRange(from, .{ .row = to.row, .col = to.col + 1 }) catch {
        ctx.status_msg.* = "out of memory";
        return;
    };
    defer ctx.allocator.free(content);
    ctx.register.set(content, false) catch {
        ctx.status_msg.* = "out of memory";
        return;
    };

    ctx.cursor.* = from;
    motions.clampCursor(ctx.buffer, ctx.cursor, ctx.mode.*);
}

pub fn yankVisualSelection(ctx: *Context) void {
    if (ctx.mode.* == .visual_line) {
        const from = @min(ctx.visual_start.row, ctx.cursor.row);
        const to = @max(ctx.visual_start.row, ctx.cursor.row);

        var content = std.ArrayList(u8){};
        defer content.deinit(ctx.allocator);
        for (from..to + 1) |row| {
            const line = ctx.buffer.getLine(row);
            content.appendSlice(ctx.allocator, line) catch {
                ctx.status_msg.* = "out of memory";
                return;
            };
            if (row < to) content.append(ctx.allocator, '\n') catch {
                ctx.status_msg.* = "out of memory";
                return;
            };
        }
        ctx.register.set(content.items, true) catch {
            ctx.status_msg.* = "out of memory";
            return;
        };
        ctx.cursor.* = ctx.visual_start.*;
        return;
    }

    var from = ctx.visual_start.*;
    var to = ctx.cursor.*;
    if (!Cursor.lessThan(from, to)) {
        const tmp = from;
        from = to;
        to = tmp;
    }

    if (from.row != to.row) return;
    const line = ctx.buffer.getLine(from.row);
    const start = @min(from.col, line.len);
    const end = @min(to.col + 1, line.len);
    ctx.register.set(line[start..end], false) catch {
        ctx.status_msg.* = "out of memory";
        return;
    };

    ctx.cursor.* = ctx.visual_start.*;
}
