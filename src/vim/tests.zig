const std = @import("std");

const Buffer = @import("buffer.zig").Buffer;
const VimEditor = @import("editor.zig").VimEditor;

test "buffer basic" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    buf.insertChar(.{ .row = 0, .col = 0 }, 'a');
    try std.testing.expectEqualStrings("a", buf.getLine(0));
}

test "vim editor" {
    const allocator = std.testing.allocator;
    var vim = VimEditor.init(allocator);
    defer vim.deinit();

    vim.handleKey('i'); // Enter insert
    vim.handleKey('h');
    vim.handleKey('e');
    vim.handleKey('l');
    vim.handleKey('l');
    vim.handleKey('o');
    try std.testing.expectEqualStrings("hello", vim.buffer.getLine(0));
}

test "yank operator does not delete" {
    const allocator = std.testing.allocator;
    var vim = VimEditor.init(allocator);
    defer vim.deinit();

    vim.handleKey('i');
    for ("hello world") |c| vim.handleKey(c);
    vim.handleKey(27);

    vim.handleKey('0');
    vim.handleKey('y');
    vim.handleKey('w');

    try std.testing.expectEqualStrings("hello world", vim.buffer.getLine(0));
    try std.testing.expect(!vim.register.isEmpty());
}

test "gg and dgg" {
    const allocator = std.testing.allocator;
    var vim = VimEditor.init(allocator);
    defer vim.deinit();

    vim.handleKey('i');
    vim.handleKey('a');
    vim.handleKey('\n');
    vim.handleKey('b');
    vim.handleKey('\n');
    vim.handleKey('c');
    vim.handleKey(27);

    try std.testing.expectEqual(@as(usize, 2), vim.cursor.row);
    vim.handleKey('g');
    vim.handleKey('g');
    try std.testing.expectEqual(@as(usize, 0), vim.cursor.row);

    vim.cursor.row = 2;
    vim.cursor.col = 0;
    vim.handleKey('d');
    vim.handleKey('g');
    vim.handleKey('g');
    try std.testing.expectEqual(@as(usize, 1), vim.buffer.lineCount());
    try std.testing.expectEqualStrings("", vim.buffer.getLine(0));
}

test "paste p/P charwise and linewise" {
    const allocator = std.testing.allocator;

    {
        var vim = VimEditor.init(allocator);
        defer vim.deinit();

        vim.handleKey('i');
        vim.handleKey('a');
        vim.handleKey(27);

        try vim.register.set("b", false);

        vim.handleKey('p');
        try std.testing.expectEqualStrings("ab", vim.buffer.getLine(0));
        try std.testing.expectEqual(@as(usize, 1), vim.cursor.col);
    }

    {
        var vim = VimEditor.init(allocator);
        defer vim.deinit();

        vim.handleKey('i');
        vim.handleKey('a');
        vim.handleKey(27);

        try vim.register.set("b", false);

        vim.handleKey('P');
        try std.testing.expectEqualStrings("ba", vim.buffer.getLine(0));
        try std.testing.expectEqual(@as(usize, 0), vim.cursor.col);
    }

    {
        var vim = VimEditor.init(allocator);
        defer vim.deinit();

        vim.handleKey('i');
        vim.handleKey('a');
        vim.handleKey(27);

        try vim.register.set("x\ny", true);

        vim.handleKey('p');
        try std.testing.expectEqual(@as(usize, 3), vim.buffer.lineCount());
        try std.testing.expectEqualStrings("a", vim.buffer.getLine(0));
        try std.testing.expectEqualStrings("x", vim.buffer.getLine(1));
        try std.testing.expectEqualStrings("y", vim.buffer.getLine(2));
        try std.testing.expectEqual(@as(usize, 1), vim.cursor.row);
        try std.testing.expectEqual(@as(usize, 0), vim.cursor.col);
    }
}
