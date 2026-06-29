// Aggregates every module so `zig build test` runs all `test` blocks, and holds
// the cross-module behavioral tests (ports of the original TS test suite).
const std = @import("std");
const testing = std.testing;

comptime {
    _ = @import("filter.zig");
    _ = @import("cli.zig");
    _ = @import("term.zig");
    _ = @import("net.zig");
    _ = @import("command.zig");
    _ = @import("version.zig");
    _ = @import("commands/ip.zig");
    _ = @import("commands/qr/encoder.zig");
    _ = @import("commands/qr/render.zig");
    _ = @import("commands/qr/types.zig");
    _ = @import("commands/sysinfo.zig");
    _ = @import("commands/serve.zig");
    _ = @import("registry.zig");
    _ = @import("semver.zig");
    _ = @import("updater/check.zig");
    _ = @import("updater/state.zig");
    _ = @import("updater/assets.zig");
    _ = @import("updater/reconcile.zig");
    _ = @import("commands/update.zig");
}

const cli = @import("cli.zig");
const filter = @import("filter.zig");
const command = @import("command.zig");
const ip = @import("commands/ip.zig");
const net = @import("net.zig");
const encoder = @import("commands/qr/encoder.zig");
const render = @import("commands/qr/render.zig");
const qrtypes = @import("commands/qr/types.zig");
const sysinfo = @import("commands/sysinfo.zig");
const serve = @import("commands/serve.zig");
const gio = @import("io.zig");
const registry = @import("registry.zig");
const semver = @import("semver.zig");
const check = @import("updater/check.zig");
const statemod = @import("updater/state.zig");
const assetsmod = @import("updater/assets.zig");
const reconcilemod = @import("updater/reconcile.zig");
const updatecmd = @import("commands/update.zig");
const applymod = @import("updater/apply.zig");
const version = @import("version.zig");
const utypes = @import("updater/types.zig");

fn noopRender(_: *command.Ctx) anyerror!void {}

fn cmd(name: []const u8, description: []const u8, aliases: []const []const u8) command.Command {
    return .{ .name = name, .description = description, .aliases = aliases, .render = noopRender };
}

// ---------------------------------------------------------------------------
// cli.parseArgs
// ---------------------------------------------------------------------------

test "parseArgs: command name" {
    var p = try cli.parseArgs(testing.allocator, &.{"ip"});
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("ip", p.command_name.?);
}

test "parseArgs: flags" {
    var p = try cli.parseArgs(testing.allocator, &.{"--version"});
    defer p.deinit(testing.allocator);
    try testing.expect(p.version);
    var p2 = try cli.parseArgs(testing.allocator, &.{"-h"});
    defer p2.deinit(testing.allocator);
    try testing.expect(p2.help);
}

test "parseArgs: first non-flag token is the command" {
    var p = try cli.parseArgs(testing.allocator, &.{ "--verbose", "sysinfo" });
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("sysinfo", p.command_name.?);
}

test "parseArgs: no command when only flags" {
    var p = try cli.parseArgs(testing.allocator, &.{});
    defer p.deinit(testing.allocator);
    try testing.expect(p.command_name == null);
}

test "parseArgs: collects positional tokens after the command" {
    var p = try cli.parseArgs(testing.allocator, &.{ "qr", "hello", "world" });
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("qr", p.command_name.?);
    try testing.expectEqual(@as(usize, 2), p.command_args.len);
    try testing.expectEqualStrings("hello", p.command_args[0]);
    try testing.expectEqualStrings("world", p.command_args[1]);
}

test "parseArgs: forwards flags after the command to command_args" {
    var p = try cli.parseArgs(testing.allocator, &.{ "ip", "--public" });
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("ip", p.command_name.?);
    try testing.expectEqual(@as(usize, 1), p.command_args.len);
    try testing.expectEqualStrings("--public", p.command_args[0]);
}

test "parseArgs: -h/-v stay global even after a command" {
    var p = try cli.parseArgs(testing.allocator, &.{ "ip", "--help" });
    defer p.deinit(testing.allocator);
    try testing.expect(p.help);
    var p2 = try cli.parseArgs(testing.allocator, &.{ "ip", "-v" });
    defer p2.deinit(testing.allocator);
    try testing.expect(p2.version);
}

// ---------------------------------------------------------------------------
// filter.fuzzyScore / filterCommands
// ---------------------------------------------------------------------------

test "fuzzyScore: empty query is 0" {
    try testing.expectEqual(@as(?i64, 0), filter.fuzzyScore("anything", ""));
}

