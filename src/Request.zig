//! Contains the parsed request in `context` as well as various
//! helper methods to ensure the request is handled correctly,
//! such as reading the body only once.
const Request = @This();

const root = @import("root");
const std = @import("std");
const Url = @import("url.zig").Url;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const Stream = std.net.Stream;

const max_buffer_size = blk: {
    const given = if (@hasDecl(root, "buffer_size")) root.buffer_size else 1024 * 64; // 64kB
    break :blk std.math.min(given, 1024 * 1024 * 16); // max stack size
};

/// Internal allocator, fed by an arena allocator. Any memory allocated using this
/// allocator will be freed upon the end of a request. It's therefore illegal behaviour
/// to read from/write to anything allocated with this after a request and must be duplicated first,
/// or allocated using a different strategy.
arena: *Allocator,
/// Provides direct access to the connection stream of the client.
/// Note that any calls to this is up to the user. Apple Pie provides no safety
/// measures for incorrect usage.
///
/// NOTE: The http status line and request headers have already been read from the stream.
/// This means the user is free to read the body itself, or use the safety functions such as
/// `body()` and `bufferedBody()`
reader: Reader,
/// Context provides all information from the actual request that was made by the client.
context: Context,
/// Used by the server to determine if the body was read or not, this is to make sure the
/// stream is empty before trying to read the next request. This must be done for keep-alive.
/// This is a pointer to a boolean value so it can be modified while the `Request` can remain read-only.
body_read: *bool,

/// Alias to Stream.ReadError
/// Possible errors that can occur when reading from the connection stream.
pub const ReadError = Stream.ReadError;

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

    fn fromString(string: []const u8) Method {
        return switch (string[0]) {
            'G' => .get,
            'H' => .head,
            'P' => @as(Method, switch (string[1]) {
                'O' => .post,
                'U' => .put,
                else => .patch,
            }),
            'D' => .delete,
            'C' => .connect,
            'O' => .options,
            'T' => .trace,
            else => .any,
        };
    }
};

/// HTTP Protocol version
pub const Protocol = enum {
    http_0_9,
    http_1_0,
    http_1_1,
    http_2_0,

    /// Checks the given string and gives its protocol version
    /// Defaults to HTTP/1.1
    fn fromString(protocol: []const u8) Protocol {
        const eql = std.mem.eql;
        if (eql(u8, protocol, "HTTP/1.1")) return .http_1_1;
        if (eql(u8, protocol, "HTTP/2.0")) return .http_2_0;
        if (eql(u8, protocol, "HTTP/1.0")) return .http_1_0;
        if (eql(u8, protocol, "HTTP/0.9")) return .http_0_9;

        return .http_1_1; // default
    }
};

/// Represents an HTTP Header
pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Alias to StringHashMapUnmanaged([]const u8)
pub const Headers = std.StringHashMapUnmanaged([]const u8);
/// Buffered reader for reading the connection stream
pub const Reader = std.io.BufferedReader(4096, Stream.Reader).Reader;

/// `Context` contains the result from the parser.
/// `Request` uses this information to handle correctness when parsing
/// a body or the headers.
pub const Context = struct {
    /// GET, POST, PUT, DELETE or PATCH
    method: Method,
    /// Url object, get be used to retrieve path or query parameters
    url: Url,
    /// HTTP Request headers data.
    raw_header_data: []const u8,
    /// Protocol used by the requester, http1.1, http2.0, etc.
    protocol: Protocol,
    /// Length of requests body
    content_length: usize,
    /// True if http protocol version 1.0 or invalid request
    should_close: bool,
    /// Hostname the request was sent to. Includes its port. Required for HTTP/1.1
    /// Cannot be null for user when `protocol` is `http1_1`.
    host: ?[]const u8,
    /// Defines if the request's body is sent chunked or not.
    /// Note that correctly parsing the body will be handled by calling `body()` and does not
    /// require manual action from the user.
    chunked: bool,
};

/// Iterator to iterate through headers
const Iterator = struct {
    slice: []const u8,
    index: usize,

    /// Searches for the next header.
    /// Parsing cannot be failed as that would have been caught by `parse()`
    pub fn next(self: *Iterator) ?Header {
        if (self.index >= self.slice.len) return null;

        var state: enum { key, value } = .key;

        var header: Header = undefined;
        var start = self.index;
        while (self.index < self.slice.len) : (self.index += 1) {
            const c = self.slice[self.index];
            if (state == .key and c == ':') {
                header.key = self.slice[start..self.index];
                start = self.index + 2;
                state = .value;
            }
            if (state == .value and c == '\r') {
                header.value = self.slice[start..self.index];
                self.index += 2;
                return header;
            }
        }

        return null;
    }
};

