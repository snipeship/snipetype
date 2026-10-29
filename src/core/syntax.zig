//! A small per-language syntax tokenizer for colouring untyped code:
//! keywords, strings, comments, numbers, type names and punctuation. One
//! `Kind` per byte, line by line, with block comments and multi-line
//! strings carried in `State`. Pure and allocation-free.

const std = @import("std");

const types = @import("types.zig");
const Lang = types.Lang;

pub const Kind = enum(u3) { plain, keyword, string, comment, number, type_name, punct };

/// Carried from one line to the next.
pub const State = struct {
    /// Inside `/* */` (or Lua `--[[ ]]`).
    block_comment: bool = false,
    /// Inside a multi-line string: '"' / '\'' for Python triple quotes,
    /// '[' for a Lua long string; 0 otherwise.
    string_delim: u8 = 0,
};

const zig_kw = [_][]const u8{
    "addrspace", "align",    "allowzero",   "and",       "anyframe", "anytype",     "asm",     "break",    "callconv",
    "catch",     "comptime", "const",       "continue",  "defer",    "else",        "enum",    "errdefer", "error",
    "export",    "extern",   "fn",          "for",       "if",       "inline",      "noalias", "noinline", "nosuspend",
    "opaque",    "or",       "orelse",      "packed",    "pub",      "resume",      "return",  "struct",   "suspend",
    "switch",    "test",     "threadlocal", "try",       "union",    "unreachable", "var",     "volatile", "while",
    "true",      "false",    "null",        "undefined", "void",     "bool",        "u8",      "u16",      "u32",
    "u64",       "usize",    "i8",          "i16",       "i32",      "i64",         "isize",   "f32",      "f64",
    "type",      "noreturn", "anyerror",
};
const rust_kw = [_][]const u8{
    "as",    "async",  "await", "break",  "const",  "continue", "crate", "dyn",   "else", "enum",   "extern", "false",
    "fn",    "for",    "if",    "impl",   "in",     "let",      "loop",  "match", "mod",  "move",   "mut",    "pub",
    "ref",   "return", "self",  "static", "struct", "super",    "trait", "true",  "type", "unsafe", "use",    "where",
    "while", "i8",     "i16",   "i32",    "i64",    "u8",       "u16",   "u32",   "u64",  "usize",  "isize",  "f32",
    "f64",   "bool",   "char",  "str",
};
const go_kw = [_][]const u8{
    "break",  "case",   "chan",   "const", "continue", "default",   "defer", "else",    "fallthrough", "for",
    "func",   "go",     "goto",   "if",    "import",   "interface", "map",   "package", "range",       "return",
    "select", "struct", "switch", "type",  "var",      "nil",       "true",  "false",   "int",         "int64",
    "string", "bool",   "byte",   "error", "float64",  "rune",      "uint",  "make",    "len",         "append",
};
const ts_kw = [_][]const u8{
    "abstract", "as",       "async",   "await",      "break",  "case",     "catch",      "class",     "const",   "continue",
    "default",  "delete",   "do",      "else",       "enum",   "export",   "extends",    "false",     "finally", "for",
    "from",     "function", "if",      "implements", "import", "in",       "instanceof", "interface", "let",     "new",
    "null",     "of",       "private", "protected",  "public", "readonly", "return",     "static",    "super",   "switch",
    "this",     "throw",    "true",    "try",        "type",   "typeof",   "undefined",  "var",       "void",    "while",
    "yield",    "string",   "number",  "boolean",    "any",    "unknown",  "never",
};
const python_kw = [_][]const u8{
    "False", "None",  "True",   "and",      "as",     "assert",  "async", "await", "break",  "class", "continue",
    "def",   "del",   "elif",   "else",     "except", "finally", "for",   "from",  "global", "if",    "import",
    "in",    "is",    "lambda", "nonlocal", "not",    "or",      "pass",  "raise", "return", "try",   "while",
    "with",  "yield", "self",
};
const c_kw = [_][]const u8{
    "auto",   "break",    "case",   "char",   "const",  "continue", "default", "do",      "double", "else",
    "enum",   "extern",   "float",  "for",    "goto",   "if",       "inline",  "int",     "long",   "register",
    "return", "short",    "signed", "sizeof", "static", "struct",   "switch",  "typedef", "union",  "unsigned",
    "void",   "volatile", "while",  "NULL",   "size_t", "bool",     "true",    "false",
};
const bash_kw = [_][]const u8{
    "if",   "then", "else",  "elif",     "fi",     "for",   "while",    "until",    "do",      "done",
    "case", "esac", "in",    "function", "return", "local", "export",   "readonly", "declare", "echo",
    "exit", "set",  "shift", "source",   "unset",  "break", "continue", "printf",   "read",    "test",
};
const lua_kw = [_][]const u8{
    "and",  "break", "do",  "else", "elseif", "end",    "false",  "for",  "function", "goto",  "if",
    "in",   "local", "nil", "not",  "or",     "repeat", "return", "then", "true",     "until", "while",
    "self",
};
const sql_kw = [_][]const u8{
    "select",     "from",     "where",     "insert",     "into",   "values",  "update",    "set",       "delete", "create",
    "table",      "drop",     "alter",     "add",        "index",  "on",      "join",      "left",      "right",  "inner",
    "outer",      "group",    "by",        "order",      "having", "limit",   "offset",    "as",        "and",    "or",
    "not",        "null",     "is",        "in",         "like",   "between", "distinct",  "count",     "sum",    "avg",
    "min",        "max",      "case",      "when",       "then",   "else",    "end",       "primary",   "key",    "foreign",
    "references", "default",  "unique",    "with",       "union",  "all",     "exists",    "integer",   "int",    "text",
    "varchar",    "boolean",  "timestamp", "serial",     "desc",   "asc",     "returning", "begin",     "commit", "true",
    "false",      "coalesce", "view",      "constraint", "check",  "cascade", "over",      "partition",
};
const java_kw = [_][]const u8{
    "abstract",     "boolean", "break",      "byte",   "case",       "catch",   "char",      "class",   "continue",
    "default",      "do",      "double",     "else",   "enum",       "extends", "final",     "finally", "float",
    "for",          "if",      "implements", "import", "instanceof", "int",     "interface", "long",    "new",
    "package",      "private", "protected",  "public", "return",     "short",   "static",    "super",   "switch",
    "synchronized", "this",    "throw",      "throws", "try",        "void",    "volatile",  "while",   "var",
    "true",         "false",   "null",       "record",
};
const yaml_kw = [_][]const u8{ "true", "false", "null", "yes", "no", "on", "off" };

