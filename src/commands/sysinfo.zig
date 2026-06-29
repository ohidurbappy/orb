const std = @import("std");
const builtin = @import("builtin");
const term = @import("../term.zig");
const gio = @import("../io.zig");
const Ctx = @import("../command.zig").Ctx;

const Dir = std.Io.Dir;

pub const SystemInfo = struct {
    os_name: []const u8,
    platform: []const u8,
    arch: []const u8,
    kernel: []const u8,
    hostname: []const u8,
    username: []const u8,
    uptime: []const u8,
    cpu_model: []const u8,
    cpu_count: usize,
    mem_total: []const u8,
    mem_used: []const u8,
    load_average: ?[]const u8,
    shell: ?[]const u8,
};

/// Side-effecting dependencies, injected so `collectSystemInfo` is testable.
/// String-returning deps yield borrowed slices valid for the call; collect
/// duplicates everything into the result allocator.
pub const Deps = struct {
    platform: *const fn () []const u8,
    arch: *const fn () []const u8,
    release: *const fn () []const u8,
    hostname: *const fn () []const u8,
    uptime: *const fn () f64,
    totalmem: *const fn () u64,
    freemem: *const fn () u64,
    cpu_model: *const fn () []const u8,
    cpu_count: *const fn () usize,
    loadavg: *const fn () [3]f64,
    username: *const fn () []const u8,
    user_shell: *const fn () ?[]const u8,
    env_shell: *const fn () ?[]const u8,
    /// Reads a text file, returning null on any error (allocated via gpa).
    read_text: *const fn (gpa: std.mem.Allocator, path: []const u8) ?[]u8,
    /// Runs a command for the pretty OS name, returning null on error.
    run_text: *const fn (gpa: std.mem.Allocator, cmd: []const u8, args: []const []const u8) ?[]u8,
};

/// Collect system info. All result strings are owned by `gpa` (use an arena).
pub fn collectSystemInfo(gpa: std.mem.Allocator, deps: Deps) !SystemInfo {
    const platform = deps.platform();
    const total = deps.totalmem();
    const free = deps.freemem();

    const shell: ?[]const u8 = deps.user_shell() orelse deps.env_shell();

    return .{
        .os_name = try prettyOsName(gpa, deps, platform),
        .platform = try gpa.dupe(u8, platform),
        .arch = try gpa.dupe(u8, deps.arch()),
        .kernel = try gpa.dupe(u8, deps.release()),
        .hostname = try gpa.dupe(u8, deps.hostname()),
        .username = try gpa.dupe(u8, deps.username()),
        .uptime = try formatUptime(gpa, deps.uptime()),
        .cpu_model = try gpa.dupe(u8, std.mem.trim(u8, deps.cpu_model(), " \t")),
        .cpu_count = deps.cpu_count(),
        .mem_total = try formatBytes(gpa, total),
        .mem_used = try formatBytes(gpa, total - free),
        .load_average = if (std.mem.eql(u8, platform, "win32")) null else try formatLoad(gpa, deps.loadavg()),
        .shell = if (shell) |s| try gpa.dupe(u8, s) else null,
    };
}

fn prettyOsName(gpa: std.mem.Allocator, deps: Deps, platform: []const u8) ![]u8 {
    if (std.mem.eql(u8, platform, "linux")) {
        if (deps.read_text(gpa, "/etc/os-release")) |content| {
            defer gpa.free(content);
            if (parseOsRelease(content)) |name| return gpa.dupe(u8, name);
        }
    }
    if (std.mem.eql(u8, platform, "darwin")) {
        const product = deps.run_text(gpa, "sw_vers", &.{"-productName"});
        defer if (product) |p| gpa.free(p);
        const version = deps.run_text(gpa, "sw_vers", &.{"-productVersion"});
        defer if (version) |v| gpa.free(v);
        if (product) |p| {
            if (version) |v| return std.fmt.allocPrint(gpa, "{s} {s}", .{ p, v });
            return gpa.dupe(u8, p);
        }
        return gpa.dupe(u8, "macOS");
    }
    if (std.mem.eql(u8, platform, "win32")) {
        return std.fmt.allocPrint(gpa, "Windows {s}", .{deps.release()});
    }
    return std.fmt.allocPrint(gpa, "{s} {s}", .{ platform, deps.release() });
}

