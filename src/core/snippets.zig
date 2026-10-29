//! Multi-line code snippets for code mode (in addition to the
//! `vim_snippets_*` banks in content.zig).
//!
//! Rules for every snippet: 3–12 lines, syntactically valid, 4-space
//! indentation, printable ASCII only, single spaces between tokens and no
//! trailing whitespace (the session collapses space runs anyway).

pub const zig = [_][]const u8{
    \\fn max(a: i32, b: i32) i32 {
    \\    return if (a > b) a else b;
    \\}
    ,
    \\pub fn sum(items: []const u32) u64 {
    \\    var total: u64 = 0;
    \\    for (items) |item| total += item;
    \\    return total;
    \\}
    ,
    \\const Point = struct {
    \\    x: f32,
    \\    y: f32,
    \\
    \\    pub fn add(a: Point, b: Point) Point {
    \\        return .{ .x = a.x + b.x, .y = a.y + b.y };
    \\    }
    \\};
    ,
    \\fn parseDigit(c: u8) !u8 {
    \\    return switch (c) {
    \\        '0'...'9' => c - '0',
    \\        else => error.InvalidDigit,
    \\    };
    \\}
    ,
    \\pub fn indexOf(haystack: []const u8, needle: u8) ?usize {
    \\    for (haystack, 0..) |c, i| {
    \\        if (c == needle) return i;
    \\    }
    \\    return null;
    \\}
    ,
    \\test "list grows" {
    \\    var list: std.ArrayList(u8) = .empty;
    \\    defer list.deinit(std.testing.allocator);
    \\    try list.append(std.testing.allocator, 'a');
    \\    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    \\}
    ,
    \\const Color = enum {
    \\    red,
    \\    green,
    \\    blue,
    \\
    \\    pub fn isWarm(self: Color) bool {
    \\        return self == .red;
    \\    }
    \\};
    ,
    \\fn reverse(buf: []u8) void {
    \\    var i: usize = 0;
    \\    var j: usize = buf.len;
    \\    while (i + 1 < j) : (i += 1) {
    \\        j -= 1;
    \\        std.mem.swap(u8, &buf[i], &buf[j]);
    \\    }
    \\}
    ,
    \\pub fn dupe(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    \\    const out = try gpa.alloc(u8, s.len);
    \\    errdefer gpa.free(out);
    \\    @memcpy(out, s);
    \\    return out;
    \\}
    ,
};

pub const rust = [_][]const u8{
    \\fn max(a: i32, b: i32) -> i32 {
    \\    if a > b { a } else { b }
    \\}
    ,
    \\fn sum(items: &[u32]) -> u64 {
    \\    items.iter().map(|&x| x as u64).sum()
    \\}
    ,
    \\#[derive(Debug, Clone, Copy, PartialEq)]
    \\struct Point {
    \\    x: f32,
    \\    y: f32,
    \\}
    ,
    \\impl Point {
    \\    fn new(x: f32, y: f32) -> Self {
    \\        Self { x, y }
    \\    }
    \\
    \\    fn length(&self) -> f32 {
    \\        (self.x * self.x + self.y * self.y).sqrt()
    \\    }
    \\}
    ,
    \\enum Shape {
    \\    Circle(f64),
    \\    Square(f64),
    \\}
    \\
    \\fn area(shape: &Shape) -> f64 {
    \\    match shape {
    \\        Shape::Circle(r) => 3.14 * r * r,
    \\        Shape::Square(s) => s * s,
    \\    }
    \\}
    ,
    \\fn parse_port(s: &str) -> Result<u16, String> {
    \\    s.trim()
    \\        .parse::<u16>()
    \\        .map_err(|e| format!("bad port: {}", e))
    \\}
    ,
    \\fn count_words(text: &str) -> HashMap<&str, usize> {
    \\    let mut counts = HashMap::new();
    \\    for word in text.split_whitespace() {
    \\        *counts.entry(word).or_insert(0) += 1;
    \\    }
    \\    counts
    \\}
    ,
    \\#[cfg(test)]
    \\mod tests {
    \\    use super::*;
    \\
    \\    #[test]
    \\    fn adds() {
    \\        assert_eq!(max(2, 3), 3);
    \\    }
    \\}
    ,
    \\fn first_even(v: &[i32]) -> Option<i32> {
    \\    for &n in v {
    \\        if n % 2 == 0 {
    \\            return Some(n);
    \\        }
    \\    }
    \\    None
    \\}
    ,
};

