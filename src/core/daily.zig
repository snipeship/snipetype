//! Daily challenge: one text per UTC date, the same for everyone. Pure
//! date arithmetic (days since 1970-01-01, proleptic Gregorian) and a
//! fixed seed mix, so native and web builds agree.

const std = @import("std");

/// UTC days since 1970-01-01 (floor, also for times before the epoch;
/// clamped to 0).
pub fn dayFromUnix(unix_s: i64) u32 {
    const d = @divFloor(unix_s, 86400);
    return @intCast(std.math.clamp(d, 0, std.math.maxInt(u32)));
}

/// Seed of a day's text: splitmix64 of the day mixed with a constant.
pub fn seedFor(day: u32) u64 {
    var z: u64 = @as(u64, day) ^ 0x5eed_da11_c0de_2026;
    z +%= 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub const Civil = struct { year: u32, month: u8, day: u8 };

/// Days since the epoch → calendar date (Howard Hinnant's civil_from_days).
pub fn civil(day: u32) Civil {
    const z: i64 = @as(i64, day) + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const y: i64 = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// "YYYY-MM-DD" (UTC). Years past 9999 wrap to 4 digits.
pub fn format(day: u32, buf: *[10]u8) []const u8 {
    const c = civil(day);
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ c.year % 10000, c.month, c.day }) catch unreachable;
    return buf[0..10];
}

const testing = std.testing;

test "dates: epoch, leap days and today" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", format(0, &buf));
    try testing.expectEqualStrings("1970-01-02", format(dayFromUnix(86400), &buf));
    try testing.expectEqualStrings("1970-01-01", format(dayFromUnix(86399), &buf));
    try testing.expectEqual(@as(u32, 0), dayFromUnix(-5));
    // 2000 is a leap year (divisible by 400), 1900 is not, 2024 is.
    try testing.expectEqualStrings("2000-02-29", format(11016, &buf));
    try testing.expectEqualStrings("2000-03-01", format(11017, &buf));
    try testing.expectEqualStrings("2024-02-29", format(19782, &buf));
    try testing.expectEqualStrings("2023-03-01", format(19417, &buf));
    try testing.expectEqualStrings("2023-02-28", format(19416, &buf));
    // 2026-10-28 00:00:00 UTC = 1793145600.
    try testing.expectEqual(@as(u32, 20754), dayFromUnix(1793145600));
    try testing.expectEqualStrings("2026-10-28", format(20754, &buf));
    try testing.expectEqualStrings("2026-12-31", format(20818, &buf));
    try testing.expectEqualStrings("2027-01-01", format(20819, &buf));
}

test "every day round-trips through a naive calendar walk" {
    var y: u32 = 1970;
    var m: u8 = 1;
    var d: u8 = 1;
    for (0..80_000) |day| {
        const c = civil(@intCast(day));
        try testing.expectEqual(Civil{ .year = y, .month = m, .day = d }, c);
        const leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
        const mdays = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        d += 1;
        if (d > mdays[m - 1]) {
            d = 1;
            m += 1;
            if (m > 12) {
                m = 1;
                y += 1;
            }
        }
    }
}

test "seeds are fixed per day and differ between days" {
    try testing.expectEqual(seedFor(20754), seedFor(20754));
    try testing.expect(seedFor(20754) != seedFor(20755));
    try testing.expect(seedFor(0) != 0);
}
