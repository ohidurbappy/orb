const build_options = @import("build_options");

/// Version baked in at build time (see build.zig). CI sets it to the release tag.
pub const VERSION: []const u8 = build_options.version;

/// `owner/repo` used for release checks and downloads.
pub const REPO: []const u8 = build_options.repo;
