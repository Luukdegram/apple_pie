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

    /// Frees all memory of a Response, as this loops through each header to remove its memory
    /// you may consider using an arena allocator to free all memory at once for better perf
    pub fn deinit(self: @This()) void {
        const allocator = self.allocator;

        //free header memory, perhaps find a better way for perf
        var it = self.headers.iterator();
        while (it.next()) |header| {
            allocator.free(header.key);
            allocator.free(header.value);
        }
        self.headers.deinit();
        self.url.deinit();

        allocator.free(self.body);
        allocator.free(self.method);
        allocator.free(self.protocol);
    }
};

/// Headers is a map that contains name and value of headers
pub const Headers = std.StringHashMap([]const u8);

/// Parse accepts an `io.InStream`, it will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt
/// The memory of the `Request` is owned by the caller and can be freed by using deinit()
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
                            request.method = try allocator.dupe(u8, part);
                        },
                        1 => {
                            request.url = try Url.init(allocator, part);
                        },
                        2 => {
                            // remove carrot from end so length -1
                            request.protocol = try allocator.dupe(u8, part[0 .. part.len - 1]);
                        },
                        else => unreachable,
                    }
                }
                state = .Header;
            },
            .Header => {
                // read until all headers are parsed, if false is returned, assume body has started
                // and set the current state to .Body (only if content-length is defined)
                if (!try parseHeader(&request.headers, allocator, bytes)) {
                    if (request.headers.contains("Content-Length")) {
                        state = .Body;
                    } else {
                        break;
                    }
                }
            },
            .Body => {
                const value = request.headers.getValue("Content-Length") orelse unreachable;
                const length = try std.fmt.parseInt(usize, value, 10);
                var body = try allocator.alloc(u8, length);
                _ = try stream.read(body);
                request.body = body;
                break;
            },
        }
    }
    return request;
}

/// Attempts to parse a line into a header, returns `null` if no header is found
/// Each KV needs to be freed manually
fn parseHeader(headers: *Headers, allocator: *std.mem.Allocator, bytes: []u8) !bool {
    if (bytes.len == 0 or bytes[0] == 13) return false;

    // remove last byte for carrot return
    const header_string = bytes[0 .. bytes.len - 1];

    // each header is defined by "name: value"
    var parts = std.mem.split(header_string, ": ");

    const key = parts.next() orelse unreachable;
    const value = parts.next() orelse unreachable;

    // overwrite duplicate keys, remove carriage return from value
    _ = try headers.put(
        try allocator.dupe(u8, key),
        try allocator.dupe(u8, value),
    );
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
