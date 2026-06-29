const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub const ReleaseAsset = types.ReleaseAsset;

/// The release asset name expected for a platform/arch. Assets ship gzipped and
/// are gunzipped by `applyUpdate`. Must match the build script + release
/// workflow output names. Writes into `buf` and returns the slice, or null for
/// unsupported combinations.
pub fn assetNameFor(buf: []u8, platform: []const u8, arch: []const u8) ?[]const u8 {
    const os = if (std.mem.eql(u8, platform, "darwin"))
        "darwin"
    else if (std.mem.eql(u8, platform, "linux"))
        "linux"
    else if (std.mem.eql(u8, platform, "win32"))
        "windows"
    else
        return null;

    const cpu = if (std.mem.eql(u8, arch, "arm64"))
        "arm64"
    else if (std.mem.eql(u8, arch, "x64"))
        "x64"
    else
        return null;

    if (std.mem.eql(u8, os, "windows") and !std.mem.eql(u8, cpu, "x64")) return null; // only windows-x64

    if (std.mem.eql(u8, os, "windows")) {
        return std.fmt.bufPrint(buf, "orb-{s}-{s}.exe.gz", .{ os, cpu }) catch null;
    }
    return std.fmt.bufPrint(buf, "orb-{s}-{s}.gz", .{ os, cpu }) catch null;
}

pub fn currentPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    };
}

pub fn currentArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @tagName(builtin.cpu.arch),
    };
}

/// Find the asset matching `platform`/`arch` among `assets`, or null.
pub fn findAsset(assets: []const ReleaseAsset, platform: []const u8, arch: []const u8) ?ReleaseAsset {
    var buf: [64]u8 = undefined;
    const name = assetNameFor(&buf, platform, arch) orelse return null;
    for (assets) |a| {
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}