/// Creates an iterator to retrieve all headers
/// As the data is known, this does not require any allocations
/// If all headers needs to be known at once, use `headers()`.
pub fn iterator(self: Request) Iterator {
    return Iterator{
        .slice = self.context.raw_header_data[0..],
        .index = 0,
    };
}

/// Creates an unmanaged Hashmap from the request headers, memory is owned by caller
/// Every header key and value will be allocated for the map and must therefore be freed
/// manually as well.
pub fn headers(self: Request, gpa: *Allocator) !Headers {
    var map = Headers{};

    var it = self.iterator();
    while (it.next()) |header| {
        try map.put(gpa, try gpa.dupe(u8, header.key), try gpa.dupe(u8, header.value));
    }

    return map;
}

const x = comptime 5;

/// Parses the body of the request and allocates the contents inside a buffer.
/// Memory must be handled manually by the caller
pub fn body(self: Request, gpa: *Allocator) ![]const u8 {
    defer self.body_read.* = true;

    if (self.context.chunked) {
        var buf_list = std.ArrayList(u8).init(gpa);
        defer buf_list.deinit();

        var chunk_buf: [max_buffer_size]u8 = undefined;
        var chunked_reader = chunkedReader(self.reader, &chunk_buf);
        while (chunked_reader.next()) |chunk| {
            buf_list.appendSlice(chunk);
        }
        return buf_list.toOwnedSlice();
    }
    const len = self.context.content_length;
    if (len == 0) return "";
    const buffer = try gpa.alloc(u8, len);
    errdefer gpa.free(buffer);

    var i: usize = 0;
    while (i < len) {
        const read_len = try self.reader.read(buffer[i..]);
        if (read_len == 0) return error.EndOfStream;
        i += read_len;
    }
    return buffer;
}

/// Reads the body of a request into the given `buffer`
/// Returns the length that was written to the buffer.
/// Asserts `buffer` has a size bigger than 0.
pub fn bufferedBody(self: Request, buffer: []u8) !usize {
    std.debug.assert(buffer.len > 0);
    defer self.body_read.* = true;

    if (self.context.chunked) {
        var chunk_buf: [max_buffer_size]u8 = undefined;
        var chunked_reader = chunkedReader(self.reader, &chunk_buf);
        var i: usize = 0;
        while (try chunked_reader.next()) |chunk| {
            std.mem.copy(u8, buffer[i..], chunk);
            i += chunk.len;
        }
        return i;
    }

    const min = std.math.min(self.context.content_length, buffer.len);
    var read_len: usize = 0;
    while (read_len < min) {
        read_len += try self.reader.read(buffer[read_len..]);
    }
    return read_len;
}

/// Returns the path of the request
/// To retrieve the raw path, access `context.url.raw_path`
pub fn path(self: Request) []const u8 {
    return self.context.url.path;
}

/// Returns the method of the request as `Method`
pub fn method(self: Request) Method {
    return self.context.method;
}

/// Returns the host. This cannot be null when the request
/// is HTTP 1.1 or higher.
pub fn host(self: Request) ?[]const u8 {
    return self.context.host;
}

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
    /// Provided request's size is bigger than max size (2^32).
    StreamTooLong,
    /// Request headers are too large and do not find in `buffer_size`
    HeadersTooLarge,
    /// Line ending of the requests are corrupted/invalid. According to the http
    /// spec, each line must end with \r\n
    InvalidLineEnding,
    /// When body is incomplete
    InvalidBody,
};

/// Parse accepts a `Reader`. It will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt.
/// The Allocator is made available to users that require an allocation for during a single request,
/// as an arena is passed in by the `Server`. The provided buffer is used to parse the actual content,
/// meaning the entire request -> response can be done with no allocations.
pub fn parse(body_read: *bool, gpa: *Allocator, reader: anytype, buffer: []u8) (ParseError || Stream.ReadError)!Request {
    return Request{
        .arena = gpa,
        .reader = reader,
        .body_read = body_read,
        .context = try parseContext(
            reader,
            buffer,
        ),
    };
}