test "fuzzyScore: non-subsequence is null" {
    try testing.expectEqual(@as(?i64, null), filter.fuzzyScore("ip", "xyz"));
}

test "fuzzyScore: matches subsequences" {
    try testing.expect(filter.fuzzyScore("sysinfo", "sfo") != null);
}

test "fuzzyScore: prefix scores higher than scattered" {
    const prefix = filter.fuzzyScore("sysinfo", "sys").?;
    const scattered = filter.fuzzyScore("sysinfo", "sfo").?;
    try testing.expect(prefix > scattered);
}

const test_commands = [_]command.Command{
    cmd("ip", "Print local IP address(es)", &.{"ipaddr"}),
    cmd("sysinfo", "Show system information (neofetch-style)", &.{ "sys", "neofetch" }),
    cmd("update", "Download and install the latest release", &.{"upgrade"}),
};

fn filteredNames(gpa: std.mem.Allocator, query: []const u8) ![][]const u8 {
    var out: [16]command.Command = undefined;
    const res = filter.filterCommands(&test_commands, query, &out);
    const names = try gpa.alloc([]const u8, res.len);
    for (res, 0..) |c, i| names[i] = c.name;
    return names;
}

test "filterCommands: empty query returns everything in order" {
    const names = try filteredNames(testing.allocator, "");
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("ip", names[0]);
    try testing.expectEqualStrings("sysinfo", names[1]);
    try testing.expectEqualStrings("update", names[2]);
}

test "filterCommands: filters by name" {
    const names = try filteredNames(testing.allocator, "sys");
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("sysinfo", names[0]);
}

test "filterCommands: matches aliases" {
    const a = try filteredNames(testing.allocator, "neofetch");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("sysinfo", a[0]);
    const b = try filteredNames(testing.allocator, "upgrade");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("update", b[0]);
}

test "filterCommands: matches description when name does not" {
    const names = try filteredNames(testing.allocator, "release");
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("update", names[0]);
}

test "filterCommands: name match ranks above description-only match" {
    const names = try filteredNames(testing.allocator, "in");
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("sysinfo", names[0]);
}

