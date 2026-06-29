const std = @import("std");
const term = @import("term.zig");
const Term = term.Term;
const state = @import("updater/state.zig");
const reconcile = @import("updater/reconcile.zig");
const types = @import("updater/types.zig");

/// Print the "update available" banner from the cached state, if any. Never
/// blocks or errors out the command.
pub fn renderCached(gpa: std.mem.Allocator, t: *Term) void {
    var st = state.readState(gpa) orelse return;
    defer state.freeState(gpa, st);
    if (st.result) |*r| {
        reconcile.reconcile(gpa, r) catch return;
        if (r.has_update) printBanner(gpa, t, r.*);
    }
}

pub fn printBanner(gpa: std.mem.Allocator, t: *Term, result: types.UpdateResult) void {
    if (!result.has_update) return;
    const latest = result.latest orelse return;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    // ⬆ Update available: <current> → <latest> — run orb update
    w.print("{s}\u{2b06} Update available:{s} {s}{s}{s} \u{2192} {s}{s}{s} \u{2014} run {s}orb update{s}\n", .{
        term.fg_yellow, term.reset,
        term.dim,       result.current, term.reset,
        term.fg_green,  latest,         term.reset,
        term.fg_cyan,   term.reset,
    }) catch return;
    t.writeAll(aw.written());
}
