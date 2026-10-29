//! Content for the Words game: common English words, code identifiers and
//! dev one-liners. Quotes live in quotes.zig.
//!
//! Plain words are lowercase letters only and are typed case-insensitively.
//! Identifiers are typed exactly, punctuation included (`_` `.` `-` and
//! uppercase need Shift). One-liners are typed like quotes: letters only, no
//! spaces.

const std = @import("std");

/// Common English words, 3 to 10 lowercase letters.
pub const common = [_][]const u8{
    // 3 letters
    "the",        "and",        "for",        "are",        "but",        "not",
    "you",        "all",        "any",        "can",        "had",        "her",
    "was",        "one",        "our",        "out",        "day",        "get",
    "has",        "him",        "his",        "how",        "man",        "new",
    "now",        "old",        "see",        "two",        "way",        "who",
    "boy",        "did",        "its",        "let",        "put",        "say",
    "she",        "too",        "use",        "cat",        "dog",        "sun",
    "run",        "red",        "big",        "box",        "cup",        "map",
    "pen",        "sky",        "sea",        "ice",        "key",        "job",
    "art",        "car",        "fun",        "hot",        "low",        "top",
    // 4 letters
    "that",       "with",       "have",       "this",       "will",       "your",
    "from",       "they",       "know",       "want",       "been",       "good",
    "much",       "some",       "time",       "very",       "when",       "come",
    "here",       "just",       "like",       "long",       "make",       "many",
    "more",       "only",       "over",       "such",       "take",       "than",
    "them",       "well",       "were",       "what",       "work",       "word",
    "year",       "back",       "call",       "came",       "each",       "even",
    "find",       "give",       "hand",       "high",       "keep",       "last",
    "late",       "line",       "life",       "live",       "look",       "made",
    "most",       "move",       "must",       "name",       "near",       "need",
    "next",       "open",       "part",       "play",       "read",       "real",
    "same",       "seem",       "show",       "side",       "tell",       "turn",
    "used",       "wait",       "walk",       "week",       "went",       "door",
    "fast",       "slow",       "rain",       "snow",       "wind",       "fire",
    "tree",       "bird",       "fish",       "blue",       "gold",       "warm",
    "cold",       "lamp",       "desk",       "code",       "test",       "file",
    "page",       "note",       "idea",       "plan",       "step",       "game",
    // 5 letters
    "about",      "after",      "again",      "could",      "every",      "first",
    "found",      "great",      "house",      "large",      "learn",      "never",
    "other",      "place",      "point",      "right",      "small",      "sound",
    "spell",      "still",      "study",      "their",      "there",      "these",
    "thing",      "think",      "three",      "water",      "where",      "which",
    "world",      "would",      "write",      "above",      "began",      "below",
    "bring",      "carry",      "clean",      "close",      "early",      "earth",
    "light",      "might",      "money",      "music",      "night",      "often",
    "order",      "paper",      "piece",      "plant",      "quick",      "river",
    "since",      "start",      "story",      "table",      "today",      "under",
    "until",      "watch",      "while",      "white",      "whole",      "young",
    "apple",      "bread",      "chair",      "cloud",      "dream",      "field",
    "fresh",      "glass",      "happy",      "heart",      "horse",      "lemon",
    "magic",      "ocean",      "party",      "pilot",      "radio",      "smile",
    "spark",      "stone",      "sugar",      "tiger",      "train",      "voice",
    "pixel",      "build",      "merge",      "query",      "shell",      "stack",
    // 6 letters
    "always",     "around",     "before",     "better",     "change",     "letter",
    "little",     "mother",     "number",     "people",     "should",     "answer",
    "animal",     "beauty",     "bridge",     "castle",     "circle",     "corner",
    "garden",     "orange",     "planet",     "pocket",     "rocket",     "silver",
    "spring",     "summer",     "winter",     "autumn",     "window",     "yellow",
    "simple",     "strong",     "travel",     "friend",     "follow",     "family",
    "forest",     "island",     "market",     "middle",     "minute",     "moment",
    "nature",     "office",     "pencil",     "public",     "reason",     "record",
    "school",     "second",     "signal",     "silent",     "stream",     "street",
    "planner",    "thread",     "server",     "socket",     "branch",     "commit",
    // 7 letters
    "another",    "between",    "country",    "example",    "picture",    "through",
    "without",    "against",    "already",    "balance",    "battery",    "blanket",
    "brother",    "capital",    "captain",    "century",    "chicken",    "climate",
    "college",    "comfort",    "company",    "concert",    "control",    "curious",
    "diamond",    "distant",    "evening",    "fantasy",    "freedom",    "general",
    "harvest",    "history",    "holiday",    "journey",    "kitchen",    "library",
    "machine",    "message",    "morning",    "natural",    "network",    "pattern",
    "perfect",    "problem",    "project",    "rainbow",    "science",    "silence",
    "station",    "teacher",    "thunder",    "tonight",    "unknown",    "weather",
    "welcome",    "whisper",    "compile",    "default",    "release",    "keyboard",
    // 8 letters
    "anything",   "complete",   "possible",   "together",   "question",   "children",
    "mountain",   "language",   "building",   "business",   "computer",   "daughter",
    "elephant",   "favorite",   "festival",   "football",   "graceful",   "hospital",
    "midnight",   "notebook",   "painting",   "pleasant",   "practice",   "princess",
    "remember",   "sandwich",   "shoulder",   "sunshine",   "surprise",   "treasure",
    "umbrella",   "universe",   "vacation",   "watching",   "absolute",   "creative",
    "function",   "variable",   "terminal",   "database",   "pipeline",   "frontend",
    // 9 and 10 letters
    "adventure",  "beautiful",  "butterfly",  "celebrate",  "chocolate",  "community",
    "dangerous",  "different",  "education",  "excellent",  "important",  "invisible",
    "knowledge",  "landscape",  "lightning",  "microwave",  "newspaper",  "orchestra",
    "spaceship",  "strawberry", "telephone",  "tomorrow",   "wonderful",  "yesterday",
    "afternoon",  "breakfast",  "cardboard",  "framework",  "algorithm",  "interface",
    "challenge",  "dinosaur",   "direction",  "discovery",  "everybody",  "happiness",
    "beginning",  "condition",  "attention",  "something",  "operation",  "carefully",
    "basketball", "friendship", "television", "volleyball", "playground", "restaurant",
    "background", "everything", "generation", "photograph", "understand", "creativity",
};

