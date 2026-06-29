const std = @import("std");
const builtin = @import("builtin");

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

/// Directory for orb's persisted state, per platform (env-paths equivalent).
pub fn configDirAlloc(gpa: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home = getenv("HOME") orelse return error.NoHome;
            return std.fmt.allocPrint(gpa, "{s}/Library/Preferences/orb", .{home});
        },
        .windows => {
            const appdata = getenv("APPDATA") orelse return error.NoAppData;
            return std.fmt.allocPrint(gpa, "{s}\\orb", .{appdata});
        },
        else => {
            if (getenv("XDG_CONFIG_HOME")) |xdg| {
                return std.fmt.allocPrint(gpa, "{s}/orb", .{xdg});
            }
            const home = getenv("HOME") orelse return error.NoHome;
            return std.fmt.allocPrint(gpa, "{s}/.config/orb", .{home});
        },
    }
}

/// Path to the cached update-check result.
pub fn stateFileAlloc(gpa: std.mem.Allocator) ![]u8 {
    const dir = try configDirAlloc(gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "state.json" });
}
