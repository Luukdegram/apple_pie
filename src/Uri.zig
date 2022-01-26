//! Implements RFC3986's generic syntax
//! https://datatracker.ietf.org/doc/html/rfc3986
const Uri = @This();

/// Scheme component of an URI, such as 'https'
scheme: []const u8,
/// The username of the userinfo component within an URI
username: ?[]const u8,
/// The password of the userinfo component.
/// NOTE: This subcomponent is deprecated and will not be shown
/// in the formatter, consider omitting the password.
password: ?[]const u8,
/// Host component within an URI, such as https://<host>
host: []const u8,
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

/// Format function according to std's format signature.
/// This will format the URI as an URL.
/// NOTE: This will *NOT* print out the password component.
pub fn format(self: Uri, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = options;
    _ = fmt;
    try writer.writeAll(self.scheme);
    try writer.writeAll("://");
    if (self.username) |name| {
        try writer.writeAll(name);
        try writer.writeByte('@');
    }
    try writer.writeAll(self.host);
    if (self.port) |port| {
        try writer.print(":{d}", .{port});
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
    /// Misses the scheme
    MissingScheme,
    /// URI is missing the host component
    MissingHost,
    /// The port was included but could not be parsed,
    /// or exceeds 65535.
    InvalidPort,
    /// Expected a specific character, but instead found a different one
    InvalidCharacter,
    /// Host contains an IP-literal, but is missing a closing ']'
    MissingClosingBracket,
};

pub fn parse(buffer: []const u8) ParseError!Uri {
    var uri: Uri = undefined;

    try parseSchema(&uri, buffer);
    const valid_schema = try consumePart("://", buffer);
    try parseAuthority(&uri, valid_schema);
}

/// From a given buffer, attempts to parse the scheme
fn parseSchema(uri: *Uri, buffer: []const u8) error{ MissingScheme, InvalidCharacter }!void {
    if (buffer.len == 0) return error.MissingScheme;
    if (!std.ascii.isAlpha(buffer[0])) return error.InvalidCharacter;
    for (buffer[1..]) |char, index| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
            else => {
                uri.scheme = buffer[0..index];
                return;
            },
        }
    }
    uri.scheme = buffer;
    return;
}

/// Parses the authority and its subcomponents of an URI
fn parseAuthority(uri: *Uri, buffer: []const u8) ParseError!void {
    if (buffer.len == 0) return error.MissingHost;

    // get the end of the authority component and also
    // parse each character to ensure it's a valid character.
    const end = for (buffer) |char, index| {
        if (char == '/' or char == '#' or char == '?') break index;
    } else buffer.len;
    if (end == 0) return error.MissingHost;
    const authority = buffer[0..end];

    // maybe parse the userinfo subcomponent, in which case this block will
    // return the remaining slice consisting of the host + port
    const remaining = if (std.mem.indexOfScalar(authority, '@')) |user_index| blk: {
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
        '[' => try parseIpv6(remaining[1..]),
        'v' => try parseIpvFuture(remaining[1..]),
        else => {},
    }
}

/// Attempts to parse the userinfo componant of an URI.
/// This component is optional in its entirely. It will set each subcomponent
/// to `null` in the event the component is non-existant.
fn parseUserInfo(uri: *Uri, buffer: []const u8) ParseError!void {
    std.debug.assert(uri.scheme.len != 0);
    uri.username = null;
    uri.password = null;
    if (std.mem.indexOfScalar(buffer, '@')) |index| {
        uri.username = buffer[0..index];
    }
    return;
}

fn consumePart(part: []const u8, buffer: []const u8) error{InvalidCharacter}![]const u8 {
    if (!std.mem.startsWith(buffer, part)) return error.InvalidCharacter;
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
