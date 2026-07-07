//! Reads live Claude Code process state from `<root>/sessions/<pid>.json`.
//! Claude Code heartbeats these files while a session runs; combined with a
//! pid liveness check they answer "is the agent working, waiting, or idle?".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const index_mod = @import("../core/index.zig");
const session_mod = @import("../core/session.zig");

const log = std.log.scoped(.liveness);

const max_state_file_bytes = 64 * 1024;
/// A "running" process whose heartbeat went stale is considered idle.
pub const idle_after_ms: i64 = 90_000;

/// Scans `<root>/sessions` and returns live state for sessions whose process
/// is actually alive. Results are arena-owned.
pub fn scan(arena: Allocator, io: Io, root: []const u8, now_ms: i64) Allocator.Error![]index_mod.LiveState {
    var states: std.ArrayList(index_mod.LiveState) = .empty;

    const sessions_path = try std.fs.path.join(arena, &.{ root, "sessions" });
    var dir = Io.Dir.cwd().openDir(io, sessions_path, .{ .iterate = true }) catch |err| {
        log.debug("cannot open {s}: {s}", .{ sessions_path, @errorName(err) });
        return states.toOwnedSlice(arena);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| {
        log.debug("iteration failed in {s}: {s}", .{ sessions_path, @errorName(err) });
        return states.toOwnedSlice(arena);
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const state = parseStateFile(arena, io, dir, entry.name, now_ms) orelse continue;
        try states.append(arena, state);
    }
    return states.toOwnedSlice(arena);
}

fn parseStateFile(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    now_ms: i64,
) ?index_mod.LiveState {
    const bytes = dir.readFileAlloc(io, name, arena, .limited(max_state_file_bytes)) catch |err| {
        log.debug("cannot read session state {s}: {s}", .{ name, @errorName(err) });
        return null;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| {
        log.debug("malformed session state {s}: {s}", .{ name, @errorName(err) });
        return null;
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    const session_id = stringAt(obj, "sessionId") orelse return null;
    const pid = intAt(obj, "pid") orelse return null;
    if (!processAlive(pid)) return null;

    const raw_status = stringAt(obj, "status") orelse "";
    const waiting_for = stringAt(obj, "waitingFor") orelse "";
    const updated_at = intAt(obj, "updatedAt") orelse 0;

    return .{
        .session_id = session_id,
        .status = mapStatus(raw_status, updated_at, now_ms),
        .waiting_for = waiting_for,
        .pid = pid,
        .updated_at_ms = updated_at,
    };
}

/// Claude Code v2.1 writes `status: busy|idle|waiting|shell` (older builds:
/// `running`). Unknown values — and a stale "working" heartbeat — degrade to
/// idle rather than misleading the user with a confident wrong answer.
fn mapStatus(raw: []const u8, updated_at_ms: i64, now_ms: i64) session_mod.Status {
    if (std.mem.eql(u8, raw, "waiting")) return .waiting_for_user;
    if (std.mem.eql(u8, raw, "busy") or std.mem.eql(u8, raw, "running")) {
        if (updated_at_ms > 0 and now_ms - updated_at_ms > idle_after_ms) return .idle;
        return .working;
    }
    return .idle;
}

fn processAlive(pid: i64) bool {
    if (pid <= 0) return false;
    return switch (@import("builtin").os.tag) {
        .windows => windowsProcessAlive(pid),
        else => posixProcessAlive(pid),
    };
}

fn posixProcessAlive(pid: i64) bool {
    const posix_pid = std.math.cast(std.posix.pid_t, pid) orelse return false;
    // Signal 0 performs the permission/existence check without delivering anything.
    std.posix.kill(posix_pid, @enumFromInt(0)) catch |err| switch (err) {
        // EPERM: the process exists but belongs to someone else — alive.
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

const win = if (@import("builtin").os.tag == .windows) struct {
    const windows = std.os.windows;
    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: windows.DWORD,
        bInheritHandle: windows.BOOL,
        dwProcessId: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
} else struct {};

fn windowsProcessAlive(pid: i64) bool {
    const raw_pid = std.math.cast(std.os.windows.DWORD, pid) orelse return false;
    const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, raw_pid) orelse return false;
    _ = win.CloseHandle(handle);
    return true;
}

fn stringAt(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn intAt(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (obj.get(name) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const claude_dirs = @import("claude_dirs.zig");

test "scan reports alive sessions and maps statuses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try claude_dirs.makePathForTest(tmp.dir, io, "root/sessions");

    // Our own pid is definitely alive; 99999999 is beyond macOS/Linux pid ranges.
    const my_pid: i64 = switch (@import("builtin").os.tag) {
        .windows => win.GetCurrentProcessId(),
        else => std.c.getpid(),
    };
    var buf: [512]u8 = undefined;
    const alive = try std.fmt.bufPrint(
        &buf,
        \\{{"pid":{d},"sessionId":"live-1","status":"waiting","waitingFor":"permission prompt","updatedAt":1000}}
    ,
        .{my_pid},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "root/sessions/1.json", .data = alive });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/sessions/2.json", .data =
        \\{"pid":99999999,"sessionId":"dead-1","status":"running","updatedAt":1000}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/sessions/3.json", .data = "not json at all" });

    const root = try tmp.dir.realPathFileAlloc(io, "root", testing.allocator);
    defer testing.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const states = try scan(arena_state.allocator(), io, root, 2000);
    try testing.expectEqual(@as(usize, 1), states.len);
    try testing.expectEqualStrings("live-1", states[0].session_id);
    try testing.expectEqual(session_mod.Status.waiting_for_user, states[0].status);
    try testing.expectEqualStrings("permission prompt", states[0].waiting_for);
}

test "mapStatus degrades stale running heartbeat to idle" {
    try testing.expectEqual(session_mod.Status.working, mapStatus("busy", 1000, 1000 + idle_after_ms));
    try testing.expectEqual(session_mod.Status.working, mapStatus("running", 1000, 1000 + idle_after_ms));
    try testing.expectEqual(session_mod.Status.idle, mapStatus("busy", 1000, 1000 + idle_after_ms + 1));
    try testing.expectEqual(session_mod.Status.waiting_for_user, mapStatus("waiting", 0, 0));
    try testing.expectEqual(session_mod.Status.idle, mapStatus("shell", 0, 0));
    try testing.expectEqual(session_mod.Status.idle, mapStatus("someday-new-status", 0, 0));
}