test "filterCommands: nothing matches" {
    const names = try filteredNames(testing.allocator, "zzzzz");
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

// ---------------------------------------------------------------------------
// ip
// ---------------------------------------------------------------------------

fn fixtureInterfaces(gpa: std.mem.Allocator) ![]ip.RawAddr {
    var list: std.ArrayList(ip.RawAddr) = .empty;
    try list.append(gpa, .{ .iface = try gpa.dupe(u8, "lo0"), .address = try gpa.dupe(u8, "127.0.0.1"), .family = .ipv4, .internal = true });
    try list.append(gpa, .{ .iface = try gpa.dupe(u8, "en0"), .address = try gpa.dupe(u8, "fe80::1"), .family = .ipv6, .internal = false });
    try list.append(gpa, .{ .iface = try gpa.dupe(u8, "en0"), .address = try gpa.dupe(u8, "192.168.1.5"), .family = .ipv4, .internal = false });
    return list.toOwnedSlice(gpa);
}

fn emptyInterfaces(gpa: std.mem.Allocator) ![]ip.RawAddr {
    return gpa.alloc(ip.RawAddr, 0);
}

fn ipv6OnlyInterfaces(gpa: std.mem.Allocator) ![]ip.RawAddr {
    var list: std.ArrayList(ip.RawAddr) = .empty;
    try list.append(gpa, .{ .iface = try gpa.dupe(u8, "en0"), .address = try gpa.dupe(u8, "fe80::1"), .family = .ipv6, .internal = false });
    return list.toOwnedSlice(gpa);
}

test "getLocalIps: excludes internal and returns both families" {
    const entries = try ip.getLocalIps(testing.allocator, fixtureInterfaces);
    defer ip.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("fe80::1", entries[0].address);
    try testing.expectEqual(ip.Family.ipv6, entries[0].family);
    try testing.expectEqualStrings("192.168.1.5", entries[1].address);
}

test "getLocalIps: handles no interfaces" {
    const entries = try ip.getLocalIps(testing.allocator, emptyInterfaces);
    defer ip.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "getPrimaryIp: prefers first IPv4" {
    const entries = try ip.getLocalIps(testing.allocator, fixtureInterfaces);
    defer ip.freeEntries(testing.allocator, entries);
    try testing.expectEqualStrings("192.168.1.5", ip.getPrimaryIp(entries).?.address);
}

test "getPrimaryIp: falls back to first entry without IPv4" {
    const entries = try ip.getLocalIps(testing.allocator, ipv6OnlyInterfaces);
    defer ip.freeEntries(testing.allocator, entries);
    try testing.expectEqual(ip.Family.ipv6, ip.getPrimaryIp(entries).?.family);
}

test "getPrimaryIp: null for empty list" {
    try testing.expect(ip.getPrimaryIp(&.{}) == null);
}

test "getLocalIpv4: ignores IPv6" {
    const entries = try ip.getLocalIps(testing.allocator, fixtureInterfaces);
    defer ip.freeEntries(testing.allocator, entries);
    try testing.expectEqualStrings("192.168.1.5", ip.getLocalIpv4(entries).?.address);
    const v6 = try ip.getLocalIps(testing.allocator, ipv6OnlyInterfaces);
    defer ip.freeEntries(testing.allocator, v6);
    try testing.expect(ip.getLocalIpv4(v6) == null);
}

test "parseIpFlags: defaults and forms" {
    try testing.expectEqual(ip.IpFlags{ .public = false, .local = false }, ip.parseIpFlags(&.{}));
    try testing.expectEqual(ip.IpFlags{ .public = true, .local = false }, ip.parseIpFlags(&.{"--public"}));
    try testing.expectEqual(ip.IpFlags{ .public = true, .local = false }, ip.parseIpFlags(&.{"-p"}));
    try testing.expectEqual(ip.IpFlags{ .public = false, .local = true }, ip.parseIpFlags(&.{"--local"}));
    try testing.expectEqual(ip.IpFlags{ .public = false, .local = true }, ip.parseIpFlags(&.{"-l"}));
}

// Fake fetch helpers for getPublicIp / runIp.
fn fetchOk(gpa: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
    return .{ .ok = true, .status = 200, .body = try gpa.dupe(u8, "203.0.113.7\n") };
}
fn fetchNotOk(gpa: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
    return .{ .ok = false, .status = 500, .body = try gpa.dupe(u8, "nope") };
}
fn fetchHtml(gpa: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
    return .{ .ok = true, .status = 200, .body = try gpa.dupe(u8, "<html>error</html>") };
}
fn fetchThrows(_: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
    return error.Offline;
}

test "getPublicIp: trims address on success" {
    const r = try ip.getPublicIp(testing.allocator, fetchOk);
    defer if (r) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("203.0.113.7", r.?);
}

test "getPublicIp: null on non-OK, non-IP, and throw" {
    try testing.expect(try ip.getPublicIp(testing.allocator, fetchNotOk) == null);
    try testing.expect(try ip.getPublicIp(testing.allocator, fetchHtml) == null);
    try testing.expect(try ip.getPublicIp(testing.allocator, fetchThrows) == null);
}

fn ipv4Only(gpa: std.mem.Allocator) ![]ip.RawAddr {
    var list: std.ArrayList(ip.RawAddr) = .empty;
    try list.append(gpa, .{ .iface = try gpa.dupe(u8, "en0"), .address = try gpa.dupe(u8, "192.168.1.5"), .family = .ipv4, .internal = false });
    return list.toOwnedSlice(gpa);
}
fn fetchPublic(gpa: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
    return .{ .ok = true, .status = 200, .body = try gpa.dupe(u8, "203.0.113.7") };
}

test "runIp: null with no scripting flag" {
    const r = try ip.runIp(testing.allocator, &.{}, .{ .interfaces = ipv4Only, .fetchFn = fetchThrows });
    try testing.expect(r == null);
}

test "runIp: --local returns LAN IPv4" {
    const r = try ip.runIp(testing.allocator, &.{"--local"}, .{ .interfaces = ipv4Only, .fetchFn = fetchThrows });
    defer testing.allocator.free(r.?);
    try testing.expectEqualStrings("192.168.1.5", r.?);
}

test "runIp: --local errors without IPv4" {
    try testing.expectError(error.NoLanIpv4, ip.runIp(testing.allocator, &.{"-l"}, .{ .interfaces = emptyInterfaces, .fetchFn = fetchThrows }));
}

test "runIp: --public returns fetched address" {
    const r = try ip.runIp(testing.allocator, &.{"--public"}, .{ .interfaces = ipv4Only, .fetchFn = fetchPublic });
    defer testing.allocator.free(r.?);
    try testing.expectEqualStrings("203.0.113.7", r.?);
}

test "runIp: --public errors when lookup fails" {
    try testing.expectError(error.NoPublicIp, ip.runIp(testing.allocator, &.{"-p"}, .{ .interfaces = ipv4Only, .fetchFn = fetchThrows }));
}

// ---------------------------------------------------------------------------
// QR render
// ---------------------------------------------------------------------------

fn expectLines(actual: [][]u8, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |e, i| try testing.expectEqualStrings(e, actual[i]);
}

test "renderQrLines: maps module pairs to half-blocks" {
    var row0 = [_]bool{ true, false };
    var row1 = [_]bool{ false, true };
    const matrix = [_][]const bool{ &row0, &row1 };
    const lines = try render.renderQrLines(testing.allocator, &matrix, 0);
    defer render.freeLines(testing.allocator, lines);
    try expectLines(lines, &.{"\u{2584}\u{2580}"});
}

test "renderQrLines: all-dark renders blank cells" {
    var row0 = [_]bool{ true, true };
    var row1 = [_]bool{ true, true };
    const matrix = [_][]const bool{ &row0, &row1 };
    const lines = try render.renderQrLines(testing.allocator, &matrix, 0);
    defer render.freeLines(testing.allocator, lines);
    try expectLines(lines, &.{"  "});
}

test "renderQrLines: quiet-zone margin" {
    var row0 = [_]bool{true};
    const matrix = [_][]const bool{&row0};
    const lines = try render.renderQrLines(testing.allocator, &matrix, 1);
    defer render.freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("\u{2588}\u{2580}\u{2588}", lines[0]);
    try testing.expectEqualStrings("\u{2588}\u{2588}\u{2588}", lines[1]);
}

test "renderQrLines: phantom row past odd grid is light" {
    var row0 = [_]bool{true};
    const matrix = [_][]const bool{&row0};
    const lines = try render.renderQrLines(testing.allocator, &matrix, 0);
    defer render.freeLines(testing.allocator, lines);
    try expectLines(lines, &.{"\u{2584}"});
}

test "resolveQrInput: prefers args joined with space" {
    const r = try render.resolveQrInput(testing.allocator, &.{ "hello", "world" }, "piped");
    defer testing.allocator.free(r.?);
    try testing.expectEqualStrings("hello world", r.?);
}

test "resolveQrInput: falls back to stdin, trims trailing" {
    const r = try render.resolveQrInput(testing.allocator, &.{}, "https://example.com\n");
    defer testing.allocator.free(r.?);
    try testing.expectEqualStrings("https://example.com", r.?);
}

test "resolveQrInput: ignores whitespace-only args before stdin" {
    const r = try render.resolveQrInput(testing.allocator, &.{"   "}, "frompipe");
    defer testing.allocator.free(r.?);
    try testing.expectEqualStrings("frompipe", r.?);
}

test "resolveQrInput: null when neither has content" {
    try testing.expect(try render.resolveQrInput(testing.allocator, &.{}, "\n") == null);
    try testing.expect(try render.resolveQrInput(testing.allocator, &.{}, null) == null);
}

// ---------------------------------------------------------------------------
// QR types build()
// ---------------------------------------------------------------------------

fn buildType(id: []const u8, kvs: []const qrtypes.KV) ![]u8 {
    const t = qrtypes.byId(id).?;
    return t.build(testing.allocator, .{ .entries = kvs });
}

fn expectBuild(id: []const u8, kvs: []const qrtypes.KV, expected: []const u8) !void {
    const got = try buildType(id, kvs);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "qr type text passes value through unchanged" {
    try expectBuild("text", &.{.{ .key = "text", .value = "hello world" }}, "hello world");
}

test "qr type url prepends https only without a scheme" {
    try expectBuild("url", &.{.{ .key = "url", .value = "example.com" }}, "https://example.com");
    try expectBuild("url", &.{.{ .key = "url", .value = "http://example.com" }}, "http://example.com");
}

test "qr type tel uses tel scheme" {
    try expectBuild("tel", &.{.{ .key = "number", .value = "+15551234567" }}, "tel:+15551234567");
}

test "qr type sms includes message only when provided" {
    try expectBuild("sms", &.{.{ .key = "number", .value = "+15551234567" }}, "SMSTO:+15551234567");
    try expectBuild("sms", &.{ .{ .key = "number", .value = "+15551234567" }, .{ .key = "message", .value = "hi" } }, "SMSTO:+15551234567:hi");
}

test "qr type email builds mailto with optional subject/body" {
    try expectBuild("email", &.{.{ .key = "to", .value = "a@b.com" }}, "mailto:a@b.com");
    try expectBuild("email", &.{
        .{ .key = "to", .value = "a@b.com" },
        .{ .key = "subject", .value = "Hi there" },
        .{ .key = "body", .value = "Yo" },
    }, "mailto:a@b.com?subject=Hi+there&body=Yo");
}

test "qr type wifi encodes encryption, escapes, nopass" {
    try expectBuild("wifi", &.{
        .{ .key = "ssid", .value = "home" },
        .{ .key = "password", .value = "pa;ss" },
        .{ .key = "encryption", .value = "wpa" },
    }, "WIFI:T:WPA;S:home;P:pa\\;ss;;");
    try expectBuild("wifi", &.{.{ .key = "ssid", .value = "guest" }}, "WIFI:T:nopass;S:guest;;");
}

test "qr type geo joins lat and lng" {
    try expectBuild("geo", &.{ .{ .key = "lat", .value = "37.7749" }, .{ .key = "lng", .value = "-122.4194" } }, "geo:37.7749,-122.4194");
}

// ---------------------------------------------------------------------------
// sysinfo.collectSystemInfo (fake deps)
// ---------------------------------------------------------------------------

fn tPlatLinux() []const u8 {
    return "linux";
}
fn tPlatDarwin() []const u8 {
    return "darwin";
}
fn tPlatWin32() []const u8 {
    return "win32";
}
fn tArch() []const u8 {
    return "x64";
}
fn tRelease() []const u8 {
    return "6.1.0";
}
fn tHostname() []const u8 {
    return "box";
}
fn tUptime() f64 {
    return 90061;
}
fn tTotalmem() u64 {
    return 16 * 1024 * 1024 * 1024;
}
fn tFreemem() u64 {
    return 8 * 1024 * 1024 * 1024;
}
fn tCpuModel() []const u8 {
    return "Test CPU @ 3.0GHz";
}
fn tCpuCount() usize {
    return 2;
}
fn tLoadavg() [3]f64 {
    return .{ 0.5, 0.75, 1.0 };
}
fn tUsername() []const u8 {
    return "tester";
}
fn tUserShell() ?[]const u8 {
    return "/bin/bash";
}
fn tEnvShell() ?[]const u8 {
    return null;
}
fn tReadNull(_: std.mem.Allocator, _: []const u8) ?[]u8 {
    return null;
}
fn tReadOsRelease(gpa: std.mem.Allocator, _: []const u8) ?[]u8 {
    return gpa.dupe(u8, "NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n") catch null;
}
fn tRunNull(_: std.mem.Allocator, _: []const u8, _: []const []const u8) ?[]u8 {
    return null;
}
fn tRunSwVers(gpa: std.mem.Allocator, cmd_name: []const u8, args: []const []const u8) ?[]u8 {
    if (std.mem.eql(u8, cmd_name, "sw_vers") and args.len > 0) {
        if (std.mem.eql(u8, args[0], "-productName")) return gpa.dupe(u8, "macOS") catch null;
        if (std.mem.eql(u8, args[0], "-productVersion")) return gpa.dupe(u8, "15.0") catch null;
    }
    return null;
}

fn baseDeps() sysinfo.Deps {
    return .{
        .platform = tPlatLinux,
        .arch = tArch,
        .release = tRelease,
        .hostname = tHostname,
        .uptime = tUptime,
        .totalmem = tTotalmem,
        .freemem = tFreemem,
        .cpu_model = tCpuModel,
        .cpu_count = tCpuCount,
        .loadavg = tLoadavg,
        .username = tUsername,
        .user_shell = tUserShell,
        .env_shell = tEnvShell,
        .read_text = tReadNull,
        .run_text = tRunNull,
    };
}

test "collectSystemInfo: formats mem, uptime, cpu, load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = try sysinfo.collectSystemInfo(arena.allocator(), baseDeps());
    try testing.expectEqualStrings("16.00 GiB", info.mem_total);
    try testing.expectEqualStrings("8.00 GiB", info.mem_used);
    try testing.expectEqualStrings("1d 1h 1m", info.uptime);
    try testing.expectEqualStrings("Test CPU @ 3.0GHz", info.cpu_model);
    try testing.expectEqual(@as(usize, 2), info.cpu_count);
    try testing.expectEqualStrings("0.50, 0.75, 1.00", info.load_average.?);
}

test "collectSystemInfo: reads PRETTY_NAME on linux" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var deps = baseDeps();
    deps.read_text = tReadOsRelease;
    const info = try sysinfo.collectSystemInfo(arena.allocator(), deps);
    try testing.expectEqualStrings("Ubuntu 24.04 LTS", info.os_name);
}

test "collectSystemInfo: falls back to platform+release" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = try sysinfo.collectSystemInfo(arena.allocator(), baseDeps());
    try testing.expectEqualStrings("linux 6.1.0", info.os_name);
}

