const std = @import("std");
const Url = @import("url.zig").Url;

/// Represents a request made by a client
pub const Request = struct {
    /// HTTP methods as specified in RFC 7231
    pub const Method = enum {
        get,
        head,
        post,
        put,
        delete,
        connect,
        options,
        trace,
        patch,
        any,

        fn fromString(method: []const u8) Method {
            return switch (method[0]) {
                'G' => Method.get,
                'H' => Method.head,
                'P' => switch (method[1]) {
                    'O' => Method.post,
                    'U' => Method.put,
                    else => Method.patch,
                },
                //'p' => if (method[1] == 'o') .post else if (method[1] == 'u') .put else .patch,
                //'P' => .post,
                'D' => Method.delete,
                'C' => Method.connect,
                'O' => Method.options,
                'T' => Method.trace,
                else => Method.any,
            };
        }
    };

    /// GET, POST, PUT, DELETE or PATCH
    method: Method,
    /// Url object, get be used to retrieve path or query parameters
    url: Url,
    /// HTTP Request headers
    headers: std.StringHashMap([]const u8),
    /// Body, which can be empty
    body: []const u8,
    /// allocator which is used to free Request's memory
    allocator: *std.mem.Allocator,
    /// Protocol used by the requester, http1.1, http2.0, etc.
    protocol: []const u8,
    /// If the buffer was too small to include the body,
    /// extra memory will be allocated and is freed upon `deinit`
    allocated_body: bool,
    /// Length of requests body
    content_length: usize,

    /// Frees all memory of a Response, as this loops through each header to remove its memory
    /// you may consider using an arena allocator to free all memory at once for better perf
    pub fn deinit(self: *Request) void {
        var it = self.headers.iterator();
        self.headers.deinit();
        if (self.allocated_body) {
            self.allocator.free(self.body);
        }
    }
};

/// Errors which can occur during the parsing of
/// a HTTP request.
pub const ParseError = error{
    OutOfMemory,
    /// Method is missing or invalid
    InvalidMethod,
    /// URL is missing in status line or invalid
    InvalidUrl,
    /// Protocol in status line is missing or invalid
    InvalidProtocol,
    /// Headers are missing
    MissingHeaders,
    /// Invalid header was found
    IncorrectHeader,
    /// Buffer overflow when parsing an integer
    Overflow,
    /// Invalid character when parsing an integer
    InvalidCharacter,
};

/// Parse accepts an `io.InStream`, it will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt
/// The memory of the `Request` is owned by the caller and can be freed by using deinit()
/// `buffer_size` is the size that is allocated to parse the request line and headers, any headers
/// bigger than this size will be skipped.
pub fn parse(
    allocator: *std.mem.Allocator,
    reader: anytype,
    buffer_size: usize,
) (ParseError || @TypeOf(reader).Error)!Request {
    const State = enum {
        method,
        url,
        protocol,
        header,
        body,
    };

    var state: State = .method;

    var request: Request = .{
        .body = "",
        .method = .get,
        .url = Url{
            .path = "/",
            .raw_path = "/",
            .raw_query = "",
        },
        .allocator = allocator,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .allocated_body = false,
        .protocol = "HTTP/1.1",
        .content_length = 0,
    };

    // Accept user defined buffer size for requestline + headers
    // we allocate memory for body if neccesary seperately.
    var buffer = try allocator.alloc(u8, buffer_size);

    const read = try reader.read(buffer);
    buffer = try allocator.resize(buffer, read);

    var i: usize = 0;
    while (i < read) {
        switch (state) {
            .method => {
                const index = std.mem.indexOf(u8, buffer[i..], " ") orelse
                    return ParseError.InvalidMethod;

                request.method = Request.Method.fromString(buffer[i .. i + index]);
                i += index + 1;
                state = .url;
            },
            .url => {
                const index = std.mem.indexOf(u8, buffer[i..], " ") orelse
                    return ParseError.InvalidUrl;

                request.url = Url.init(buffer[i .. i + index]);
                i += request.url.raw_path.len + 1;
                state = .protocol;
            },
            .protocol => {
                const index = std.mem.indexOf(u8, buffer[i..], "\r\n") orelse
                    return ParseError.InvalidProtocol;

                if (index > 8) return ParseError.InvalidProtocol;
                request.protocol = buffer[i .. i + index];
                i += request.protocol.len + 2; // skip \r\n
                state = .header;
            },
            .header => {
                if (buffer[i] == '\r') {
                    if (request.content_length == 0) break;
                    state = .body;
                    i += 2; //Skip the \r\n
                    continue;
                }
                const index = std.mem.indexOf(u8, buffer[i..], ": ") orelse
                    return ParseError.MissingHeaders;

                const key = buffer[i .. i + index];
                i += key.len + 2; // skip ": "

                const end = std.mem.indexOf(u8, buffer[i..], "\r\n") orelse
                    return ParseError.IncorrectHeader;

                const value = buffer[i .. i + end];
                i += value.len + 2; //skip \r\n
                try request.headers.put(key, value);

                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    request.content_length = try std.fmt.parseInt(usize, value, 10);
                }
            },
            .body => {
                const length = request.content_length;

                // if body fit inside the 4kb buffer, we use that,
                // else allocate more memory
                if (length <= read - i) {
                    request.body = buffer[i..];
                } else {
                    var body = try allocator.alloc(u8, length);
                    std.mem.copy(u8, body, buffer[i..]);
                    _ = try reader.readAll(body[read - i ..]);
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

    std.testing.expectEqualSlices(u8, "/test", request.url.path);
    std.testing.expectEqualSlices(u8, "HTTP/1.1", request.protocol);
    std.testing.expectEqual(Request.Method.get, request.method);
    std.testing.expect(request.body.len == "some body".len);
}
