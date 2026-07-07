//! Fan-out of serialized SSE frames from the collector to any number of
//! connected stream clients. Slow clients lose oldest frames instead of
//! stalling the collector.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.broadcast);

/// Frames a subscriber may buffer before oldest frames are dropped.
pub const max_queued_frames = 256;

pub const Broadcaster = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    subscribers: std.ArrayList(*Subscriber) = .empty,

    pub fn init(gpa: Allocator) Broadcaster {
        return .{ .gpa = gpa };
    }

    /// Destroys all remaining subscribers. Callers must guarantee no
    /// subscriber thread is still alive (the daemon stops publishers first
    /// and the TUI path exits the process instead of tearing down live SSE
    /// connections).
    pub fn deinit(b: *Broadcaster, io: Io) void {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        for (b.subscribers.items) |sub| {
            sub.close(io);
            sub.deinit();
            b.gpa.destroy(sub);
        }
        b.subscribers.deinit(b.gpa);
    }

    pub fn subscribe(b: *Broadcaster, io: Io) Allocator.Error!*Subscriber {
        const sub = try b.gpa.create(Subscriber);
        errdefer b.gpa.destroy(sub);
        sub.* = .{ .gpa = b.gpa };
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        try b.subscribers.append(b.gpa, sub);
        return sub;
    }

    /// Removes and destroys the subscriber. Only the owning connection
    /// thread may call this, after it stops reading the queue.
    pub fn unsubscribe(b: *Broadcaster, io: Io, sub: *Subscriber) void {
        b.mutex.lockUncancelable(io);
        for (b.subscribers.items, 0..) |candidate, i| {
            if (candidate == sub) {
                _ = b.subscribers.swapRemove(i);
                break;
            }
        }
        b.mutex.unlock(io);
        sub.deinit();
        b.gpa.destroy(sub);
    }

    /// Copies `frame` into every subscriber queue.
    pub fn publish(b: *Broadcaster, io: Io, frame: []const u8) void {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        for (b.subscribers.items) |sub| sub.push(io, frame);
    }
};

pub const Subscriber = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList([]const u8) = .empty,
    dropped_frames: u64 = 0,
    closed: bool = false,

    fn push(sub: *Subscriber, io: Io, frame: []const u8) void {
        const copy = sub.gpa.dupe(u8, frame) catch |err| {
            log.warn("dropping SSE frame, out of memory: {s}", .{@errorName(err)});
            return;
        };
        sub.mutex.lockUncancelable(io);
        defer sub.mutex.unlock(io);
        if (sub.closed) {
            sub.gpa.free(copy);
            return;
        }
        if (sub.queue.items.len >= max_queued_frames) {
            const oldest = sub.queue.orderedRemove(0);
            sub.gpa.free(oldest);
            sub.dropped_frames += 1;
        }
        sub.queue.append(sub.gpa, copy) catch |err| {
            log.warn("dropping SSE frame, queue append failed: {s}", .{@errorName(err)});
            sub.gpa.free(copy);
            return;
        };
        sub.cond.signal(io);
    }

    /// Blocks until a frame is available or the subscriber is closed.
    /// Caller owns the returned frame. Null means closed.
    pub fn next(sub: *Subscriber, io: Io) ?[]const u8 {
        sub.mutex.lockUncancelable(io);
        defer sub.mutex.unlock(io);
        while (sub.queue.items.len == 0) {
            if (sub.closed) return null;
            sub.cond.waitUncancelable(io, &sub.mutex);
        }
        return sub.queue.orderedRemove(0);
    }

    /// Wakes up any blocked `next` caller and refuses further frames.
    pub fn close(sub: *Subscriber, io: Io) void {
        sub.mutex.lockUncancelable(io);
        defer sub.mutex.unlock(io);
        sub.closed = true;
        sub.cond.broadcast(io);
    }

    fn deinit(sub: *Subscriber) void {
        for (sub.queue.items) |frame| sub.gpa.free(frame);
        sub.queue.deinit(sub.gpa);
        sub.* = undefined;
    }
};

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "publish fans out to subscribers and respects the queue cap" {
    const io = testing.io;
    var broadcaster = Broadcaster.init(testing.allocator);
    defer broadcaster.deinit(io);

    const sub = try broadcaster.subscribe(io);
    defer broadcaster.unsubscribe(io, sub);

    broadcaster.publish(io, "frame-1");
    broadcaster.publish(io, "frame-2");

    const first = sub.next(io).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("frame-1", first);
    const second = sub.next(io).?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("frame-2", second);

    for (0..max_queued_frames + 10) |_| broadcaster.publish(io, "flood");
    try testing.expectEqual(@as(u64, 10), sub.dropped_frames);
    try testing.expectEqual(@as(usize, max_queued_frames), sub.queue.items.len);
}

test "closed subscriber unblocks with null" {
    const io = testing.io;
    var broadcaster = Broadcaster.init(testing.allocator);
    defer broadcaster.deinit(io);

    const sub = try broadcaster.subscribe(io);
    defer broadcaster.unsubscribe(io, sub);
    sub.close(io);
    try testing.expectEqual(@as(?[]const u8, null), sub.next(io));
    broadcaster.publish(io, "after close");
    try testing.expectEqual(@as(usize, 0), sub.queue.items.len);
}
