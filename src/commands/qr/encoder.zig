//! A from-scratch QR Code encoder, a faithful port of the `qrcode` npm library's
//! core (the algorithm orb previously depended on). Supports numeric,
//! alphanumeric, and byte modes with automatic mode + version selection,
//! Reed-Solomon error correction, and penalty-based mask selection — producing
//! the same module matrices the old encoder did for single-segment input.

const std = @import("std");

pub const Level = enum {
    L,
    M,
    Q,
    H,

    /// Column index into the EC tables (L,M,Q,H order).
    fn col(self: Level) usize {
        return switch (self) {
            .L => 0,
            .M => 1,
            .Q => 2,
            .H => 3,
        };
    }

    /// The 2-bit value used in format information.
    fn bit(self: Level) u32 {
        return switch (self) {
            .L => 1,
            .M => 0,
            .Q => 3,
            .H => 2,
        };
    }
};

/// Parse an error-correction level letter, defaulting to M.
pub fn parseLevel(s: []const u8) Level {
    if (s.len == 0) return .M;
    return switch (std.ascii.toUpper(s[0])) {
        'L' => .L,
        'Q' => .Q,
        'H' => .H,
        else => .M,
    };
}

const Mode = enum { numeric, alphanumeric, byte };

// ---------------------------------------------------------------------------
// Capacity / EC tables (from the QR spec; transcribed from the qrcode library).
// ---------------------------------------------------------------------------

const CODEWORDS_COUNT = [_]u16{
    0, // version 0 unused
    26,   44,   70,   100,  134,  172,  196,  242,  292,  346,
    404,  466,  532,  581,  655,  733,  815,  901,  991,  1085,
    1156, 1258, 1364, 1474, 1588, 1706, 1828, 1921, 2051, 2185,
    2323, 2465, 2611, 2761, 2876, 3034, 3196, 3362, 3532, 3706,
};

// Indexed [(version-1)*4 + level.col].
const EC_BLOCKS_TABLE = [_]u16{
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  1,  2,  2,  4,
    1,  2,  4,  4,  2,  4,  4,  4,  2,  4,  6,  5,  2,  4,  6,  6,
    2,  5,  8,  8,  4,  5,  8,  8,  4,  5,  8,  11, 4,  8,  10, 11,
    4,  9,  12, 16, 4,  9,  16, 16, 6,  10, 12, 18, 6,  10, 17, 16,
    6,  11, 16, 19, 6,  13, 18, 21, 7,  14, 21, 25, 8,  16, 20, 25,
    8,  17, 23, 25, 9,  17, 23, 34, 9,  18, 25, 30, 10, 20, 27, 32,
    12, 21, 29, 35, 12, 23, 34, 37, 12, 25, 34, 40, 13, 26, 35, 42,
    14, 28, 38, 45, 15, 29, 40, 48, 16, 31, 43, 51, 17, 33, 45, 54,
    18, 35, 48, 57, 19, 37, 51, 60, 19, 38, 53, 63, 20, 40, 56, 66,
    21, 43, 59, 70, 22, 45, 62, 74, 24, 47, 65, 77, 25, 49, 68, 81,
};

const EC_CODEWORDS_TABLE = [_]u16{
    7,    10,   13,   17,   10,   16,   22,   28,   15,   26,   36,   44,   20,   36,   52,   64,
    26,   48,   72,   88,   36,   64,   96,   112,  40,   72,   108,  130,  48,   88,   132,  156,
    60,   110,  160,  192,  72,   130,  192,  224,  80,   150,  224,  264,  96,   176,  260,  308,
    104,  198,  288,  352,  120,  216,  320,  384,  132,  240,  360,  432,  144,  280,  408,  480,
    168,  308,  448,  532,  180,  338,  504,  588,  196,  364,  546,  650,  224,  416,  600,  700,
    224,  442,  644,  750,  252,  476,  690,  816,  270,  504,  750,  900,  300,  560,  810,  960,
    312,  588,  870,  1050, 336,  644,  952,  1110, 360,  700,  1020, 1200, 390,  728,  1050, 1260,
    420,  784,  1140, 1350, 450,  812,  1200, 1440, 480,  868,  1290, 1530, 510,  924,  1350, 1620,
    540,  980,  1440, 1710, 570,  1036, 1530, 1800, 570,  1064, 1590, 1890, 600,  1120, 1680, 1980,
    630,  1204, 1770, 2100, 660,  1260, 1860, 2220, 720,  1316, 1950, 2310, 750,  1372, 2040, 2430,
};

