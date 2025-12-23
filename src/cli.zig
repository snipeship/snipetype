const std = @import("std");
const one = @import("one");

pub const HELP =
    \\ONE - Typing Speed Test with Vim Editor
    \\
    \\USAGE: one [OPTIONS]
    \\
    \\OPTIONS:
    \\  -m, --mode <MODE>   words | sentences | code | vim
    \\  -w, --words <N>     Number of words/items (default: 10)
    \\  -t, --time <SEC>    Time limit in seconds
    \\  -l, --lang <LANG>   zig | rust | go | ts | python | c | mixed
    \\  -h, --help          Show help
    \\
    \\VIM MODE KEYS:
    \\  Motion:     h j k l w b e 0 $ ^ gg G
    \\  Insert:     i I a A o O s S
    \\  Visual:     v V (then d/c/y to operate)
    \\  Operators:  d dd D c cc C y yy x X
    \\  Other:      p P J r
    \\
    \\EXAMPLES:
    \\  one                      10 random words
    \\  one -m sentences         Coherent sentences
    \\  one -m code -l rust      Rust code snippets
    \\  one -m vim               Multi-line vim editing
    \\  one -m vim -l zig        Zig code in vim mode
    \\  one -t 60                60 second challenge
    \\
;

pub fn parseArgs(allocator: std.mem.Allocator) !one.Config {
    var cfg = one.Config{};
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return error.HelpRequested;
        } else if ((std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--mode")) and i + 1 < args.len) {
            i += 1;
            cfg.mode = one.Mode.fromString(args[i]) orelse return error.InvalidArg;
        } else if ((std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--words")) and i + 1 < args.len) {
            i += 1;
            cfg.word_count = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
            cfg.word_count = @max(1, @min(100, cfg.word_count));
        } else if ((std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--time")) and i + 1 < args.len) {
            i += 1;
            cfg.time_limit = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArg;
        } else if ((std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--lang")) and i + 1 < args.len) {
            i += 1;
            cfg.lang = one.Lang.fromString(args[i]) orelse return error.InvalidArg;
        }
    }
    return cfg;
}
