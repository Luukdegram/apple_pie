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

/// Builds query parameters from url's `raw_query`
/// Memory is owned by caller
/// Each key and value must be freed individually, calling `deinit` on the
/// result of this, will do exactly that.
pub fn queryParameters(self: Uri, gpa: std.mem.Allocator) DecodeError!KeyValueMap {
    return decodeQueryString(gpa, self.query orelse return KeyValueMap{ .map = .{} });
}

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

/// Possible errors when decoding
const DecodeError = error{ OutOfMemory, InvalidCharacter };

/// Parses the given payload into URI components.
/// All components will be validated against invalid characters
pub fn parse(buffer: []const u8) ParseError!Uri {
    var uri = Uri.empty;
    if (buffer.len == 0) return uri;

    var position: usize = 0;
    if (buffer[0] == '/') {
        try parsePath(&uri, buffer, true);
    } else {
        try parseSchema(&uri, buffer);
        position += uri.scheme.?.len;
        try consumePart("://", buffer[position..]);
        position += 3;
        position += try parseAuthority(&uri, buffer[position..]);
        if (position == buffer.len) return uri;
        if (buffer[position] == '/') {
            try parsePath(&uri, buffer[position..], false);
        } else uri.path = "";
    }
    position += uri.path.len;
    if (position == buffer.len) return uri;
    if (buffer[position] == '?') {
        try parseQuery(&uri, buffer[position..]);
        position += uri.query.?.len + 1;
    }
    if (position == buffer.len) return uri;
    std.debug.assert(buffer[position] == '#');
    try parseFragment(&uri, buffer[position..]);

    return uri;
}

/// Wrapping map over a map of keys and values
/// that provides an easy way to free all its memory.
pub const KeyValueMap = struct {
    /// inner map
    map: MapType,

    const MapType = std.StringHashMapUnmanaged([]const u8);

    /// Frees all memory owned by this `KeyValueMap`
    pub fn deinit(self: *KeyValueMap, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |pair| {
            gpa.free(pair.key_ptr.*);
            gpa.free(pair.value_ptr.*);
        }
        self.map.deinit(gpa);
    }

    /// Wrapping method over inner `map`'s `get()` function for easy access
    pub fn get(self: KeyValueMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// Wrapping method over inner map's `iterator()` function for easy access
    pub fn iterator(self: KeyValueMap) MapType.Iterator {
        return self.map.iterator();
    }
};

/// Decodes a query string into key-value pairs. This will also
/// url-decode and replace %<hex> with its ascii value.
///
/// Memory is owned by the caller and as each key and value are allocated due to decoding,
/// must be freed individually. Calling `deinit` on the result, will do this.
pub fn decodeQueryString(gpa: std.mem.Allocator, data: []const u8) DecodeError!KeyValueMap {
    var queries = KeyValueMap{ .map = KeyValueMap.MapType{} };
    errdefer queries.deinit(gpa);

    var query = data;
    if (std.mem.startsWith(u8, query, "?")) {
        query = query[1..];
    }
    while (query.len > 0) {
        var key = query;
        if (std.mem.indexOfScalar(u8, key, '&')) |index| {
            query = key[index + 1 ..];
            key = key[0..index];
        } else {
            query = "";
        }

        if (key.len == 0) continue;
        var value: []const u8 = undefined;
        if (std.mem.indexOfScalar(u8, key, '=')) |index| {
            value = key[index + 1 ..];
            key = key[0..index];
        }

        key = try decode(gpa, key);
        errdefer gpa.free(key);
        value = try decode(gpa, value);
        errdefer gpa.free(value);

        try queries.map.put(gpa, key, value);
    }

    return queries;
}

/// Decodes the given input `value` by decoding the %hex number into ascii
/// memory is owned by caller
pub fn decode(allocator: std.mem.Allocator, value: []const u8) DecodeError![]const u8 {
    var perc_counter: usize = 0;
    var has_plus: bool = false;

    // find % and + symbols to determine buffer size
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '%' => {
                perc_counter += 1;
                if (i + 2 > value.len or !std.ascii.isAlNum(value[i + 1]) or !std.ascii.isAlNum(value[i + 2])) {
                    return error.InvalidCharacter;
                }
                i += 2;
            },
            '+' => {
                has_plus = true;
            },
            else => {},
        }
    }

    // replace url encoded string
    var buffer = try std.ArrayList(u8).initCapacity(allocator, value.len - 2 * perc_counter);
    defer buffer.deinit();

    // No decoding required, so copy into allocated buffer so the result
    // can be freed consistantly.
    if (perc_counter == 0 and !has_plus) {
        buffer.appendSliceAssumeCapacity(value);
        return buffer.toOwnedSlice();
    }

    i = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '%' => {
                const a = try std.fmt.charToDigit(value[i + 1], 16);
                const b = try std.fmt.charToDigit(value[i + 2], 16);
                buffer.appendAssumeCapacity(a << 4 | b);
                i += 2;
            },
            '+' => buffer.appendAssumeCapacity(' '),
            else => buffer.appendAssumeCapacity(value[i]),
        }
    }
    return buffer.toOwnedSlice();
}