/// Extract PRETTY_NAME (or NAME) from /etc/os-release content. Returns a slice
/// into `content`.
pub fn parseOsRelease(content: []const u8) ?[]const u8 {
    var pretty: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        // Strip surrounding double quotes.
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (std.mem.eql(u8, key, "PRETTY_NAME")) pretty = value;
        if (std.mem.eql(u8, key, "NAME")) name = value;
    }
    return pretty orelse name;
}

pub fn formatUptime(gpa: std.mem.Allocator, seconds: f64) ![]u8 {
    const s: u64 = @intFromFloat(@floor(seconds));
    const days = s / 86400;
    const hours = (s % 86400) / 3600;
    const mins = (s % 3600) / 60;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (days > 0) try w.print("{d}d ", .{days});
    if (hours > 0) try w.print("{d}h ", .{hours});
    try w.print("{d}m", .{mins});
    return aw.toOwnedSlice();
}

pub fn formatBytes(gpa: std.mem.Allocator, bytes: u64) ![]u8 {
    const gib = @as(f64, @floatFromInt(bytes)) / 1073741824.0; // 1024^3
    if (gib >= 1.0) return std.fmt.allocPrint(gpa, "{d:.2} GiB", .{gib});
    const mib = @as(f64, @floatFromInt(bytes)) / 1048576.0; // 1024^2
    return std.fmt.allocPrint(gpa, "{d:.0} MiB", .{mib});
}

pub fn formatLoad(gpa: std.mem.Allocator, load: [3]f64) ![]u8 {
    return std.fmt.allocPrint(gpa, "{d:.2}, {d:.2}, {d:.2}", .{ load[0], load[1], load[2] });
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const LOGOS = struct {
    const darwin = [_][]const u8{ "   .:'    ", " _ :'_    ", " (_'\\/_)  ", " /     \\  ", " \\     /  ", "  `---'   " };
    const linux = [_][]const u8{ "   .--.   ", "  |o_o |  ", "  |:_/ |  ", " //   \\ \\ ", "(|     | )", "/'\\_   _/`\\" };
    const win32 = [_][]const u8{ " .---.---.", " |   |   |", " |---+---|", " |   |   |", " '---'---'", "          " };
    const fallback = [_][]const u8{ "  ___  ", " / _ \\ ", "| | | |", "| |_| |", " \\___/ ", "  orb  " };
};

fn logoFor(platform: []const u8) []const []const u8 {
    if (std.mem.eql(u8, platform, "darwin")) return &LOGOS.darwin;
    if (std.mem.eql(u8, platform, "linux")) return &LOGOS.linux;
    if (std.mem.eql(u8, platform, "win32")) return &LOGOS.win32;
    return &LOGOS.fallback;
}

pub fn render(ctx: *Ctx) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const info = try collectSystemInfo(a, realDeps);
    const logo = logoFor(info.platform);

    const Row = struct { label: []const u8, value: ?[]const u8 };
    const user_host = try std.fmt.allocPrint(a, "{s}@{s}", .{ info.username, info.hostname });
    const cpu = try std.fmt.allocPrint(a, "{s} ({d})", .{ info.cpu_model, info.cpu_count });
    const mem = try std.fmt.allocPrint(a, "{s} / {s}", .{ info.mem_used, info.mem_total });
    const rows = [_]Row{
        .{ .label = "User", .value = user_host },
        .{ .label = "OS", .value = info.os_name },
        .{ .label = "Kernel", .value = info.kernel },
        .{ .label = "Arch", .value = info.arch },
        .{ .label = "Uptime", .value = info.uptime },
        .{ .label = "Shell", .value = info.shell },
        .{ .label = "CPU", .value = cpu },
        .{ .label = "Memory", .value = mem },
        .{ .label = "Load", .value = info.load_average },
    };

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;

    // Logo column beside the key/value rows.
    const max_rows = @max(logo.len, rows.len);
    var i: usize = 0;
    while (i < max_rows) : (i += 1) {
        const logo_line = if (i < logo.len) logo[i] else "          ";
        try w.print("{s}{s}{s}  ", .{ term.fg_green, logo_line, term.reset });
        if (i < rows.len) {
            const row = rows[i];
            if (row.value) |v| {
                try w.print("{s}{s}{s: <8}{s}{s}", .{ term.bold, term.fg_cyan, row.label, term.reset, v });
            }
        }
        try w.print("\n", .{});
    }
    ctx.term.writeAll(aw.written());
}