test "collectSystemInfo: uses sw_vers on darwin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var deps = baseDeps();
    deps.platform = tPlatDarwin;
    deps.run_text = tRunSwVers;
    const info = try sysinfo.collectSystemInfo(arena.allocator(), deps);
    try testing.expectEqualStrings("macOS 15.0", info.os_name);
}

test "collectSystemInfo: omits load average on windows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var deps = baseDeps();
    deps.platform = tPlatWin32;
    const info = try sysinfo.collectSystemInfo(arena.allocator(), deps);
    try testing.expect(info.load_average == null);
    try testing.expectEqualStrings("Windows 6.1.0", info.os_name);
}

// ---------------------------------------------------------------------------
// serve
// ---------------------------------------------------------------------------

fn serveFixture(gpa: std.mem.Allocator) ![]ip.RawAddr {
    var list: std.ArrayList(ip.RawAddr) = .empty;
    try list.append(gpa, .{ .iface = try gpa.dupe(u8, "en0"), .address = try gpa.dupe(u8, "192.168.1.42"), .family = .ipv4, .internal = false });
    return list.toOwnedSlice(gpa);
}

test "resolveServePort: first bare-number arg" {
    try testing.expectEqual(@as(u16, 8080), serve.resolveServePort(&.{"8080"}, serve.DEFAULT_PORT));
    try testing.expectEqual(@as(u16, 3000), serve.resolveServePort(&.{ "--foo", "3000" }, serve.DEFAULT_PORT));
}

