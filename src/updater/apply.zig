const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;
const net = @import("../net.zig");
const gio = @import("../io.zig");
const check = @import("check.zig");
const assets = @import("assets.zig");
const refresh = @import("refresh.zig");

pub const Phase = enum { checking, downloading, installing };
pub const UpdateProgress = struct { phase: Phase, total_bytes: ?u64 = null };
pub const ProgressFn = *const fn (UpdateProgress) void;

pub const Status = enum { updated, up_to_date, unsupported, no_asset, err };

pub const ApplyOutcome = struct {
    status: Status,
    message: []const u8, // owned by gpa

    pub fn deinit(self: *const ApplyOutcome, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
    }
};

fn noop(_: UpdateProgress) void {}

/// Download the release asset for this platform and atomically replace the
/// running binary. Returns a structured outcome; never throws fatally.
pub fn applyUpdate(gpa: std.mem.Allocator, fetchFn: net.FetchFn, onProgress: ProgressFn) !ApplyOutcome {
    onProgress(.{ .phase = .checking });
    const result = check.checkForUpdate(gpa, fetchFn, @import("../version.zig").VERSION) catch
        return outcome(gpa, .err, "Update check failed.");
    defer result.deinit(gpa);

    if (!result.has_update or result.latest == null) {
        return outcomeFmt(gpa, .up_to_date, "Already on the latest version ({s}).", .{result.current});
    }

    const asset = assets.findAsset(result.assets, assets.currentPlatform(), assets.currentArch()) orelse
        return outcomeFmt(gpa, .no_asset, "No release asset for {s}/{s} in {s}.", .{ assets.currentPlatform(), assets.currentArch(), result.latest.? });

    onProgress(.{ .phase = .downloading, .total_bytes = asset.size });
    var res = fetchFn(gpa, asset.browser_download_url, .{ .headers = &.{
        .{ .name = "Accept", .value = "application/octet-stream" },
        .{ .name = "User-Agent", .value = "orb-updater" },
    } }) catch return outcome(gpa, .err, "Download failed.");
    defer res.deinit(gpa);
    if (!res.ok) return outcomeFmt(gpa, .err, "Download failed: HTTP {d}", .{res.status});

    // Release assets are gzipped; decompress back to the raw executable.
    var in = std.Io.Reader.fixed(res.body);
    var win: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in, .gzip, &win);
    const bytes = dec.reader.allocRemaining(gpa, .unlimited) catch
        return outcome(gpa, .err, "Failed to decompress update.");
    defer gpa.free(bytes);

    onProgress(.{ .phase = .installing });
    const target = refresh.exePathAlloc(gpa) catch return outcome(gpa, .err, "Could not locate the running binary.");
    defer gpa.free(target);

    const io = gio.get();
    const cwd = std.Io.Dir.cwd();
    const tmp = try std.fmt.allocPrintSentinel(gpa, "{s}.new", .{target}, 0);
    defer gpa.free(tmp);

    cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes }) catch
        return outcome(gpa, .err, "Could not write the new binary.");
    if (builtin.os.tag != .windows) {
        _ = std.c.chmod(tmp.ptr, 0o755);
    }

    if (builtin.os.tag == .windows) {
        const old = try std.fmt.allocPrint(gpa, "{s}.old", .{target});
        defer gpa.free(old);
        cwd.deleteFile(io, old) catch {};
        cwd.rename(target, cwd, old, io) catch return outcome(gpa, .err, "Could not replace the binary.");
        cwd.rename(tmp, cwd, target, io) catch return outcome(gpa, .err, "Could not replace the binary.");
    } else {
        cwd.rename(tmp, cwd, target, io) catch return outcome(gpa, .err, "Could not replace the binary.");
    }

    return outcomeFmt(gpa, .updated, "Updated to {s}. Restart orb to use the new version.", .{result.latest.?});
}

fn outcome(gpa: std.mem.Allocator, status: Status, msg: []const u8) !ApplyOutcome {
    return .{ .status = status, .message = try gpa.dupe(u8, msg) };
}
fn outcomeFmt(gpa: std.mem.Allocator, status: Status, comptime fmt: []const u8, args: anytype) !ApplyOutcome {
    return .{ .status = status, .message = try std.fmt.allocPrint(gpa, fmt, args) };
}

pub const defaultProgress: ProgressFn = noop;
