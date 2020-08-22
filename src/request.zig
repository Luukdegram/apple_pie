const std = @import("std");
const Url = @import("url.zig").Url;

/// Represents a request made by a client
pub const Request = struct {
    /// GET, POST, PUT, DELETE or PATCH
    method: []const u8,
    /// Url object, get be used to retrieve path or query parameters
    url: Url,
    /// Headers according to http2
    headers: std.http.Headers,
    /// Body, which can be empty
    body: []const u8,
    /// allocator which is used to free Request's memory
    allocator: *std.mem.Allocator,
    /// Protocol used by the requester, http1.1, http2.0, etc.
    protocol: []const u8,
    /// If the buffer was too small to include the body,
    /// extra memory will be allocated and is freed upon `deinit`
    allocated_body: bool,

    /// Frees all memory of a Response, as this loops through each header to remove its memory
    /// you may consider using an arena allocator to free all memory at once for better perf
    pub fn deinit(self: @This()) void {
        const allocator = self.allocator;

        self.headers.deinit();
        allocator.free(self.method);
        if (self.allocated_body) {
            allocator.free(self.body);
        }
    }
};

/// Parse accepts an `io.InStream`, it will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt
/// The memory of the `Request` is owned by the caller and can be freed by using deinit()
/// `buffer_size` is the size that is allocated to parse the request line and headers, any headers
/// bigger than this size will be skipped.
pub fn parse(
    allocator: *std.mem.Allocator,
    stream: anytype,
    buffer_size: usize,
) !Request {
    const State = enum {
        Method,
        Url,
        Protocol,
        Header,
        Body,
    };

    var state: State = .Method;

    var request: Request = undefined;
    request.body = "";
    request.method = "GET";
    request.url = try Url.init("/");
    request.allocator = allocator;
    request.headers = std.http.Headers.init(allocator);
    request.allocated_body = false;
    request.protocol = "HTTP/1.1";

    // Accept 4kb for requestline + headers
    // we allocate memory for body if neccesary seperately.
    var buffer = try allocator.alloc(u8, buffer_size);

    const read = try stream.read(buffer);
    buffer = buffer[0..read];

    var i: usize = 0;
    while (i < read) {
        switch (state) {
            .Method => {
                if (std.mem.indexOf(u8, buffer[i..], " ")) |index| {
                    request.method = buffer[i .. i + index];
                    i += request.method.len + 1;
                    state = .Url;
                } else {
                    return error.MissingMethod;
                }
            },
            .Url => {
                if (std.mem.indexOf(u8, buffer[i..], " ")) |index| {
                    request.url = try Url.init(buffer[i .. i + index]);
                    i += request.url.raw_path.len + 1;
                    state = .Protocol;
                } else {
                    return error.MissingUrl;
                }
            },
            .Protocol => {
                if (std.mem.indexOf(u8, buffer[i..], "\r\n")) |index| {
                    if (index > 8) return error.MissingProtocol;
                    request.protocol = buffer[i .. i + index];
                    i += request.protocol.len + 2; // skip \r\n
                    state = .Header;
                } else {
                    return error.MissingProtocol;
                }
            },
            .Header => {
                if (buffer[i] == '\r') {
                    if (!request.headers.contains("Content-Length")) break;
                    state = .Body;
                    i += 2; //Skip the \r\n
                    continue;
                }
                const index = std.mem.indexOf(u8, buffer[i..], ": ") orelse return error.MissingHeaders;
                const key = buffer[i .. i + index];
                i += key.len + 2; // skip ": "

                const end = std.mem.indexOf(u8, buffer[i..], "\r\n") orelse return error.IncorrectHeader;
                const value = buffer[i .. i + end];
                i += value.len + 2; //skip \r\n
                _ = try request.headers.append(key, value, null);
            },
            .Body => {
                const entries = (try request.headers.get(allocator, "Content-Length")).?;
                defer allocator.free(entries);
                const length = try std.fmt.parseInt(usize, entries[0].value, 10);

                // if body fit inside the 4kb buffer, we use that,
                // else allocate more memory
                if (length <= read - i) {
                    request.body = buffer[i..];
                } else {
                    var body = try allocator.alloc(u8, length);
                    std.mem.copy(u8, body, buffer[i..]);
                    _ = try stream.read(body[read - i ..]);
                    request.body = body;
                    request.allocated_body = true;
                }
                break;
            },
        }
    }

    return request;
}

test "Basic request parse" {
    const allocator = std.testing.allocator;
    const contents = "GET /test?test HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "User-Agent: insomnia/7.1.1\r\n" ++
        "Accept: */*\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "some body";

    const stream = std.io.fixedBufferStream(contents).reader();
    var request = try parse(allocator, stream, 4096);
    defer request.deinit();

    std.testing.expect(request.headers.data.items.len == 4);
    std.testing.expectEqualSlices(u8, "/test", request.url.path);
    std.testing.expectEqualSlices(u8, "HTTP/1.1", request.protocol);
    std.testing.expectEqualSlices(u8, "GET", request.method);
    std.testing.expect(request.body.len == "some body".len);
}