fn symbolSize(version: usize) usize {
    return version * 4 + 17;
}
fn totalCodewords(version: usize) usize {
    return CODEWORDS_COUNT[version];
}
fn ecCodewords(version: usize, level: Level) usize {
    return EC_CODEWORDS_TABLE[(version - 1) * 4 + level.col()];
}
fn blocksCount(version: usize, level: Level) usize {
    return EC_BLOCKS_TABLE[(version - 1) * 4 + level.col()];
}

/// Character-count-indicator bit width for a mode at a version.
fn charCountBits(mode: Mode, version: usize) usize {
    const ccBits: [3]usize = switch (mode) {
        .numeric => .{ 10, 12, 14 },
        .alphanumeric => .{ 9, 11, 13 },
        .byte => .{ 8, 16, 16 },
    };
    if (version >= 1 and version < 10) return ccBits[0];
    if (version < 27) return ccBits[1];
    return ccBits[2];
}

// ---------------------------------------------------------------------------
// Galois field GF(256) with primitive polynomial 0x11d.
// ---------------------------------------------------------------------------

const GF = struct {
    exp: [512]u8,
    log: [256]u8,
};

const gf: GF = blk: {
    @setEvalBranchQuota(10000);
    var exp: [512]u8 = undefined;
    var log: [256]u8 = [_]u8{0} ** 256;
    var x: u32 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        exp[i] = @intCast(x);
        log[@as(usize, @intCast(x))] = @intCast(i);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11d;
    }
    i = 255;
    while (i < 512) : (i += 1) exp[i] = exp[i - 255];
    break :blk .{ .exp = exp, .log = log };
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf.exp[@as(usize, gf.log[a]) + @as(usize, gf.log[b])];
}

fn polyMul(gpa: std.mem.Allocator, p1: []const u8, p2: []const u8) ![]u8 {
    const coeff = try gpa.alloc(u8, p1.len + p2.len - 1);
    @memset(coeff, 0);
    for (p1, 0..) |a, i| {
        for (p2, 0..) |b, j| coeff[i + j] ^= gfMul(a, b);
    }
    return coeff;
}

fn generateECPolynomial(gpa: std.mem.Allocator, degree: usize) ![]u8 {
    var poly = try gpa.dupe(u8, &[_]u8{1});
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        const factor = [_]u8{ 1, gf.exp[i] };
        const next = try polyMul(gpa, poly, &factor);
        gpa.free(poly);
        poly = next;
    }
    return poly;
}

/// Reed-Solomon EC codewords for `data` using a degree-`gen.len-1` generator,
/// computed as the polynomial remainder (matches qrcode's Polynomial.mod).
fn rsEncode(gpa: std.mem.Allocator, data: []const u8, gen: []const u8) ![]u8 {
    const degree = gen.len - 1;
    var buf = try gpa.alloc(u8, data.len + degree);
    defer gpa.free(buf);
    @memcpy(buf[0..data.len], data);
    @memset(buf[data.len..], 0);

    var start: usize = 0;
    while (buf.len - start >= gen.len) {
        const coeff = buf[start];
        if (coeff != 0) {
            for (gen, 0..) |g, i| buf[start + i] ^= gfMul(g, coeff);
        }
        start += 1;
        while (start < buf.len and buf[start] == 0) start += 1;
    }

    const out = try gpa.alloc(u8, degree);
    @memset(out, 0);
    const rem = buf.len - start;
    @memcpy(out[degree - rem ..], buf[start..]);
    return out;
}

// ---------------------------------------------------------------------------
// Bit buffer for the data stream.
// ---------------------------------------------------------------------------

const BitBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_len: usize = 0,

    fn deinit(self: *BitBuffer, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    fn putBit(self: *BitBuffer, gpa: std.mem.Allocator, bit: bool) !void {
        const idx = self.bit_len / 8;
        if (self.bytes.items.len <= idx) try self.bytes.append(gpa, 0);
        if (bit) self.bytes.items[idx] |= @as(u8, 0x80) >> @intCast(self.bit_len % 8);
        self.bit_len += 1;
    }

    fn put(self: *BitBuffer, gpa: std.mem.Allocator, num: u32, length: usize) !void {
        var i: usize = 0;
        while (i < length) : (i += 1) {
            const bit = ((num >> @intCast(length - i - 1)) & 1) == 1;
            try self.putBit(gpa, bit);
        }
    }
};

// ---------------------------------------------------------------------------
// Mode detection and data writing.
// ---------------------------------------------------------------------------

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn alphaValue(c: u8) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'Z') return 10 + (c - 'A');
    return switch (c) {
        ' ' => 36,
        '$' => 37,
        '%' => 38,
        '*' => 39,
        '+' => 40,
        '-' => 41,
        '.' => 42,
        '/' => 43,
        ':' => 44,
        else => null,
    };
}

fn isAlphanumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (alphaValue(c) == null) return false;
    }
    return true;
}

fn bestMode(s: []const u8) Mode {
    if (isNumeric(s)) return .numeric;
    if (isAlphanumeric(s)) return .alphanumeric;
    return .byte;
}

/// Floor of usable-bit capacity → max storable characters, matching qrcode's
/// float arithmetic exactly.
fn capacity(version: usize, level: Level, mode: Mode) usize {
    const data_bits: f64 = @floatFromInt((totalCodewords(version) - ecCodewords(version, level)) * 8);
    const reserved: f64 = @floatFromInt(charCountBits(mode, version) + 4);
    const usable = data_bits - reserved;
    return switch (mode) {
        .numeric => @intFromFloat(@floor((usable / 10.0) * 3.0)),
        .alphanumeric => @intFromFloat(@floor((usable / 11.0) * 2.0)),
        .byte => @intFromFloat(@floor(usable / 8.0)),
    };
}

fn bestVersion(mode: Mode, length: usize, level: Level) ?usize {
    var v: usize = 1;
    while (v <= 40) : (v += 1) {
        if (length <= capacity(v, level, mode)) return v;
    }
    return null;
}

fn writeData(buf: *BitBuffer, gpa: std.mem.Allocator, mode: Mode, s: []const u8) !void {
    switch (mode) {
        .byte => {
            for (s) |c| try buf.put(gpa, c, 8);
        },
        .numeric => {
            var i: usize = 0;
            while (i + 3 <= s.len) : (i += 3) {
                const val = parseDigits(s[i .. i + 3]);
                try buf.put(gpa, val, 10);
            }
            const rem = s.len - i;
            if (rem == 2) {
                try buf.put(gpa, parseDigits(s[i .. i + 2]), 7);
            } else if (rem == 1) {
                try buf.put(gpa, parseDigits(s[i .. i + 1]), 4);
            }
        },
        .alphanumeric => {
            var i: usize = 0;
            while (i + 2 <= s.len) : (i += 2) {
                const a = alphaValue(s[i]).?;
                const b = alphaValue(s[i + 1]).?;
                try buf.put(gpa, a * 45 + b, 11);
            }
            if (s.len % 2 == 1) {
                try buf.put(gpa, alphaValue(s[s.len - 1]).?, 6);
            }
        },
    }
}

fn parseDigits(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| n = n * 10 + (c - '0');
    return n;
}

// ---------------------------------------------------------------------------
// Module matrix.
// ---------------------------------------------------------------------------

