pub const Stats = struct {
    correct_chars: usize = 0,
    errors: usize = 0,
};

pub fn compareTypedToTarget(typed: []const u8, target: []const u8) Stats {
    var stats = Stats{};

    const len = @min(typed.len, target.len);
    for (0..len) |i| {
        if (typed[i] == target[i]) {
            stats.correct_chars += 1;
        } else {
            stats.errors += 1;
        }
    }

    if (typed.len > target.len) {
        stats.errors += typed.len - target.len;
    } else if (typed.len < target.len) {
        stats.errors += target.len - typed.len;
    }

    return stats;
}

pub fn wpm(correct_chars: usize, elapsed_ms: i64) f64 {
    if (elapsed_ms <= 0) return 0;
    return @as(f64, @floatFromInt(correct_chars)) / 5.0 / (@as(f64, @floatFromInt(elapsed_ms)) / 60000.0);
}

pub fn accuracy(correct_chars: usize, errors: usize) f64 {
    const total = correct_chars + errors;
    if (total == 0) return 100.0;
    return @as(f64, @floatFromInt(correct_chars)) / @as(f64, @floatFromInt(total)) * 100.0;
}
