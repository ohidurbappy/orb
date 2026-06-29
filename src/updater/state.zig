const std = @import("std");
const gio = @import("../io.zig");
const paths = @import("paths.zig");
const types = @import("types.zig");

pub const UpdateResult = types.UpdateResult;

pub const UpdateState = struct {
    /// Epoch ms of the last completed check.
    last_check: i64,
    result: ?UpdateResult = null,
};

/// Re-check at most this often (10 minutes).
pub const CHECK_INTERVAL_MS: i64 = 10 * 60 * 1000;

/// True when the cache is missing or older than the interval.
pub fn isStale(state: ?UpdateState, now: i64) bool {
    const s = state orelse return true;
    return now - s.last_check >= CHECK_INTERVAL_MS;
}

/// Read and parse the cached state. Returns null on any error. Caller owns the
/// returned state's allocations (free with `freeState`).
pub fn readState(gpa: std.mem.Allocator) ?UpdateState {
    const path = paths.stateFileAlloc(gpa) catch return null;
    defer gpa.free(path);

    const body = std.Io.Dir.cwd().readFileAlloc(gio.get(), path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const last_check: i64 = if (obj.get("lastCheck")) |v| (if (v == .integer) v.integer else return null) else return null;

    var result: ?UpdateResult = null;
    if (obj.get("result")) |rv| {
        if (rv == .object) {
            const ro = rv.object;
            result = .{
                .has_update = if (ro.get("hasUpdate")) |x| (x == .bool and x.bool) else false,
                .current = dupeStr(gpa, ro, "current") orelse (gpa.dupe(u8, "") catch return null),
                .latest = dupeStr(gpa, ro, "latest"),
                .url = dupeStr(gpa, ro, "url"),
                .assets = gpa.alloc(types.ReleaseAsset, 0) catch return null,
            };
        }
    }
    return .{ .last_check = last_check, .result = result };
}

fn dupeStr(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return gpa.dupe(u8, v.string) catch null;
}

pub fn freeState(gpa: std.mem.Allocator, state: UpdateState) void {
    if (state.result) |r| r.deinit(gpa);
}

/// Persist the state (best-effort; never errors out the CLI).
pub fn writeState(gpa: std.mem.Allocator, state: UpdateState) void {
    const dir = paths.configDirAlloc(gpa) catch return;
    defer gpa.free(dir);
    const path = paths.stateFileAlloc(gpa) catch return;
    defer gpa.free(path);

    const io = gio.get();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("{{\"lastCheck\":{d}", .{state.last_check}) catch return;
    if (state.result) |r| {
        w.print(",\"result\":{{\"hasUpdate\":{},\"current\":\"{s}\"", .{ r.has_update, r.current }) catch return;
        if (r.latest) |l| w.print(",\"latest\":\"{s}\"", .{l}) catch return;
        if (r.url) |u| w.print(",\"url\":\"{s}\"", .{u}) catch return;
        w.writeAll("}") catch return;
    }
    w.writeAll("}") catch return;

    cwd.writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {};
}
