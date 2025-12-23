const std = @import("std");
const posix = std.posix;

pub const Terminal = struct {
    original: posix.termios,
    width: usize,
    height: usize,

    pub fn init() !Terminal {
        const current = try posix.tcgetattr(posix.STDIN_FILENO);
        var ws: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        return .{
            .original = current,
            .width = if (ws.col > 0) ws.col else 80,
            .height = if (ws.row > 0) ws.row else 24,
        };
    }

    pub fn updateSize(self: *Terminal) void {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (ws.col > 0) self.width = @intCast(ws.col);
        if (ws.row > 0) self.height = @intCast(ws.row);
    }

    pub fn enableRawMode(self: *Terminal) !void {
        var raw = self.original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    }

    pub fn restore(self: *Terminal) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

pub fn readKey() ?u8 {
    var buf: [1]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;
    return buf[0];
}