fn parseContext(reader: anytype, buffer: []u8) (ParseError || @TypeOf(reader).Error)!Context {
    var ctx: Context = .{
        .method = .get,
        .url = Url{
            .path = "/",
            .raw_path = "/",
            .raw_query = "",
        },
        .raw_header_data = undefined,
        .protocol = .http_1_1,
        .content_length = 0,
        .should_close = false,
        .host = null,
        .chunked = false,
    };

    var parser = Parser(@TypeOf(reader)).init(buffer, reader);
    while (try parser.nextEvent()) |event| {
        switch (event) {
            .status => |status| {
                ctx.protocol = Request.Protocol.fromString(status.protocol);
                ctx.url = Url.init(status.path);
                ctx.method = Request.Method.fromString(status.method);
            },
            .header => |header| {
                if (ctx.protocol != .http_1_0 and
                    ctx.protocol != .http_0_9 and
                    !ctx.should_close and
                    std.ascii.eqlIgnoreCase(header.key, "connection"))
                {
                    if (std.ascii.eqlIgnoreCase(header.value, "close")) ctx.should_close = true;
                }

                if (ctx.host == null and std.ascii.eqlIgnoreCase(header.key, "host"))
                    ctx.host = header.value;

                // check if chunked body
                if (ctx.protocol == .http_1_1 and
                    !ctx.chunked and
                    std.ascii.eqlIgnoreCase("transfer-encoding", header.key))
                {
                    // transfer-encoding can contain a list of encodings.
                    // Therefore, iterate over them and check for 'chunked'.
                    var split = std.mem.split(header.value, ", ");
                    while (split.next()) |maybe_chunk| {
                        if (std.ascii.eqlIgnoreCase("chunked", maybe_chunk)) {
                            ctx.chunked = true;
                        }
                    }
                }
            },
        }
    }

    ctx.content_length = parser.content_length;
    ctx.raw_header_data = buffer[parser.header_start..parser.header_end];

    return ctx;
}

fn Parser(ReaderType: anytype) type {
    return struct {
        const Self = @This();

        buffer: []u8,
        index: usize,
        state: std.meta.Tag(Event),
        reader: ReaderType,
        done: bool,
        content_length: usize,
        header_start: usize,
        header_end: usize,

        const Event = union(enum) {
            status: struct {
                method: []const u8,
                path: []const u8,
                protocol: []const u8,
            },
            header: struct {
                key: []const u8,
                value: []const u8,
            },
        };

        const Error = ParseError || ReaderType.Error;

        fn init(buffer: []u8, reader: ReaderType) Self {
            return .{
                .buffer = buffer,
                .reader = reader,
                .state = .status,
                .index = 0,
                .done = false,
                .content_length = 0,
                .header_start = 0,
                .header_end = 0,
            };
        }

        fn nextEvent(self: *Self) Error!?Event {
            if (self.done) return null;

            return switch (self.state) {
                .status => self.parseStatus(),
                .header => self.parseHeader(),
            };
        }

        fn parseStatus(self: *Self) Error!?Event {
            self.state = .header;
            const line = (try self.reader.readUntilDelimiterOrEof(self.buffer, '\n')) orelse return ParseError.EndOfStream;
            self.index += line.len + 1;
            self.header_start = self.index;
            var it = mem.tokenize(try assertLE(line), " ");

            const parsed_method = it.next() orelse return ParseError.InvalidMethod;
            const parsed_path = it.next() orelse return ParseError.InvalidUrl;
            const protocol = it.next() orelse return ParseError.InvalidProtocol;

            return Event{
                .status = .{
                    .method = parsed_method,
                    .path = parsed_path,
                    .protocol = protocol,
                },
            };
        }

        fn parseHeader(self: *Self) Error!?Event {
            const line = (try self.reader.readUntilDelimiterOrEof(self.buffer[self.index..], '\n')) orelse return ParseError.EndOfStream;
            self.index += line.len + 1;
            if (line.len == 1 and line[0] == '\r') {
                self.done = true;
                self.header_end = self.index;
                return null;
            }
            var it = mem.tokenize(try assertLE(line), " ");

            const key = try assertKey(it.next() orelse return ParseError.MissingHeaders);
            const value = it.next() orelse return ParseError.IncorrectHeader;

            // if content length hasn't been set yet,
            // check if it exists and set it by parsing the int value
            if (self.content_length == 0 and
                std.ascii.eqlIgnoreCase("content-length", key))
            {
                self.content_length = try std.fmt.parseInt(usize, value, 10);
            }

            return Event{
                .header = .{
                    .key = key,
                    .value = value,
                },
            };
        }

        fn assertKey(key: []const u8) ParseError![]const u8 {
            const idx = key.len - 1;
            if (key[idx] != ':') return ParseError.IncorrectHeader;
            return key[0..idx];
        }
    };
}

fn assertLE(line: []const u8) ParseError![]const u8 {
    if (line.len == 0) return ParseError.InvalidLineEnding;
    const idx = line.len - 1;
    if (line[idx] != '\r') return ParseError.InvalidLineEnding;

    return line[0..idx];
}

