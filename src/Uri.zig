//! Implements RFC3986's generic syntax
//! https://datatracker.ietf.org/doc/html/rfc3986
const Uri = @This();

/// Scheme component of an URI, such as 'https'
scheme: ?[]const u8,
/// The username of the userinfo component within an URI
username: ?[]const u8,
/// The password of the userinfo component.
/// NOTE: This subcomponent is deprecated and will not be shown
/// in the formatter, consider omitting the password.
password: ?[]const u8,
/// Host component within an URI, such as https://<host>
host: ?[]const u8,
/// Parsed port comonent of an URI, such as https://host:<port>
port: ?u16,
/// The path component of an URI: https://<host><path>
/// Note: It's possible for the path to be empty.
path: []const u8,
/// Query component of the URI such as https://<host>?<query>
query: ?[]const u8,
/// Fragment identifier component, which allows for indirect identification
/// of a secondary resource.
fragment: ?[]const u8,

pub const empty: Uri = .{
    .scheme = null,
    .username = null,
    .password = null,
    .host = null,
    .port = null,
    .path = &.{},
    .query = null,
    .fragment = null,
};

/// Format function according to std's format signature.
/// This will format the URI as an URL.
/// NOTE: This will *NOT* print out the password component.
pub fn format(self: Uri, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = options;
    _ = fmt;
    if (self.scheme) |scheme| {
        try writer.writeAll(scheme);
        try writer.writeAll("://");

        if (self.username) |name| {
            try writer.writeAll(name);
            try writer.writeByte('@');
        }
        if (self.host) |host| {
            try writer.writeAll(host);
        }
        if (self.port) |port| {
            try writer.print(":{d}", .{port});
        }
    }
    try writer.writeAll(self.path);

    if (self.query) |query| {
        try writer.writeByte('?');
        try writer.writeAll(query);
    }
    if (self.fragment) |fragment| {
        try writer.writeByte('#');
        try writer.writeAll(fragment);
    }
}

const std = @import("std");

/// When attempting to parse a buffer into URI components,
/// the following errors may occur.
pub const ParseError = error{
    /// The URI contains a scheme, but is missing a host
    MissingHost,
    /// The port was included but could not be parsed,
    /// or exceeds 65535.
    InvalidPort,
    /// Expected a specific character, but instead found a different one
    InvalidCharacter,
};

pub fn parse(buffer: []const u8) ParseError!Uri {
    var uri = Uri.empty;
    if (buffer.len == 0) return uri;

    var position: usize = 0;
    if (buffer[0] == '/') {
        // try parsePath(&uri, buffer);
    } else {
        try parseSchema(&uri, buffer);
        const valid_schema = try consumePart("://", buffer[uri.scheme.?.len..]);
        position = try parseAuthority(&uri, valid_schema);
        if (position == buffer.len) return uri;
        if (buffer[position] == '/') {
            // try parsePath(&uri, buffer[position..]);
        } else uri.path = "";
    }
    position += uri.path.len;
    if (position == buffer.len) return uri;

    return uri;
}

/// From a given buffer, attempts to parse the scheme
fn parseSchema(uri: *Uri, buffer: []const u8) error{InvalidCharacter}!void {
    if (!std.ascii.isAlpha(buffer[0])) return error.InvalidCharacter;
    for (buffer[1..]) |char, index| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
            else => {
                uri.scheme = buffer[0 .. index + 1];
                return;
            },
        }
    }
    uri.scheme = buffer;
    return;
}

/// Parses the authority and its subcomponents of an URI
fn parseAuthority(uri: *Uri, buffer: []const u8) ParseError!usize {
    if (buffer.len == 0) return 0;
    // get the end of the authority component and also
    // parse each character to ensure it's a valid character.
    const end = for (buffer) |char, index| {
        if (char == '/' or char == '#' or char == '?') break index;
    } else buffer.len;
    if (end == 0) return error.MissingHost;
    const authority = buffer[0..end];

    // maybe parse the userinfo subcomponent, in which case this block will
    // return the remaining slice consisting of the host + port
    const remaining = if (std.mem.indexOfScalar(u8, authority, '@')) |user_index| blk: {
        const user_info = authority[0..user_index];
        // verify userinfo characters
        var colon_index: usize = 0;
        for (user_info) |char, index| {
            if (!isRegName(char)) return error.InvalidCharacter;
            if (char == ':') {
                uri.username = user_info[0..index];
                colon_index = index;
            }
        }
        if (colon_index != 0 and colon_index < user_info.len - 1) {
            uri.password = user_info[colon_index..][1..];
        } else if (colon_index == 0) {
            uri.username = user_info;
        }

        break :blk authority[user_index..][1..];
    } else authority;

    if (remaining.len == 0) return error.MissingHost;
    switch (remaining[0]) {
        '[' => try parseIpv6(uri, remaining[1..end]),
        else => try parseHost(uri, remaining[0..end]),
    }

    return end;
}

