//! Contains the parsed request in `context` as well as various
//! helper methods to ensure the request is handled correctly,
//! such as reading the body only once.
const Request = @This();

const root = @import("root");
const std = @import("std");
const Uri = @import("Uri.zig");
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
arena: Allocator,
/// Context provides all information from the actual request that was made by the client.
context: Context,

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
        return if (std.mem.eql(u8, string, "GET"))
            .get
        else if (std.mem.eql(u8, string, "POST"))
            .post
        else if (std.mem.eql(u8, string, "PUT"))
            .put
        else if (std.mem.eql(u8, string, "DELETE"))
            .delete
        else if (std.mem.eql(u8, string, "HEAD"))
            .head
        else if (std.mem.eql(u8, string, "PATCH"))
            .patch
        else if (std.mem.eql(u8, string, "OPTIONS"))
            .options
        else if (std.mem.eql(u8, string, "TRACE"))
            @as(Method, .trace)
        else
            .any;
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
    /// URI object, contains the parsed and validated path and optional
    /// query and fragment.
    /// Note: For http 1.1 this may also contain the authority component.
    uri: Uri,
    /// HTTP Request headers data.
    raw_header_data: []const u8,
    /// Protocol used by the requester, http1.1, http2.0, etc.
    protocol: Protocol,
    /// Hostname the request was sent to. Includes its port. Required for HTTP/1.1
    /// Cannot be null for user when `protocol` is `http1_1`.
    host: ?[]const u8,
    /// Body of the request. Its livetime equals that of the request itself,
    /// meaning that any access to its data beyond that is illegal and must be duplicated
    /// to extend its lifetime.
    raw_body: []const u8,
    /// State of the connection. `keep_alive` is the default for HTTP/1.1 and `close` for earlier versions.
    /// For HTTP/2.2 browsers such as Chrome and Firefox ignore this.
    connection_type: enum {
        keep_alive,
        close,
    },
    /// When form data is supplied, this represents how the data is encoded.
    form_type: FormType = .none,

    /// Represents the encoding of form data.
    const FormType = union(enum) {
        /// No form data was supplied
        none,
        /// Uses application/x-www-form-urlencoded
        url_encoded,
        /// Uses multipart/form-data
        /// Value contains the boundary  value. Used to find each chunk
        multipart: []const u8,
    };
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
pub fn headers(self: Request, gpa: Allocator) !Headers {
    var map = Headers{};

    var it = self.iterator();
    while (it.next()) |header| {
        try map.put(gpa, try gpa.dupe(u8, header.key), try gpa.dupe(u8, header.value));
    }

    return map;
}

/// Returns the content of the body
/// Its livetime equals that of the request itself,
/// meaning that any access to its data beyond that is illegal and must be duplicated
/// to extend its lifetime.
///
/// In case of a form, this contains the raw body.
/// Use formIterator() or formValue() to access form fields/values.
pub fn body(self: Request) []const u8 {
    return self.context.raw_body;
}

