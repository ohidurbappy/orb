const std = @import("std");

/// Result of an HTTP fetch. `body` is owned by the caller's allocator.
pub const FetchResult = struct {
    ok: bool,
    status: u16,
    body: []u8,

    pub fn deinit(self: *FetchResult, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub const FetchOptions = struct {
    headers: []const Header = &.{},
};

/// A fetch function. Real network code uses `fetch`; tests inject a fake to
/// exercise parsing/branching without touching the network (mirrors the TS DI).
pub const FetchFn = *const fn (gpa: std.mem.Allocator, url: []const u8, opts: FetchOptions) anyerror!FetchResult;

/// Perform a real HTTP(S) GET, collecting the body into an allocated buffer.
pub fn fetch(gpa: std.mem.Allocator, url: []const u8, opts: FetchOptions) anyerror!FetchResult {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(gpa);
    for (opts.headers) |h| {
        try extra.append(gpa, .{ .name = h.name, .value = h.value });
    }

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = extra.items,
        .response_writer = &body.writer,
    });

    const status: u16 = @intFromEnum(result.status);
    return .{
        .ok = status >= 200 and status < 300,
        .status = status,
        .body = try body.toOwnedSlice(),
    };
}
