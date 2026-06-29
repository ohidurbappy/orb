const std = @import("std");
const Term = @import("term.zig").Term;

/// Inputs a command receives, mirroring the TS `CommandProps` plus the runtime
/// handles a Zig command needs (allocator, terminal).
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    /// Positional CLI tokens after the command name.
    args: []const []const u8,
    /// Text piped via stdin, populated only when the command sets `reads_stdin`.
    input: ?[]const u8 = null,
    term: *Term,
    /// True when launched from the interactive menu (vs. one-shot CLI dispatch).
    from_menu: bool = false,
};

/// Plain-text one-shot handler (e.g. `orb ip --local`). Returns an allocated
/// string to print and skip the interactive UI, or null to fall through to
/// `render`. Returns an error to print to stderr and exit non-zero.
pub const RunFn = *const fn (ctx: *Ctx) anyerror!?[]const u8;

/// Interactive / rendered handler — the Ink "Component" equivalent.
pub const RenderFn = *const fn (ctx: *Ctx) anyerror!void;

/// A single tool in the orb toolbox. The registry is the single source of truth
/// driving `--help`, the interactive menu, and CLI dispatch.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    aliases: []const []const u8 = &.{},
    render: RenderFn,
    /// Optional plain-output handler for script-friendly one-shot runs.
    run: ?RunFn = null,
    /// When true, the command drives its own lifetime (long-lived / async).
    manages_exit: bool = false,
    /// When true and stdin is piped (not a TTY), the runner reads it fully.
    reads_stdin: bool = false,
};
