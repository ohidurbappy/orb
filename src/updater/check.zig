const std = @import("std");
const net = @import("../net.zig");
const semver = @import("../semver.zig");
const version = @import("../version.zig");
const types = @import("types.zig");

pub const ReleaseAsset = types.ReleaseAsset;
pub const UpdateResult = types.UpdateResult;

fn latestReleaseUrl(gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa, "https://api.github.com/repos/{s}/releases/latest", .{version.REPO});
}

fn noUpdate(gpa: std.mem.Allocator, current: []const u8) !UpdateResult {
    return .{
        .has_update = false,
        .current = try gpa.dupe(u8, current),
        .latest = null,
        .url = null,
        .assets = try gpa.alloc(ReleaseAsset, 0),
    };
}

/// Query GitHub for the latest release and compare it to `current_version`.
/// Network/parse errors surface a "no update" result rather than erroring —
/// update checks must never break the command the user actually ran.
pub fn checkForUpdate(gpa: std.mem.Allocator, fetchFn: net.FetchFn, current_version: []const u8) !UpdateResult {
    const url = try latestReleaseUrl(gpa);
    defer gpa.free(url);

    const ua = try std.fmt.allocPrint(gpa, "orb/{s}", .{current_version});
    defer gpa.free(ua);

    var res = fetchFn(gpa, url, .{ .headers = &.{
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "User-Agent", .value = ua },
    } }) catch return noUpdate(gpa, current_version);
    defer res.deinit(gpa);
    if (!res.ok) return noUpdate(gpa, current_version);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, res.body, .{}) catch
        return noUpdate(gpa, current_version);
    defer parsed.deinit();
    if (parsed.value != .object) return noUpdate(gpa, current_version);
    const obj = parsed.value.object;

    const tag = strField(obj, "tag_name") orelse return noUpdate(gpa, current_version);
    const cleaned = semver.clean(tag) orelse return noUpdate(gpa, current_version);
    if (!semver.valid(cleaned)) return noUpdate(gpa, current_version);

    var assets: std.ArrayList(ReleaseAsset) = .empty;
    errdefer {
        for (assets.items) |a| {
            gpa.free(a.name);
            gpa.free(a.browser_download_url);
        }
        assets.deinit(gpa);
    }
    if (obj.get("assets")) |av| {
        if (av == .array) {
            for (av.array.items) |item| {
                if (item != .object) continue;
                const ao = item.object;
                const name = strField(ao, "name") orelse continue;
                const durl = strField(ao, "browser_download_url") orelse continue;
                const size: u64 = if (ao.get("size")) |s| (if (s == .integer) @intCast(s.integer) else 0) else 0;
                try assets.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                    .browser_download_url = try gpa.dupe(u8, durl),
                    .size = size,
                });
            }
        }
    }

    return .{
        .has_update = semver.gt(cleaned, current_version),
        .current = try gpa.dupe(u8, current_version),
        .latest = try gpa.dupe(u8, cleaned),
        .url = if (strField(obj, "html_url")) |h| try gpa.dupe(u8, h) else null,
        .assets = try assets.toOwnedSlice(gpa),
    };
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