fn keywords(lang: Lang) []const []const u8 {
    return switch (lang) {
        .zig => &zig_kw,
        .rust => &rust_kw,
        .go => &go_kw,
        .typescript => &ts_kw,
        .python => &python_kw,
        .c, .mixed => &c_kw,
        .bash => &bash_kw,
        .lua => &lua_kw,
        .sql => &sql_kw,
        .java => &java_kw,
        .yaml => &yaml_kw,
    };
}

fn isKeyword(lang: Lang, word: []const u8) bool {
    for (keywords(lang)) |k| {
        if (lang == .sql) {
            if (std.ascii.eqlIgnoreCase(k, word)) return true;
        } else if (std.mem.eql(u8, k, word)) return true;
    }
    return false;
}

/// Languages where a Capitalized identifier is (almost always) a type.
fn capsAreTypes(lang: Lang) bool {
    return switch (lang) {
        .zig, .rust, .go, .typescript, .java, .c, .mixed => true,
        else => false,
    };
}

fn lineComment(lang: Lang) []const u8 {
    return switch (lang) {
        .python, .bash, .yaml => "#",
        .lua, .sql => "--",
        else => "//",
    };
}

fn hasBlockComments(lang: Lang) bool {
    return switch (lang) {
        .zig, .python, .bash, .yaml => false,
        else => true,
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isPunct(c: u8) bool {
    return std.mem.indexOfScalar(u8, "(){}[]<>=+-*/%!&|^~?:;,.@$#", c) != null;
}

fn fill(out: []Kind, from: usize, to: usize, k: Kind) void {
    @memset(out[from..to], k);
}

/// One Kind per byte of `line` into out[0..line.len] (out.len >= line.len).
/// `.mixed` is highlighted as generic C-like code.
pub fn highlightLine(lang: Lang, line: []const u8, state: *State, out: []Kind) void {
    std.debug.assert(out.len >= line.len);
    fill(out, 0, line.len, .plain);
    if (lang == .yaml) return yamlLine(line, state, out);
    const lc = lineComment(lang);
    var i: usize = 0;
    while (i < line.len) {
        // Carried constructs first.
        if (state.block_comment) {
            const close = if (lang == .lua) "]]" else "*/";
            const found = std.mem.indexOfPos(u8, line, i, close);
            const end = if (found) |e| e + close.len else line.len;
            fill(out, i, end, .comment);
            if (found != null) state.block_comment = false;
            i = end;
            continue;
        }
        if (state.string_delim != 0) {
            const close: []const u8 = switch (state.string_delim) {
                '"' => "\"\"\"",
                '\'' => "'''",
                else => "]]",
            };
            const found = std.mem.indexOfPos(u8, line, i, close);
            const end = if (found) |e| e + close.len else line.len;
            fill(out, i, end, .string);
            if (found != null) state.string_delim = 0;
            i = end;
            continue;
        }
        const c = line[i];
        const rest = line[i..];
        // Comments.
        if (lang == .lua and std.mem.startsWith(u8, rest, "--[[")) {
            state.block_comment = true;
            fill(out, i, i + 4, .comment);
            i += 4;
            continue;
        }
        if (std.mem.startsWith(u8, rest, lc) and (lang != .bash or i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            fill(out, i, line.len, .comment);
            return;
        }
        if (hasBlockComments(lang) and lang != .lua and std.mem.startsWith(u8, rest, "/*")) {
            state.block_comment = true;
            fill(out, i, i + 2, .comment);
            i += 2;
            continue;
        }
        // Multi-line strings.
        if (lang == .python and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {
            fill(out, i, i + 3, .string);
            state.string_delim = c;
            i += 3;
            continue;
        }
        if (lang == .lua and std.mem.startsWith(u8, rest, "[[")) {
            fill(out, i, i + 2, .string);
            state.string_delim = '[';
            i += 2;
            continue;
        }
        // Strings and char literals.
        if (c == '"' or c == '`' or (c == '\'' and quoteIsString(lang, line, i))) {
            const end = stringEnd(line, i, lang);
            fill(out, i, end, .string);
            i = end;
            continue;
        }
        // Numbers.
        if (std.ascii.isDigit(c) and (i == 0 or !isIdent(line[i - 1]))) {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                const d = line[j];
                if (d == '.' and j + 1 < line.len and std.ascii.isDigit(line[j + 1])) continue;
                if (!isIdent(d)) break;
            }
            fill(out, i, j, .number);
            i = j;
            continue;
        }
        // Identifiers, keywords, type names (and Zig builtins).
        if (isIdentStart(c) or (lang == .zig and c == '@' and i + 1 < line.len and isIdentStart(line[i + 1]))) {
            var j = i + 1;
            while (j < line.len and isIdent(line[j])) j += 1;
            const word = line[i..j];
            const kind: Kind = if (c == '@')
                .keyword
            else if (isKeyword(lang, word))
                .keyword
            else if (capsAreTypes(lang) and std.ascii.isUpper(c) and !allCaps(word))
                .type_name
            else
                .plain;
            fill(out, i, j, kind);
            i = j;
            continue;
        }
        if (isPunct(c)) out[i] = .punct;
        i += 1;
    }
}

/// ALL_CAPS (constants, macros) are not type names.
fn allCaps(word: []const u8) bool {
    if (word.len < 2) return false;
    for (word) |c| if (std.ascii.isLower(c)) return false;
    return true;
}

/// Rust/Zig/C/Java `'` starts a char literal only when it closes within a
/// few bytes (Rust lifetimes like `'a` don't); elsewhere it is a string.
fn quoteIsString(lang: Lang, line: []const u8, i: usize) bool {
    return switch (lang) {
        .rust, .zig, .c, .java, .go => blk: {
            if (i + 2 < line.len and line[i + 1] != '\\' and line[i + 2] == '\'') break :blk true;
            if (i + 3 < line.len and line[i + 1] == '\\' and line[i + 3] == '\'') break :blk true;
            if (i + 1 < line.len and line[i + 1] == '\\') break :blk std.mem.indexOfScalarPos(u8, line, i + 2, '\'') != null;
            break :blk false;
        },
        // Bash/Lua/SQL/Python/TS: an apostrophe inside a word ("don't" in
        // a comment is already handled) is still a quote.
        else => true,
    };
}

/// End (exclusive) of the string starting at `i`; unterminated strings run
/// to the end of the line.
fn stringEnd(line: []const u8, i: usize, lang: Lang) usize {
    const q = line[i];
    // SQL and bash single quotes have no escapes.
    const escapes = !(q == '\'' and (lang == .sql or lang == .bash));
    var j = i + 1;
    while (j < line.len) : (j += 1) {
        if (escapes and line[j] == '\\') {
            j += 1;
            continue;
        }
        if (line[j] == q) return j + 1;
    }
    return line.len;
}

/// YAML: `key:` → keyword, scalars after the colon → string (numbers and
/// booleans as such), `#` comments, `-`/`:` punctuation.
fn yamlLine(line: []const u8, state: *State, out: []Kind) void {
    _ = state;
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    // List item markers.
    while (i + 1 < line.len and line[i] == '-' and line[i + 1] == ' ') {
        out[i] = .punct;
        i += 2;
        while (i < line.len and line[i] == ' ') i += 1;
    }
    if (i < line.len and line[i] == '#') return fill(out, i, line.len, .comment);
    // A key: everything up to ": " (or a trailing ':').
    var value_start = i;
    var k = i;
    while (k < line.len) : (k += 1) {
        if (line[k] == '"' or line[k] == '\'' or line[k] == '#') break;
        if (line[k] == ':' and (k + 1 == line.len or line[k + 1] == ' ')) {
            fill(out, i, k, .keyword);
            out[k] = .punct;
            value_start = k + 1;
            break;
        }
    }
    var j = value_start;
    while (j < line.len and line[j] == ' ') j += 1;
    if (j >= line.len) return;
    // The value, up to a ` #` comment.
    var end = line.len;
    var p = j;
    var quote: u8 = 0;
    while (p < line.len) : (p += 1) {
        const ch = line[p];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '#' and p > 0 and line[p - 1] == ' ') {
            end = p;
            fill(out, p, line.len, .comment);
            break;
        }
    }
    const value = std.mem.trimEnd(u8, line[j..end], " ");
    const v_end = j + value.len;
    if (value.len == 0) return;
    const kind: Kind = if (isNumber(value))
        .number
    else if (isKeyword(.yaml, value))
        .keyword
    else if (value[0] == '|' or value[0] == '>' or value[0] == '&' or value[0] == '*' or value[0] == '[' or value[0] == '{')
        .punct
    else
        .string;
    if (kind == .punct) {
        // Flow collections and block scalars: mark brackets only.
        for (j..v_end) |q| {
            if (isPunct(line[q])) out[q] = .punct;
        }
        return;
    }
    fill(out, j, v_end, kind);
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var digits = false;
    for (s, 0..) |c, i| {
        if (std.ascii.isDigit(c)) {
            digits = true;
        } else if (!(c == '.' or c == '_' or (i == 0 and c == '-'))) return false;
    }
    return digits;
}

/// Best guess for unlabeled code (drills): distinctive markers per
/// language; .mixed when nothing stands out.
pub fn guessLang(text: []const u8) Lang {
    return guess(text, false);
}

/// guessLang for the user's own text, which is usually prose: a language
/// needs two marker hits, and YAML needs every line to be a key, a list
/// item or a comment, so "await" or "Note: …" in a paragraph stays plain.
pub fn guessCustomLang(text: []const u8) Lang {
    return guess(text, true);
}

fn guess(text: []const u8, strict: bool) Lang {
    const Marker = struct { lang: Lang, s: []const u8 };
    const markers = [_]Marker{
        .{ .lang = .zig, .s = "pub fn " },           .{ .lang = .zig, .s = "@import(" },       .{ .lang = .zig, .s = "!void" },
        .{ .lang = .zig, .s = "comptime" },          .{ .lang = .zig, .s = "errdefer" },       .{ .lang = .zig, .s = "orelse" },
        .{ .lang = .zig, .s = "[]const u8" },        .{ .lang = .zig, .s = ") |" },            .{ .lang = .rust, .s = "let mut " },
        .{ .lang = .rust, .s = "impl " },            .{ .lang = .rust, .s = "&self" },         .{ .lang = .rust, .s = "println!" },
        .{ .lang = .rust, .s = "Vec<" },             .{ .lang = .rust, .s = "::new(" },        .{ .lang = .rust, .s = "-> Result<" },
        .{ .lang = .go, .s = "func " },              .{ .lang = .go, .s = " := " },            .{ .lang = .go, .s = "package " },
        .{ .lang = .go, .s = "err != nil" },         .{ .lang = .go, .s = "fmt." },            .{ .lang = .typescript, .s = " => " },
        .{ .lang = .typescript, .s = "interface " }, .{ .lang = .typescript, .s = "export " }, .{ .lang = .typescript, .s = ": string" },
        .{ .lang = .typescript, .s = "console." },   .{ .lang = .typescript, .s = "await " },  .{ .lang = .python, .s = "def " },
        .{ .lang = .python, .s = "self." },          .{ .lang = .python, .s = "elif " },       .{ .lang = .python, .s = "None" },
        .{ .lang = .python, .s = "):\n" },           .{ .lang = .c, .s = "#include" },         .{ .lang = .c, .s = "printf(" },
        .{ .lang = .c, .s = "NULL" },                .{ .lang = .c, .s = "char *" },           .{ .lang = .c, .s = "malloc(" },
        .{ .lang = .bash, .s = "#!/" },              .{ .lang = .bash, .s = "echo " },         .{ .lang = .bash, .s = "; then" },
        .{ .lang = .bash, .s = "; do" },             .{ .lang = .bash, .s = "fi\n" },          .{ .lang = .bash, .s = "${" },
        .{ .lang = .lua, .s = "local " },            .{ .lang = .lua, .s = " then\n" },        .{ .lang = .lua, .s = "~=" },
        .{ .lang = .lua, .s = "elseif " },           .{ .lang = .lua, .s = "end\n" },          .{ .lang = .sql, .s = "SELECT " },
        .{ .lang = .sql, .s = "FROM " },             .{ .lang = .sql, .s = "WHERE " },         .{ .lang = .sql, .s = "INSERT INTO" },
        .{ .lang = .sql, .s = "CREATE TABLE" },      .{ .lang = .java, .s = "public class" },  .{ .lang = .java, .s = "System.out" },
        .{ .lang = .java, .s = "private " },         .{ .lang = .java, .s = "@Override" },     .{ .lang = .java, .s = "static void" },
    };
    var score: [std.meta.tags(Lang).len]usize = @splat(0);
    for (markers) |m| score[@backingInt(m.lang)] += std.mem.count(u8, text, m.s);
    var best: Lang = .mixed;
    var best_n: usize = 0;
    var tie = false;
    for (score, 0..) |n, i| {
        if (n > best_n) {
            best = @fromBackingInt(@intCast(i));
            best_n = n;
            tie = false;
        } else if (n == best_n and n > 0) tie = true;
    }
    if (best_n < 2 or tie) {
        if (best_n == 0 or tie) return yamlish(text, strict);
        if (strict) return .mixed;
    }
    return best;
}

/// Mostly `key: value` lines and no code punctuation → YAML.
fn yamlish(text: []const u8, strict: bool) Lang {
    var keys: usize = 0;
    var lines: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        lines += 1;
        if (std.mem.indexOfAny(u8, line, ";{}()") != null) return .mixed;
        const t = std.mem.trimStart(u8, line, " -");
        if (std.mem.indexOf(u8, t, ": ") != null or std.mem.endsWith(u8, t, ":")) keys += 1;
        if (strict and !strictYamlLine(line)) return .mixed;
    }
    // Strict: every line already passed, so one key is enough.
    if (strict) return if (lines >= 2 and keys >= 1) .yaml else .mixed;
    return if (lines >= 2 and keys * 2 > lines) .yaml else .mixed;
}

/// A strict YAML line: blank, a `# comment`, a `- ` item, or `key:` /
/// `key: value` with no spaces in the key ("Note, however: x" is prose).
fn strictYamlLine(line: []const u8) bool {
    var t = std.mem.trimStart(u8, line, " ");
    if (t.len == 0 or t[0] == '#') return true;
    if (std.mem.startsWith(u8, t, "- ")) return true;
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return false;
    if (colon == 0) return false;
    for (t[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '"')) return false;
    t = t[colon + 1 ..];
    return t.len == 0 or t[0] == ' ';
}

// ---- tests ----

const testing = std.testing;

/// Kinds of `line` as a string of one letter per byte:
/// . plain, k keyword, s string, c comment, n number, t type, p punct.
fn kinds(lang: Lang, line: []const u8, state: *State) [128]u8 {
    var out: [128]Kind = undefined;
    highlightLine(lang, line, state, &out);
    var s: [128]u8 = @splat(0);
    for (out[0..line.len], 0..) |k, i| s[i] = ".kscntp"[@backingInt(k)];
    return s;
}

fn expectKinds(lang: Lang, line: []const u8, state: *State, want: []const u8) !void {
    const got = kinds(lang, line, state);
    try testing.expectEqualStrings(want, got[0..line.len]);
}

test "zig: keywords, builtins, strings, numbers, types, comments" {
    var st: State = .{};
    try expectKinds(.zig, "const x = @import(\"std\");", &st, "kkkkk...p.kkkkkkkpssssspp");
    try expectKinds(.zig, "var n: u32 = 0x1F; // hi", &st, "kkk..p.kkk.p.nnnnp.ccccc");
    try expectKinds(.zig, "fn f(p: Point) void {", &st, "kk..p.p.tttttp.kkkk.p");
    try expectKinds(.zig, "c == 'a' or c == '\\n'", &st, "..pp.sss.kk...pp.ssss");
    try expectKinds(.zig, "0..9", &st, "nppn");
}

test "rust: lifetimes are not char literals; block comments carry" {
    var st: State = .{};
    try expectKinds(.rust, "fn f<'a>(s: &'a str)", &st, "kk..p..pp.p.p...kkkp");
    try expectKinds(.rust, "let c = 'x'; /* start", &st, "kkk...p.sssp.cccccccc");
    try testing.expect(st.block_comment);
    try expectKinds(.rust, "still */ Vec::new()", &st, "cccccccc.tttpp...pp");
    try testing.expect(!st.block_comment);
}

test "python: triple-quoted strings span lines; # comments" {
    var st: State = .{};
    try expectKinds(.python, "def f(self):  # doc", &st, "kkk..pkkkkpp..ccccc");
    try expectKinds(.python, "    s = \"\"\"multi", &st, "......p.ssssssss");
    try testing.expectEqual(@as(u8, '"'), st.string_delim);
    try expectKinds(.python, "line\"\"\" + 'x'", &st, "sssssss.p.sss");
    try testing.expectEqual(@as(u8, 0), st.string_delim);
    // Capitalized names are not types in Python.
    try expectKinds(.python, "Point(1.5)", &st, ".....pnnnp");
}

test "c, go, ts, java" {
    var st: State = .{};
    try expectKinds(.c, "int *p = NULL; /* x */ y", &st, "kkk.p..p.kkkkp.ccccccc..");
    try testing.expect(!st.block_comment);
    try expectKinds(.go, "if err != nil {", &st, "kk.....pp.kkk.p");
    try expectKinds(.typescript, "const s = `hi ${x}`;", &st, "kkkkk...p.sssssssssp");
    try expectKinds(.java, "public static String name;", &st, "kkkkkk.kkkkkk.tttttt.....p");
}

test "bash, lua, sql" {
    var st: State = .{};
    try expectKinds(.bash, "echo \"$#\" # done", &st, "kkkk.ssss.cccccc");
    try expectKinds(.bash, "x=${#arr}", &st, ".pppp...p");
    try expectKinds(.lua, "local t = {} -- note", &st, "kkkkk...p.pp.ccccccc");
    try expectKinds(.lua, "x = 1 --[[ block", &st, "..p.n.cccccccccc");
    try testing.expect(st.block_comment);
    try expectKinds(.lua, "end ]] y ~= nil", &st, "cccccc...pp.kkk");
    try expectKinds(.sql, "select Name FROM t WHERE a = 'it''s';", &st, "kkkkkk......kkkk...kkkkk...p.sssssssp");
    try expectKinds(.sql, "-- all rows", &st, "ccccccccccc");
}

test "yaml: keys, scalars, comments" {
    var st: State = .{};
    try expectKinds(.yaml, "  name: web  # svc", &st, "..kkkkp.sss..ccccc");
    try expectKinds(.yaml, "- port: 8080", &st, "p.kkkkp.nnnn");
    try expectKinds(.yaml, "enabled: true", &st, "kkkkkkkp.kkkk");
    try expectKinds(.yaml, "  - \"quoted: x\"", &st, "..p.sssssssssss");
    try expectKinds(.yaml, "steps:", &st, "kkkkkp");
}

test "every snippet highlights without overrunning and keeps its length" {
    const content = @import("content.zig");
    for (std.meta.tags(Lang)) |lang| {
        for (content.codeSnippets(lang)) |snip| {
            var st: State = .{};
            var it = std.mem.splitScalar(u8, snip, '\n');
            while (it.next()) |line| {
                var out: [256]Kind = undefined;
                highlightLine(lang, line, &st, &out);
            }
            // Snippets close what they open.
            if (lang != .mixed) {
                try testing.expect(!st.block_comment);
                try testing.expectEqual(@as(u8, 0), st.string_delim);
            }
        }
    }
}

test "guessLang" {
    try testing.expectEqual(Lang.zig, guessLang("pub fn main() !void {\n    const std = @import(\"std\");\n}"));
    try testing.expectEqual(Lang.rust, guessLang("fn main() {\n    let mut v = Vec::new();\n    println!(\"{}\", 1);\n}"));
    try testing.expectEqual(Lang.go, guessLang("func main() {\n    x := 1\n    if err != nil {\n    }\n}"));
    try testing.expectEqual(Lang.python, guessLang("def f(self):\n    return self.x\n"));
    try testing.expectEqual(Lang.sql, guessLang("SELECT a\nFROM t\nWHERE b = 1;"));
    try testing.expectEqual(Lang.yaml, guessLang("name: ci\non:\n  push:\n    branches: [main]"));
    try testing.expectEqual(Lang.mixed, guessLang("the quick brown fox"));
}

test "guessCustomLang: prose with one marker stays plain, real code is still guessed" {
    try testing.expectEqual(Lang.mixed, guessCustomLang("We await the results.\nIt's None of my business, really."));
    try testing.expectEqual(Lang.mixed, guessCustomLang("Note: the meeting moved.\nAgenda: budget and hiring.\nPlease reply soon."));
    try testing.expectEqual(Lang.mixed, guessCustomLang("Pick the private room\nfrom the list."));
    try testing.expectEqual(Lang.python, guessCustomLang("def f(x):\n    return None\n"));
    try testing.expectEqual(Lang.yaml, guessCustomLang("name: app\nports:\n  - 80\n  - 443\n"));
    // The drills' guess is unchanged.
    try testing.expectEqual(Lang.python, guessLang("x = None"));
}
