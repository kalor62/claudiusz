//! Loopback-only HTTP transport: accept loop and per-connection threads.
//! Request handling is delegated to `api.Handlers`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const api = @import("../api/handlers.zig");

const log = std.log.scoped(.http);

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    handlers: *api.Handlers,

    /// Blocks forever, accepting connections. Binds to 127.0.0.1 only —
    /// transcript contents must never be reachable from the network.
    pub fn serve(s: *Server) !void {
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", s.port) catch unreachable;
        var listener = address.listen(s.io, .{ .reuse_address = true }) catch |err| {
            log.err("cannot listen on 127.0.0.1:{d}: {s}", .{ s.port, @errorName(err) });
            return err;
        };
        defer listener.deinit(s.io);
        log.info("API listening on http://127.0.0.1:{d}", .{s.port});

        while (true) {
            const stream = listener.accept(s.io) catch |err| {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleConnection, .{ s, stream }) catch |err| {
                log.warn("cannot spawn connection thread: {s}", .{@errorName(err)});
                stream.close(s.io);
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        var recv_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(s.io, &recv_buffer);
        var writer = stream.writer(s.io, &send_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);

        while (true) {
            var request = http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    log.debug("closing connection: {s}", .{@errorName(err)});
                }
                return;
            };
            s.handlers.handle(s.io, &request) catch |err| {
                log.debug("request handling aborted: {s}", .{@errorName(err)});
                return;
            };
        }
    }
};
