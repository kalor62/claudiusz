//! Reads Claude Code's own stats cache (`<root>/stats-cache.json`) — the data
//! behind the /stats command. It reaches further back than the transcripts
//! (which Claude Code periodically purges), so it is the source for weekly
//! usage history. `tokensByModel` counts input+output, without cache traffic.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const stats = @import("../core/stats.zig");

const log = std.log.scoped(.claude_stats);

const max_file_bytes = 8 * 1024 * 1024;
pub const max_top_models = 3;

pub const ModelTokens = struct {
    model: []const u8,
    tokens: u64,
};

pub const Week = struct {
    start_day_key: i32,
    messages: u64 = 0,
    sessions: u64 = 0,
    tool_calls: u64 = 0,
    tokens_total: u64 = 0,
    /// Heaviest models this week, tokens descending.
    top_models: []ModelTokens = &.{},
};

pub const DayTokens = struct {
    day_key: i32,
    models: []ModelTokens,
};

pub const Summary = struct {
    available: bool = false,
    /// Newest week first.
    weeks: []Week = &.{},
    /// Trailing days of per-model tokens (newest first), for limit windows.
    recent_days: []DayTokens = &.{},
    total_sessions: u64 = 0,
    total_messages: u64 = 0,
    first_session_date: []const u8 = "",
    last_computed_date: []const u8 = "",
};

/// One configured weekly budget and the tokens consumed against it.
pub const LimitBar = struct {
    label: []const u8,
    used: u64,
    budget: u64,
};

const WeekAccum = struct {
    messages: u64 = 0,
    sessions: u64 = 0,
    tool_calls: u64 = 0,
    tokens_total: u64 = 0,
    models: std.StringHashMapUnmanaged(u64) = .empty,
};

