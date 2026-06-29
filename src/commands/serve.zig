const std = @import("std");
const builtin = @import("builtin");
const term = @import("../term.zig");
const ip = @import("ip.zig");
const qr = @import("qr/render.zig");
const gio = @import("../io.zig");
const Ctx = @import("../command.zig").Ctx;

const Dir = std.Io.Dir;
const net = std.Io.net;

/// Default port when none is given, matching `python -m http.server`.
pub const DEFAULT_PORT: u16 = 8000;

/// Pick the port from the CLI args (first bare number), else the default.
pub fn resolveServePort(args: []const []const u8, fallback: u16) u16 {
    for (args) |a| {
        if (a.len == 0) continue;
        var all_digits = true;
        for (a) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;
        const n = std.fmt.parseInt(u32, a, 10) catch continue;
        if (n >= 1 and n <= 65535) return @intCast(n);
        return fallback;
    }
    return fallback;
}

pub const ServeUrls = struct {
    local: []u8,
    network: ?[]u8,

    pub fn deinit(self: *ServeUrls, gpa: std.mem.Allocator) void {
        gpa.free(self.local);
        if (self.network) |n| gpa.free(n);
    }
};

/// The URLs the server is reachable at — localhost plus the LAN IPv4.
pub fn serveUrls(gpa: std.mem.Allocator, port: u16, interfaces: ip.InterfacesFn) !ServeUrls {
    const entries = try ip.getLocalIps(gpa, interfaces);
    defer ip.freeEntries(gpa, entries);
    const lan = ip.getLocalIpv4(entries);
    return .{
        .local = try std.fmt.allocPrint(gpa, "http://localhost:{d}", .{port}),
        .network = if (lan) |l| try std.fmt.allocPrint(gpa, "http://{s}:{d}", .{ l.address, port }) else null,
    };
}

// ---------------------------------------------------------------------------
// Request handling (kept free of sockets so it is unit-testable).
// ---------------------------------------------------------------------------

pub const Response = struct {
    status: u16,
    content_type: []const u8,
    body: []u8, // owned by gpa

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

fn notFound(gpa: std.mem.Allocator) !Response {
    return .{ .status = 404, .content_type = "text/plain", .body = try gpa.dupe(u8, "Not Found") };
}

fn escapeHtml(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            '"' => try out.appendSlice(gpa, "&quot;"),
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Minimal URI-encode for hrefs: keep path-safe chars, percent-encode the rest.
fn encodeUri(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-_.!~*'()", c) != null) {
            try out.append(gpa, c);
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0xf]);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn percentDecode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(gpa, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(gpa, s[i]);
                continue;
            };
            try out.append(gpa, hi * 16 + lo);
            i += 2;
        } else {
            try out.append(gpa, s[i]);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Normalize a URL path by resolving `.`/`..` segments, clamped at the root so
/// traversal can never escape (mirrors the WHATWG URL normalization the TS
/// handler relied on). Returns a clean relative path with no leading slash.
fn normalizePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0) _ = segs.pop();
            continue;
        }
        try segs.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", segs.items);
}

/// Handle a GET for `url_path` against `root`, returning a Response.
pub fn handleRequest(gpa: std.mem.Allocator, root: []const u8, url_path: []const u8) !Response {
    const io = gio.get();
    const cwd = Dir.cwd();

    const decoded = try percentDecode(gpa, url_path);
    defer gpa.free(decoded);
    const clean = try normalizePath(gpa, decoded);
    defer gpa.free(clean);

    const target = if (clean.len == 0)
        try gpa.dupe(u8, root)
    else
        try std.fs.path.join(gpa, &.{ root, clean });
    defer gpa.free(target);

    const stat = cwd.statFile(io, target, .{}) catch return notFound(gpa);

    if (stat.kind == .directory) {
        const index_path = try std.fs.path.join(gpa, &.{ target, "index.html" });
        defer gpa.free(index_path);
        if (cwd.statFile(io, index_path, .{})) |istat| {
            if (istat.kind == .file) {
                const body = cwd.readFileAlloc(io, index_path, gpa, .limited(1 << 30)) catch return notFound(gpa);
                return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = body };
            }
        } else |_| {}
        return directoryListing(gpa, target, url_path);
    }

    const body = cwd.readFileAlloc(io, target, gpa, .limited(1 << 30)) catch return notFound(gpa);
    return .{ .status = 200, .content_type = contentTypeFor(target), .body = body };
}

const DirEntry = struct { name: []u8, is_dir: bool };