/// Sanitizes the given `path` by removing '..' etc.
/// This returns a slice from a static buffer and therefore requires no allocations
pub fn resolvePath(path: []const u8, buffer: []u8) []const u8 {
    if (path.len == 0) {
        buffer[0] = '.';
        return buffer[0..1][0..];
    }

    const rooted = path[0] == '/';
    const len = path.len;
    std.mem.copy(u8, buffer, path);
    var out = BufferUtil.init(buffer, path);

    var i: usize = 0;
    var dot: usize = 0;

    if (rooted) {
        out.append('/');
        i = 1;
        dot = 1;
    }

    while (i < len) {
        if (path[i] == '/') {
            // empty path element
            i += 1;
            continue;
        }

        if (path[i] == '.' and (i + 1 == len or path[i + 1] == '/')) {
            // . element
            i += 1;
            continue;
        }

        if (path[i] == '.' and path[i + 1] == '.' and (i + 2 == len or path[i + 2] == '/')) {
            // .. element, remove '..' bits till last '/'
            i += 2;

            if (out.index > dot) {
                out.index -= 1;

                while (out.index > dot and out.char() != '/') : (out.index -= 1) {}
                continue;
            }

            if (!rooted) {
                if (out.index > 0) out.append('/');
                out.append('.');
                out.append('.');
                dot = out.index;
                continue;
            }
        }

        if (rooted and out.index != 1 or !rooted and out.index != 0) out.append('/');

        while (i < len and path[i] != '/') : (i += 1) {
            out.append(path[i]);
        }
    }

    if (out.index == 0) {
        buffer[0] = '.';
        return buffer[0..1][0..];
    }

    return out.result();
}

const BufferUtil = struct {
    buffer: []u8,
    index: usize,
    path: []const u8,

    fn init(buffer: []u8, path: []const u8) BufferUtil {
        return .{ .buffer = buffer, .index = 0, .path = path };
    }

    fn append(self: *BufferUtil, c: u8) void {
        std.debug.assert(self.index < self.buffer.len);

        if (self.index < self.path.len and self.path[self.index] == c) {
            self.index += 1;
            return;
        }

        self.buffer[self.index] = c;
        self.index += 1;
    }

    fn char(self: BufferUtil) u8 {
        return self.buffer[self.index];
    }

    fn result(self: BufferUtil) []const u8 {
        return self.buffer[0..self.index][0..];
    }
};

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
pub fn parseAuthority(uri: *Uri, buffer: []const u8) ParseError!usize {
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
            if (char == ':') {
                uri.username = user_info[0..index];
                colon_index = index;
                continue;
            }
            if (!isRegName(char)) return error.InvalidCharacter;
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
        '[' => try parseIpv6(uri, remaining[1..]),
        else => try parseHost(uri, remaining[0..]),
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

/// Parses the path
/// When `is_no_scheme` is true, it will ensure the first segment is non-zero without any colon
fn parsePath(uri: *Uri, buffer: []const u8, is_no_scheme: bool) ParseError!void {
    if (is_no_scheme) {
        if (buffer.len == 0) return error.InvalidCharacter;
        if (buffer.len == 1) {
            if (buffer[0] != '/') return error.InvalidCharacter;
            uri.path = "/";
            return;
        }
        if (buffer[1] == ':') return error.InvalidCharacter;
    }

    for (buffer) |char, index| {
        if (char == '?' or char == '#') {
            uri.path = buffer[0..index];
            return;
        }
        if (!isPChar(char) and char != '/') {
            return error.InvalidCharacter;
        }
    }
    uri.path = buffer;
}

/// Parses the query component of an URI
fn parseQuery(uri: *Uri, buffer: []const u8) ParseError!void {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer[0] == '?');
    for (buffer[1..]) |char, index| {
        if (char == '#') {
            uri.query = buffer[0..index];
            return;
        }
        if (!isPChar(char) and char != '/' and char != '?') {
            return error.InvalidCharacter;
        }
    }
    uri.query = buffer[1..];
}

/// Parses the fragment component of an URI
fn parseFragment(uri: *Uri, buffer: []const u8) ParseError!void {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer[0] == '#');
    for (buffer[1..]) |char| {
        if (!isPChar(char) and char != '/' and char != '?') {
            return error.InvalidCharacter;
        }
    }
    uri.fragment = buffer[1..];
}

fn consumePart(part: []const u8, buffer: []const u8) error{InvalidCharacter}!void {
    if (!std.mem.startsWith(u8, buffer, part)) return error.InvalidCharacter;
}

/// Returns true when Reg-name
/// *( unreserved / %<HEX> / sub-delims )
fn isRegName(char: u8) bool {
    return isUnreserved(char) or char == '%' or isSubDelim(char);
}