const Matrix = struct {
    size: usize,
    data: []u8,
    reserved: []u8,

    fn init(gpa: std.mem.Allocator, size: usize) !Matrix {
        const data = try gpa.alloc(u8, size * size);
        const reserved = try gpa.alloc(u8, size * size);
        @memset(data, 0);
        @memset(reserved, 0);
        return .{ .size = size, .data = data, .reserved = reserved };
    }
    fn deinit(self: *Matrix, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.free(self.reserved);
    }
    fn set(self: *Matrix, row: usize, col: usize, value: bool, reserve: bool) void {
        const idx = row * self.size + col;
        self.data[idx] = @intFromBool(value);
        if (reserve) self.reserved[idx] = 1;
    }
    fn get(self: *const Matrix, row: usize, col: usize) u8 {
        return self.data[row * self.size + col];
    }
    fn isReserved(self: *const Matrix, row: usize, col: usize) bool {
        return self.reserved[row * self.size + col] != 0;
    }
    fn xor(self: *Matrix, row: usize, col: usize, value: bool) void {
        self.data[row * self.size + col] ^= @intFromBool(value);
    }
};

fn setupFinderPattern(m: *Matrix, version: usize) void {
    const size = symbolSize(version);
    const positions = [_][2]usize{ .{ 0, 0 }, .{ size - 7, 0 }, .{ 0, size - 7 } };
    for (positions) |p| {
        const row = p[0];
        const col = p[1];
        var r: i32 = -1;
        while (r <= 7) : (r += 1) {
            const rr = @as(i32, @intCast(row)) + r;
            if (rr <= -1 or rr >= @as(i32, @intCast(size))) continue;
            var c: i32 = -1;
            while (c <= 7) : (c += 1) {
                const cc = @as(i32, @intCast(col)) + c;
                if (cc <= -1 or cc >= @as(i32, @intCast(size))) continue;
                const dark = (r >= 0 and r <= 6 and (c == 0 or c == 6)) or
                    (c >= 0 and c <= 6 and (r == 0 or r == 6)) or
                    (r >= 2 and r <= 4 and c >= 2 and c <= 4);
                m.set(@intCast(rr), @intCast(cc), dark, true);
            }
        }
    }
}

fn setupTimingPattern(m: *Matrix) void {
    const size = m.size;
    var r: usize = 8;
    while (r < size - 8) : (r += 1) {
        const value = r % 2 == 0;
        m.set(r, 6, value, true);
        m.set(6, r, value, true);
    }
}

fn alignmentPositions(version: usize, out: *[7]usize) usize {
    if (version == 1) return 0;
    const posCount = version / 7 + 2;
    const size = symbolSize(version);
    const intervals: usize = if (size == 145) 26 else (std.math.divCeil(usize, size - 13, 2 * posCount - 2) catch unreachable) * 2;
    // positions[0] = size-7; each subsequent subtracts intervals; final pushes 6; reversed.
    var tmp: [7]usize = undefined;
    tmp[0] = size - 7;
    var i: usize = 1;
    while (i < posCount - 1) : (i += 1) tmp[i] = tmp[i - 1] - intervals;
    tmp[posCount - 1] = 6;
    // reverse into out
    var k: usize = 0;
    while (k < posCount) : (k += 1) out[k] = tmp[posCount - 1 - k];
    return posCount;
}

fn setupAlignmentPattern(m: *Matrix, version: usize) void {
    var coords: [7]usize = undefined;
    const n = alignmentPositions(version, &coords);
    if (n == 0) return;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            // Skip positions occupied by finder patterns.
            if ((i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0)) continue;
            const row = coords[i];
            const col = coords[j];
            var r: i32 = -2;
            while (r <= 2) : (r += 1) {
                var c: i32 = -2;
                while (c <= 2) : (c += 1) {
                    const dark = (r == -2 or r == 2 or c == -2 or c == 2 or (r == 0 and c == 0));
                    m.set(@intCast(@as(i32, @intCast(row)) + r), @intCast(@as(i32, @intCast(col)) + c), dark, true);
                }
            }
        }
    }
}

fn getBCHDigit(data: u32) u32 {
    var digit: u32 = 0;
    var d = data;
    while (d != 0) : (d >>= 1) digit += 1;
    return digit;
}

