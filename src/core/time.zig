//! Minimal ISO 8601 parsing and formatting. Claude Code timestamps look like
//! "2026-07-07T18:54:46.347Z"; we only need UTC with optional fractions.

const std = @import("std");

/// Parses an ISO 8601 UTC timestamp into milliseconds since the Unix epoch.
/// Returns null on any malformed input.
pub fn parseIso8601Ms(text: []const u8) ?i64 {
    if (text.len < 19) return null;
    if (text[4] != '-' or text[7] != '-') return null;
    if (text[10] != 'T' and text[10] != ' ') return null;
    if (text[13] != ':' or text[16] != ':') return null;

    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var millis: i64 = 0;
    if (text.len > 20 and text[19] == '.') {
        var digits: usize = 0;
        var i: usize = 20;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            if (digits < 3) {
                millis = millis * 10 + (text[i] - '0');
                digits += 1;
            }
        }
        if (digits == 0) return null;
        while (digits < 3) : (digits += 1) millis *= 10;
    }

    const days = daysFromCivil(year, month, day);
    const seconds = days * 86_400 + hour * 3_600 + minute * 60 + second;
    return seconds * 1_000 + millis;
}

/// Formats milliseconds since epoch as UTC "HH:MM:SS" into `buf`.
pub fn formatClock(buf: *[8]u8, timestamp_ms: i64) []const u8 {
    const total_seconds = @divFloor(timestamp_ms, 1_000);
    const day_seconds: u32 = @intCast(@mod(total_seconds, 86_400));
    const hour = day_seconds / 3_600;
    const minute = (day_seconds % 3_600) / 60;
    const second = day_seconds % 60;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch unreachable;
}

/// Days since 1970-01-01 for a proleptic Gregorian date.
/// Howard Hinnant's days-from-civil algorithm.
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

test "parseIso8601Ms parses a real transcript timestamp" {
    try std.testing.expectEqual(@as(?i64, 1783450486347), parseIso8601Ms("2026-07-07T18:54:46.347Z"));
}

test "parseIso8601Ms parses the epoch" {
    try std.testing.expectEqual(@as(?i64, 0), parseIso8601Ms("1970-01-01T00:00:00.000Z"));
}

test "parseIso8601Ms accepts missing fraction" {
    try std.testing.expectEqual(@as(?i64, 86_400_000), parseIso8601Ms("1970-01-02T00:00:00Z"));
}

test "parseIso8601Ms rejects malformed input" {
    try std.testing.expectEqual(@as(?i64, null), parseIso8601Ms(""));
    try std.testing.expectEqual(@as(?i64, null), parseIso8601Ms("not a date"));
    try std.testing.expectEqual(@as(?i64, null), parseIso8601Ms("2026-13-07T18:54:46Z"));
    try std.testing.expectEqual(@as(?i64, null), parseIso8601Ms("2026-07-07X18:54:46Z"));
}

test "formatClock renders UTC wall time" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("18:54:46", formatClock(&buf, 1783450486347));
    try std.testing.expectEqualStrings("00:00:00", formatClock(&buf, 0));
}