// ---------------------------------------------------------------------------
// Real dependencies (best-effort per platform; fall back gracefully).
// ---------------------------------------------------------------------------

var uname_buf: std.posix.utsname = undefined;
var uname_done = false;
fn unameCached() *std.posix.utsname {
    if (!uname_done) {
        uname_buf = std.posix.uname();
        uname_done = true;
    }
    return &uname_buf;
}

fn rPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    };
}

fn rArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn rRelease() []const u8 {
    if (builtin.os.tag == .windows) return getenv("OS") orelse "Windows";
    return std.mem.span(@as([*:0]const u8, @ptrCast(&unameCached().release)));
}

fn rHostname() []const u8 {
    if (builtin.os.tag == .windows) return getenv("COMPUTERNAME") orelse "windows";
    return std.mem.span(@as([*:0]const u8, @ptrCast(&unameCached().nodename)));
}

fn rUptime() f64 {
    if (builtin.os.tag == .linux) {
        var buf: [128]u8 = undefined;
        const content = Dir.cwd().readFile(gio.get(), "/proc/uptime", &buf) catch return 0;
        const space = std.mem.indexOfScalar(u8, content, ' ') orelse content.len;
        return std.fmt.parseFloat(f64, content[0..space]) catch 0;
    }
    if (builtin.os.tag == .macos) {
        // sysctl kern.boottime → struct timeval; uptime = now - boottime.
        var tv: c_sysctl.timeval = undefined;
        var size: usize = @sizeOf(c_sysctl.timeval);
        var mib = [_]c_int{ c_sysctl.CTL_KERN, c_sysctl.KERN_BOOTTIME };
        if (c_sysctl.sysctl(&mib, 2, &tv, &size, null, 0) != 0) return 0;
        const now = gio.nowSeconds();
        return @floatFromInt(now - tv.tv_sec);
    }
    return 0;
}

fn rTotalmem() u64 {
    if (builtin.os.tag == .linux) {
        const info = std.os.linux.sysinfo;
        var si: std.os.linux.Sysinfo = undefined;
        if (info(&si) == 0) return @as(u64, si.totalram) * si.mem_unit;
        return 0;
    }
    if (builtin.os.tag == .macos) {
        var mem: u64 = 0;
        var size: usize = @sizeOf(u64);
        var mib = [_]c_int{ c_sysctl.CTL_HW, c_sysctl.HW_MEMSIZE };
        if (c_sysctl.sysctl(&mib, 2, &mem, &size, null, 0) == 0) return mem;
        return 0;
    }
    return 0;
}