pub const go = [_][]const u8{
    \\func max(a, b int) int {
    \\    if a > b {
    \\        return a
    \\    }
    \\    return b
    \\}
    ,
    \\func sum(items []int) int {
    \\    total := 0
    \\    for _, v := range items {
    \\        total += v
    \\    }
    \\    return total
    \\}
    ,
    \\type Point struct {
    \\    X float64
    \\    Y float64
    \\}
    \\
    \\func (p Point) Add(q Point) Point {
    \\    return Point{X: p.X + q.X, Y: p.Y + q.Y}
    \\}
    ,
    \\func readConfig(path string) ([]byte, error) {
    \\    data, err := os.ReadFile(path)
    \\    if err != nil {
    \\        return nil, fmt.Errorf("read %s: %w", path, err)
    \\    }
    \\    return data, nil
    \\}
    ,
    \\func worker(jobs <-chan int, results chan<- int) {
    \\    for j := range jobs {
    \\        results <- j * 2
    \\    }
    \\}
    ,
    \\func countWords(text string) map[string]int {
    \\    counts := make(map[string]int)
    \\    for _, w := range strings.Fields(text) {
    \\        counts[w]++
    \\    }
    \\    return counts
    \\}
    ,
    \\type Stack struct {
    \\    items []int
    \\}
    \\
    \\func (s *Stack) Push(v int) {
    \\    s.items = append(s.items, v)
    \\}
    ,
    \\func TestMax(t *testing.T) {
    \\    if got := max(2, 3); got != 3 {
    \\        t.Errorf("max(2, 3) = %d, want 3", got)
    \\    }
    \\}
    ,
    \\func handler(w http.ResponseWriter, r *http.Request) {
    \\    switch r.Method {
    \\    case http.MethodGet:
    \\        fmt.Fprintln(w, "ok")
    \\    default:
    \\        w.WriteHeader(http.StatusMethodNotAllowed)
    \\    }
    \\}
    ,
};

pub const ts = [_][]const u8{
    \\function max(a: number, b: number): number {
    \\    return a > b ? a : b;
    \\}
    ,
    \\const sum = (items: number[]): number =>
    \\    items.reduce((acc, x) => acc + x, 0);
    \\
    \\console.log(sum([1, 2, 3]));
    ,
    \\interface User {
    \\    id: number;
    \\    name: string;
    \\    email?: string;
    \\}
    ,
    \\export async function getUser(id: number): Promise<User> {
    \\    const res = await fetch(`/api/users/${id}`);
    \\    if (!res.ok) {
    \\        throw new Error(`HTTP ${res.status}`);
    \\    }
    \\    return res.json();
    \\}
    ,
    \\type Shape =
    \\    | { kind: "circle"; r: number }
    \\    | { kind: "square"; s: number };
    \\
    \\function area(shape: Shape): number {
    \\    switch (shape.kind) {
    \\        case "circle":
    \\            return Math.PI * shape.r ** 2;
    \\        case "square":
    \\            return shape.s * shape.s;
    \\    }
    \\}
    ,
    \\class Counter {
    \\    private count = 0;
    \\
    \\    increment(): number {
    \\        return ++this.count;
    \\    }
    \\}
    ,
    \\function groupBy<T>(items: T[], key: (item: T) => string) {
    \\    const out: Record<string, T[]> = {};
    \\    for (const item of items) {
    \\        (out[key(item)] ??= []).push(item);
    \\    }
    \\    return out;
    \\}
    ,
    \\const debounce = (fn: () => void, ms: number) => {
    \\    let timer: ReturnType<typeof setTimeout> | undefined;
    \\    return () => {
    \\        clearTimeout(timer);
    \\        timer = setTimeout(fn, ms);
    \\    };
    \\};
    ,
    \\export function unique(values: string[]): string[] {
    \\    return [...new Set(values)].sort();
    \\}
    ,
};

