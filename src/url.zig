const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Url = struct {
    path: []const u8,
    raw_path: []const u8,
    raw_query: []const u8,
    allocator: *Allocator,

    /// Builds a new URL from a given path
    pub fn init(allocator: *Allocator, path: []const u8) !Url {
        var buffer = try allocator.alloc(u8, path.len);
        std.mem.copy(u8, buffer, path);

        const query = blk: {
            var raw_query: []const u8 = undefined;
            if (std.mem.indexOf(u8, buffer, "?")) |index| {
                raw_query = buffer[index + 1 ..];
            } else {
                raw_query = "";
            }
            break :blk raw_query;
        };

        return Url{
            .path = buffer,
            .raw_path = buffer,
            .raw_query = query,
            .allocator = allocator,
        };
    }

    /// Frees Url's memory
    pub fn deinit(self: @This()) void {
        const allocator = self.allocator;
        // raw_path contains full buffer right now, so free only this for now.
        allocator.free(self.raw_path);
    }

    /// Builds query parameters from url's `raw_query`
    /// Memory is owned by caller
    pub fn queryParameters(self: @This(), allocator: *Allocator) std.StringHashMap([]const u8) {
        var query = self.raw_query;
        while (query.len > 0) {
            var key = query;
            if (std.mem.indexOfAny(u8, key, "&")) |index| {
                query = key[index..];
                key = key[0..index];
            }
            if (key.len == 0) continue;
            var value: []u8 = undefined;
            if (std.mem.indexOfAny(u8, key, "=")) |index| {
                value = key[index..];
                key = key[0..index];
            }
        }
    }
};

test "Basic raw query" {
    const path = "/example?name=value";
    const url: Url = try Url.init(testing.allocator, path);
    defer url.deinit();

    testing.expectEqualSlices(u8, "name=value", url.raw_query);
}