const G15: u32 = (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | (1 << 0);
const G15_MASK: u32 = (1 << 14) | (1 << 12) | (1 << 10) | (1 << 4) | (1 << 1);
const G18: u32 = (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 5) | (1 << 2) | (1 << 0);

fn formatEncodedBits(level: Level, mask: u32) u32 {
    const data = (level.bit() << 3) | mask;
    var d = data << 10;
    const g15_bch = getBCHDigit(G15);
    while (getBCHDigit(d) >= g15_bch) {
        d ^= G15 << @intCast(getBCHDigit(d) - g15_bch);
    }
    return ((data << 10) | d) ^ G15_MASK;
}

fn versionEncodedBits(version: usize) u32 {
    var d: u32 = @as(u32, @intCast(version)) << 12;
    const g18_bch = getBCHDigit(G18);
    while (getBCHDigit(d) >= g18_bch) {
        d ^= G18 << @intCast(getBCHDigit(d) - g18_bch);
    }
    return (@as(u32, @intCast(version)) << 12) | d;
}

fn setupFormatInfo(m: *Matrix, level: Level, mask: u32) void {
    const size = m.size;
    const bits = formatEncodedBits(level, mask);
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const md = ((bits >> @intCast(i)) & 1) == 1;
        // vertical
        if (i < 6) {
            m.set(i, 8, md, true);
        } else if (i < 8) {
            m.set(i + 1, 8, md, true);
        } else {
            m.set(size - 15 + i, 8, md, true);
        }
        // horizontal
        if (i < 8) {
            m.set(8, size - i - 1, md, true);
        } else if (i < 9) {
            m.set(8, 15 - i - 1 + 1, md, true);
        } else {
            m.set(8, 15 - i - 1, md, true);
        }
    }
    m.set(size - 8, 8, true, true);
}

fn setupVersionInfo(m: *Matrix, version: usize) void {
    const size = m.size;
    const bits = versionEncodedBits(version);
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const row = i / 3;
        const col = i % 3 + size - 8 - 3;
        const md = ((bits >> @intCast(i)) & 1) == 1;
        m.set(row, col, md, true);
        m.set(col, row, md, true);
    }
}