/// Code identifiers and keywords, typed exactly (2 to 20 characters, no
/// spaces).
pub const code = [_][]const u8{
    // keywords
    "if",             "for",           "let",        "var",
    "const",          "async",         "await",      "return",
    "impl",           "defer",         "struct",     "enum",
    "match",          "null",          "true",       "false",
    "self",           "import",        "export",     "yield",
    "break",          "continue",      "switch",     "while",
    "else",           "try",           "catch",      "throw",
    "typeof",         "extends",       "interface",  "readonly",
    "unsafe",         "mut",           "pub",        "trait",
    "lambda",         "def",           "elif",       "None",
    "nil",            "comptime",      "errdefer",   "usize",
    "u8",             "i32",           "f64",        "fn",
    // camelCase / PascalCase
    "parseArgs",      "useEffect",     "useState",   "useMemo",
    "getElementById", "querySelector", "setTimeout", "fetchData",
    "handleClick",    "onSubmit",      "isValid",    "toString",
    "toUpperCase",    "forEach",       "indexOf",    "addEventListener",
    "innerHTML",      "readFile",      "parseInt",   "isEmpty",
    "getUser",        "userId",        "maxRetries", "onChange",
    "camelCase",      "PascalCase",    "ArrayList",  "HashMap",
    "Option",         "Result",        "Vec",        "String",
    "Promise",        "Error",         "Allocator",  "Iterator",
    // snake_case and constants
    "snake_case",     "max_len",       "user_id",    "is_empty",
    "to_string",      "read_line",     "unwrap_or",  "file_name",
    "__init__",       "__main__",      "MAX_SIZE",   "API_KEY",
    "HTTP_OK",        "DEBUG",         "EOF",        "node_modules",
    // dotted
    "std.mem",        "std.debug",     "std.heap",   "mem.eql",
    "console.log",    "JSON.parse",    "Array.from", "Object.keys",
    "Promise.all",    "os.path",       "sys.argv",   "self.name",
    "fmt.Println",    "http.Get",      "io.Writer",  "Math.max",
    // kebab-case and file names
    "kebab-case",     "max-width",     "font-size",  "line-height",
    "border-radius",  "z-index",       "aria-label", "data-id",
    "pre-commit",     "content-type",  "x-api-key",  "dry-run",
    "package.json",   "Cargo.toml",    "build.zig",  "main.zig",
    "README.md",      "index.html",    "app.js",     "go.mod",
};