test "resolveServePort: fallback when absent or invalid" {
    try testing.expectEqual(@as(u16, 8000), serve.resolveServePort(&.{}, serve.DEFAULT_PORT));
    try testing.expectEqual(@as(u16, 8000), serve.resolveServePort(&.{"notaport"}, serve.DEFAULT_PORT));
    try testing.expectEqual(@as(u16, 8000), serve.resolveServePort(&.{"99999"}, serve.DEFAULT_PORT));
}

test "serveUrls: builds local and network URLs" {
    var urls = try serve.serveUrls(testing.allocator, 8080, serveFixture);
    defer urls.deinit(testing.allocator);
    try testing.expectEqualStrings("http://localhost:8080", urls.local);
    try testing.expectEqualStrings("http://192.168.1.42:8080", urls.network.?);
}

test "serveUrls: null network without LAN IPv4" {
    var urls = try serve.serveUrls(testing.allocator, 8080, emptyInterfaces);
    defer urls.deinit(testing.allocator);
    try testing.expect(urls.network == null);
}

test "handleRequest: serves file contents, lists dirs, index, 404, no traversal" {
    const io = gio.get();
    const cwd = std.Io.Dir.cwd();
    const base = "zig-orb-serve-test";
    cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base);
    defer cwd.deleteTree(io, base) catch {};
    try cwd.writeFile(io, .{ .sub_path = base ++ "/hello.txt", .data = "hi there" });
    try cwd.createDirPath(io, base ++ "/sub");
    try cwd.writeFile(io, .{ .sub_path = base ++ "/sub/index.html", .data = "<h1>sub index</h1>" });

    const cwd_path = try gio.cwdAlloc(testing.allocator);
    defer testing.allocator.free(cwd_path);
    const root = try std.fs.path.join(testing.allocator, &.{ cwd_path, base });
    defer testing.allocator.free(root);

    {
        var res = try serve.handleRequest(testing.allocator, root, "/hello.txt");
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), res.status);
        try testing.expectEqualStrings("hi there", res.body);
    }
    {
        var res = try serve.handleRequest(testing.allocator, root, "/");
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), res.status);
        try testing.expect(std.mem.indexOf(u8, res.body, "Directory listing for /") != null);
        try testing.expect(std.mem.indexOf(u8, res.body, "hello.txt") != null);
        try testing.expect(std.mem.indexOf(u8, res.body, "sub/") != null);
    }
    {
        var res = try serve.handleRequest(testing.allocator, root, "/sub");
        defer res.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, res.body, "sub index") != null);
    }
    {
        var res = try serve.handleRequest(testing.allocator, root, "/nope.txt");
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 404), res.status);
    }
    {
        var res = try serve.handleRequest(testing.allocator, root, "/../../etc/passwd");
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 404), res.status);
        try testing.expect(res.status != 200);
    }
}

