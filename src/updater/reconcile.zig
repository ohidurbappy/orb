const std = @import("std");
const semver = @import("../semver.zig");
const version = @import("../version.zig");
const types = @import("types.zig");

pub const UpdateResult = types.UpdateResult;

/// Re-derive the update verdict against the version actually running. The cache
/// may have been written by a different (older) binary, so its frozen
/// `has_update`/`current` can't be trusted — only `latest`/`url`/`assets` are
/// reused. Mutates `result` in place (replacing `current`).
pub fn reconcile(gpa: std.mem.Allocator, result: *UpdateResult) !void {
    gpa.free(result.current);
    result.current = try gpa.dupe(u8, version.VERSION);
    result.has_update = if (result.latest) |l|
        (semver.valid(l) and semver.gt(l, version.VERSION))
    else
        false;
}
