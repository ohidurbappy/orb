const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const registry = @import("registry.zig");
const version = @import("version.zig");
const term_mod = @import("term.zig");
const cmd = @import("command.zig");
const refresh = @import("updater/refresh.zig");
const banner = @import("banner.zig");
const menu = @import("menu.zig");
const gio = @import("io.zig");

const Term = term_mod.Term;
const File = std.Io.File;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    gio.set(init.io);

    // Collect argv0 + the args after it (excluding the program name) as owned slices.
    var arg_it = try init.minimal.args.iterateAllocator(gpa);
    const argv0_raw = arg_it.next() orelse "orb";
    const argv0 = try gpa.dupe(u8, argv0_raw);
    defer gpa.free(argv0);
    var arg_list: std.ArrayList([]const u8) = .empty;
    while (arg_it.next()) |a| try arg_list.append(gpa, try gpa.dupe(u8, a));
    arg_it.deinit();
    const argv = try arg_list.toOwnedSlice(gpa);
    defer freeArgs(gpa, argv);

    // Hidden command used by the detached background update check.
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "__refresh-update")) {
        refresh.runRefresh(gpa) catch {};
        return;
    }

    var parsed = try cli.parseArgs(gpa, argv);
    defer parsed.deinit(gpa);

    if (parsed.version) {
        try stdoutPrint("{s}\n", .{version.VERSION});
        return;
    }
    if (parsed.help) {
        try printHelp();
        return;
    }

    var term = Term.init();

    if (parsed.command_name) |name| {
        const command = registry.findCommand(name) orelse {
            try stderrPrint("Unknown command: {s}\n\n", .{name});
            try printHelp();
            std.process.exit(1);
        };

        // Pull piped input for commands that want it (no positional args + non-TTY stdin).
        var input: ?[]const u8 = null;
        defer if (input) |i| gpa.free(i);
        const stdin_tty = File.stdin().isTty(gio.get()) catch true;
        if (command.reads_stdin and parsed.command_args.len == 0 and !stdin_tty) {
            input = try readStdin(gpa);
        }

        var ctx = cmd.Ctx{ .gpa = gpa, .args = parsed.command_args, .input = input, .term = &term };

        // Plain-output handler (e.g. `orb ip --local`): print and skip the UI.
        if (command.run) |runFn| {
            const out = runFn(&ctx) catch |err| {
                try stderrPrint("{s}\n", .{errMessage(err)});
                std.process.exit(1);
            };
            if (out) |s| {
                defer gpa.free(s);
                try stdoutPrint("{s}\n", .{s});
                refresh.spawnBackgroundRefresh(gpa, argv0, gio.nowMillis());
                return;
            }
        }

        // Otherwise render: cached update banner + the command's output.
        banner.renderCached(gpa, &term);
        command.render(&ctx) catch |err| {
            try stderrPrint("{s}\n", .{errMessage(err)});
            std.process.exit(1);
        };
        refresh.spawnBackgroundRefresh(gpa, argv0, gio.nowMillis());
        return;
    }

    // No command → interactive menu. Kick off a background refresh for next time.
    refresh.spawnBackgroundRefresh(gpa, argv0, gio.nowMillis());
    try menu.run(gpa, &term);
}

/// Map a command error to the human message printed to stderr.
fn errMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoPublicIp => "Could not determine public IP.",
        error.NoLanIpv4 => "No LAN IPv4 address found.",
        else => @errorName(err),
    };
}

fn freeArgs(gpa: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

fn readStdin(gpa: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var sr = File.stdin().reader(gio.get(), &buf);
    return sr.interface.allocRemaining(gpa, .unlimited);
}

fn printHelp() !void {
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("orb — a growable cross-platform CLI toolbox\n\n");
    try w.writeAll("Usage:\n");
    try w.writeAll("  orb              Open the interactive menu\n");
    try w.writeAll("  orb <command>    Run a command directly\n\n");
    try w.writeAll("Commands:\n");
    for (registry.COMMANDS) |c| try w.print("  {s: <12} {s}\n", .{ c.name, c.description });
    try w.writeAll("\nFlags:\n");
    try w.writeAll("  -h, --help       Show this help\n");
    try w.writeAll("  -v, --version    Show version\n");
    try stdoutPrint("{s}", .{aw.written()});
}

fn stdoutPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stdout().writer(gio.get(), &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stderr().writer(gio.get(), &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
