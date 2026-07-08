//! Command-line interface: argument parsing and usage text.

const std = @import("std");

pub const Command = enum { tui, serve, tail };

pub const Options = struct {
    command: Command = .tui,
    /// Claude config root override (--root). Null means "<HOME>/.claude".
    root: ?[]const u8 = null,
    port: u16 = 8899,
    /// Replay full history instead of starting at end of files (tail only).
    from_start: bool = false,
    /// Skip the index snapshot cache; always rebuild from transcripts.
    no_cache: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

pub const Error = error{InvalidArguments};

pub const usage =
    \\claudiusz — real-time observability for Claude Code
    \\
    \\Usage:
    \\  claudiusz [command] [options]
    \\
    \\Commands:
    \\  (none)   Run the TUI with the HTTP API (default)
    \\  serve    Run headless: HTTP API only
    \\  tail     Print the normalized live event stream to stdout
    \\
    \\Options:
    \\  --root <dir>    Claude config root to watch (default: ~/.claude).
    \\                  Run one instance per root for isolated stats.
    \\  --port <port>   HTTP API port (default: 8899)
    \\  --from-start    tail: replay existing transcripts before following
    \\  --no-cache      Rebuild the index from transcripts, ignoring the
    \\                  startup snapshot cache
    \\  -h, --help      Show this help
    \\  -V, --version   Show version
    \\
;

/// Parses process arguments (including argv[0]). Prints nothing; the caller
/// decides how to render help/version/errors.
pub fn parse(args: []const [:0]const u8) Error!Options {
    var options = Options{};
    var i: usize = 1;
    var command_seen = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.show_help = true;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            options.show_version = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            options.root = try takeValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const value = try takeValue(args, &i);
            options.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--from-start")) {
            options.from_start = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            options.no_cache = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArguments;
        } else if (!command_seen) {
            options.command = std.meta.stringToEnum(Command, arg) orelse return error.InvalidArguments;
            command_seen = true;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

fn takeValue(args: []const [:0]const u8, i: *usize) Error![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.InvalidArguments;
    return args[i.*];
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "defaults to tui command" {
    const args = [_][:0]const u8{"claudiusz"};
    const options = try parse(&args);
    try testing.expectEqual(Command.tui, options.command);
    try testing.expectEqual(@as(u16, 8899), options.port);
    try testing.expectEqual(@as(?[]const u8, null), options.root);
}

test "parses command, root and port" {
    const args = [_][:0]const u8{ "claudiusz", "tail", "--root", "/tmp/enterprise", "--port", "8900", "--from-start" };
    const options = try parse(&args);
    try testing.expectEqual(Command.tail, options.command);
    try testing.expectEqualStrings("/tmp/enterprise", options.root.?);
    try testing.expectEqual(@as(u16, 8900), options.port);
    try testing.expect(options.from_start);
}

test "rejects unknown flags, commands and missing values" {
    const unknown_flag = [_][:0]const u8{ "claudiusz", "--bogus" };
    try testing.expectError(error.InvalidArguments, parse(&unknown_flag));
    const unknown_command = [_][:0]const u8{ "claudiusz", "dance" };
    try testing.expectError(error.InvalidArguments, parse(&unknown_command));
    const missing_value = [_][:0]const u8{ "claudiusz", "--root" };
    try testing.expectError(error.InvalidArguments, parse(&missing_value));
    const bad_port = [_][:0]const u8{ "claudiusz", "--port", "banana" };
    try testing.expectError(error.InvalidArguments, parse(&bad_port));
}

test "help and version flags" {
    const help_args = [_][:0]const u8{ "claudiusz", "--help" };
    try testing.expect((try parse(&help_args)).show_help);
    const version_args = [_][:0]const u8{ "claudiusz", "-V" };
    try testing.expect((try parse(&version_args)).show_version);
}
