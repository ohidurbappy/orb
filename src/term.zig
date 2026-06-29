const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const gio = @import("io.zig");
const File = std.Io.File;

/// ANSI SGR escape sequences. Components append these to a frame buffer.
pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const fg_red = "\x1b[31m";
pub const fg_green = "\x1b[32m";
pub const fg_yellow = "\x1b[33m";
pub const fg_cyan = "\x1b[36m";

/// A decoded keypress from the terminal.
pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
    backspace,
    ctrl_c,
    /// Ctrl+<letter> other than C, carrying the lowercase letter.
    ctrl: u8,
    /// Unrecognized / ignorable input.
    other,
};

const is_windows = builtin.os.tag == .windows;
const Termios = if (is_windows) void else posix.termios;

/// Terminal controller: raw-mode toggling, key decoding, and frame output.
///
/// Raw mode and key reading use POSIX termios. On Windows (where std does not
/// expose the console-mode APIs) the terminal reports non-interactive, so the
/// interactive menu/builders fall back to their non-TTY behavior while every
/// one-shot command works normally.
pub const Term = struct {
    in: File,
    out: File,
    raw_enabled: bool = false,
    orig: ?Termios = null,

    pub fn init() Term {
        return .{ .in = File.stdin(), .out = File.stdout() };
    }

    /// True when stdin is a TTY we can put into raw mode (Ink's `isRawModeSupported`).
    pub fn isInteractive(self: *Term) bool {
        if (comptime is_windows) return false;
        const io = gio.get();
        const in_tty = self.in.isTty(io) catch return false;
        const out_tty = self.out.isTty(io) catch return false;
        return in_tty and out_tty;
    }

    pub fn enableRaw(self: *Term) !void {
        if (comptime is_windows) return;
        if (self.raw_enabled) return;
        const orig = try posix.tcgetattr(self.in.handle);
        self.orig = orig;
        var raw = orig;
        // cfmakeraw-equivalent: disable canonical mode, echo, signals.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(self.in.handle, .FLUSH, raw);
        self.raw_enabled = true;
    }

    pub fn restore(self: *Term) void {
        if (comptime is_windows) return;
        if (self.orig) |orig| {
            posix.tcsetattr(self.in.handle, .FLUSH, orig) catch {};
        }
        self.raw_enabled = false;
    }

    /// Block for the next keypress and decode it.
    pub fn readKey(self: *Term) !Key {
        if (comptime is_windows) return .escape;
        var buf: [8]u8 = undefined;
        const n = posix.read(self.in.handle, &buf) catch return .other;
        if (n == 0) return .escape; // EOF
        return decodeKey(buf[0..n]);
    }

    pub fn writeAll(self: *Term, bytes: []const u8) void {
        var buf: [4096]u8 = undefined;
        var w = self.out.writer(gio.get(), &buf);
        w.interface.writeAll(bytes) catch {};
        w.interface.flush() catch {};
    }

    /// Clear the screen and move the cursor home, ready for a fresh frame.
    pub fn clear(self: *Term) void {
        self.writeAll("\x1b[2J\x1b[3J\x1b[H");
    }

    pub fn hideCursor(self: *Term) void {
        self.writeAll("\x1b[?25l");
    }

    pub fn showCursor(self: *Term) void {
        self.writeAll("\x1b[?25h");
    }
};

/// Decode a raw input chunk into a Key. Kept free of any Term state so it is
/// unit-testable against byte sequences.
pub fn decodeKey(bytes: []const u8) Key {
    if (bytes.len == 0) return .other;
    const b = bytes[0];

    // CSI escape sequences (arrow keys): ESC [ A/B/C/D.
    if (b == 0x1b) {
        if (bytes.len >= 3 and bytes[1] == '[') {
            return switch (bytes[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .other,
            };
        }
        return .escape;
    }

    if (b == '\r' or b == '\n') return .enter;
    if (b == 0x7f or b == 0x08) return .backspace;
    if (b == 0x03) return .ctrl_c;
    // Other control chars Ctrl+A..Z (except the ones handled above).
    if (b >= 1 and b <= 26) return .{ .ctrl = b - 1 + 'a' };

    // Printable byte (we forward bytes as-is, so UTF-8 multibyte input arrives
    // one byte at a time but is rare for these prompts).
    return .{ .char = b };
}
