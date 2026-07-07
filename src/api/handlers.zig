//! HTTP API: translates the index into JSON responses and pumps the SSE
//! stream. Transport (sockets, connection threads) lives in infra/http.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const index_mod = @import("../core/index.zig");
const broadcast = @import("../infra/broadcast.zig");

const log = std.log.scoped(.api);

const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "access-control-allow-origin", .value = "*" },
};

const sse_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "access-control-allow-origin", .value = "*" },
};

pub const Handlers = struct {
    gpa: Allocator,
    index: *index_mod.Index,
    broadcaster: *broadcast.Broadcaster,
    version: []const u8,

    /// Serves one request. Transport errors propagate (the connection is
    /// dead); handler-level problems become HTTP error responses.
    pub fn handle(h: *Handlers, io: Io, request: *std.http.Server.Request) !void {
        const target = request.head.target;
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. query_start orelse target.len];
        const query = if (query_start) |i| target[i + 1 ..] else "";

        if (request.head.method != .GET) {
            return request.respond("{\"error\":\"method not allowed\"}\n", .{
                .status = .method_not_allowed,
                .extra_headers = &json_headers,
            });
        }
        if (std.mem.eql(u8, path, "/api/stream")) return h.serveStream(io, request);

        var arena_state = std.heap.ArenaAllocator.init(h.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const body = h.routeJson(io, arena, path, query) catch |err| switch (err) {
            error.OutOfMemory => return request.respond("{\"error\":\"out of memory\"}\n", .{
                .status = .internal_server_error,
                .extra_headers = &json_headers,
            }),
        } orelse return request.respond("{\"error\":\"not found\"}\n", .{
            .status = .not_found,
            .extra_headers = &json_headers,
        });
        try request.respond(body, .{ .extra_headers = &json_headers });
    }

    /// Returns the JSON body for `path`, or null for "no such route".
    fn routeJson(
        h: *Handlers,
        io: Io,
        arena: Allocator,
        path: []const u8,
        query: []const u8,
    ) Allocator.Error!?[]const u8 {
        if (std.mem.eql(u8, path, "/api/health")) {
            return try toJson(arena, .{ .status = "ok", .version = h.version });
        }
        if (std.mem.eql(u8, path, "/api/sessions")) {
            return try toJson(arena, try h.index.listSessions(io, arena));
        }
        const sessions_prefix = "/api/sessions/";
        if (std.mem.startsWith(u8, path, sessions_prefix)) {
            const rest = path[sessions_prefix.len..];
            if (std.mem.endsWith(u8, rest, "/tail")) {
                const id = rest[0 .. rest.len - "/tail".len];
                if (id.len == 0) return null;
                const limit = queryUint(query, "n") orelse 50;
                return try toJson(arena, try h.index.tailEvents(io, arena, id, @min(limit, 1000)));
            }
            if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
            const detail = (try h.index.sessionDetail(io, arena, rest)) orelse return null;
            return try toJson(arena, detail);
        }
        return null;
    }

    fn serveStream(h: *Handlers, io: Io, request: *std.http.Server.Request) !void {
        var send_buffer: [1024]u8 = undefined;
        var body = try request.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .transfer_encoding = .none,
                .extra_headers = &sse_headers,
            },
        });

        const sub = try h.broadcaster.subscribe(io);
        defer h.broadcaster.unsubscribe(io, sub);

        var hello_buf: [128]u8 = undefined;
        const hello = std.fmt.bufPrint(
            &hello_buf,
            "event: hello\ndata: {{\"version\":\"{s}\"}}\n\n",
            .{h.version},
        ) catch unreachable;
        try writeFrame(&body, hello);

        while (sub.next(io)) |frame| {
            defer h.gpa.free(frame);
            try writeFrame(&body, frame);
        }
    }
};

/// SSE frames must reach the socket immediately: drain the body buffer into
/// the HTTP output, then flush that to the network.
fn writeFrame(body: *std.http.BodyWriter, frame: []const u8) !void {
    try body.writer.writeAll(frame);
    try body.writer.flush();
    try body.flush();
}

fn toJson(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

fn queryUint(query: []const u8, name: []const u8) ?usize {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return std.fmt.parseInt(usize, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "queryUint extracts numeric parameters" {
    try testing.expectEqual(@as(?usize, 25), queryUint("a=1&n=25", "n"));
    try testing.expectEqual(@as(?usize, null), queryUint("n=abc", "n"));
    try testing.expectEqual(@as(?usize, null), queryUint("", "n"));
}

test "routeJson serves sessions, detail, tail and 404" {
    const io = testing.io;
    var ix = try index_mod.Index.init(testing.allocator, 8);
    defer ix.deinit();
    var broadcaster = broadcast.Broadcaster.init(testing.allocator);
    defer broadcaster.deinit(io);
    var handlers = Handlers{
        .gpa = testing.allocator,
        .index = &ix,
        .broadcaster = &broadcaster,
        .version = "test",
    };

    const parser = @import("../core/parser.zig");
    const line =
        \\{"type":"user","message":{"content":"hello api"},"timestamp":"2026-07-07T10:00:00Z","cwd":"/w/alpha","sessionId":"s1"}
    ;
    const events = try parser.parseLine(testing.allocator, line);
    defer testing.allocator.free(events);
    for (events) |e| try ix.applyEvent(io, e);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sessions_json = (try handlers.routeJson(io, arena, "/api/sessions", "")).?;
    try testing.expect(std.mem.indexOf(u8, sessions_json, "\"id\":\"s1\"") != null);
    try testing.expect(std.mem.indexOf(u8, sessions_json, "\"project\":\"alpha\"") != null);

    const detail_json = (try handlers.routeJson(io, arena, "/api/sessions/s1", "")).?;
    try testing.expect(std.mem.indexOf(u8, detail_json, "\"permission_mode\"") != null);

    const tail_json = (try handlers.routeJson(io, arena, "/api/sessions/s1/tail", "n=10")).?;
    try testing.expect(std.mem.indexOf(u8, tail_json, "\"kind\":\"prompt\"") != null);
    try testing.expect(std.mem.indexOf(u8, tail_json, "hello api") != null);

    try testing.expectEqual(@as(?[]const u8, null), try handlers.routeJson(io, arena, "/api/sessions/nope", ""));
    try testing.expectEqual(@as(?[]const u8, null), try handlers.routeJson(io, arena, "/api/bogus", ""));
    try testing.expect((try handlers.routeJson(io, arena, "/api/health", "")) != null);
}
