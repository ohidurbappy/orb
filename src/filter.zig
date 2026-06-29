const std = @import("std");
const Command = @import("command.zig").Command;

fn toLower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// Find `needle` in `haystack` (both lowercase) starting at `from`, returning the
/// index or null. Mirrors JS `String.prototype.indexOf(ch, from)`.
fn indexOf(haystack: []const u8, needle: u8, from: usize) ?usize {
    var i = from;
    while (i < haystack.len) : (i += 1) {
        if (toLower(haystack[i]) == needle) return i;
    }
    return null;
}

/// Score how well `query` fuzzy-matches `text` (case-insensitive subsequence).
/// Returns null when the query is not a subsequence. Higher is better: contiguous
/// runs, word-boundary hits, and an early first match all score higher.
pub fn fuzzyScore(text: []const u8, query: []const u8) ?i64 {
    if (query.len == 0) return 0;

    var score: i64 = 0;
    var ti: usize = 0;
    // prevMatch starts at -2 so the first match is never treated as contiguous.
    var prev_match: i64 = -2;

    for (query) |qc_raw| {
        const qc = toLower(qc_raw);
        const found = indexOf(text, qc, ti) orelse return null;
        const fi: i64 = @intCast(found);

        score += 1;
        if (fi == prev_match + 1) score += 5; // contiguous run
        if (found == 0) {
            score += 8; // matches very start
        } else if (!isWordChar(toLower(text[found - 1]))) {
            score += 3; // word boundary
        }
        score -= fi - @as(i64, @intCast(ti)); // penalize skipped chars

        prev_match = fi;
        ti = found + 1;
    }
    return score;
}

fn maxOpt(values: []const ?i64) ?i64 {
    var best: ?i64 = null;
    for (values) |v| {
        if (v) |n| {
            if (best == null or n > best.?) best = n;
        }
    }
    return best;
}

fn scoreCommand(cmd: Command, query: []const u8) ?i64 {
    var name_best: ?i64 = fuzzyScore(cmd.name, query);
    for (cmd.aliases) |alias| {
        const s = fuzzyScore(alias, query);
        if (s) |n| {
            if (name_best == null or n > name_best.?) name_best = n;
        }
    }
    const desc_score = fuzzyScore(cmd.description, query);

    if (name_best == null and desc_score == null) return null;

    // Name matches dominate (×3); a description-only match still surfaces, lower.
    const name_weighted: i64 = if (name_best) |n| n * 3 else std.math.minInt(i64);
    const desc_w: i64 = if (desc_score) |d| d else std.math.minInt(i64);
    return @max(name_weighted, desc_w);
}

const Scored = struct { cmd: Command, index: usize, score: i64 };

/// Filter and rank commands by a query, writing matches into `out` (must be at
/// least `commands.len` long) and returning the populated slice. An empty query
/// returns every command in registry order.
pub fn filterCommands(commands: []const Command, query: []const u8, out: []Command) []Command {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        @memcpy(out[0..commands.len], commands);
        return out[0..commands.len];
    }

    var scored: [64]Scored = undefined;
    var n: usize = 0;
    for (commands, 0..) |cmd, i| {
        if (scoreCommand(cmd, trimmed)) |s| {
            scored[n] = .{ .cmd = cmd, .index = i, .score = s };
            n += 1;
        }
    }

    // Stable sort: score desc, then original index asc.
    std.mem.sort(Scored, scored[0..n], {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.index < b.index;
        }
    }.lessThan);

    for (scored[0..n], 0..) |s, i| out[i] = s.cmd;
    return out[0..n];
}