/// Returns the path of the request
/// To retrieve the raw path, access `context.uri.raw_path`
pub fn path(self: Request) []const u8 {
    return self.context.uri.path;
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

/// Returns a `FormIterator` which can be used
/// to iterate over form fields.
pub fn formIterator(self: Request) FormIterator {
    return .{
        .form_data = self.context.raw_body,
        .index = 0,
        .form_type = self.context.form_type,
    };
}

/// Searches for a given `key` in the form and returns its value.
/// Returns `null` when key is not found.
///
/// NOTE: As the key and value may be url-encoded, this function requires
/// allocations to decode them. Only the result must be freed manually,
/// as this function will handle free'ing any memory that isn't returned to the user.
///
/// NOTE2: If retrieving multiple fields, use `formIterator()` or `form()`
/// as each call to `formValue` will iterate over all fields.
pub fn formValue(self: Request, gpa: Allocator, key: []const u8) !?[]const u8 {
    var it = self.formIterator();
    return while (try it.next(gpa)) |field| {
        defer gpa.free(field.key);
        if (std.mem.eql(u8, key, field.key)) break field.value;
        gpa.free(field.value); // only free value if it doesn't match the wanted key.
    } else null;
}

/// Constructs a map of key-value pairs for each form field.
/// User is responsible for managing its memory.
pub fn form(self: Request, gpa: Allocator) !Uri.KeyValueMap {
    var map = Uri.KeyValueMap{ .map = .{} };
    errdefer map.deinit(gpa);
    var it = self.formIterator();
    while (try it.next(gpa)) |field| {
        errdefer field.deinit(gpa);
        try map.map.put(gpa, field.key, field.value);
    }
    return map;
}

/// Iterator to find all form fields.
const FormIterator = struct {
    form_data: []const u8,
    index: usize,
    form_type: Context.FormType,

    /// Represents a key-value pair in a form body
    const Field = struct {
        /// Input field
        key: []const u8,
        /// Value of the field. Allocated and should be freed manually.
        value: []const u8,

        /// Frees the memory allocated for the `Field`
        pub fn deinit(self: Field, gpa: Allocator) void {
            gpa.free(self.key);
            gpa.free(self.value);
        }
    };

    /// Finds the next form field. Will return `null` when it reached
    /// the end of the form.
    pub fn next(self: *FormIterator, gpa: Allocator) !?Field {
        if (self.index >= self.form_data.len) return null;

        switch (self.form_type) {
            .none => return null,
            .multipart => |boundary_name| {
                const data = self.form_data[self.index..];
                var batch_name: [72]u8 = undefined;
                std.mem.copy(u8, &batch_name, "--");
                std.mem.copy(u8, batch_name[2..], boundary_name);
                var batch_it = std.mem.split(u8, data, batch_name[0 .. boundary_name.len + 2]);

                var batch = batch_it.next() orelse return error.InvalidBody;
                batch = batch_it.next() orelse return error.InvalidBody; // Actually get the batch as first one has len 0
                self.index += batch.len;
                if (std.mem.startsWith(u8, batch, "--")) return null; // end of body

                var field: Field = undefined;
                var cur_index = boundary_name.len + 3; // '--' & '\n'

                // get input name
                const name_start = std.mem.indexOfPos(u8, batch, cur_index, "name=") orelse return error.InvalidBody;
                var field_start = name_start + "name=".len;
                if (batch[field_start] == '"') field_start += 1;

                var field_end = field_start;
                for (batch[field_end..]) |c, i| {
                    if (c == '"' or c == '\n') {
                        field_end += i;
                        break;
                    }
                }
                cur_index = field_end;
                if (batch[cur_index] == '"') cur_index += 2 else cur_index += 1; // '"' & '\n'

                field.key = try gpa.dupe(u8, batch[field_start..field_end]);
                errdefer gpa.free(field.key);

                var value_list = std.ArrayList(u8).init(gpa);
                try value_list.ensureTotalCapacity(batch.len - cur_index);
                defer value_list.deinit();

                for (batch[cur_index..]) |char| if (char != '\r' and char != '\n') value_list.appendAssumeCapacity(char);
                field.value = value_list.toOwnedSlice();
                return field;
            },
            .url_encoded => {
                var key = self.form_data[self.index..];
                if (std.mem.indexOfScalar(u8, key, '&')) |index| {
                    key = key[0..index];
                    self.index += key.len + 1;
                } else self.index += key.len;

                var value: []const u8 = undefined;
                if (std.mem.indexOfScalar(u8, key, '=')) |index| {
                    value = key[index + 1 ..];
                    key = key[0..index];
                } else return error.InvalidBody;

                const unencoded_key = try Uri.decode(gpa, key);
                errdefer gpa.free(unencoded_key);
                return Field{
                    .key = unencoded_key,
                    .value = try Uri.decode(gpa, value),
                };
            },
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
    /// When the client uses HTTP version 1.1 and misses the 'host' header, this error will
    /// be returned.
    MissingHost,
};

/// Parse accepts a `Reader`. It will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt.
/// The Allocator is made available to users that require an allocation for during a single request,
/// as an arena is passed in by the `Server`. The provided buffer is used to parse the actual content,
/// meaning the entire request -> response can be done with no allocations.
pub fn parse(gpa: Allocator, reader: anytype, buffer: []u8) (ParseError || Stream.ReadError)!Request {
    return Request{
        .arena = gpa,
        .context = try parseContext(
            gpa,
            reader,
            buffer,
        ),
    };
}

fn parseContext(gpa: Allocator, reader: anytype, buffer: []u8) (ParseError || @TypeOf(reader).Error)!Context {
    var ctx: Context = .{
        .method = .get,
        .uri = Uri.empty,
        .raw_header_data = undefined,
        .protocol = .http_1_1,
        .host = null,
        .raw_body = "",
        .connection_type = .keep_alive,
    };

    var parser = Parser(@TypeOf(reader)).init(gpa, buffer, reader);
    while (try parser.nextEvent()) |event| {
        switch (event) {
            .status => |status| {
                ctx.protocol = Request.Protocol.fromString(status.protocol);
                ctx.connection_type = if (ctx.protocol == .http_1_0) .close else .keep_alive;
                ctx.uri = Uri.parse(status.path) catch return error.InvalidUrl;
                ctx.method = Request.Method.fromString(status.method);
            },
            .header => |header| {
                if (ctx.protocol == .http_1_1 and
                    ctx.connection_type == .keep_alive and
                    std.ascii.eqlIgnoreCase(header.key, "connection"))
                {
                    if (std.ascii.eqlIgnoreCase(header.value, "close")) ctx.connection_type = .close;
                }

                if (ctx.host == null and std.ascii.eqlIgnoreCase(header.key, "host")) {
                    ctx.host = header.value;
                    _ = Uri.parseAuthority(&ctx.uri, header.value) catch return error.IncorrectHeader;
                }

                if (ctx.form_type == .none and
                    std.ascii.eqlIgnoreCase(header.key, "content-type"))
                {
                    const until_first_semicolon = std.mem.sliceTo(header.value, ';');
                    const trimmed_value = std.mem.trim(u8, until_first_semicolon, " ");
                    if (std.ascii.indexOfIgnoreCase(trimmed_value, "multipart/form-data")) |_| {
                        const semicolon = "multipart/form-data".len;
                        if (header.value[semicolon] != ';') return error.InvalidBody;

                        if (std.mem.indexOfScalarPos(u8, header.value, semicolon, '=')) |eql_char| {
                            var end = parser.index - 3; // remove \r\n
                            if (buffer[end] != '"') end += 1;
                            var start: usize = parser.index - 2 - header.value.len + eql_char + 1;
                            if (buffer[start] == '"') start += 1; // strip "
                            if (end - start > 70) return error.IncorrectHeader; // Boundary may be at max 70 characters
                            ctx.form_type = .{ .multipart = buffer[start..end] };
                        } else return error.InvalidBody;
                    } else if (std.ascii.eqlIgnoreCase(trimmed_value, "application/x-www-form-urlencoded")) {
                        ctx.form_type = .url_encoded;
                    }
                }
            },
            .end_of_header => ctx.raw_header_data = buffer[parser.header_start..parser.header_end],
            .body => |content| ctx.raw_body = content,
        }
    }

    if (ctx.host == null and ctx.protocol == .http_1_1) return error.MissingHost;

    return ctx;
}

fn Parser(ReaderType: anytype) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        buffer: []u8,
        index: usize,
        state: std.meta.Tag(Event),
        reader: ReaderType,
        done: bool,
        content_length: usize,
        header_start: usize,
        header_end: usize,
        chunked: bool,

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
            body: []const u8,
            // reached end of header
            end_of_header: void,
        };

        const Error = ParseError || ReaderType.Error;

        fn init(gpa: Allocator, buffer: []u8, reader: ReaderType) Self {
            return .{
                .gpa = gpa,
                .buffer = buffer,
                .reader = reader,
                .state = .status,
                .index = 0,
                .done = false,
                .content_length = 0,
                .header_start = 0,
                .header_end = 0,
                .chunked = false,
            };
        }

        fn nextEvent(self: *Self) Error!?Event {
            if (self.done) return null;

            return switch (self.state) {
                .status => self.parseStatus(),
                .header => self.parseHeader(),
                .body => self.parseBody(),
                .end_of_header => unreachable,
            };
        }

        fn parseStatus(self: *Self) Error!?Event {
            self.state = .header;
            const line = (try self.reader.readUntilDelimiterOrEof(self.buffer, '\n')) orelse return ParseError.EndOfStream;
            self.index += line.len + 1;
            self.header_start = self.index;
            var it = mem.tokenize(u8, try assertLE(line), " ");

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
                self.header_end = self.index;
                if (self.content_length == 0 and !self.chunked) {
                    self.done = true;
                }
                self.state = .body;
                return Event.end_of_header;
            }
            var it = mem.split(u8, try assertLE(line), ": ");

            const key = it.next() orelse return ParseError.MissingHeaders;
            const value = it.next() orelse return ParseError.IncorrectHeader;

            // if content length hasn't been set yet,
            // check if it exists and set it by parsing the int value
            if (self.content_length == 0 and
                std.ascii.eqlIgnoreCase("content-length", key))
            {
                self.content_length = try std.fmt.parseInt(usize, value, 10);
            }

            // check if chunked body
            if (std.ascii.eqlIgnoreCase("transfer-encoding", key)) {
                // transfer-encoding can contain a list of encodings.
                // Therefore, iterate over them and check for 'chunked'.
                var split = std.mem.split(u8, value, ", ");
                while (split.next()) |maybe_chunk| {
                    if (std.ascii.eqlIgnoreCase("chunked", maybe_chunk)) {
                        self.chunked = true;
                    }
                }
            }

            return Event{
                .header = .{
                    .key = key,
                    .value = value,
                },
            };
        }

        fn parseBody(self: *Self) Error!?Event {
            defer self.done = true;

            if (self.content_length != 0) {
                const raw_body = try self.gpa.alloc(u8, self.content_length);
                try self.reader.readNoEof(raw_body);
                return Event{ .body = raw_body };
            }

            std.debug.assert(self.chunked);
            var body_list = std.ArrayList(u8).init(self.gpa);
            defer body_list.deinit();

            var read_len: usize = 0;
            while (true) {
                var len_buf: [1024]u8 = undefined; //Used to read the length of a chunk
                const lf_line = (try self.reader.readUntilDelimiterOrEof(&len_buf, '\n')) orelse
                    return error.InvalidBody;
                const line = try assertLE(lf_line);

                const index = std.mem.indexOfScalar(u8, line, ';') orelse
                    line.len;
                const chunk_len = try std.fmt.parseInt(usize, line[0..index], 10);
                try body_list.resize(read_len + chunk_len);
                try self.reader.readNoEof(body_list.items[read_len..]);
                read_len += chunk_len;

                // validate clrf
                var crlf: [2]u8 = undefined;
                try self.reader.readNoEof(&crlf);
                if (!std.mem.eql(u8, "\r\n", &crlf)) return error.InvalidBody;

                if (chunk_len == 0) {
                    break;
                }
            }
            return Event{ .body = body_list.toOwnedSlice() };
        }

        fn assertLE(line: []const u8) ParseError![]const u8 {
            if (line.len == 0) return ParseError.InvalidLineEnding;
            const idx = line.len - 1;
            if (line[idx] != '\r') return ParseError.InvalidLineEnding;

            return line[0..idx];
        }
    };
}

