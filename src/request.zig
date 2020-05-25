const std = @import("std");
const Url = @import("url.zig").Url;

/// Represents a request made by a client
pub const Request = struct {
    method: []const u8,
    url: Url,
    headers: Headers,
    body: []const u8,
    allocator: *std.mem.Allocator,
    protocol: []const u8,

    pub fn deinit(self: @This()) void {
        self.headers.deinit();
        self.url.deinit();

        const allocator = self.allocator;
        allocator.free(self.body);
        allocator.free(self.method);
        allocator.free(self.protocol);
    }
};

/// Headers is a map that contains name and value of headers
pub const Headers = std.StringHashMap([]const u8);

/// parse accepts an `io.InStream`, it will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt
pub fn parse(
    allocator: *std.mem.Allocator,
    stream: var,
) !Request {
    const State = enum {
        RequestLine,
        Header,
        Body,
    };

    var state: State = .RequestLine;

    var request: Request = undefined;
    request.body = "";
    request.allocator = allocator;

    // per line we accept 4Kb, this should be enough
    var buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);

    request.headers = Headers.init(allocator);
    errdefer request.headers.deinit();

    // read stream until end of file, parse each line
    while (try stream.readUntilDelimiterOrEof(buffer, '\n')) |bytes| {
        switch (state) {
            .RequestLine => {
                var parts = std.mem.split(bytes, " ");
                var index: usize = 0;
                while (parts.next()) |part| : (index += 1) {
                    switch (index) {
                        0 => {
                            var method_buffer = try allocator.alloc(u8, part.len);
                            std.mem.copy(u8, method_buffer, part);
                            request.method = method_buffer;
                        },
                        1 => {
                            request.url = try Url.init(allocator, part);
                        },
                        2 => {
                            var proto_buffer = try allocator.alloc(u8, part.len);
                            std.mem.copy(u8, proto_buffer, part);
                            request.protocol = proto_buffer;
                        },
                        else => unreachable,
                    }
                }
                state = .Header;
            },
            .Header => {
                // read until all headers are parsed, if false is returned, assume body has started
                // and set the current state to .Body (only if content-length is defined)
                var header_buffer = try allocator.alloc(u8, bytes.len);
                std.mem.copy(u8, header_buffer, bytes);
                if (!try parseHeader(&request.headers, header_buffer)) {
                    if (request.headers.contains("Content-Length")) {
                        state = .Body;
                    } else {
                        break;
                    }
                }
            },
            .Body => {
                if (request.headers.getValue("Content-Length")) |value| {
                    const length = try std.fmt.parseInt(usize, value, 10);
                    var body = try allocator.alloc(u8, length);
                    _ = try stream.read(body);
                    request.body = body;
                    break;
                }
            },
        }
    }
    return request;
}

/// Attempts to parse a line into a header, returns `null` if no header is found
fn parseHeader(headers: *Headers, bytes: []u8) !bool {
    if (bytes.len == 0 or bytes[0] == 13) return false;

    // each header is defined by "name: value"
    var parts = std.mem.split(bytes, ": ");

    const key = parts.next() orelse unreachable;
    const value = parts.next() orelse unreachable;

    // overwrite duplicate keys, remove carriage return from value
    _ = try headers.put(key, value[0 .. value.len - 1]);
    return true;
}

test "Basic request parse" {
    const allocator = std.testing.allocator;
    const contents =
        \\GET /test?test HTTP/1.1
        \\Host: localhost:8080
        \\User-Agent: insomnia/7.1.1
        \\Accept: */*
        \\
        \\
    ;

    const stream = std.io.fixedBufferStream(contents).inStream();
    var request = try parse(allocator, stream);
    defer request.deinit();

    std.testing.expect(request.headers.size == 3);
    std.testing.expectEqualSlices(u8, "/test?test", request.url.path);
    std.testing.expectEqualSlices(u8, "HTTP/1.1", request.protocol);
    std.testing.expectEqualSlices(u8, "GET", request.method);
    std.testing.expect(request.body.len == 0);
}
