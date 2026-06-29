const std = @import("std");
const term = @import("term.zig");
const Term = term.Term;
const registry = @import("registry.zig");
const filter = @import("filter.zig");
const cmd = @import("command.zig");
const banner = @import("banner.zig");

/// Run the interactive fuzzy-search menu: type to filter, ↑/↓ to move, Enter to
/// run, Esc to clear the query (or quit when empty).
pub fn run(gpa: std.mem.Allocator, t: *Term) !void {
    if (!t.isInteractive()) {
        // No TTY: just list the commands.
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        for (registry.COMMANDS) |c| try aw.writer.print("{s: <12} {s}\n", .{ c.name, c.description });
        t.writeAll(aw.written());
        return;
    }

    try t.enableRaw();
    defer t.restore();

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(gpa);
    var selected: usize = 0;

    while (true) {
        var out: [registry.COMMANDS.len]registry.Command = undefined;
        const results = filter.filterCommands(&registry.COMMANDS, query.items, &out);
        if (results.len == 0) {
            selected = 0;
        } else if (selected >= results.len) {
            selected = results.len - 1;
        }

        try draw(gpa, t, query.items, results, selected);

        const key = try t.readKey();
        switch (key) {
            .escape => {
                if (query.items.len > 0) {
                    query.clearRetainingCapacity();
                    selected = 0;
                } else return;
            },
            .ctrl_c => return,
            .enter => {
                if (results.len == 0) continue;
                try runCommand(gpa, t, results[selected]);
            },
            .up => selected = if (selected == 0) 0 else selected - 1,
            .down => if (results.len > 0) {
                selected = @min(results.len - 1, selected + 1);
            },
            .backspace => {
                if (query.items.len > 0) _ = query.pop();
                selected = 0;
            },
            .char => |c| {
                try query.append(gpa, c);
                selected = 0;
            },
            else => {},
        }
    }
}

fn runCommand(gpa: std.mem.Allocator, t: *Term, command: registry.Command) !void {
    // Hand control to the command. Interactive commands manage their own raw
    // mode / input; print commands return immediately and we wait for Esc.
    t.restore();
    t.clear();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("{s}{s}{s}{s} \u{2014} press Esc to go back{s}\n\n", .{ term.bold, term.fg_green, command.name, term.reset, term.reset });
    t.writeAll(aw.written());

    var ctx = cmd.Ctx{ .gpa = gpa, .args = &.{}, .input = null, .term = t, .from_menu = true };
    command.render(&ctx) catch {};

    if (!command.manages_exit) {
        // Static output: wait for Esc/Ctrl-C/Enter before returning to the menu.
        try t.enableRaw();
        while (true) {
            const key = try t.readKey();
            switch (key) {
                .escape, .ctrl_c, .enter => break,
                else => {},
            }
        }
    }
    try t.enableRaw();
}

fn draw(gpa: std.mem.Allocator, t: *Term, query: []const u8, results: []const registry.Command, selected: usize) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    banner.renderCached(gpa, t);

    try w.print("{s}{s}\u{276f} {s}{s}", .{ term.bold, term.fg_cyan, term.reset, query });
    if (query.len == 0) {
        try w.print("{s}Type to search\u{2026} (\u{2191}/\u{2193}, Enter; Esc to quit){s}", .{ term.dim, term.reset });
    }
    try w.writeAll("\n\n");

    if (results.len == 0) {
        try w.print("{s}No matching tools.{s}\n", .{ term.dim, term.reset });
    } else {
        for (results, 0..) |c, i| {
            const sel = i == selected;
            const marker = if (sel) "\u{276f} " else "  ";
            const color = if (sel) term.fg_green else term.fg_cyan;
            try w.print("{s}{s}{s: <12}{s}{s}{s}{s}\n", .{ marker, color, c.name, term.reset, if (sel) "" else term.dim, c.description, term.reset });
        }
    }
    t.clear();
    t.writeAll(aw.written());
}
