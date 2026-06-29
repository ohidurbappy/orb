const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net.zig");
const term = @import("../term.zig");
const Ctx = @import("../command.zig").Ctx;

pub const Family = enum {
    ipv4,
    ipv6,
    pub fn name(self: Family) []const u8 {
        return switch (self) {
            .ipv4 => "IPv4",
            .ipv6 => "IPv6",
        };
    }
};

pub const IpEntry = struct {
    iface: []const u8,
    address: []const u8,
    family: Family,
};

/// A raw interface address as reported by the OS (before internal filtering).
/// The injectable provider returns these so tests can pass fixtures.
pub const RawAddr = struct {
    iface: []const u8,
    address: []const u8,
    family: Family,
    internal: bool,
};

/// Provider of raw interface addresses (DI seam, like TS's `networkInterfaces`).
pub const InterfacesFn = *const fn (gpa: std.mem.Allocator) anyerror![]RawAddr;

/// Collect non-internal (loopback excluded) addresses for every interface.
/// Returned slice and its strings are owned by `gpa`.
pub fn getLocalIps(gpa: std.mem.Allocator, interfaces: InterfacesFn) ![]IpEntry {
    const raw = try interfaces(gpa);
    defer freeRaw(gpa, raw);

    var list: std.ArrayList(IpEntry) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.iface);
            gpa.free(e.address);
        }
        list.deinit(gpa);
    }
    for (raw) |addr| {
        if (addr.internal) continue;
        try list.append(gpa, .{
            .iface = try gpa.dupe(u8, addr.iface),
            .address = try gpa.dupe(u8, addr.address),
            .family = addr.family,
        });
    }
    return list.toOwnedSlice(gpa);
}

pub fn freeEntries(gpa: std.mem.Allocator, entries: []IpEntry) void {
    for (entries) |e| {
        gpa.free(e.iface);
        gpa.free(e.address);
    }
    gpa.free(entries);
}

fn freeRaw(gpa: std.mem.Allocator, raw: []RawAddr) void {
    for (raw) |a| {
        gpa.free(a.iface);
        gpa.free(a.address);
    }
    gpa.free(raw);
}

/// The single most useful "this machine's IP" — first non-internal IPv4, else
/// the first entry. Null when offline.
pub fn getPrimaryIp(entries: []const IpEntry) ?IpEntry {
    for (entries) |e| {
        if (e.family == .ipv4) return e;
    }
    return if (entries.len > 0) entries[0] else null;
}

/// The first non-internal IPv4 — this machine's address on the LAN.
pub fn getLocalIpv4(entries: []const IpEntry) ?IpEntry {
    for (entries) |e| {
        if (e.family == .ipv4) return e;
    }
    return null;
}

pub const IpFlags = struct {
    public: bool = false,
    local: bool = false,
};

pub fn parseIpFlags(args: []const []const u8) IpFlags {
    var flags: IpFlags = .{};
    for (args) |a| {
        if (std.mem.eql(u8, a, "--public") or std.mem.eql(u8, a, "-p")) flags.public = true;
        if (std.mem.eql(u8, a, "--local") or std.mem.eql(u8, a, "-l")) flags.local = true;
    }
    return flags;
}

/// Loose check that a string looks like an IPv4 or IPv6 address.
pub fn looksLikeIp(value: []const u8) bool {
    if (value.len == 0) return false;
    // IPv4: d{1,3}(.d{1,3}){3}
    var is_v4 = true;
    {
        var parts: usize = 0;
        var digits: usize = 0;
        for (value) |ch| {
            if (ch == '.') {
                if (digits == 0 or digits > 3) {
                    is_v4 = false;
                    break;
                }
                parts += 1;
                digits = 0;
            } else if (ch >= '0' and ch <= '9') {
                digits += 1;
            } else {
                is_v4 = false;
                break;
            }
        }
        if (is_v4 and (parts != 3 or digits == 0 or digits > 3)) is_v4 = false;
    }
    if (is_v4) return true;
    // IPv6-ish: only hex digits and colons.
    for (value) |ch| {
        const hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!hex and ch != ':') return false;
    }
    return true;
}

/// Fetch this machine's public IP from an external echo service. Returns null on
/// any network/parse error. `fetchFn` is injected for tests.
pub fn getPublicIp(gpa: std.mem.Allocator, fetchFn: net.FetchFn) !?[]u8 {
    var res = fetchFn(gpa, "https://api.ipify.org", .{}) catch return null;
    defer res.deinit(gpa);
    if (!res.ok) return null;
    const trimmed = std.mem.trim(u8, res.body, " \t\r\n");
    if (!looksLikeIp(trimmed)) return null;
    return try gpa.dupe(u8, trimmed);
}

