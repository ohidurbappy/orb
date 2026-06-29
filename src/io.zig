const std = @import("std");

/// Process-wide blocking IO implementation, used for filesystem, socket, and
/// child-process operations that the 0.16 std requires an `Io` for.
///
/// `main` installs the runtime's `Io` (which has a real allocator — needed by
/// process spawning and other io operations) via `set`. When unset (e.g. in
/// tests), a lazily-created threaded instance backed by the page allocator is
/// used so those operations still work.
var configured: ?std.Io = null;
var fallback: ?std.Io.Threaded = null;

pub fn set(io: std.Io) void {
    configured = io;
}

pub fn get() std.Io {
    if (configured) |io| return io;
    if (fallback == null) fallback = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return fallback.?.io();
}

extern "c" fn time(t: ?*c_long) c_long;

/// Wall-clock seconds since the Unix epoch (libc time).
pub fn nowSeconds() i64 {
    return @intCast(time(null));
}

/// Wall-clock milliseconds since the Unix epoch (second precision is enough for
/// the update-check throttle).
pub fn nowMillis() i64 {
    return nowSeconds() * 1000;
}

/// The current working directory's absolute path (libc getcwd). Caller owns it.
pub fn cwdAlloc(gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) return error.GetCwdFailed;
    return gpa.dupe(u8, std.mem.sliceTo(&buf, 0));
}