test "Basic request parse" {
    const contents =
        "GET /test?test HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "User-Agent: insomnia/7.1.1\r\n" ++
        "Accept: */*\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "some body";

    var buf: [4096]u8 = undefined;
    const stream = std.io.fixedBufferStream(contents).reader();
    var request = try parse(std.testing.allocator, stream, &buf);
    defer std.testing.allocator.free(request.context.raw_body);

    try std.testing.expectEqualStrings("/test", request.path());
    try std.testing.expectEqual(Request.Protocol.http_1_1, request.context.protocol);
    try std.testing.expectEqual(Request.Method.get, request.context.method);
    try std.testing.expectEqualStrings("some body", request.body());

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
    const _headers =
        "User-Agent: ApplePieClient/1\r\n" ++
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
        "GET /test?test HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "User-Agent: insomnia/7.1.1\r\n" ++
        "Accept: */*\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
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
    var request = try parse(std.testing.allocator, fb, &buf);
    defer std.testing.allocator.free(request.body());

    try std.testing.expectEqualStrings("MozillaDeveloperNetwork", request.body());
}

test "Form body (url-encoded)" {
    const content =
        "POST / HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Accept: */*\r\n" ++
        "Content-Length: 27\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "\r\n" ++
        "Field1=value1&Field2=value2";

    var buf: [2048]u8 = undefined;
    var fb = std.io.fixedBufferStream(content).reader();
    var request = try parse(std.testing.allocator, fb, &buf);
    defer std.testing.allocator.free(request.body());

    try std.testing.expectEqualStrings("Field1=value1&Field2=value2", request.body());

    const expected: []const []const u8 = &.{
        "Field1", "value1", "Field2", "value2",
    };

    var it = request.formIterator();
    var index: usize = 0;
    while (try it.next(std.testing.allocator)) |field| {
        defer field.deinit(std.testing.allocator);
        defer index += 2;

        try std.testing.expectEqualStrings(expected[index], field.key);
        try std.testing.expectEqualStrings(expected[index + 1], field.value);
    }
    try std.testing.expectEqual(expected.len, index);

    const check_value = try request.formValue(std.testing.allocator, "Field2");
    defer if (check_value) |val| std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("value2", check_value.?);

    var as_map = try request.form(std.testing.allocator);
    defer as_map.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("value1", as_map.get("Field1").?);
}

