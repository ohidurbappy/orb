const std = @import("std");
const term = @import("../term.zig");
const net = @import("../net.zig");
const apply = @import("../updater/apply.zig");
const Ctx = @import("../command.zig").Ctx;

/// The user-facing label for an update phase. Allocated via `gpa`.
pub fn progressLabel(gpa: std.mem.Allocator, progress: apply.UpdateProgress) ![]u8 {
    return switch (progress.phase) {
        .downloading => blk: {
            if (progress.total_bytes) |tb| {
                const mb = @as(f64, @floatFromInt(tb)) / 1024.0 / 1024.0;
                break :blk std.fmt.allocPrint(gpa, "Downloading update ({d:.1} MB)\u{2026}", .{mb});
            }
            break :blk gpa.dupe(u8, "Downloading update\u{2026}");
        },
        .installing => gpa.dupe(u8, "Installing\u{2026}"),
        .checking => gpa.dupe(u8, "Checking for updates\u{2026}"),
    };
}

fn colorFor(status: apply.Status) []const u8 {
    return switch (status) {
        .updated => term.fg_green,
        .up_to_date => term.fg_cyan,
        .unsupported, .no_asset => term.fg_yellow,
        .err => term.fg_red,
    };
}

pub fn render(ctx: *Ctx) anyerror!void {
    const outcome = try apply.applyUpdate(ctx.gpa, net.fetch, apply.defaultProgress);
    defer outcome.deinit(ctx.gpa);

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    try aw.writer.print("{s}{s}{s}\n", .{ colorFor(outcome.status), outcome.message, term.reset });
    ctx.term.writeAll(aw.written());
}
