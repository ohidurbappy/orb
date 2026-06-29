const std = @import("std");

pub const QrField = struct {
    key: []const u8,
    label: []const u8,
    placeholder: ?[]const u8 = null,
    optional: bool = false,
};

pub const KV = struct { key: []const u8, value: []const u8 };

/// Entered field values, with helpers mirroring the TS `get`/raw access.
pub const Values = struct {
    entries: []const KV,

    /// Raw value for a key, or "" when absent.
    pub fn raw(self: Values, key: []const u8) []const u8 {
        for (self.entries) |kv| {
            if (std.mem.eql(u8, kv.key, key)) return kv.value;
        }
        return "";
    }
    /// Trimmed value for a key (the TS `get` helper).
    pub fn get(self: Values, key: []const u8) []const u8 {
        return std.mem.trim(u8, self.raw(key), " \t\r\n");
    }
};

pub const BuildFn = *const fn (gpa: std.mem.Allocator, v: Values) anyerror![]u8;

pub const QrType = struct {
    id: []const u8,
    label: []const u8,
    hint: []const u8,
    fields: []const QrField,
    build: BuildFn,
};

// --- helpers -------------------------------------------------------------

/// Escape the characters significant inside a `WIFI:` payload.
fn escapeWifi(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (value) |c| {
        switch (c) {
            '\\', ';', ',', ':', '"' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// True if `url` already starts with a `scheme://` prefix.
fn hasScheme(url: []const u8) bool {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return false;
    var i: usize = 1;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        if (std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-') continue;
        // First non-scheme char must begin "://".
        return std.mem.startsWith(u8, url[i..], "://");
    }
    return false;
}

/// application/x-www-form-urlencoded encoding (URLSearchParams semantics):
/// space→'+', unreserved kept, everything else percent-encoded.
fn formEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '*' or c == '-' or c == '.' or c == '_') {
            try out.append(gpa, c);
        } else if (c == ' ') {
            try out.append(gpa, '+');
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0xf]);
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- build functions ------------------------------------------------------

fn buildText(gpa: std.mem.Allocator, v: Values) ![]u8 {
    return gpa.dupe(u8, v.raw("text"));
}

fn buildUrl(gpa: std.mem.Allocator, v: Values) ![]u8 {
    const url = v.get("url");
    if (hasScheme(url)) return gpa.dupe(u8, url);
    return std.fmt.allocPrint(gpa, "https://{s}", .{url});
}

fn buildTel(gpa: std.mem.Allocator, v: Values) ![]u8 {
    return std.fmt.allocPrint(gpa, "tel:{s}", .{v.get("number")});
}

fn buildSms(gpa: std.mem.Allocator, v: Values) ![]u8 {
    const number = v.get("number");
    const message = v.get("message");
    if (message.len > 0) return std.fmt.allocPrint(gpa, "SMSTO:{s}:{s}", .{ number, message });
    return std.fmt.allocPrint(gpa, "SMSTO:{s}", .{number});
}

fn buildEmail(gpa: std.mem.Allocator, v: Values) ![]u8 {
    const to = v.get("to");
    const subject = v.get("subject");
    const body = v.get("body");

    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(gpa);
    if (subject.len > 0) {
        const enc = try formEncode(gpa, subject);
        defer gpa.free(enc);
        try params.appendSlice(gpa, "subject=");
        try params.appendSlice(gpa, enc);
    }
    if (body.len > 0) {
        const enc = try formEncode(gpa, body);
        defer gpa.free(enc);
        if (params.items.len > 0) try params.append(gpa, '&');
        try params.appendSlice(gpa, "body=");
        try params.appendSlice(gpa, enc);
    }
    if (params.items.len > 0) return std.fmt.allocPrint(gpa, "mailto:{s}?{s}", .{ to, params.items });
    return std.fmt.allocPrint(gpa, "mailto:{s}", .{to});
}

fn buildWifi(gpa: std.mem.Allocator, v: Values) ![]u8 {
    const ssid = try escapeWifi(gpa, v.get("ssid"));
    defer gpa.free(ssid);
    const password = try escapeWifi(gpa, v.get("password"));
    defer gpa.free(password);

    const has_password = password.len > 0;
    var enc_buf: [16]u8 = undefined;
    var enc: []const u8 = "nopass";
    if (has_password) {
        const raw_enc = v.get("encryption");
        if (raw_enc.len > 0) {
            enc = std.ascii.upperString(&enc_buf, raw_enc);
        } else {
            enc = "WPA";
        }
    }
    if (std.mem.eql(u8, enc, "nopass")) {
        return std.fmt.allocPrint(gpa, "WIFI:T:{s};S:{s};;", .{ enc, ssid });
    }
    return std.fmt.allocPrint(gpa, "WIFI:T:{s};S:{s};P:{s};;", .{ enc, ssid, password });
}

fn buildGeo(gpa: std.mem.Allocator, v: Values) ![]u8 {
    return std.fmt.allocPrint(gpa, "geo:{s},{s}", .{ v.get("lat"), v.get("lng") });
}

// --- the registry of QR types --------------------------------------------

pub const QR_TYPES = [_]QrType{
    .{ .id = "text", .label = "Text", .hint = "Any plain text", .fields = &.{
        .{ .key = "text", .label = "Text" },
    }, .build = buildText },
    .{ .id = "url", .label = "URL", .hint = "Open a website", .fields = &.{
        .{ .key = "url", .label = "URL", .placeholder = "example.com" },
    }, .build = buildUrl },
    .{ .id = "tel", .label = "Telephone", .hint = "Dial a phone number", .fields = &.{
        .{ .key = "number", .label = "Phone number", .placeholder = "+15551234567" },
    }, .build = buildTel },
    .{ .id = "sms", .label = "SMS", .hint = "Pre-filled text message", .fields = &.{
        .{ .key = "number", .label = "Phone number", .placeholder = "+15551234567" },
        .{ .key = "message", .label = "Message", .optional = true },
    }, .build = buildSms },
    .{ .id = "email", .label = "Email", .hint = "Pre-filled email", .fields = &.{
        .{ .key = "to", .label = "To", .placeholder = "name@example.com" },
        .{ .key = "subject", .label = "Subject", .optional = true },
        .{ .key = "body", .label = "Body", .optional = true },
    }, .build = buildEmail },
    .{ .id = "wifi", .label = "Wi-Fi", .hint = "Join a wireless network", .fields = &.{
        .{ .key = "ssid", .label = "Network name (SSID)" },
        .{ .key = "password", .label = "Password", .optional = true },
        .{ .key = "encryption", .label = "Encryption (WPA/WEP/nopass)", .placeholder = "WPA", .optional = true },
    }, .build = buildWifi },
    .{ .id = "geo", .label = "Location", .hint = "Geographic coordinates", .fields = &.{
        .{ .key = "lat", .label = "Latitude", .placeholder = "37.7749" },
        .{ .key = "lng", .label = "Longitude", .placeholder = "-122.4194" },
    }, .build = buildGeo },
};

pub fn byId(id: []const u8) ?QrType {
    for (QR_TYPES) |t| {
        if (std.mem.eql(u8, t.id, id)) return t;
    }
    return null;
}
