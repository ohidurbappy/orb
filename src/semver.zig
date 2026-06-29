const std = @import("std");

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
};

/// Strip surrounding whitespace and a single leading `v`/`=`, returning a slice
/// of `s` that looks like a bare version, or null when it isn't valid semver.
/// Mirrors the subset of `semver.clean` orb relies on.
pub fn clean(s: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len > 0 and (t[0] == 'v' or t[0] == 'V' or t[0] == '=')) t = t[1..];
    t = std.mem.trim(u8, t, " \t\r\n");
    if (parse(t) == null) return null;
    return t;
}

/// Parse `MAJOR.MINOR.PATCH` (ignoring any `-prerelease`/`+build` suffix).
pub fn parse(s: []const u8) ?Version {
    // Cut off prerelease/build metadata.
    var core = s;
    if (std.mem.indexOfAny(u8, core, "-+")) |i| core = core[0..i];

    var it = std.mem.splitScalar(u8, core, '.');
    const major = parseNum(it.next() orelse return null) orelse return null;
    const minor = parseNum(it.next() orelse return null) orelse return null;
    const patch = parseNum(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseNum(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

pub fn valid(s: []const u8) bool {
    return parse(s) != null;
}

/// True when `a` is a strictly greater version than `b`.
pub fn gt(a: []const u8, b: []const u8) bool {
    const va = parse(a) orelse return false;
    const vb = parse(b) orelse return false;
    if (va.major != vb.major) return va.major > vb.major;
    if (va.minor != vb.minor) return va.minor > vb.minor;
    return va.patch > vb.patch;
}

/// Increment the major version (resetting minor/patch). Allocated result.
pub fn incMajor(gpa: std.mem.Allocator, s: []const u8) !?[]u8 {
    const v = parse(s) orelse return null;
    return try std.fmt.allocPrint(gpa, "{d}.0.0", .{v.major + 1});
}