fn setupData(m: *Matrix, data: []const u8) void {
    const size: i32 = @intCast(m.size);
    var inc: i32 = -1;
    var row: i32 = size - 1;
    var bit_index: i32 = 7;
    var byte_index: usize = 0;

    var col: i32 = size - 1;
    while (col > 0) : (col -= 2) {
        if (col == 6) col -= 1;
        while (true) {
            var c: i32 = 0;
            while (c < 2) : (c += 1) {
                const cc = col - c;
                if (!m.isReserved(@intCast(row), @intCast(cc))) {
                    var dark = false;
                    if (byte_index < data.len) {
                        dark = ((data[byte_index] >> @intCast(bit_index)) & 1) == 1;
                    }
                    m.set(@intCast(row), @intCast(cc), dark, false);
                    bit_index -= 1;
                    if (bit_index == -1) {
                        byte_index += 1;
                        bit_index = 7;
                    }
                }
            }
            row += inc;
            if (row < 0 or row >= size) {
                row -= inc;
                inc = -inc;
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Masking.
// ---------------------------------------------------------------------------

fn maskAt(pattern: u32, i: usize, j: usize) bool {
    return switch (pattern) {
        0 => (i + j) % 2 == 0,
        1 => i % 2 == 0,
        2 => j % 3 == 0,
        3 => (i + j) % 3 == 0,
        4 => (i / 2 + j / 3) % 2 == 0,
        5 => (i * j) % 2 + (i * j) % 3 == 0,
        6 => ((i * j) % 2 + (i * j) % 3) % 2 == 0,
        7 => ((i * j) % 3 + (i + j) % 2) % 2 == 0,
        else => unreachable,
    };
}

fn applyMask(pattern: u32, m: *Matrix) void {
    const size = m.size;
    var col: usize = 0;
    while (col < size) : (col += 1) {
        var row: usize = 0;
        while (row < size) : (row += 1) {
            if (m.isReserved(row, col)) continue;
            m.xor(row, col, maskAt(pattern, row, col));
        }
    }
}

fn penaltyN1(m: *const Matrix) u32 {
    const size = m.size;
    var points: u32 = 0;
    var row: usize = 0;
    while (row < size) : (row += 1) {
        var same_col: u32 = 0;
        var same_row: u32 = 0;
        var last_col: i32 = -1;
        var last_row: i32 = -1;
        var col: usize = 0;
        while (col < size) : (col += 1) {
            var module: i32 = m.get(row, col);
            if (module == last_col) {
                same_col += 1;
            } else {
                if (same_col >= 5) points += 3 + (same_col - 5);
                last_col = module;
                same_col = 1;
            }
            module = m.get(col, row);
            if (module == last_row) {
                same_row += 1;
            } else {
                if (same_row >= 5) points += 3 + (same_row - 5);
                last_row = module;
                same_row = 1;
            }
        }
        if (same_col >= 5) points += 3 + (same_col - 5);
        if (same_row >= 5) points += 3 + (same_row - 5);
    }
    return points;
}

fn penaltyN2(m: *const Matrix) u32 {
    const size = m.size;
    var points: u32 = 0;
    var row: usize = 0;
    while (row < size - 1) : (row += 1) {
        var col: usize = 0;
        while (col < size - 1) : (col += 1) {
            const last = @as(u32, m.get(row, col)) + m.get(row, col + 1) + m.get(row + 1, col) + m.get(row + 1, col + 1);
            if (last == 4 or last == 0) points += 1;
        }
    }
    return points * 3;
}

fn penaltyN3(m: *const Matrix) u32 {
    const size = m.size;
    var points: u32 = 0;
    var row: usize = 0;
    while (row < size) : (row += 1) {
        var bits_col: u32 = 0;
        var bits_row: u32 = 0;
        var col: usize = 0;
        while (col < size) : (col += 1) {
            bits_col = ((bits_col << 1) & 0x7FF) | m.get(row, col);
            if (col >= 10 and (bits_col == 0x5D0 or bits_col == 0x05D)) points += 1;
            bits_row = ((bits_row << 1) & 0x7FF) | m.get(col, row);
            if (col >= 10 and (bits_row == 0x5D0 or bits_row == 0x05D)) points += 1;
        }
    }
    return points * 40;
}

fn penaltyN4(m: *const Matrix) u32 {
    var dark: usize = 0;
    for (m.data) |d| dark += d;
    const count = m.data.len;
    const ratio = @as(f64, @floatFromInt(dark * 100)) / @as(f64, @floatFromInt(count));
    const k_f = @abs(@ceil(ratio / 5.0) - 10.0);
    const k: u32 = @intFromFloat(k_f);
    return k * 10;
}

fn getBestMask(m: *Matrix, level: Level) u32 {
    var best: u32 = 0;
    var lowest: u32 = std.math.maxInt(u32);
    var p: u32 = 0;
    while (p < 8) : (p += 1) {
        setupFormatInfo(m, level, p);
        applyMask(p, m);
        const penalty = penaltyN1(m) + penaltyN2(m) + penaltyN3(m) + penaltyN4(m);
        applyMask(p, m); // undo
        if (penalty < lowest) {
            lowest = penalty;
            best = p;
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Codeword assembly (block split + interleave).
// ---------------------------------------------------------------------------

fn createData(gpa: std.mem.Allocator, version: usize, level: Level, mode: Mode, text: []const u8) ![]u8 {
    var buf: BitBuffer = .{};
    defer buf.deinit(gpa);

    const mode_bit: u32 = switch (mode) {
        .numeric => 1,
        .alphanumeric => 2,
        .byte => 4,
    };
    try buf.put(gpa, mode_bit, 4);
    try buf.put(gpa, @intCast(text.len), charCountBits(mode, version));
    try writeData(&buf, gpa, mode, text);

    const data_total_bits = (totalCodewords(version) - ecCodewords(version, level)) * 8;

    // Terminator (up to 4 zero bits).
    if (buf.bit_len + 4 <= data_total_bits) try buf.put(gpa, 0, 4);
    // Pad to a byte boundary.
    while (buf.bit_len % 8 != 0) try buf.putBit(gpa, false);
    // Pad bytes 0xEC / 0x11 alternately.
    const remaining_bytes = (data_total_bits - buf.bit_len) / 8;
    var i: usize = 0;
    while (i < remaining_bytes) : (i += 1) {
        try buf.put(gpa, if (i % 2 == 1) 0x11 else 0xEC, 8);
    }

    return createCodewords(gpa, version, level, buf.bytes.items);
}

fn createCodewords(gpa: std.mem.Allocator, version: usize, level: Level, data: []const u8) ![]u8 {
    const total = totalCodewords(version);
    const ec_total = ecCodewords(version, level);
    const data_total = total - ec_total;
    const blocks = blocksCount(version, level);

    const blocks_g2 = total % blocks;
    const blocks_g1 = blocks - blocks_g2;
    const total_in_g1 = total / blocks;
    const data_in_g1 = data_total / blocks;
    const ec_count = total_in_g1 - data_in_g1;

    const gen = try generateECPolynomial(gpa, ec_count);
    defer gpa.free(gen);

    const dc = try gpa.alloc([]const u8, blocks);
    defer gpa.free(dc);
    const ec = try gpa.alloc([]u8, blocks);
    defer {
        for (ec) |e| gpa.free(e);
        gpa.free(ec);
    }

    var offset: usize = 0;
    var max_data: usize = 0;
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        const data_size = if (b < blocks_g1) data_in_g1 else data_in_g1 + 1;
        dc[b] = data[offset .. offset + data_size];
        ec[b] = try rsEncode(gpa, dc[b], gen);
        offset += data_size;
        max_data = @max(max_data, data_size);
    }

    const out = try gpa.alloc(u8, total);
    var index: usize = 0;

    var i: usize = 0;
    while (i < max_data) : (i += 1) {
        var r: usize = 0;
        while (r < blocks) : (r += 1) {
            if (i < dc[r].len) {
                out[index] = dc[r][i];
                index += 1;
            }
        }
    }
    i = 0;
    while (i < ec_count) : (i += 1) {
        var r: usize = 0;
        while (r < blocks) : (r += 1) {
            out[index] = ec[r][i];
            index += 1;
        }
    }

    return out;
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

pub const EncodeError = error{ EmptyInput, TooMuchData, OutOfMemory };

/// Encode `text` into a QR module matrix. Returns a freshly-allocated
/// `[][]bool` where `true` is a dark module. Caller frees via `freeMatrix`.
pub fn encodeMatrix(gpa: std.mem.Allocator, text: []const u8, level: Level) EncodeError![][]bool {
    if (text.len == 0) return error.EmptyInput;

    const mode = bestMode(text);
    const version = bestVersion(mode, text.len, level) orelse return error.TooMuchData;

    const codewords = try createData(gpa, version, level, mode, text);
    defer gpa.free(codewords);

    var m = try Matrix.init(gpa, symbolSize(version));
    defer m.deinit(gpa);

    setupFinderPattern(&m, version);
    setupTimingPattern(&m);
    setupAlignmentPattern(&m, version);
    setupFormatInfo(&m, level, 0); // reserve format area
    if (version >= 7) setupVersionInfo(&m, version);
    setupData(&m, codewords);

    const mask = getBestMask(&m, level);
    applyMask(mask, &m);
    setupFormatInfo(&m, level, mask);

    // Convert to [][]bool.
    const rows = try gpa.alloc([]bool, m.size);
    for (rows, 0..) |*row, r| {
        row.* = try gpa.alloc(bool, m.size);
        for (row.*, 0..) |*cell, c| cell.* = m.get(r, c) != 0;
    }
    return rows;
}

pub fn freeMatrix(gpa: std.mem.Allocator, matrix: [][]bool) void {
    for (matrix) |row| gpa.free(row);
    gpa.free(matrix);
}