pub const python = [_][]const u8{
    \\def max_of(a, b):
    \\    """Return the larger of a and b."""
    \\    return a if a > b else b
    ,
    \\def total(items):
    \\    result = 0
    \\    for item in items:
    \\        result += item
    \\    return result
    ,
    \\def count_words(text: str) -> dict[str, int]:
    \\    counts: dict[str, int] = {}
    \\    for word in text.split():
    \\        counts[word] = counts.get(word, 0) + 1
    \\    return counts
    ,
    \\class Stack:
    \\    def __init__(self):
    \\        self.items = []
    \\
    \\    def push(self, item):
    \\        self.items.append(item)
    \\
    \\    def pop(self):
    \\        return self.items.pop()
    ,
    \\def read_lines(path):
    \\    with open(path, encoding="utf-8") as f:
    \\        return [line.rstrip() for line in f]
    ,
    \\def parse_port(value: str) -> int:
    \\    try:
    \\        port = int(value)
    \\    except ValueError:
    \\        raise ValueError(f"bad port: {value!r}")
    \\    if not 0 < port < 65536:
    \\        raise ValueError("port out of range")
    \\    return port
    ,
    \\def fib(n):
    \\    a, b = 0, 1
    \\    for _ in range(n):
    \\        a, b = b, a + b
    \\    return a
    ,
    \\def test_fib():
    \\    assert fib(0) == 0
    \\    assert fib(10) == 55
    ,
    \\squares = {n: n * n for n in range(10)}
    \\evens = [n for n in squares if n % 2 == 0]
    \\print(sorted(evens, reverse=True))
    ,
};

pub const c = [_][]const u8{
    \\int max(int a, int b) {
    \\    return a > b ? a : b;
    \\}
    ,
    \\long sum(const int *items, size_t len) {
    \\    long total = 0;
    \\    for (size_t i = 0; i < len; i++) {
    \\        total += items[i];
    \\    }
    \\    return total;
    \\}
    ,
    \\struct point {
    \\    double x;
    \\    double y;
    \\};
    ,
    \\size_t my_strlen(const char *s) {
    \\    const char *p = s;
    \\    while (*p) {
    \\        p++;
    \\    }
    \\    return (size_t)(p - s);
    \\}
    ,
    \\void swap(int *a, int *b) {
    \\    int tmp = *a;
    \\    *a = *b;
    \\    *b = tmp;
    \\}
    ,
    \\struct node {
    \\    int value;
    \\    struct node *next;
    \\};
    \\
    \\struct node *push(struct node *head, int value) {
    \\    struct node *n = malloc(sizeof(*n));
    \\    n->value = value;
    \\    n->next = head;
    \\    return n;
    \\}
    ,
    \\int count_char(const char *s, char c) {
    \\    int n = 0;
    \\    for (; *s != '\0'; s++) {
    \\        if (*s == c) {
    \\            n++;
    \\        }
    \\    }
    \\    return n;
    \\}
    ,
    \\#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
    \\
    \\static const char *names[] = {"red", "green", "blue"};
    \\
    \\int main(void) {
    \\    for (size_t i = 0; i < ARRAY_LEN(names); i++) {
    \\        printf("%s\n", names[i]);
    \\    }
    \\    return 0;
    \\}
    ,
    \\enum color { RED, GREEN, BLUE };
    \\
    \\const char *color_name(enum color c) {
    \\    switch (c) {
    \\    case RED:
    \\        return "red";
    \\    case GREEN:
    \\        return "green";
    \\    default:
    \\        return "blue";
    \\    }
    \\}
    ,
};

