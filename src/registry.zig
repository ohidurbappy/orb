const std = @import("std");
const cmd = @import("command.zig");
const ip = @import("commands/ip.zig");
const qr = @import("commands/qr/qr.zig");
const serve = @import("commands/serve.zig");
const sysinfo = @import("commands/sysinfo.zig");
const update = @import("commands/update.zig");

pub const Command = cmd.Command;
pub const Ctx = cmd.Ctx;

/// The single source of truth for available tools — drives `--help`, the
/// interactive menu, and CLI dispatch.
pub const COMMANDS = [_]Command{
    .{
        .name = "ip",
        .description = "Show IPs — default lists local; --local (LAN IPv4), --public",
        .aliases = &.{"ipaddr"},
        .render = ip.render,
        .run = ip.run,
    },
    .{
        .name = "qr",
        .description = "Encode text (argument or piped stdin) into a QR code",
        .aliases = &.{"qrcode"},
        .render = qr.run,
        .reads_stdin = true,
        .manages_exit = true,
    },
    .{
        .name = "serve",
        .description = "Serve the current directory over HTTP (e.g. orb serve 8080)",
        .aliases = &.{"http"},
        .render = serve.render,
        .manages_exit = true,
    },
    .{
        .name = "sysinfo",
        .description = "Show system information (neofetch-style)",
        .aliases = &.{ "sys", "neofetch" },
        .render = sysinfo.render,
    },
    .{
        .name = "update",
        .description = "Download and install the latest release",
        .aliases = &.{ "upgrade", "self-update" },
        .render = update.render,
        .manages_exit = true,
    },
};

/// Resolve a command by its name or one of its aliases.
pub fn findCommand(name: []const u8) ?Command {
    for (COMMANDS) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
        for (c.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return c;
        }
    }
    return null;
}
