//! Time-bucketed usage statistics: day keys, aggregates, report shapes.

const std = @import("std");
const event_mod = @import("event.zig");
const index_mod = @import("index.zig");

const Tokens = event_mod.Tokens;

/// Counters accumulated for one UTC day (also used for range totals).
pub const DayAgg = struct {
    prompts: u32 = 0,
    tool_calls: u32 = 0,
    failures: u32 = 0,
    tokens: Tokens = .{},

    pub fn add(a: *DayAgg, b: DayAgg) void {
        a.prompts += b.prompts;
        a.tool_calls += b.tool_calls;
        a.failures += b.failures;
        a.tokens.input += b.tokens.input;
        a.tokens.output += b.tokens.output;
        a.tokens.cache_read += b.tokens.cache_read;
        a.tokens.cache_creation += b.tokens.cache_creation;
    }
};

pub const DayRow = struct {
    date: []const u8,
    day_key: i32,
    prompts: u32,
    tool_calls: u32,
    failures: u32,
    tokens: Tokens,
};

pub const ProjectRow = struct {
    project: []const u8,
    sessions: u32 = 0,
    prompts: u32 = 0,
    tool_calls: u32 = 0,
    failures: u32 = 0,
    hook_errors: u32 = 0,
    tokens: Tokens = .{},
};

pub const Report = struct {
    range_days: u32,
    generated_at_ms: i64,
    totals: DayAgg,
    days: []DayRow,
    top_tools: []index_mod.ToolCount,
    top_projects: []ProjectRow,
    hour_prompts: [24]u32,
};

/// UTC day index since the epoch; null for records without a timestamp.
pub fn dayKeyFromMs(timestamp_ms: i64) ?i32 {
    if (timestamp_ms <= 0) return null;
    return @intCast(@divFloor(timestamp_ms, 86_400_000));
}

pub fn hourFromMs(timestamp_ms: i64) u5 {
    const seconds = @divFloor(timestamp_ms, 1000);
    return @intCast(@divFloor(@mod(seconds, 86_400), 3_600));
}

/// Formats a day key as "YYYY-MM-DD" (inverse of Hinnant's days-from-civil).
pub fn formatDayKey(buf: *[10]u8, day_key: i32) []const u8 {
    const z: i64 = @as(i64, day_key) + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    var year = yoe + era * 400;
    if (month <= 2) year += 1;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(year)), @as(u32, @intCast(month)), @as(u32, @intCast(day)),
    }) catch unreachable;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const time_mod = @import("time.zig");

test "day keys round-trip through civil dates" {
    const ms = time_mod.parseIso8601Ms("2026-07-07T18:54:46.347Z").?;
    const key = dayKeyFromMs(ms).?;
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2026-07-07", formatDayKey(&buf, key));
    try testing.expectEqualStrings("1970-01-01", formatDayKey(&buf, 0));
    try testing.expectEqualStrings("2000-02-29", formatDayKey(&buf, dayKeyFromMs(time_mod.parseIso8601Ms("2000-02-29T12:00:00Z").?).?));
}

test "hourFromMs extracts the UTC hour" {
    const ms = time_mod.parseIso8601Ms("2026-07-07T18:54:46Z").?;
    try testing.expectEqual(@as(u5, 18), hourFromMs(ms));
    try testing.expectEqual(@as(u5, 0), hourFromMs(time_mod.parseIso8601Ms("2026-07-07T00:00:00Z").?));
}

test "dayKeyFromMs rejects missing timestamps" {
    try testing.expectEqual(@as(?i32, null), dayKeyFromMs(0));
    try testing.expectEqual(@as(?i32, null), dayKeyFromMs(-5));
}