// ---------------------------------------------------------------------------
// QR encoder vs. ground-truth matrices from the `qrcode` library.
// ---------------------------------------------------------------------------

test "encodeMatrix: square with dark top-left finder" {
    const matrix = try encoder.encodeMatrix(testing.allocator, "hello", .M);
    defer encoder.freeMatrix(testing.allocator, matrix);
    try testing.expect(matrix.len > 0);
    try testing.expectEqual(matrix.len, matrix[0].len);
    try testing.expect(matrix[0][0]);
}

test "encodeMatrix: matches qrcode fixtures across modes/levels" {
    const gpa = testing.allocator;
    const json = @embedFile("testdata/qr_truth.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*; // "<L>|<text>"
        const level = encoder.parseLevel(key[0..1]);
        const text = key[2..];
        const obj = entry.value_ptr.*.object;
        const size: usize = @intCast(obj.get("size").?.integer);
        const rows = obj.get("rows").?.array;

        const matrix = try encoder.encodeMatrix(gpa, text, level);
        defer encoder.freeMatrix(gpa, matrix);

        try testing.expectEqual(size, matrix.len);
        for (rows.items, 0..) |rowval, r| {
            const rowstr = rowval.string;
            for (rowstr, 0..) |ch, c| {
                try testing.expectEqual(ch == '1', matrix[r][c]);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// registry.findCommand
// ---------------------------------------------------------------------------

test "findCommand: resolves by name and alias, unknown is null" {
    try testing.expectEqualStrings("ip", registry.findCommand("ip").?.name);
    try testing.expectEqualStrings("sysinfo", registry.findCommand("neofetch").?.name);
    try testing.expectEqualStrings("update", registry.findCommand("upgrade").?.name);
    try testing.expect(registry.findCommand("nope") == null);
}

test "findCommand: every command has a unique name" {
    for (registry.COMMANDS, 0..) |a, i| {
        for (registry.COMMANDS, 0..) |b, j| {
            if (i != j) try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

// ---------------------------------------------------------------------------
// semver
// ---------------------------------------------------------------------------

test "semver: clean, valid, gt" {
    try testing.expectEqualStrings("1.2.0", semver.clean("v1.2.0").?);
    try testing.expect(semver.clean("nightly") == null);
    try testing.expect(semver.valid("1.0.0"));
    try testing.expect(!semver.valid("nope"));
    try testing.expect(semver.gt("1.2.0", "1.0.0"));
    try testing.expect(!semver.gt("1.0.0", "1.0.0"));
}

// ---------------------------------------------------------------------------
// checkForUpdate (fake fetch)
// ---------------------------------------------------------------------------

fn jsonFetch(comptime body: []const u8, comptime ok: bool, comptime status: u16) net.FetchFn {
    return struct {
        fn f(gpa: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
            return .{ .ok = ok, .status = status, .body = try gpa.dupe(u8, body) };
        }
    }.f;
}
fn throwingFetch(_: std.mem.Allocator, _: []const u8, _: net.FetchOptions) anyerror!net.FetchResult {
    return error.Offline;
}

test "checkForUpdate: reports update when latest tag is greater" {
    const res = try check.checkForUpdate(testing.allocator, jsonFetch("{\"tag_name\":\"v1.2.0\",\"html_url\":\"http://x\",\"assets\":[]}", true, 200), "1.0.0");
    defer res.deinit(testing.allocator);
    try testing.expect(res.has_update);
    try testing.expectEqualStrings("1.2.0", res.latest.?);
    try testing.expectEqualStrings("http://x", res.url.?);
}

test "checkForUpdate: no update when already current" {
    const res = try check.checkForUpdate(testing.allocator, jsonFetch("{\"tag_name\":\"v1.0.0\"}", true, 200), "1.0.0");
    defer res.deinit(testing.allocator);
    try testing.expect(!res.has_update);
}

test "checkForUpdate: no update when response not ok" {
    const res = try check.checkForUpdate(testing.allocator, jsonFetch("{}", false, 404), "1.0.0");
    defer res.deinit(testing.allocator);
    try testing.expect(!res.has_update);
    try testing.expect(res.latest == null);
}

test "checkForUpdate: swallows network errors" {
    const res = try check.checkForUpdate(testing.allocator, throwingFetch, "1.0.0");
    defer res.deinit(testing.allocator);
    try testing.expect(!res.has_update);
    try testing.expectEqualStrings("1.0.0", res.current);
}

test "checkForUpdate: ignores invalid tags" {
    const res = try check.checkForUpdate(testing.allocator, jsonFetch("{\"tag_name\":\"nightly\"}", true, 200), "1.0.0");
    defer res.deinit(testing.allocator);
    try testing.expect(!res.has_update);
}

// ---------------------------------------------------------------------------
// state.isStale
// ---------------------------------------------------------------------------

test "isStale: no state is stale" {
    try testing.expect(statemod.isStale(null, 1000));
}
test "isStale: fresh within interval" {
    const now: i64 = 1_000_000;
    try testing.expect(!statemod.isStale(.{ .last_check = now - 1000 }, now));
}
test "isStale: stale once interval elapsed" {
    const now: i64 = 1_000_000;
    try testing.expect(statemod.isStale(.{ .last_check = now - statemod.CHECK_INTERVAL_MS }, now));
}

// ---------------------------------------------------------------------------
// assets
// ---------------------------------------------------------------------------

test "assetNameFor: maps platforms/arches to gzipped names" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("orb-darwin-arm64.gz", assetsmod.assetNameFor(&buf, "darwin", "arm64").?);
    try testing.expectEqualStrings("orb-linux-x64.gz", assetsmod.assetNameFor(&buf, "linux", "x64").?);
    try testing.expectEqualStrings("orb-windows-x64.exe.gz", assetsmod.assetNameFor(&buf, "win32", "x64").?);
}
test "assetNameFor: null for unsupported combos" {
    var buf: [64]u8 = undefined;
    try testing.expect(assetsmod.assetNameFor(&buf, "win32", "arm64") == null);
    try testing.expect(assetsmod.assetNameFor(&buf, "freebsd", "x64") == null);
    try testing.expect(assetsmod.assetNameFor(&buf, "linux", "ia32") == null);
}
test "findAsset: matches and misses" {
    const assets = [_]utypes.ReleaseAsset{
        .{ .name = "orb-linux-x64.gz", .browser_download_url = "u1", .size = 1 },
        .{ .name = "orb-darwin-arm64.gz", .browser_download_url = "u2", .size = 2 },
    };
    try testing.expectEqualStrings("u2", assetsmod.findAsset(&assets, "darwin", "arm64").?.browser_download_url);
    try testing.expect(assetsmod.findAsset(&assets, "win32", "x64") == null);
}

// ---------------------------------------------------------------------------
// reconcile
// ---------------------------------------------------------------------------

fn makeResult(has_update: bool, current: []const u8, latest: ?[]const u8) !utypes.UpdateResult {
    return .{
        .has_update = has_update,
        .current = try testing.allocator.dupe(u8, current),
        .latest = if (latest) |l| try testing.allocator.dupe(u8, l) else null,
        .url = null,
        .assets = try testing.allocator.alloc(utypes.ReleaseAsset, 0),
    };
}

test "reconcile: clears stale hasUpdate when cached latest <= running" {
    var r = try makeResult(true, "0.0.1", version.VERSION);
    defer r.deinit(testing.allocator);
    try reconcilemod.reconcile(testing.allocator, &r);
    try testing.expectEqualStrings(version.VERSION, r.current);
    try testing.expect(!r.has_update);
}

test "reconcile: reports update when cached latest is newer" {
    const newer = (try semver.incMajor(testing.allocator, version.VERSION)).?;
    defer testing.allocator.free(newer);
    var r = try makeResult(false, "0.0.1", newer);
    defer r.deinit(testing.allocator);
    try reconcilemod.reconcile(testing.allocator, &r);
    try testing.expect(r.has_update);
    try testing.expectEqualStrings(newer, r.latest.?);
    try testing.expectEqualStrings(version.VERSION, r.current);
}

test "reconcile: missing or invalid latest is no update" {
    var r1 = try makeResult(true, "0.0.1", null);
    defer r1.deinit(testing.allocator);
    try reconcilemod.reconcile(testing.allocator, &r1);
    try testing.expect(!r1.has_update);

    var r2 = try makeResult(true, "0.0.1", "nightly");
    defer r2.deinit(testing.allocator);
    try reconcilemod.reconcile(testing.allocator, &r2);
    try testing.expect(!r2.has_update);
}

// ---------------------------------------------------------------------------
// progressLabel
// ---------------------------------------------------------------------------

fn expectLabel(progress: applymod.UpdateProgress, expected: []const u8) !void {
    const got = try updatecmd.progressLabel(testing.allocator, progress);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "progressLabel" {
    try expectLabel(.{ .phase = .checking }, "Checking for updates\u{2026}");
    try expectLabel(.{ .phase = .downloading, .total_bytes = 24 * 1024 * 1024 }, "Downloading update (24.0 MB)\u{2026}");
    try expectLabel(.{ .phase = .downloading }, "Downloading update\u{2026}");
    try expectLabel(.{ .phase = .installing }, "Installing\u{2026}");
}
