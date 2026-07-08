//! USD cost estimation for token usage. Claude Code transcripts carry no
//! cost field, so rates per million tokens are keyed off model-id substrings.

const std = @import("std");
const Tokens = @import("event.zig").Tokens;

pub const Rate = struct {
    /// Substring matched against the model id; first match wins.
    needle: []const u8,
    input_per_mtok: f64,
    output_per_mtok: f64,
};

const cache_read_factor = 0.1;
const cache_write_factor = 1.25;

// Legacy $15/$75 Opus ids must precede the generic $5/$25 "opus" needle.
const rates = [_]Rate{
    .{ .needle = "fable", .input_per_mtok = 10, .output_per_mtok = 50 },
    .{ .needle = "mythos", .input_per_mtok = 10, .output_per_mtok = 50 },
    .{ .needle = "opus-4-1", .input_per_mtok = 15, .output_per_mtok = 75 },
    .{ .needle = "opus-4-2025", .input_per_mtok = 15, .output_per_mtok = 75 },
    .{ .needle = "opus-3", .input_per_mtok = 15, .output_per_mtok = 75 },
    .{ .needle = "3-opus", .input_per_mtok = 15, .output_per_mtok = 75 },
    .{ .needle = "opus", .input_per_mtok = 5, .output_per_mtok = 25 },
    .{ .needle = "sonnet", .input_per_mtok = 3, .output_per_mtok = 15 },
    .{ .needle = "haiku", .input_per_mtok = 1, .output_per_mtok = 5 },
};

pub fn rateFor(model: []const u8) ?Rate {
    for (rates) |rate| {
        if (std.mem.indexOf(u8, model, rate.needle) != null) return rate;
    }
    return null;
}

/// Estimated USD cost of the usage, or null for unknown models.
pub fn costUsd(model: []const u8, tokens: Tokens) ?f64 {
    const rate = rateFor(model) orelse return null;
    const input: f64 = @floatFromInt(tokens.input);
    const output: f64 = @floatFromInt(tokens.output);
    const cache_read: f64 = @floatFromInt(tokens.cache_read);
    const cache_write: f64 = @floatFromInt(tokens.cache_creation);
    const input_side = input + cache_read * cache_read_factor + cache_write * cache_write_factor;
    return (input_side * rate.input_per_mtok + output * rate.output_per_mtok) / 1_000_000.0;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "rateFor matches tiers with legacy opus precedence" {
    try testing.expectEqual(@as(f64, 5), rateFor("claude-opus-4-8").?.input_per_mtok);
    try testing.expectEqual(@as(f64, 15), rateFor("claude-opus-4-1-20250805").?.input_per_mtok);
    try testing.expectEqual(@as(f64, 10), rateFor("claude-fable-5").?.input_per_mtok);
    try testing.expectEqual(@as(f64, 3), rateFor("claude-sonnet-5").?.input_per_mtok);
    try testing.expectEqual(@as(f64, 1), rateFor("claude-haiku-4-5-20251001").?.input_per_mtok);
    try testing.expectEqual(@as(?Rate, null), rateFor("gpt-x"));
}

test "costUsd folds cache reads and writes into the input side" {
    const cost = costUsd("claude-opus-4-8", .{
        .input = 1_000_000,
        .output = 1_000_000,
        .cache_read = 1_000_000,
        .cache_creation = 1_000_000,
    }).?;
    // 5 + 25 + 0.5 + 6.25
    try testing.expectApproxEqAbs(@as(f64, 36.75), cost, 0.0001);
    try testing.expectEqual(@as(?f64, null), costUsd("", .{ .output = 5 }));
}