pub const bash = [_][]const u8{
    \\for file in *.log; do
    \\    gzip -9 "$file"
    \\    echo "compressed $file"
    \\done
    ,
    \\if [ -z "$HOME" ]; then
    \\    echo "HOME is not set" >&2
    \\    exit 1
    \\fi
    ,
    \\backup() {
    \\    local src="$1"
    \\    local dest="$2/$(date +%F)"
    \\    mkdir -p "$dest"
    \\    cp -r "$src" "$dest"
    \\}
    ,
    \\count=0
    \\while read -r line; do
    \\    count=$((count + 1))
    \\done < input.txt
    \\echo "lines: $count"
    ,
    \\set -euo pipefail
    \\name="${1:-world}"
    \\greeting="hello, $name"
    \\echo "$greeting"
    ,
    \\for dir in src lib test; do
    \\    if [ -d "$dir" ]; then
    \\        find "$dir" -name "*.tmp" -delete
    \\    fi
    \\done
    ,
    \\files=(*.txt)
    \\echo "found ${#files[@]} files"
    \\for f in "${files[@]}"; do
    \\    wc -l "$f"
    \\done
    ,
    \\retry() {
    \\    local tries=0
    \\    until "$@"; do
    \\        tries=$((tries + 1))
    \\        [ "$tries" -ge 5 ] && return 1
    \\        sleep 1
    \\    done
    \\}
    ,
    \\if grep -q "error" build.log; then
    \\    echo "build failed"
    \\else
    \\    echo "build passed"
    \\fi
    ,
};

pub const lua = [_][]const u8{
    \\local function add(a, b)
    \\    return a + b
    \\end
    \\print(add(2, 3))
    ,
    \\local fruits = { "apple", "pear", "plum" }
    \\for i, name in ipairs(fruits) do
    \\    print(i, name)
    \\end
    ,
    \\local Point = {}
    \\Point.__index = Point
    \\
    \\function Point.new(x, y)
    \\    return setmetatable({ x = x, y = y }, Point)
    \\end
    ,
    \\local function fib(n)
    \\    if n < 2 then
    \\        return n
    \\    end
    \\    return fib(n - 1) + fib(n - 2)
    \\end
    ,
    \\local counts = {}
    \\for word in text:gmatch("%a+") do
    \\    counts[word] = (counts[word] or 0) + 1
    \\end
    ,
    \\local ok, err = pcall(function()
    \\    error("something broke")
    \\end)
    \\if not ok then
    \\    print("caught: " .. err)
    \\end
    ,
    \\local config = {
    \\    width = 800,
    \\    height = 600,
    \\    title = "game",
    \\}
    \\print(config.title, config.width)
    ,
    \\function love.update(dt)
    \\    player.x = player.x + player.speed * dt
    \\    if player.x > 800 then
    \\        player.x = 0
    \\    end
    \\end
    ,
    \\local i = 10
    \\while i > 0 do
    \\    io.write(i, " ")
    \\    i = i - 1
    \\end
    ,
};

pub const sql = [_][]const u8{
    \\SELECT id, name, email
    \\FROM users
    \\WHERE active = TRUE
    \\ORDER BY name;
    ,
    \\CREATE TABLE orders (
    \\    id SERIAL PRIMARY KEY,
    \\    user_id INTEGER NOT NULL,
    \\    total NUMERIC(10, 2),
    \\    created_at TIMESTAMP DEFAULT NOW()
    \\);
    ,
    \\SELECT u.name, COUNT(o.id) AS orders
    \\FROM users u
    \\LEFT JOIN orders o ON o.user_id = u.id
    \\GROUP BY u.name
    \\HAVING COUNT(o.id) > 5;
    ,
    \\INSERT INTO products (name, price, stock)
    \\VALUES
    \\    ('keyboard', 49.99, 120),
    \\    ('mouse', 19.50, 300);
    ,
    \\UPDATE accounts
    \\SET balance = balance - 100
    \\WHERE id = 42
    \\RETURNING balance;
    ,
    \\DELETE FROM sessions
    \\WHERE expires_at < NOW()
    \\    AND user_id IS NOT NULL;
    ,
    \\WITH recent AS (
    \\    SELECT * FROM events
    \\    WHERE created_at > NOW() - INTERVAL '7 days'
    \\)
    \\SELECT kind, COUNT(*) FROM recent GROUP BY kind;
    ,
    \\SELECT name,
    \\    CASE
    \\        WHEN score >= 90 THEN 'A'
    \\        WHEN score >= 80 THEN 'B'
    \\        ELSE 'C'
    \\    END AS grade
    \\FROM students;
    ,
    \\CREATE INDEX idx_orders_user
    \\ON orders (user_id, created_at);
    \\ANALYZE orders;
    ,
};

