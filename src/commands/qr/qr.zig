const std = @import("std");
const term = @import("../../term.zig");
const render = @import("render.zig");
const types = @import("types.zig");
const Ctx = @import("../../command.zig").Ctx;

const Key = term.Key;

/// Print a rendered QR for `text` plus the payload caption.
fn printQr(ctx: *Ctx, w: *std.Io.Writer, text: []const u8) !void {
    const lines = render.toQrLines(ctx.gpa, text, .{}) catch {
        try w.print("{s}Could not encode QR.{s}\n", .{ term.fg_red, term.reset });
        return;
    };
    defer render.freeLines(ctx.gpa, lines);
    for (lines) |line| try w.print("{s}\n", .{line});
    try w.print("\n{s}{s}{s}\n", .{ term.dim, text, term.reset });
}

pub fn render_(ctx: *Ctx) anyerror!void {
    return run(ctx);
}

pub fn run(ctx: *Ctx) anyerror!void {
    const preset = try render.resolveQrInput(ctx.gpa, ctx.args, ctx.input);
    defer if (preset) |p| ctx.gpa.free(p);

    const interactive = preset == null and ctx.term.isInteractive();

    // Direct render (payload from args/stdin, or no TTY to prompt on).
    if (preset) |text| {
        var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
        defer aw.deinit();
        try printQr(ctx, &aw.writer, text);
        ctx.term.writeAll(aw.written());
        return;
    }

    if (!interactive) {
        var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{s}Nothing to encode.{s}\n", .{ term.fg_yellow, term.reset });
        try w.print("{s}Usage: orb qr <text>{s}\n", .{ term.dim, term.reset });
        try w.print("{s}   or: echo \"text\" | orb qr{s}\n", .{ term.dim, term.reset });
        try w.print("{s}Run in a terminal with no argument to pick a type interactively.{s}\n", .{ term.dim, term.reset });
        ctx.term.writeAll(aw.written());
        return;
    }

    try interactiveBuilder(ctx);
}

fn interactiveBuilder(ctx: *Ctx) !void {
    try ctx.term.enableRaw();
    defer ctx.term.restore();

    var type_index: usize = 0;

    // Stage: pick a type.
    pick: while (true) {
        try drawPicker(ctx, type_index);
        const key = try ctx.term.readKey();
        switch (key) {
            .escape, .ctrl_c => return,
            .up => type_index = if (type_index == 0) 0 else type_index - 1,
            .down => type_index = @min(types.QR_TYPES.len - 1, type_index + 1),
            .enter => {
                if (try fillFields(ctx, type_index)) return; // built + rendered
                continue :pick; // esc went back to picker
            },
            else => {},
        }
    }
}

/// Returns true when a QR was rendered (done), false when the user backed out.
fn fillFields(ctx: *Ctx, type_index: usize) !bool {
    const t = types.QR_TYPES[type_index];

    var values: std.ArrayList(types.KV) = .empty;
    defer {
        for (values.items) |kv| ctx.gpa.free(kv.value);
        values.deinit(ctx.gpa);
    }

    var field_index: usize = 0;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(ctx.gpa);

    while (field_index < t.fields.len) {
        const field = t.fields[field_index];
        try drawFill(ctx, t, values.items, field, buffer.items);
        const key = try ctx.term.readKey();
        switch (key) {
            .escape => return false, // back to picker
            .enter => {
                const trimmed = std.mem.trim(u8, buffer.items, " \t");
                if (trimmed.len == 0 and !field.optional) continue; // required can't be empty
                try values.append(ctx.gpa, .{ .key = field.key, .value = try ctx.gpa.dupe(u8, buffer.items) });
                buffer.clearRetainingCapacity();
                field_index += 1;
            },
            .backspace => {
                if (buffer.items.len > 0) _ = buffer.pop();
            },
            .char => |c| try buffer.append(ctx.gpa, c),
            else => {},
        }
    }

    const payload = try t.build(ctx.gpa, .{ .entries = values.items });
    defer ctx.gpa.free(payload);

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    try printQr(ctx, &aw.writer, payload);
    try aw.writer.print("{s}Press any key to exit.{s}\n", .{ term.dim, term.reset });
    ctx.term.clear();
    ctx.term.writeAll(aw.written());
    _ = try ctx.term.readKey();
    return true;
}

fn drawPicker(ctx: *Ctx, selected: usize) !void {
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{s}{s}What kind of QR code?{s}\n", .{ term.bold, term.fg_cyan, term.reset });
    try w.print("{s}\u{2191}/\u{2193} to move \u{00b7} Enter to select \u{00b7} Esc to quit{s}\n\n", .{ term.dim, term.reset });
    for (types.QR_TYPES, 0..) |t, i| {
        const sel = i == selected;
        const marker = if (sel) "\u{276f} " else "  ";
        const color = if (sel) term.fg_green else term.fg_cyan;
        try w.print("{s}{s}{s: <14}{s}{s}{s}\n", .{ marker, color, t.label, term.reset, term.dim, t.hint });
        try w.writeAll(term.reset);
    }
    ctx.term.clear();
    ctx.term.writeAll(aw.written());
}

fn drawFill(ctx: *Ctx, t: types.QrType, filled: []const types.KV, field: types.QrField, buffer: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{s}{s}{s}{s} \u{2014} Enter to confirm \u{00b7} Esc to go back{s}\n\n", .{ term.bold, term.fg_cyan, t.label, term.reset, term.reset });
    for (filled) |kv| {
        try w.print("{s}{s: <26}{s}{s}\n", .{ term.dim, kvLabel(t, kv.key), term.reset, kv.value });
    }
    const opt = if (field.optional) " (optional)" else "";
    try w.print("{s}{s}{s}{s: <14}{s}{s}{s}", .{ term.bold, term.fg_green, field.label, "", opt, term.reset, buffer });
    try w.print("{s}\u{258f}{s}", .{ term.fg_green, term.reset });
    if (buffer.len == 0) {
        if (field.placeholder) |ph| try w.print("{s} e.g. {s}{s}", .{ term.dim, ph, term.reset });
    }
    try w.writeAll("\n");
    ctx.term.clear();
    ctx.term.writeAll(aw.written());
}

fn kvLabel(t: types.QrType, key: []const u8) []const u8 {
    for (t.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.label;
    }
    return key;
}