pub const RunDeps = struct {
    interfaces: InterfacesFn = realInterfaces,
    fetchFn: net.FetchFn = net.fetch,
};

/// Plain-text handler for `orb ip`'s scripting flags. Returns an allocated
/// address to print, or null (no flag) to fall through to the interactive view.
/// Errors so the runner can exit non-zero. Caller frees the returned string.
pub fn runIp(gpa: std.mem.Allocator, args: []const []const u8, deps: RunDeps) !?[]u8 {
    const flags = parseIpFlags(args);

    if (flags.public) {
        const ip = try getPublicIp(gpa, deps.fetchFn);
        if (ip == null) return error.NoPublicIp;
        return ip;
    }

    if (flags.local) {
        const entries = try getLocalIps(gpa, deps.interfaces);
        defer freeEntries(gpa, entries);
        const ipv4 = getLocalIpv4(entries);
        if (ipv4 == null) return error.NoLanIpv4;
        return try gpa.dupe(u8, ipv4.?.address);
    }

    return null;
}

/// `run` entry: propagates clean errors that main maps to stderr messages.
pub fn run(ctx: *Ctx) anyerror!?[]const u8 {
    return runIp(ctx.gpa, ctx.args, .{});
}

/// Interactive/print render: list every interface with the primary highlighted.
pub fn render(ctx: *Ctx) anyerror!void {
    const entries = try getLocalIps(ctx.gpa, realInterfaces);
    defer freeEntries(ctx.gpa, entries);

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;

    if (entries.len == 0) {
        try w.print("{s}No non-internal network interfaces found.{s}\n", .{ term.fg_yellow, term.reset });
        ctx.term.writeAll(aw.written());
        return;
    }

    if (getPrimaryIp(entries)) |primary| {
        try w.print("{s}{s}Local IP: {s}{s}{s}{s} ({s}){s}\n\n", .{
            term.bold, term.fg_green, term.reset,
            term.bold, primary.address, term.reset,
            primary.iface,            term.reset,
        });
    }
    for (entries) |e| {
        try w.print("{s}{s: <10}{s}{s}{s: <6}{s}{s}\n", .{
            term.fg_cyan, e.iface,        term.reset,
            term.dim,     e.family.name(), term.reset,
            e.address,
        });
    }
    ctx.term.writeAll(aw.written());
}

// ---------------------------------------------------------------------------
// Real interface enumeration (getifaddrs on POSIX). Windows returns empty for
// now (degrades gracefully like an offline machine).
// ---------------------------------------------------------------------------

pub fn realInterfaces(gpa: std.mem.Allocator) ![]RawAddr {
    if (builtin.os.tag == .windows) return gpa.alloc(RawAddr, 0);
    return posixInterfaces(gpa);
}

const c = if (builtin.os.tag != .windows) @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("net/if.h");
    @cInclude("arpa/inet.h");
}) else struct {};

fn posixInterfaces(gpa: std.mem.Allocator) ![]RawAddr {
    var ifap: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return gpa.alloc(RawAddr, 0);
    defer c.freeifaddrs(ifap);

    var list: std.ArrayList(RawAddr) = .empty;
    errdefer freeRaw(gpa, list.toOwnedSlice(gpa) catch &.{});

    var it = ifap;
    while (it) |ifa| : (it = ifa.ifa_next) {
        const sa = ifa.ifa_addr orelse continue;
        const fam = sa.*.sa_family;
        const is_loopback = (ifa.ifa_flags & c.IFF_LOOPBACK) != 0;
        const name = std.mem.span(ifa.ifa_name);

        var addrbuf: [128]u8 = undefined;
        if (fam == c.AF_INET) {
            const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(sa));
            const p = c.inet_ntop(c.AF_INET, &sin.sin_addr, &addrbuf, addrbuf.len) orelse continue;
            try list.append(gpa, .{
                .iface = try gpa.dupe(u8, name),
                .address = try gpa.dupe(u8, std.mem.span(p)),
                .family = .ipv4,
                .internal = is_loopback,
            });
        } else if (fam == c.AF_INET6) {
            const sin6: *c.struct_sockaddr_in6 = @ptrCast(@alignCast(sa));
            const p = c.inet_ntop(c.AF_INET6, &sin6.sin6_addr, &addrbuf, addrbuf.len) orelse continue;
            try list.append(gpa, .{
                .iface = try gpa.dupe(u8, name),
                .address = try gpa.dupe(u8, std.mem.span(p)),
                .family = .ipv6,
                .internal = is_loopback,
            });
        }
    }
    return list.toOwnedSlice(gpa);
}
