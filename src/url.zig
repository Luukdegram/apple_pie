const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// QueryParameters is an alias for a String HashMap
pub const QueryParameters = std.StringHashMap([]const u8);

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
    pub fn queryParameters(self: @This(), allocator: *Allocator) !QueryParameters {
        var queries = QueryParameters.init(allocator);
        errdefer queries.deinit();

        var query = self.raw_query;
        if (std.mem.startsWith(u8, query, "?")) {
            query = query[1..];
        }
        while (query.len > 0) {
            var key = query;
            if (std.mem.indexOfAny(u8, key, "&")) |index| {
                query = key[index + 1 ..];
                key = key[0..index];
            } else {
                query = "";
            }

            if (key.len == 0) continue;
            var value: []const u8 = undefined;
            if (std.mem.indexOfAny(u8, key, "=")) |index| {
                value = key[index + 1 ..];
                key = key[0..index];
            }

            key = try unescape(allocator, key);
            value = try unescape(allocator, value);

            _ = try queries.put(key, value);
        }

        return queries;
    }
};

/// Unescapes the given string literal by decoding the %hex number into ascii
/// memory is owned & freed by caller
fn unescape(allocator: *Allocator, value: []const u8) ![]const u8 {
    var perc_counter: usize = 0;
    var has_plus: bool = false;

    // find % and + symbols to determine buffer size
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '%' => {
                perc_counter += 1;
                if (i + 2 > value.len or !isHex(value[i + 1]) or !isHex(value[i + 2])) {
                    return error.MalformedUrl;
                }
                i += 2;
            },
            '+' => {
                has_plus = true;
            },
            else => {},
        }
    }
    if (perc_counter == 0 and !has_plus) return value;

    // replace url encoded string
    var buffer = try allocator.alloc(u8, value.len - 2 * perc_counter);
    errdefer allocator.free(buffer);

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

/// Escapes a string by encoding symbols so it can be safely used inside an URL
fn escape(value: []const u8) []const u8 {}

/// Returns true if the given byte is heximal
fn isHex(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

test "Basic raw query" {
    const path = "/example?name=value";
    const url: Url = try Url.init(path);

    testing.expectEqualSlices(u8, "?name=value", url.raw_query);
}

test "Retrieve query parameters" {
    const path = "/example?name=value";
    const url: Url = try Url.init(path);

    const query_params = try url.queryParameters(testing.allocator);
    defer query_params.deinit();
    testing.expect(query_params.contains("name"));
    testing.expectEqualSlices(u8, "value", query_params.getValue("name") orelse " ");
}