/// Arena-owned weekly summary; `.available == false` when the cache file is
/// missing or unreadable (claudiusz keeps working without it).
pub fn load(arena: Allocator, io: Io, root: []const u8, max_weeks: usize) Summary {
    const path = std.fs.path.join(arena, &.{ root, "stats-cache.json" }) catch |err| {
        log.debug("stats cache path allocation failed: {s}", .{@errorName(err)});
        return .{};
    };
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| {
        if (err != error.FileNotFound) log.debug("cannot read {s}: {s}", .{ path, @errorName(err) });
        return .{};
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| {
        log.debug("malformed {s}: {s}", .{ path, @errorName(err) });
        return .{};
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return .{},
    };
    return build(arena, obj, max_weeks) catch |err| {
        log.debug("stats cache aggregation failed: {s}", .{@errorName(err)});
        return .{};
    };
}

/// How many trailing days of per-model tokens survive into `recent_days`.
const recent_day_window = 8;

fn build(arena: Allocator, obj: std.json.ObjectMap, max_weeks: usize) Allocator.Error!Summary {
    var by_week: std.AutoArrayHashMapUnmanaged(i32, WeekAccum) = .empty;
    var by_day: std.AutoArrayHashMapUnmanaged(i32, std.StringHashMapUnmanaged(u64)) = .empty;

    if (arrayAt(obj, "dailyActivity")) |days| {
        for (days.items) |item| {
            const day = objectOf(item) orelse continue;
            const day_key = dayKeyFromDateString(stringAt(day, "date")) orelse continue;
            const accum = try accumFor(arena, &by_week, stats.weekStart(day_key));
            accum.messages += uintAt(day, "messageCount");
            accum.sessions += uintAt(day, "sessionCount");
            accum.tool_calls += uintAt(day, "toolCallCount");
        }
    }
    if (arrayAt(obj, "dailyModelTokens")) |days| {
        for (days.items) |item| {
            const day = objectOf(item) orelse continue;
            const day_key = dayKeyFromDateString(stringAt(day, "date")) orelse continue;
            const models = switch (day.get("tokensByModel") orelse continue) {
                .object => |o| o,
                else => continue,
            };
            const accum = try accumFor(arena, &by_week, stats.weekStart(day_key));
            const day_gop = try by_day.getOrPut(arena, day_key);
            if (!day_gop.found_existing) day_gop.value_ptr.* = .empty;
            var it = models.iterator();
            while (it.next()) |entry| {
                const tokens = uintOf(entry.value_ptr.*);
                accum.tokens_total += tokens;
                const gop = try accum.models.getOrPut(arena, entry.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += tokens;
                const dgop = try day_gop.value_ptr.getOrPut(arena, entry.key_ptr.*);
                if (!dgop.found_existing) dgop.value_ptr.* = 0;
                dgop.value_ptr.* += tokens;
            }
        }
    }

    const keys = try arena.dupe(i32, by_week.keys());
    std.sort.pdq(i32, keys, {}, std.sort.desc(i32));
    const week_count = @min(keys.len, max_weeks);
    const weeks = try arena.alloc(Week, week_count);
    for (keys[0..week_count], 0..) |key, i| {
        const accum = by_week.getPtr(key).?;
        weeks[i] = .{
            .start_day_key = key,
            .messages = accum.messages,
            .sessions = accum.sessions,
            .tool_calls = accum.tool_calls,
            .tokens_total = accum.tokens_total,
            .top_models = try topModels(arena, &accum.models),
        };
    }

    var day_keys = try arena.dupe(i32, by_day.keys());
    std.sort.pdq(i32, day_keys, {}, std.sort.desc(i32));
    const day_count = @min(day_keys.len, recent_day_window);
    const recent_days = try arena.alloc(DayTokens, day_count);
    for (day_keys[0..day_count], 0..) |key, i| {
        var models = by_day.getPtr(key).?;
        var rows = try arena.alloc(ModelTokens, models.count());
        var it = models.iterator();
        var n: usize = 0;
        while (it.next()) |entry| : (n += 1) {
            rows[n] = .{ .model = entry.key_ptr.*, .tokens = entry.value_ptr.* };
        }
        recent_days[i] = .{ .day_key = key, .models = rows };
    }

    return .{
        .available = true,
        .weeks = weeks,
        .recent_days = recent_days,
        .total_sessions = uintAt(obj, "totalSessions"),
        .total_messages = uintAt(obj, "totalMessages"),
        .first_session_date = datePart(stringAt(obj, "firstSessionDate")),
        .last_computed_date = datePart(stringAt(obj, "lastComputedDate")),
    };
}

fn topModels(arena: Allocator, models: *std.StringHashMapUnmanaged(u64)) Allocator.Error![]ModelTokens {
    var rows = try arena.alloc(ModelTokens, models.count());
    var it = models.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        rows[i] = .{ .model = entry.key_ptr.*, .tokens = entry.value_ptr.* };
    }
    std.sort.pdq(ModelTokens, rows, {}, tokensDesc);
    return rows[0..@min(rows.len, max_top_models)];
}

fn tokensDesc(_: void, a: ModelTokens, b: ModelTokens) bool {
    if (a.tokens != b.tokens) return a.tokens > b.tokens;
    return std.mem.lessThan(u8, a.model, b.model);
}

fn accumFor(
    arena: Allocator,
    by_week: *std.AutoArrayHashMapUnmanaged(i32, WeekAccum),
    week_key: i32,
) Allocator.Error!*WeekAccum {
    const gop = try by_week.getOrPut(arena, week_key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// Reads the user's weekly budgets from `<root>/claudiusz.json` and computes
/// tokens consumed against each. Returns an empty slice when the config is
/// absent (e.g. enterprise plans without weekly limits) — the caller then
/// simply shows nothing.
///
/// Config shape:
///   { "weekly_limits": { "all": 12000000, "fable": 6000000 },
///     "week_reset_day": "thu" }
/// Keys are model-id substrings ("all" matches everything); values are weekly
/// input+output token budgets, calibrated by the user against /usage.
pub fn loadLimits(arena: Allocator, io: Io, root: []const u8, summary: Summary) []LimitBar {
    if (!summary.available or summary.recent_days.len == 0) return &.{};
    const path = std.fs.path.join(arena, &.{ root, "claudiusz.json" }) catch return &.{};
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| {
        if (err != error.FileNotFound) log.debug("cannot read {s}: {s}", .{ path, @errorName(err) });
        return &.{};
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| {
        log.warn("malformed {s}: {s}", .{ path, @errorName(err) });
        return &.{};
    };
    const obj = objectOf(parsed) orelse return &.{};
    const limits = objectOf(obj.get("weekly_limits") orelse return &.{}) orelse return &.{};

    const newest_day = summary.recent_days[0].day_key;
    const window_start = windowStart(newest_day, stringAt(obj, "week_reset_day"));

    var bars: std.ArrayList(LimitBar) = .empty;
    var it = limits.iterator();
    while (it.next()) |entry| {
        const budget = uintOf(entry.value_ptr.*);
        if (budget == 0) continue;
        var used: u64 = 0;
        for (summary.recent_days) |day| {
            if (day.day_key < window_start) continue;
            for (day.models) |model| {
                const matches = std.mem.eql(u8, entry.key_ptr.*, "all") or
                    std.mem.indexOf(u8, model.model, entry.key_ptr.*) != null;
                if (matches) used += model.tokens;
            }
        }
        bars.append(arena, .{ .label = entry.key_ptr.*, .used = used, .budget = budget }) catch return bars.items;
    }
    return bars.items;
}

/// First day of the current limit window: the most recent occurrence of the
/// configured reset weekday, or a trailing 7 days when none is configured.
fn windowStart(newest_day: i32, reset_day: []const u8) i32 {
    const weekday_names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
    for (weekday_names, 0..) |name, target| {
        if (std.ascii.startsWithIgnoreCase(reset_day, name)) {
            const weekday = @mod(newest_day + 3, 7);
            return newest_day - @mod(weekday - @as(i32, @intCast(target)), 7);
        }
    }
    return newest_day - 6;
}

/// Parses the "YYYY-MM-DD" prefix of a date string into a day key.
fn dayKeyFromDateString(text: []const u8) ?i32 {
    if (text.len < 10 or text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u4, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u5, text[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return stats.dayKeyFromYmd(year, month, day);
}

fn datePart(text: []const u8) []const u8 {
    return text[0..@min(text.len, 10)];
}

fn objectOf(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn arrayAt(obj: std.json.ObjectMap, name: []const u8) ?std.json.Array {
    return switch (obj.get(name) orelse return null) {
        .array => |a| a,
        else => null,
    };
}

fn stringAt(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    return switch (obj.get(name) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn uintAt(obj: std.json.ObjectMap, name: []const u8) u64 {
    return uintOf(obj.get(name) orelse return 0);
}

fn uintOf(value: std.json.Value) u64 {
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const claude_dirs = @import("claude_dirs.zig");

test "load groups daily stats into weeks with top models" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try claude_dirs.makePathForTest(tmp.dir, io, "root");
    // 2026-07-06 is a Monday; 2026-07-05 (Sunday) belongs to the prior week.
    try tmp.dir.writeFile(io, .{ .sub_path = "root/stats-cache.json", .data =
        \\{
        \\  "version": 4,
        \\  "lastComputedDate": "2026-07-07",
        \\  "firstSessionDate": "2025-12-24T07:32:29.051Z",
        \\  "totalSessions": 11,
        \\  "totalMessages": 222,
        \\  "dailyActivity": [
        \\    {"date": "2026-07-05", "messageCount": 10, "sessionCount": 1, "toolCallCount": 4},
        \\    {"date": "2026-07-06", "messageCount": 20, "sessionCount": 2, "toolCallCount": 6},
        \\    {"date": "2026-07-07", "messageCount": 30, "sessionCount": 1, "toolCallCount": 9}
        \\  ],
        \\  "dailyModelTokens": [
        \\    {"date": "2026-07-05", "tokensByModel": {"claude-opus-4-8": 100}},
        \\    {"date": "2026-07-06", "tokensByModel": {"claude-opus-4-8": 500, "claude-fable-5": 2000}},
        \\    {"date": "2026-07-07", "tokensByModel": {"claude-fable-5": 1000}}
        \\  ]
        \\}
    });
    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const summary = load(arena_state.allocator(), io, root, 8);

    try testing.expect(summary.available);
    try testing.expectEqual(@as(u64, 11), summary.total_sessions);
    try testing.expectEqualStrings("2025-12-24", summary.first_session_date);
    try testing.expectEqualStrings("2026-07-07", summary.last_computed_date);

    try testing.expectEqual(@as(usize, 2), summary.weeks.len);
    const current = summary.weeks[0];
    try testing.expectEqual(stats.dayKeyFromYmd(2026, 7, 6), current.start_day_key);
    try testing.expectEqual(@as(u64, 50), current.messages);
    try testing.expectEqual(@as(u64, 3), current.sessions);
    try testing.expectEqual(@as(u64, 15), current.tool_calls);
    try testing.expectEqual(@as(u64, 3500), current.tokens_total);
    try testing.expectEqual(@as(usize, 2), current.top_models.len);
    try testing.expectEqualStrings("claude-fable-5", current.top_models[0].model);
    try testing.expectEqual(@as(u64, 3000), current.top_models[0].tokens);

    const previous = summary.weeks[1];
    try testing.expectEqual(@as(u64, 10), previous.messages);
    try testing.expectEqual(@as(u64, 100), previous.tokens_total);
}

test "loadLimits fills bars from configured budgets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try claude_dirs.makePathForTest(tmp.dir, io, "root");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/stats-cache.json", .data =
        \\{
        \\  "dailyModelTokens": [
        \\    {"date": "2026-07-06", "tokensByModel": {"claude-fable-5": 3000, "claude-opus-4-8": 1000}},
        \\    {"date": "2026-07-07", "tokensByModel": {"claude-fable-5": 2000}}
        \\  ]
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/claudiusz.json", .data =
        \\{"weekly_limits": {"all": 10000, "fable": 5000}, "week_reset_day": "mon"}
    });
    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const summary = load(arena, io, root, 8);
    const bars = loadLimits(arena, io, root, summary);

    try testing.expectEqual(@as(usize, 2), bars.len);
    try testing.expectEqualStrings("all", bars[0].label);
    // 2026-07-07 is a Tuesday, so a Monday reset covers both days.
    try testing.expectEqual(@as(u64, 6000), bars[0].used);
    try testing.expectEqual(@as(u64, 10000), bars[0].budget);
    try testing.expectEqualStrings("fable", bars[1].label);
    try testing.expectEqual(@as(u64, 5000), bars[1].used);
}

test "loadLimits without config or data returns nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try claude_dirs.makePathForTest(tmp.dir, io, "root");
    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const summary = load(arena, io, root, 8);
    try testing.expectEqual(@as(usize, 0), loadLimits(arena, io, root, summary).len);
}

test "missing stats cache is not an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const summary = load(arena_state.allocator(), testing.io, "/nonexistent", 8);
    try testing.expect(!summary.available);
    try testing.expectEqual(@as(usize, 0), summary.weeks.len);
}
