const std = @import("std");
const Url = @import("url.zig").Url;
const pike = @import("pike");

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
                'D' => Method.delete,
                'C' => Method.connect,
                'O' => Method.options,
                'T' => Method.trace,
                else => Method.any,
            };
        }
    };

    /// HTTP Protocol version
    pub const Protocol = enum {
        http1_0,
        http1_1,
        http2_0,

        /// Checks the given string and gives its protocol version
        /// Defaults to HTTP/1.1
        fn fromString(protocol: []const u8) Protocol {
            const eql = std.mem.eql;
            if (eql(u8, protocol, "HTTP/1.1")) return .http1_1;
            if (eql(u8, protocol, "HTTP/2.0")) return .http2_0;
            if (eql(u8, protocol, "HTTP/1.0")) return .http1_0;

            return .http1_1;
        }
    };

    /// GET, POST, PUT, DELETE or PATCH
    method: Method,
    /// Url object, get be used to retrieve path or query parameters
    url: Url,
    /// HTTP Request headers data.
    raw_header_data: []const u8,
    /// Body, which can be empty
    body: []const u8,
    /// allocator which is used to free Request's memory
    allocator: *std.mem.Allocator,
    /// Protocol used by the requester, http1.1, http2.0, etc.
    protocol: Protocol,
    /// Length of requests body
    content_length: usize,
    /// True if http protocol version 1.0 or invalid request
    should_close: bool,
    /// Hostname the request was sent to. Includes its port. Required for HTTP/1.1
    /// Cannot be null for user when `protocol` is `http1_1`.
    host: ?[]const u8,
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
    /// When the connection has been closed or no more data is available
    EndOfStream,
};

/// Parse accepts an `io.InStream`, it will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt
/// The memory of the `Request` is owned by the caller and can be freed by using deinit()
/// `buffer_size` is the size that is allocated to parse the request line and headers, any headers
/// bigger than this size will be skipped.
pub fn parse(
    allocator: *std.mem.Allocator,
    reader: anytype,
    comptime buffer_size: usize,
) !Request {
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
        .raw_header_data = undefined,
        .protocol = .http1_1,
        .content_length = 0,
        .should_close = false,
        .host = null,
    };

    // we allocate memory for body if neccesary seperately.
    var buffer: [buffer_size]u8 = undefined;

    const read = try reader.read(&buffer);
    if (read == 0) return ParseError.EndOfStream;

    // index for where header data starts to save
    var header_Start: usize = 0;

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
                request.protocol = Request.Protocol.fromString(buffer[i .. i + index]);
                i += index + 2; // skip \r\n
                state = .header;
                header_Start = i;
            },
            .header => {
                if (buffer[i] == '\r') {
                    if (request.content_length == 0) break;
                    state = .body;
                    i += 2; //Skip the \r\n
                    request.raw_header_data = buffer[header_Start..i];
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

                if (request.content_length == 0 and std.ascii.eqlIgnoreCase(key, "content-length")) {
                    request.content_length = try std.fmt.parseInt(usize, value, 10);
                    continue;
                }

                if (request.host == null and std.ascii.eqlIgnoreCase(key, "host"))
                    request.host = value;
            },
            .body => {
                const length = request.content_length;

                // if body fit inside the 4kb buffer, we use that,
                // else allocate more memory
                if (length <= read - i) {
                    request.body = buffer[i .. i + length];
                } else {
                    var body = try allocator.alloc(u8, length);
                    std.mem.copy(u8, body, buffer[i..]);
                    var index: usize = read - i;
                    while (index < body.len) {
                        index += try reader.read(body[index..]);
                    }
                    request.body = body;
                }
                break;
            },
        }
    }

    return request;
}

test "Basic request parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "GET /test?test HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "User-Agent: insomnia/7.1.1\r\n" ++
        "Accept: */*\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "some body";

    const stream = std.io.fixedBufferStream(contents).reader();
    var request = try parse(&arena.allocator, stream, 4096);

    std.testing.expectEqualStrings("/test", request.url.path);
    std.testing.expectEqual(Request.Protocol.http1_1, request.protocol);
    std.testing.expectEqual(Request.Method.get, request.method);
    std.testing.expectEqualStrings("some body", request.body);
}