fn rFreemem() u64 {
    if (builtin.os.tag == .linux) {
        var si: std.os.linux.Sysinfo = undefined;
        if (std.os.linux.sysinfo(&si) == 0) return @as(u64, si.freeram) * si.mem_unit;
        return 0;
    }
    if (builtin.os.tag == .macos) {
        var free_pages: u32 = 0;
        var sz: usize = @sizeOf(u32);
        if (c_sysctl.sysctlbyname("vm.page_free_count", &free_pages, &sz, null, 0) != 0) return 0;
        var page_size: u32 = 0;
        sz = @sizeOf(u32);
        if (c_sysctl.sysctlbyname("hw.pagesize", &page_size, &sz, null, 0) != 0) return 0;
        return @as(u64, free_pages) * page_size;
    }
    return 0;
}

fn rCpuModel() []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    if (builtin.os.tag == .macos) {
        var size: usize = S.buf.len;
        if (c_sysctl.sysctlbyname("machdep.cpu.brand_string", &S.buf, &size, null, 0) == 0 and size > 0) {
            return S.buf[0 .. size - 1]; // drop trailing NUL
        }
    }
    if (builtin.os.tag == .linux) {
        var fbuf: [8192]u8 = undefined;
        const content = Dir.cwd().readFile(gio.get(), "/proc/cpuinfo", &fbuf) catch return "Unknown";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "model name")) {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                const n = @min(val.len, S.buf.len);
                @memcpy(S.buf[0..n], val[0..n]);
                return S.buf[0..n];
            }
        }
    }
    return "Unknown";
}

fn rCpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}

fn rLoadavg() [3]f64 {
    if (builtin.os.tag == .linux) {
        var buf: [128]u8 = undefined;
        const content = Dir.cwd().readFile(gio.get(), "/proc/loadavg", &buf) catch return .{ 0, 0, 0 };
        var it = std.mem.tokenizeScalar(u8, content, ' ');
        var out = [3]f64{ 0, 0, 0 };
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const tok = it.next() orelse break;
            out[i] = std.fmt.parseFloat(f64, tok) catch 0;
        }
        return out;
    }
    if (builtin.os.tag == .macos) {
        var out = [3]f64{ 0, 0, 0 };
        if (c_sysctl.getloadavg(&out, 3) == 3) return out;
        return .{ 0, 0, 0 };
    }
    return .{ 0, 0, 0 };
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

fn rUsername() []const u8 {
    return getenv("USER") orelse getenv("LOGNAME") orelse getenv("USERNAME") orelse "unknown";
}

fn rUserShell() ?[]const u8 {
    return null; // resolved via env SHELL below (matches TS fallback chain)
}

fn rEnvShell() ?[]const u8 {
    return getenv("SHELL");
}

fn rReadText(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return Dir.cwd().readFileAlloc(gio.get(), path, gpa, .limited(1 << 20)) catch null;
}

fn rRunText(gpa: std.mem.Allocator, cmd: []const u8, args: []const []const u8) ?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, cmd) catch return null;
    argv.appendSlice(gpa, args) catch return null;

    const result = std.process.run(gpa, gio.get(), .{ .argv = argv.items }) catch return null;
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return gpa.dupe(u8, trimmed) catch null;
}

pub const realDeps = Deps{
    .platform = rPlatform,
    .arch = rArch,
    .release = rRelease,
    .hostname = rHostname,
    .uptime = rUptime,
    .totalmem = rTotalmem,
    .freemem = rFreemem,
    .cpu_model = rCpuModel,
    .cpu_count = rCpuCount,
    .loadavg = rLoadavg,
    .username = rUsername,
    .user_shell = rUserShell,
    .env_shell = rEnvShell,
    .read_text = rReadText,
    .run_text = rRunText,
};

const c_sysctl = if (builtin.os.tag == .macos) struct {
    pub const CTL_KERN = 1;
    pub const KERN_BOOTTIME = 21;
    pub const CTL_HW = 6;
    pub const HW_MEMSIZE = 24;
    pub const timeval = extern struct { tv_sec: c_long, tv_usec: c_long };
    pub extern "c" fn sysctl(name: [*]c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
    pub extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
    pub extern "c" fn getloadavg(loadavg: [*]f64, nelem: c_int) c_int;
} else struct {};