/// Checks if unreserved character
/// ALPHA / DIGIT/ [ "-" / "." / "_" / "~" ]
fn isUnreserved(char: u8) bool {
    return std.ascii.isAlNum(char) or switch (char) {
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

test "Userinfo" {
    const cases = .{
        .{ "https://user:password@host.com", "user", "password", "host.com" },
        .{ "https://user@host.com", "user", "", "host.com" },
    };

    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.username.?);
        if (uri.password) |password| {
            try std.testing.expectEqualStrings(case[2], password);
        } else try std.testing.expectEqualStrings(case[2], "");
        try std.testing.expectEqualStrings(case[3], uri.host.?);
    }

    const error_cases = .{
        "https://us|er@host.com",
        "https://user@password@host.com",
    };

    inline for (error_cases) |case| {
        try std.testing.expectError(ParseError.InvalidCharacter, parse(case));
    }
}

test "Path" {
    const cases = .{
        .{ "gemini://example.com:100/hello", "/hello" },
        .{ "gemini://example.com/hello/world", "/hello/world" },
        .{ "gemini://example.com/../hello", "/../hello" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.path);
    }
}

test "Query" {
    const cases = .{
        .{ "gemini://example.com:100/hello?", "" },
        .{ "gemini://example.com/?cool=true", "cool=true" },
        .{ "gemini://example.com?hello=world", "hello=world" },
    };

    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.query.?);
    }
}

test "Fragment" {
    const cases = .{
        .{ "gemini://example.com:100/hello?#hi", "hi" },
        .{ "gemini://example.com/#hello", "hello" },
        .{ "gemini://example.com#hello-world", "hello-world" },
    };
    inline for (cases) |case| {
        const uri = try parse(case[0]);
        try std.testing.expectEqualStrings(case[1], uri.fragment.?);
    }
}

test "Resolve paths" {
    const cases = .{
        // Already clean
        .{ .input = "", .expected = "." },
        .{ .input = "abc", .expected = "abc" },
        .{ .input = "abc/def", .expected = "abc/def" },
        .{ .input = "a/b/c", .expected = "a/b/c" },
        .{ .input = ".", .expected = "." },
        .{ .input = "..", .expected = ".." },
        .{ .input = "../..", .expected = "../.." },
        .{ .input = "../../abc", .expected = "../../abc" },
        .{ .input = "/abc", .expected = "/abc" },
        .{ .input = "/", .expected = "/" },

        // Remove trailing slash
        .{ .input = "abc/", .expected = "abc" },
        .{ .input = "abc/def/", .expected = "abc/def" },
        .{ .input = "a/b/c/", .expected = "a/b/c" },
        .{ .input = "./", .expected = "." },
        .{ .input = "../", .expected = ".." },
        .{ .input = "../../", .expected = "../.." },
        .{ .input = "/abc/", .expected = "/abc" },

        // Remove doubled slash
        .{ .input = "abc//def//ghi", .expected = "abc/def/ghi" },
        .{ .input = "//abc", .expected = "/abc" },
        .{ .input = "///abc", .expected = "/abc" },
        .{ .input = "//abc//", .expected = "/abc" },
        .{ .input = "abc//", .expected = "abc" },

        // Remove . elements
        .{ .input = "abc/./def", .expected = "abc/def" },
        .{ .input = "/./abc/def", .expected = "/abc/def" },
        .{ .input = "abc/.", .expected = "abc" },

        // Remove .. elements
        .{ .input = "abc/def/ghi/../jkl", .expected = "abc/def/jkl" },
        .{ .input = "abc/def/../ghi/../jkl", .expected = "abc/jkl" },
        .{ .input = "abc/def/..", .expected = "abc" },
        .{ .input = "abc/def/../..", .expected = "." },
        .{ .input = "/abc/def/../..", .expected = "/" },
        .{ .input = "abc/def/../../..", .expected = ".." },
        .{ .input = "/abc/def/../../..", .expected = "/" },
        .{ .input = "abc/def/../../../ghi/jkl/../../../mno", .expected = "../../mno" },

        // Combinations
        .{ .input = "abc/./../def", .expected = "def" },
        .{ .input = "abc//./../def", .expected = "def" },
        .{ .input = "abc/../../././../def", .expected = "../../def" },
    };

    inline for (cases) |case| {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, resolvePath(case.input, &buf));
    }
}

test "decode url encoded data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("hello, world", try decode(arena.allocator(), "hello%2C+world"));
    try std.testing.expectEqualStrings("contact@example.com", try decode(arena.allocator(), "contact%40example.com"));
}

test "Retrieve query parameters" {
    const path = "/example?name=value";
    const uri = try parse(path);

    var query_params = try uri.queryParameters(std.testing.allocator);
    defer query_params.deinit(std.testing.allocator);
    try std.testing.expect(query_params.map.contains("name"));
    try std.testing.expectEqualStrings("value", query_params.get("name") orelse " ");
}