/// Parses the host and port where host represents 'reg-name' from the URI spec.
/// This will also validate both host and port contain valid characters.
fn parseHost(uri: *Uri, buffer: []const u8) !void {
    const host_end = if (std.mem.lastIndexOfScalar(u8, buffer, ':')) |colon_pos| blk: {
        const end_port = for (buffer[colon_pos + 1 ..]) |char, index| {
            if (!std.ascii.isDigit(char)) break index;
        } else buffer.len - (colon_pos + 1);
        uri.port = std.fmt.parseInt(u16, buffer[colon_pos + 1 ..][0..end_port], 10) catch return error.InvalidPort;
        break :blk colon_pos;
    } else buffer.len;

    // validate host characters
    for (buffer[0..host_end]) |char| {
        if (!isRegName(char) and !isIpv4(char)) return error.InvalidCharacter;
    }
    uri.host = buffer[0..host_end];
}

/// Parses the host as an ipv6 address and when found, also parses
/// and validates the port.
fn parseIpv6(uri: *Uri, buffer: []const u8) !void {
    const end = std.mem.indexOfScalar(u8, buffer, ']') orelse return error.InvalidCharacter;
    if (end > 39) return error.InvalidCharacter; // IPv6 addresses consist of max 8 16-bit pieces.
    uri.host = buffer[0..end];
    for (uri.host.?) |char| {
        if (!isLs32(char)) return error.InvalidCharacter;
    }

    if (std.mem.indexOfScalarPos(u8, buffer, end, ':')) |colon_pos| {
        const end_port = for (buffer[colon_pos + 1 ..]) |char, index| {
            if (!std.ascii.isDigit(char)) break index;
        } else buffer.len - (colon_pos + 1);
        uri.port = std.fmt.parseInt(u16, buffer[colon_pos + 1 ..][0..end_port], 10) catch return error.InvalidPort;
    }
}

fn consumePart(part: []const u8, buffer: []const u8) error{InvalidCharacter}![]const u8 {
    if (!std.mem.startsWith(u8, buffer, part)) return error.InvalidCharacter;
    return buffer[part.len..];
}

/// Returns true when Reg-name
/// *( unreserved / %<HEX> / sub-delims )
fn isRegName(char: u8) bool {
    return isUnreserved(char) or char == '%' or isSubDelim(char);
}

/// Checks if unreserved character
/// ALPHA / DIGIT/ [ "-" / "." / "_" / "~" ]
fn isUnreserved(char: u8) bool {
    return std.ascii.isAlpha(char) or std.ascii.isDigit(char) or switch (char) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Returns true when character is a sub-delim character
/// !, $, &, \, (, ), *, *, +, ',', =
fn isSubDelim(char: u8) bool {
    return switch (char) {
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        '=',
        => true,
        else => false,
    };
}

/// Returns true when given char is pchar
/// unreserved / pct-encoded / sub-delims / ":" / "@"
fn isPChar(char: u8) bool {
    return switch (char) {
        '%', ':', '@' => true,
        else => isUnreserved(char) or isSubDelim(char),
    };
}

fn isLs32(char: u8) bool {
    return std.ascii.isAlNum(char) or char == ':' or char == '.';
}

fn isIpv4(char: u8) bool {
    return std.ascii.isDigit(char) or char == '.';
}

test "Format" {
    const uri: Uri = .{
        .scheme = "https",
        .username = "user",
        .password = "secret",
        .host = "example.com",
        .port = 8080,
        .path = "/index.html",
        .query = "hello=world",
        .fragment = "header1",
    };

    try std.testing.expectFmt(
        "https://user@example.com:8080/index.html?hello=world#header1",
        "{}",
        .{uri},
    );
}

test "Scheme" {
    const cases = .{
        .{ "https://", "https" },
        .{ "gemini://", "gemini" },
        .{ "git://", "git" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.scheme.?);
    }

    const error_cases = .{
        "htt?s", "gem||", "ha$",
    };

    inline for (error_cases) |case| {
        try std.testing.expectError(ParseError.InvalidCharacter, parse(case));
    }
}

test "Host" {
    const cases = .{
        .{ "https://exa2ple", "exa2ple" },
        .{ "gemini://example.com", "example.com" },
        .{ "git://sub.domain.com", "sub.domain.com" },
        .{ "https://[2001:db8:0:0:0:0:2:1]", "2001:db8:0:0:0:0:2:1" },
        .{ "https://[::ffff:192.168.100.228]", "::ffff:192.168.100.228" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.host.?);
    }

    const error_cases = .{
        "https://exam|",
        "gemini://exa\"",
        "git://sub.example.[om",
        "https://[::ffff:192.$168.100.228]",
    };

    inline for (error_cases) |case| {
        try std.testing.expectError(ParseError.InvalidCharacter, parse(case));
    }
}