fn directoryListing(gpa: std.mem.Allocator, dir_path: []const u8, url_path: []const u8) !Response {
    const io = gio.get();
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return notFound(gpa);
    defer dir.close(io);

    var entries: std.ArrayList(DirEntry) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        try entries.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .is_dir = e.kind == .directory });
    }
    // Directories first, then alphabetical.
    std.mem.sort(DirEntry, entries.items, {}, struct {
        fn lt(_: void, a: DirEntry, b: DirEntry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    const title_path = try escapeHtml(gpa, url_path);
    defer gpa.free(title_path);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("<!doctype html><html><head><meta charset=\"utf-8\"><title>Directory listing for {s}</title></head>\n", .{title_path});
    try w.print("<body><h1>Directory listing for {s}</h1><ul>", .{title_path});

    const base = if (std.mem.endsWith(u8, url_path, "/")) url_path else try std.fmt.allocPrint(gpa, "{s}/", .{url_path});
    const base_owned = !std.mem.endsWith(u8, url_path, "/");
    defer if (base_owned) gpa.free(base);

    if (!std.mem.eql(u8, url_path, "/")) {
        const up = try std.fmt.allocPrint(gpa, "{s}..", .{base});
        defer gpa.free(up);
        const href = try encodeUri(gpa, up);
        defer gpa.free(href);
        try w.print("<li><a href=\"{s}\">../</a></li>", .{href});
    }
    for (entries.items) |e| {
        const display = if (e.is_dir) try std.fmt.allocPrint(gpa, "{s}/", .{e.name}) else try gpa.dupe(u8, e.name);
        defer gpa.free(display);
        const link = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, display });
        defer gpa.free(link);
        const href = try encodeUri(gpa, link);
        defer gpa.free(href);
        const esc = try escapeHtml(gpa, display);
        defer gpa.free(esc);
        try w.print("<li><a href=\"{s}\">{s}</a></li>", .{ href, esc });
    }
    try w.writeAll("</ul></body></html>");

    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = try aw.toOwnedSlice() };
}

fn contentTypeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".pdf", "application/pdf" },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, ext, m[0])) return m[1];
    }
    return "application/octet-stream";
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        else => "Internal Server Error",
    };
}

// ---------------------------------------------------------------------------
// HTTP server + interactive view.
// ---------------------------------------------------------------------------

const ServerState = struct {
    server: net.Server,
    root: []const u8,
    gpa: std.mem.Allocator,
    running: std.atomic.Value(bool),

    fn acceptLoop(self: *ServerState) void {
        const io = gio.get();
        while (self.running.load(.acquire)) {
            const stream = self.server.accept(io) catch break;
            self.handleConn(io, stream);
        }
    }

    fn handleConn(self: *ServerState, io: std.Io, stream: net.Stream) void {
        defer stream.close(io);
        var rbuf: [8192]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const line = sr.interface.takeDelimiterInclusive('\n') catch return;

        var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r\n"), ' ');
        _ = parts.next(); // method
        const raw_path = parts.next() orelse "/";
        const path = raw_path[0 .. std.mem.indexOfScalar(u8, raw_path, '?') orelse raw_path.len];

        var res = handleRequest(self.gpa, self.root, path) catch return;
        defer res.deinit(self.gpa);

        var wbuf: [8192]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const w = &sw.interface;
        w.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
            res.status, statusText(res.status), res.content_type, res.body.len,
        }) catch return;
        w.writeAll(res.body) catch return;
        w.flush() catch return;
    }
};

pub fn render(ctx: *Ctx) anyerror!void {
    const io = gio.get();
    const port = resolveServePort(ctx.args, DEFAULT_PORT);
    const root = try gio.cwdAlloc(ctx.gpa);
    defer ctx.gpa.free(root);

    var addr = net.IpAddress.parse("0.0.0.0", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
        defer aw.deinit();
        try aw.writer.print("{s}Could not start server on port {d}: {s}{s}\n", .{ term.fg_red, port, @errorName(err), term.reset });
        ctx.term.writeAll(aw.written());
        return;
    };

    var state = ServerState{
        .server = server,
        .root = root,
        .gpa = ctx.gpa,
        .running = std.atomic.Value(bool).init(true),
    };
    const thread = try std.Thread.spawn(.{}, ServerState.acceptLoop, .{&state});

    // Status screen + a QR for the network URL.
    var urls = try serveUrls(ctx.gpa, port, ip.realInterfaces);
    defer urls.deinit(ctx.gpa);
    const qr_target = urls.network orelse urls.local;

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{s}{s}Serving {s}{s}\n\n", .{ term.bold, term.fg_green, term.reset, root });
    try w.print("{s}Local{s}     {s}{s}{s}\n", .{ term.dim, term.reset, term.fg_cyan, urls.local, term.reset });
    if (urls.network) |net_url| {
        try w.print("{s}Network{s}   {s}{s}{s}\n", .{ term.dim, term.reset, term.fg_cyan, net_url, term.reset });
    }
    if (qr.toQrLines(ctx.gpa, qr_target, .{})) |lines| {
        defer qr.freeLines(ctx.gpa, lines);
        try w.print("\n{s}Scan to open on your phone ({s}):{s}\n\n", .{ term.dim, qr_target, term.reset });
        for (lines) |line| try w.print("{s}\n", .{line});
    } else |_| {}
    const can_read = ctx.term.isInteractive();
    try w.print("\n{s}Press {s} to stop.{s}\n", .{ term.dim, if (can_read) "Esc" else "Ctrl-C", term.reset });
    ctx.term.writeAll(aw.written());

    if (can_read) {
        try ctx.term.enableRaw();
        defer ctx.term.restore();
        while (true) {
            const key = try ctx.term.readKey();
            switch (key) {
                .escape, .ctrl_c => break,
                else => {},
            }
        }
        state.running.store(false, .release);
        // Unblock accept() by connecting to ourselves, then tear down.
        if (net.IpAddress.connect(&addr, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        thread.join();
        server.deinit(io);
    } else {
        thread.join();
    }
}
