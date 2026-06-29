const std = @import("std");

pub const ParsedArgs = struct {
    command_name: ?[]const u8 = null,
    /// Positional tokens after the command name, forwarded to the command.
    command_args: [][]const u8,
    help: bool = false,
    version: bool = false,

    pub fn deinit(self: *ParsedArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.command_args);
    }
};

/// Parse argv (already stripped of the program name) into a command + flags.
/// `-h/--help` and `-v/--version` are global even after a command; everything
/// after the command name is forwarded so the command parses its own options.
pub fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var command_name: ?[]const u8 = null;
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(gpa);
    var help = false;
    var version = false;

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            version = true;
        } else if (command_name == null and !std.mem.startsWith(u8, arg, "-")) {
            command_name = arg;
        } else {
            try args.append(gpa, arg);
        }
    }

    return .{
        .command_name = command_name,
        .command_args = try args.toOwnedSlice(gpa),
        .help = help,
        .version = version,
    };
}