test "Form body (multipart)" {
    const content =
        "POST / HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Accept: */*\r\n" ++
        "Content-Length: 140\r\n" ++
        "Content-Type: multipart/form-data; boundary=\"boundary\"\r\n" ++
        "\r\n" ++
        "--boundary\n" ++
        "Content-Disposition: form-data; name=\"Field1\"\n" ++
        "value1\n" ++
        "--boundary\n" ++
        "Content-Disposition: form-data; name=\"Field2\"\n" ++
        "value2\n" ++
        "--boundary--";

    var buf: [2048]u8 = undefined;
    var fb = std.io.fixedBufferStream(content).reader();
    var request = try parse(std.testing.allocator, fb, &buf);
    defer std.testing.allocator.free(request.body());

    try std.testing.expectEqualStrings("--boundary\n" ++
        "Content-Disposition: form-data; name=\"Field1\"\n" ++
        "value1\n" ++
        "--boundary\n" ++
        "Content-Disposition: form-data; name=\"Field2\"\n" ++
        "value2\n" ++
        "--boundary--", request.body());

    const expected: []const []const u8 = &.{
        "Field1", "value1", "Field2", "value2",
    };

    var it = request.formIterator();
    var index: usize = 0;
    while (try it.next(std.testing.allocator)) |field| {
        defer field.deinit(std.testing.allocator);
        defer index += 2;

        try std.testing.expectEqualStrings(expected[index], field.key);
        try std.testing.expectEqualStrings(expected[index + 1], field.value);
    }
    try std.testing.expectEqual(expected.len, index);

    const check_value = try request.formValue(std.testing.allocator, "Field2");
    defer if (check_value) |val| std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("value2", check_value.?);

    var as_map = try request.form(std.testing.allocator);
    defer as_map.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("value1", as_map.get("Field1").?);
}
