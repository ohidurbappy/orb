const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net.zig");
const gio = @import("../io.zig");
const version = @import("../version.zig");
const check = @import("check.zig");
const state = @import("state.zig");

/// The compiled Zig binary is always a real executable (there is no `bun run`
/// equivalent), so self-update is always supported. Kept for parity with the
/// previous design / applyUpdate's guard.
pub fn isCompiled() bool {
    return true;
}

/// Absolute path to the running executable. Caller owns the result.
pub fn exePathAlloc(gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (builtin.os.tag == .macos) {
        var size: u32 = buf.len;
        if (std.c._NSGetExecutablePath(&buf, &size) != 0) return error.PathTooLong;
        return gpa.dupe(u8, std.mem.sliceTo(&buf, 0));
    }
    if (builtin.os.tag == .linux) {
        const len = try std.Io.Dir.readLinkAbsolute(gio.get(), "/proc/self/exe", &buf);
        return gpa.dupe(u8, buf[0..len]);
    }
    return error.Unsupported;
}

/// Perform a check and persist the result. Used by the hidden refresh command.
pub fn runRefresh(gpa: std.mem.Allocator) !void {
    const result = try check.checkForUpdate(gpa, net.fetch, version.VERSION);
    defer result.deinit(gpa);
    state.writeState(gpa, .{ .last_check = gio.nowMillis(), .result = result });
}

/// Fire a detached child to refresh the update cache, then return immediately so
/// a one-shot command never blocks on the network. No-op when the cache is fresh.
pub fn spawnBackgroundRefresh(gpa: std.mem.Allocator, argv0: []const u8, now: i64) void {
    const cached = state.readState(gpa);
    defer if (cached) |c| state.freeState(gpa, c);
    if (!state.isStale(cached, now)) return;

    const exe = exePathAlloc(gpa) catch gpa.dupe(u8, argv0) catch return;
    defer gpa.free(exe);

    var child = std.process.spawn(gio.get(), .{
        .argv = &.{ exe, "__refresh-update" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // Detach: don't wait. The child outlives us and refreshes the cache.
    _ = &child;
}
