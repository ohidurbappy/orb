const std = @import("std");

pub const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
    size: u64,
};

/// Outcome of an update check. All slices are owned by the allocator passed to
/// the producing function; free with `deinit`.
pub const UpdateResult = struct {
    has_update: bool,
    current: []const u8,
    latest: ?[]const u8,
    url: ?[]const u8,
    assets: []const ReleaseAsset,

    pub fn deinit(self: *const UpdateResult, gpa: std.mem.Allocator) void {
        gpa.free(self.current);
        if (self.latest) |l| gpa.free(l);
        if (self.url) |u| gpa.free(u);
        for (self.assets) |a| {
            gpa.free(a.name);
            gpa.free(a.browser_download_url);
        }
        gpa.free(self.assets);
    }
};
