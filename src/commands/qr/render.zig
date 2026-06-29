const std = @import("std");
const encoder = @import("encoder.zig");

pub const Level = encoder.Level;
pub const parseLevel = encoder.parseLevel;

const BLOCK_FULL = "\u{2588}"; // █ both light
const BLOCK_UPPER = "\u{2580}"; // ▀ light on top only
const BLOCK_LOWER = "\u{2584}"; // ▄ light on bottom only
const BLANK = " "; // both dark

/// Choose the half-block glyph for a vertical module pair. Light modules render
/// as the visible block (dark = empty), keeping codes scannable on dark
/// terminal backgrounds.
pub fn glyph(top_dark: bool, bottom_dark: bool) []const u8 {
    if (!top_dark and !bottom_dark) return BLOCK_FULL;
    if (!top_dark and bottom_dark) return BLOCK_UPPER;
    if (top_dark and !bottom_dark) return BLOCK_LOWER;
    return BLANK;
}

/// Render a module matrix to terminal lines using vertical half-blocks (two
/// module rows per text row), surrounded by a `margin`-module light quiet zone.
/// Returns allocated UTF-8 lines; free with `freeLines`.
pub fn renderQrLines(gpa: std.mem.Allocator, matrix: []const []const bool, margin: usize) ![][]u8 {
    const size = matrix.len;
    const dim = size + margin * 2;

    const isDark = struct {
        fn f(mtx: []const []const bool, mg: usize, sz: usize, r: usize, c: usize) bool {
            if (r < mg or c < mg) return false;
            const mr = r - mg;
            const mc = c - mg;
            if (mr >= sz or mc >= sz) return false;
            return mtx[mr][mc];
        }
    }.f;

    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }

    var r: usize = 0;
    while (r < dim) : (r += 2) {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(gpa);
        var c: usize = 0;
        while (c < dim) : (c += 1) {
            const top_dark = isDark(matrix, margin, size, r, c);
            const bottom_dark = if (r + 1 < dim) isDark(matrix, margin, size, r + 1, c) else false;
            try line.appendSlice(gpa, glyph(top_dark, bottom_dark));
        }
        try lines.append(gpa, try line.toOwnedSlice(gpa));
    }
    return lines.toOwnedSlice(gpa);
}

pub fn freeLines(gpa: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

pub const QrOptions = struct {
    level: Level = .M,
    margin: usize = 1,
};

/// Encode `text` and render it to terminal lines in one step.
pub fn toQrLines(gpa: std.mem.Allocator, text: []const u8, opts: QrOptions) ![][]u8 {
    const matrix = try encoder.encodeMatrix(gpa, text, opts.level);
    defer encoder.freeMatrix(gpa, matrix);
    // renderQrLines wants []const []const bool; [][]bool coerces.
    return renderQrLines(gpa, matrix, opts.margin);
}

/// Decide what to encode: an explicit positional argument wins; otherwise fall
/// back to piped stdin (trailing whitespace trimmed). Returns null when neither
/// yields content. The returned slice is owned by `gpa`.
pub fn resolveQrInput(gpa: std.mem.Allocator, args: []const []const u8, stdin: ?[]const u8) !?[]u8 {
    if (args.len > 0) {
        const joined = try std.mem.join(gpa, " ", args);
        defer gpa.free(joined);
        const trimmed = std.mem.trim(u8, joined, " \t\r\n");
        if (trimmed.len > 0) return try gpa.dupe(u8, trimmed);
    }
    if (stdin) |s| {
        const trimmed = std.mem.trimEnd(u8, s, " \t\r\n\x0b\x0c");
        if (trimmed.len > 0) return try gpa.dupe(u8, trimmed);
    }
    return null;
}
