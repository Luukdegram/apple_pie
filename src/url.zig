const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Wrapping map over a map of keys and values
/// that provides an easy way to free all its memory.
pub const KeyValueMap = struct {
    /// inner map
    map: MapType,

    const MapType = std.StringHashMapUnmanaged([]const u8);

    /// Frees all memory owned by this `KeyValueMap`
    pub fn deinit(self: *KeyValueMap, gpa: Allocator) void {
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

/// Possible errors when parsing query parameters
const QueryError = error{ MalformedUrl, OutOfMemory, InvalidCharacter };

pub const Url = struct {
    path: []const u8,
    raw_path: []const u8,
    raw_query: []const u8,

    /// Builds a new URL from a given path
    pub fn init(path: []const u8) Url {
        const query = blk: {
            var raw_query: []const u8 = undefined;
            if (std.mem.indexOf(u8, path, "?")) |index| {
                raw_query = path[index..];
            } else {
                raw_query = "";
            }
            break :blk raw_query;
        };

        return Url{
            .path = path[0 .. path.len - query.len],
            .raw_path = path,
            .raw_query = query,
        };
    }

    /// Builds query parameters from url's `raw_query`
    /// Memory is owned by caller
    /// Note: For now, each key/value pair needs to be freed manually
    pub fn queryParameters(self: Url, gpa: Allocator) QueryError!KeyValueMap {
        return decodeQueryString(gpa, self.raw_query);
    }
};

/// Decodes a query string into key-value pairs. This will also
/// url-decode and replace %<hex> with its ascii value.
///
/// Memory is owned by the caller and as each key and value are allocated due to decoding,
/// must be freed individually
pub fn decodeQueryString(gpa: Allocator, data: []const u8) QueryError!KeyValueMap {
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
pub fn decode(allocator: Allocator, value: []const u8) QueryError![]const u8 {
    var perc_counter: usize = 0;
    var has_plus: bool = false;

    // find % and + symbols to determine buffer size
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '%' => {
                perc_counter += 1;
                if (i + 2 > value.len or !isHex(value[i + 1]) or !isHex(value[i + 2])) {
                    return QueryError.MalformedUrl;
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
    const buffer = try allocator.alloc(u8, value.len - 2 * perc_counter);
    errdefer allocator.free(buffer);

    // No decoding required, so copy into allocated buffer so the result
    // can be freed consistantly.
    if (perc_counter == 0 and !has_plus) {
        std.mem.copy(u8, buffer, value);
        return buffer;
    }

    i = 0;
    while (i < buffer.len) : (i += 1) {
        switch (value[i]) {
            '%' => {
                const a = try std.fmt.charToDigit(value[i + 1], 16);
                const b = try std.fmt.charToDigit(value[i + 2], 16);
                buffer[i] = a << 4 | b;
                i += 2;
            },
            '+' => buffer[i] = ' ',
            else => buffer[i] = value[i],
        }
    }
    return buffer;
}

/// Sanitizes the given `path` by removing '..' etc.
/// This returns a slice from a static buffer and therefore requires no allocations
pub fn sanitize(path: []const u8, buffer: []u8) []const u8 {
    // var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;

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

/// Escapes a string by encoding symbols so it can be safely used inside an URL
fn escape(value: []const u8) []const u8 {
    _ = value;
    @compileError("TODO: Implement escape()");
}

/// Returns true if the given byte is heximal
fn isHex(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

test "Basic raw query" {
    const path = "/example?name=value";
    const url: Url = Url.init(path);

    try testing.expectEqualSlices(u8, "?name=value", url.raw_query);
}

test "Retrieve query parameters" {
    const path = "/example?name=value";
    const url: Url = Url.init(path);

    var query_params = try url.queryParameters(testing.allocator);
    defer query_params.deinit(testing.allocator);
    try testing.expect(query_params.map.contains("name"));
    try testing.expectEqualStrings("value", query_params.get("name") orelse " ");
}

test "Sanitize paths" {
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
        try testing.expectEqualStrings(case.expected, sanitize(case.input, &buf));
    }
}