/// Reads request bodies that use transfer-encoding 'chunked'
fn ChunkedReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        reader: ReaderType,
        buffer: []u8,
        state: enum {
            reading,
            end,
        },

        fn init(reader: ReaderType, buffer: []u8) Self {
            return .{ .reader = reader, .buffer = buffer, .state = .reading };
        }

        /// Reads from the body and returns the next chunk it finds.
        ///
        /// NOTE: This overwrites its inner buffer on each call,
        /// therefore the user must copy or use the data before the next call.
        pub fn next(self: *Self) !?[]const u8 {
            switch (self.state) {
                .reading => {
                    const lf_line = (try self.reader.readUntilDelimiterOrEof(self.buffer, '\n')) orelse
                        return error.InvalidBody;
                    const line = try assertLE(lf_line);

                    const index = std.mem.indexOfScalar(u8, line, ';') orelse
                        line.len;

                    const chunk_len = try std.fmt.parseInt(usize, line[0..index], 10);
                    try self.reader.readNoEof(self.buffer[0..chunk_len]);

                    // validate clrf
                    var crlf: [2]u8 = undefined;
                    try self.reader.readNoEof(&crlf);
                    if (!std.mem.eql(u8, "\r\n", &crlf)) return error.InvalidBody;

                    if (chunk_len == 0) {
                        self.state = .end;
                        return null;
                    } else return self.buffer[0..chunk_len];
                },
                .end => return null,
            }
        }

        /// Reads the chunked body and discards all data.
        /// Does validate correctness of the body.
        pub fn skip(self: *Self) !void {
            if (self.state == .end) return;
            while (true) {
                const lf_line = (try self.reader.readUntilDelimiterOrEof(self.buffer, '\n')) orelse
                    return error.InvalidBody;
                const line = try assertLE(lf_line);

                const index = std.mem.indexOfScalar(u8, line, ';') orelse
                    line.len;

                const chunk_len = try std.fmt.parseInt(usize, line[0..index], 10);
                try self.reader.readNoEof(self.buffer[0..chunk_len]);

                // validate clrf
                var crlf: [2]u8 = undefined;
                try self.reader.readNoEof(&crlf);
                if (!std.mem.eql(u8, "\r\n", &crlf)) return error.InvalidBody;

                if (chunk_len == 0) {
                    self.state = .end;
                    return;
                }
            }
        }
    };
}

/// initializes a new `ChunkedReader` from a given reader and buffer
pub fn chunkedReader(reader: anytype, buffer: []u8) ChunkedReader(@TypeOf(reader)) {
    return ChunkedReader(@TypeOf(reader)).init(reader, buffer);
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

    var buf: [4096]u8 = undefined;
    const stream = std.io.fixedBufferStream(contents).reader();
    var ctx = try parseContext(stream, &buf);

    try std.testing.expectEqualStrings("/test", ctx.url.path);
    try std.testing.expectEqual(Request.Protocol.http_1_1, ctx.protocol);
    try std.testing.expectEqual(Request.Method.get, ctx.method);
    // TODO: Find a way to test body
    // try std.testing.expectEqualStrings("some body", try request.body(&arena.allocator));

    var check = false;
    var request = Request{
        .arena = undefined,
        .reader = undefined,
        .context = ctx,
        .body_read = &check,
    };
    var _headers = try request.headers(std.testing.allocator);
    defer {
        var it = _headers.iterator();
        while (it.next()) |header| {
            std.testing.allocator.free(header.key_ptr.*);
            std.testing.allocator.free(header.value_ptr.*);
        }
        _headers.deinit(std.testing.allocator);
    }

    try std.testing.expect(_headers.contains("Host"));
    try std.testing.expect(_headers.contains("Accept"));
}

test "Request iterator" {
    const _headers = "User-Agent: ApplePieClient/1\r\n" ++
        "Accept: application/json\r\n" ++
        "content-Length: 0\r\n";

    var it = Request.Iterator{
        .slice = _headers,
        .index = 0,
    };
    const header1 = it.next().?;
    const header2 = it.next().?;
    const header3 = it.next().?;
    const header4 = it.next();

    try std.testing.expectEqualStrings("User-Agent", header1.key);
    try std.testing.expectEqualStrings("ApplePieClient/1", header1.value);
    try std.testing.expectEqualStrings("Accept", header2.key);
    try std.testing.expectEqualStrings("content-Length", header3.key);
    try std.testing.expectEqual(@as(?Request.Header, null), header4);
}

test "Chunked encoding" {
    const content =
        "7\r\n" ++
        "Mozilla\r\n" ++
        "9\r\n" ++
        "Developer\r\n" ++
        "7\r\n" ++
        "Network\r\n" ++
        "0\r\n" ++
        "\r\n";
    var buf: [2048]u8 = undefined;
    var fb = std.io.fixedBufferStream(content).reader();
    var reader = chunkedReader(fb, &buf);

    var result: [2048]u8 = undefined;
    var i: usize = 0;
    while (try reader.next()) |chunk| {
        std.mem.copy(u8, result[i..], chunk);
        i += chunk.len;
    }

    try std.testing.expectEqualStrings("MozillaDeveloperNetwork", result[0..i]);
}