pub const java = [_][]const u8{
    \\public class Main {
    \\    public static void main(String[] args) {
    \\        System.out.println("Hello, world!");
    \\    }
    \\}
    ,
    \\public int sum(int[] values) {
    \\    int total = 0;
    \\    for (int v : values) {
    \\        total += v;
    \\    }
    \\    return total;
    \\}
    ,
    \\public record Point(double x, double y) {
    \\    public double length() {
    \\        return Math.sqrt(x * x + y * y);
    \\    }
    \\}
    ,
    \\List<String> names = new ArrayList<>();
    \\names.add("ada");
    \\names.add("linus");
    \\for (String name : names) {
    \\    System.out.println(name.toUpperCase());
    \\}
    ,
    \\try (BufferedReader in = Files.newBufferedReader(path)) {
    \\    String line;
    \\    while ((line = in.readLine()) != null) {
    \\        process(line);
    \\    }
    \\} catch (IOException e) {
    \\    log.error("read failed", e);
    \\}
    ,
    \\@Override
    \\public boolean equals(Object o) {
    \\    if (this == o) return true;
    \\    if (!(o instanceof User other)) return false;
    \\    return id == other.id;
    \\}
    ,
    \\Map<String, Integer> counts = new HashMap<>();
    \\for (String word : words) {
    \\    counts.merge(word, 1, Integer::sum);
    \\}
    ,
    \\public interface Shape {
    \\    double area();
    \\
    \\    default String describe() {
    \\        return "area " + area();
    \\    }
    \\}
    ,
    \\List<Integer> evens = numbers.stream()
    \\    .filter(n -> n % 2 == 0)
    \\    .map(n -> n * n)
    \\    .toList();
    ,
};

pub const yaml = [_][]const u8{
    \\server:
    \\  host: localhost
    \\  port: 8080
    \\  debug: false
    ,
    \\name: ci
    \\on:
    \\  push:
    \\    branches: [main]
    \\jobs:
    \\  test:
    \\    runs-on: ubuntu-latest
    \\    steps:
    \\      - uses: actions/checkout@v4
    \\      - run: make test
    ,
    \\services:
    \\  web:
    \\    image: nginx:1.27
    \\    ports:
    \\      - "80:80"
    \\  db:
    \\    image: postgres:16
    \\    environment:
    \\      POSTGRES_PASSWORD: secret
    ,
    \\apiVersion: v1
    \\kind: Service
    \\metadata:
    \\  name: api
    \\spec:
    \\  selector:
    \\    app: api
    \\  ports:
    \\    - port: 80
    \\      targetPort: 3000
    ,
    \\# feature flags
    \\features:
    \\  dark_mode: true
    \\  beta_search: false
    \\  max_items: 50
    ,
    \\users:
    \\  - name: ada
    \\    role: admin
    \\  - name: linus
    \\    role: editor
    ,
    \\logging:
    \\  level: info
    \\  format: json
    \\  outputs:
    \\    - stdout
    \\    - file: /var/log/app.log
    ,
    \\retry:
    \\  attempts: 3
    \\  backoff: 1.5
    \\  on: [timeout, reset]
    \\  message: "retrying in {delay}s"
    ,
};