/// Our own dev one-liners, 4 to 9 words. Typed like quotes (letters only).
pub const oneliners = [_][]const u8{
    "write the test before the fix",
    "the bug was in the config all along",
    "it works on my machine",
    "never deploy on a friday afternoon",
    "read the error message twice",
    "naming things is the hard part",
    "delete the code you no longer need",
    "small commits make happy reviewers",
    "the build is green so ship it",
    "measure before you optimize anything",
    "every todo quietly becomes a forever",
    "comments drift but the code runs",
    "ask the rubber duck before a human",
    "one more coffee and then the refactor",
    "the flaky test failed again today",
    "check the logs before you guess",
    "nobody reads the docs until it breaks",
    "merge conflicts build character",
    "keep functions short and names honest",
    "the cache was stale the whole time",
    "push early and push often",
    "a quick fix is never quick",
    "the standup ran long again",
    "pair up when you feel stuck",
    "revert first and ask questions later",
    "trust the types but test the edges",
    "the deadline moved but the scope did not",
    "turn it off and on again",
    "write code for the next reader",
    "the linter found something new",
    "estimate it and then double it",
    "the pull request needs one more review",
    "refactor in tiny safe steps",
    "the dependency update broke everything",
    "good logs save long nights",
    "simple beats clever nearly every time",
    "close the laptop and take a walk",
    "the hotfix needs a hotfix",
    "fix the root cause not the symptom",
    "the meeting could have been a message",
    "leave the code nicer than you found it",
    "rename it now before it spreads",
};

/// Number of space-separated words in `text`.
pub fn wordCount(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |_| n += 1;
    return n;
}

/// Letters of `w` (what a plain word or quote word types).
pub fn letterCount(w: []const u8) usize {
    var n: usize = 0;
    for (w) |c| n += @intFromBool(std.ascii.isAlphabetic(c));
    return n;
}

/// Whether `w` contains an uppercase letter (identifiers with uppercase are
/// typed case-sensitively).
pub fn hasUpper(w: []const u8) bool {
    for (w) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "common words are lowercase letters, 3 to 10 long" {
    try testing.expect(common.len >= 400);
    for (common) |w| {
        try testing.expect(w.len >= 3 and w.len <= 10);
        for (w) |c| try testing.expect(c >= 'a' and c <= 'z');
    }
    for (common, 0..) |a, i| {
        for (common[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
    var short: usize = 0;
    var long: usize = 0;
    for (common) |w| {
        if (w.len <= 5) short += 1;
        if (w.len >= 7) long += 1;
    }
    try testing.expect(short >= 100);
    try testing.expect(long >= 100);
}

test "identifiers are printable ASCII without spaces" {
    try testing.expect(code.len >= 120);
    var upper: usize = 0;
    var punct: usize = 0;
    for (code) |w| {
        try testing.expect(w.len >= 2 and w.len <= 20);
        for (w) |c| try testing.expect(c > ' ' and c < 127);
        upper += @intFromBool(hasUpper(w));
        for (w) |c| {
            if (c == '_' or c == '.' or c == '-') {
                punct += 1;
                break;
            }
        }
    }
    try testing.expect(upper >= 20);
    try testing.expect(punct >= 30);
}

test "one-liners have 4 to 9 typeable words" {
    try testing.expect(oneliners.len >= 40);
    for (oneliners) |l| {
        const n = wordCount(l);
        try testing.expect(n >= 4 and n <= 9);
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        while (it.next()) |w| try testing.expect(letterCount(w) >= 1 and letterCount(w) <= 20);
    }
}
