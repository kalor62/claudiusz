//! CLI entry point. All real logic lives in the `claudiusz` library module.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const claudiusz = @import("claudiusz");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{ .logFn = logToFd };

/// Where log lines go: stderr (fd 2) normally, a file once the TUI owns the
/// terminal — raw-mode escape output and stderr text cannot share a screen.
var log_fd = std.atomic.Value(i32).init(2);

pub const tui_log_path = "/tmp/claudiusz-tui.log";

fn logToFd(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{s}({s}): " ++ format ++ "\n",
        .{ level.asText(), @tagName(scope) } ++ args,
    ) catch return;
    if (builtin.os.tag == .windows) {
        std.debug.print("{s}", .{line});
        return;
    }
    const fd = log_fd.load(.acquire);
    var rest: []const u8 = line;
    while (rest.len > 0) {
        const written = std.c.write(fd, rest.ptr, rest.len);
        if (written <= 0) return;
        rest = rest[@intCast(written)..];
    }
}

fn redirectLogsToFile() void {
    if (builtin.os.tag == .windows) return;
    const fd = std.c.open(tui_log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    log_fd.store(fd, .release);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const options = claudiusz.cli.parse(args) catch {
        printToStderr(io, claudiusz.cli.usage);
        std.process.exit(2);
    };
    if (options.show_help) return printToStdout(io, claudiusz.cli.usage);
    if (options.show_version) {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "claudiusz {s}\n", .{claudiusz.version}) catch unreachable;
        return printToStdout(io, line);
    }

    const cfg = claudiusz.config.resolve(arena, init.environ_map, options) catch |err| switch (err) {
        error.HomeNotSet => {
            printToStderr(io, "error: HOME is not set; pass --root <dir> explicitly\n");
            std.process.exit(2);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    switch (options.command) {
        .tail => try runTail(init.gpa, io, cfg, options.from_start),
        .serve => try runServe(init.gpa, io, cfg),
        .tui => try runTui(init.gpa, io, cfg),
    }
}

fn runServe(gpa: std.mem.Allocator, io: Io, cfg: claudiusz.config.Config) !void {
    const daemon = try gpa.create(claudiusz.daemon.Daemon);
    defer gpa.destroy(daemon);
    try daemon.init(gpa, io, cfg);
    defer daemon.deinit();

    const collector = try daemon.startCollector();
    collector.detach();
    try daemon.serveHttp();
}

fn runTui(gpa: std.mem.Allocator, io: Io, cfg: claudiusz.config.Config) !void {
    if (@import("builtin").os.tag == .windows) {
        printToStderr(io, "error: the TUI needs a POSIX terminal; on Windows use `claudiusz serve` with an external frontend\n");
        std.process.exit(1);
    }
    redirectLogsToFile();

    const daemon = try gpa.create(claudiusz.daemon.Daemon);
    try daemon.init(gpa, io, cfg);
    const collector = try daemon.startCollector();
    const http_thread = try std.Thread.spawn(.{}, serveHttpLogged, .{daemon});
    http_thread.detach();

    var app = try claudiusz.tui.app.App.init(gpa, daemon);
    const run_result = app.run();
    app.deinit();

    daemon.stop();
    collector.join();
    try run_result;
    // Detached HTTP threads may still hold the daemon; let process exit
    // reclaim everything instead of freeing memory under their feet.
    std.process.exit(0);
}

fn serveHttpLogged(daemon: *claudiusz.daemon.Daemon) void {
    daemon.serveHttp() catch |err| {
        log.err("HTTP API stopped: {s}", .{@errorName(err)});
    };
}

fn runTail(gpa: std.mem.Allocator, io: Io, cfg: claudiusz.config.Config, from_start: bool) !void {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var printer = EventPrinter{
        .gpa = gpa,
        .out = &stdout_writer.interface,
        .color = Io.File.stdout().isTty(io) catch false,
    };

    var watcher = claudiusz.Watcher.init(gpa, io, cfg.root, .{ .start_at_end = !from_start });
    defer watcher.deinit();

    log.info("watching {s} (poll every {d} ms)", .{ cfg.root, cfg.poll_interval_ms });
    while (true) {
        try watcher.tick(&printer);
        printer.out.flush() catch |err| log.debug("stdout flush failed: {s}", .{@errorName(err)});
        io.sleep(.fromMilliseconds(@intCast(cfg.poll_interval_ms)), .awake) catch |err| {
            log.debug("sleep interrupted: {s}", .{@errorName(err)});
            return;
        };
    }
}

/// Formats normalized events as single lines for `claudiusz tail`.
const EventPrinter = struct {
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    color: bool,

    pub fn onLine(p: *EventPrinter, path: []const u8, line: []const u8) void {
        _ = path;
        const events = claudiusz.parser.parseLine(p.gpa, line) catch |err| {
            log.warn("out of memory while parsing a transcript line: {s}", .{@errorName(err)});
            return;
        };
        defer claudiusz.event.freeEvents(p.gpa, events);
        for (events) |*e| {
            p.printEvent(e) catch |err| {
                log.debug("stdout write failed: {s}", .{@errorName(err)});
                return;
            };
        }
    }

    fn printEvent(p: *EventPrinter, e: *const claudiusz.event.Event) Io.Writer.Error!void {
        var clock_buf: [8]u8 = undefined;
        const clock = claudiusz.time.formatClock(&clock_buf, e.timestamp_ms);
        const project = if (e.cwd.len > 0) std.fs.path.basename(e.cwd) else "-";
        const side = if (e.is_sidechain) "*" else " ";

        try p.out.print("{s} {s: <20}{s} {s}{s: <14}{s} ", .{
            clock,
            project,
            side,
            p.kindColor(e),
            e.kindName(),
            if (p.color) reset_color else "",
        });
        switch (e.payload) {
            .prompt => |v| try printText(p.out, v.text, v.truncated),
            .assistant_text => |v| try printText(p.out, v.text, v.truncated),
            .tool_call => |v| try p.out.print("{s} {s}", .{ v.name, v.detail }),
            .tool_result => |v| {
                const status = if (v.ok) |ok| (if (ok) "ok" else "FAILED") else "?";
                try p.out.print("[{s}] ", .{status});
                try printText(p.out, v.summary, false);
            },
            .usage => |v| try p.out.print("{s} in={d} out={d} cache_read={d} cache_create={d}", .{
                v.model, v.tokens.input, v.tokens.output, v.tokens.cache_read, v.tokens.cache_creation,
            }),
            .meta => |v| try p.out.print("{s}={s}", .{ @tagName(v.kind), v.value }),
            .system => |v| {
                try p.out.print("{s}", .{v.subtype});
                if (v.duration_ms) |d| try p.out.print(" {d}ms", .{d});
            },
            .unknown => |v| try p.out.print("type={s}", .{v.record_type}),
        }
        try p.out.writeAll("\n");
    }

    const reset_color = "\x1b[0m";

    fn kindColor(p: *const EventPrinter, e: *const claudiusz.event.Event) []const u8 {
        if (!p.color) return "";
        return switch (e.payload) {
            .prompt => "\x1b[1;36m", // bold cyan
            .assistant_text => "\x1b[32m", // green
            .tool_call => "\x1b[33m", // yellow
            .tool_result => |v| if (v.ok == false) "\x1b[1;31m" else "\x1b[2;33m",
            .usage => "\x1b[35m", // magenta
            .meta, .system => "\x1b[2m", // dim
            .unknown => "\x1b[31m", // red
        };
    }

    /// Prints text with newlines flattened so one event stays one line.
    fn printText(out: *Io.Writer, text: []const u8, truncated: bool) Io.Writer.Error!void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try out.writeAll(rest[0..nl]);
            try out.writeAll(" ⏎ ");
            rest = rest[nl + 1 ..];
        }
        try out.writeAll(rest);
        if (truncated) try out.writeAll("…");
    }
};

fn printToStdout(io: Io, text: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    writeAllFlushLogged(&writer.interface, text, "stdout");
}

fn printToStderr(io: Io, text: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    writeAllFlushLogged(&writer.interface, text, "stderr");
}

fn writeAllFlushLogged(writer: *Io.Writer, text: []const u8, stream_name: []const u8) void {
    writer.writeAll(text) catch |err| {
        log.debug("{s} write failed: {s}", .{ stream_name, @errorName(err) });
        return;
    };
    writer.flush() catch |err| log.debug("{s} flush failed: {s}", .{ stream_name, @errorName(err) });
}

test {
    std.testing.refAllDecls(@This());
}
