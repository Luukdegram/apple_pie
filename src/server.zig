const std = @import("std");
const req = @import("request.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = req.Request;

/// HTTP Status codes according to `rfc2616`
/// https://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html
const StatusCode = enum(u16) {
    /// Informational 1xx
    Continue = 100,
    /// Successful 2xx
    SwitchingProtocols = 101,
    Ok = 200,
    Created = 201,
    Accepted = 202,
    NonAuthoritativeInformation = 203,
    NoContent = 204,
    ResetContent = 205,
    /// Redirections 3xx
    PartialContent = 206,
    MultipleChoices = 300,
    MovedPermanently = 301,
    Found = 302,
    SeeOther = 303,
    NotModified = 304,
    UseProxy = 305,
    /// Client errors 4xx
    TemporaryRedirect = 307,
    BadRequest = 400,
    /// reserved status code for future use
    Unauthorized = 401,
    PaymentRequired = 402,
    Forbidden = 403,
    NotFound = 404,
    MethodNotAllowed = 405,
    NotAcceptable = 406,
    ProxyAuthenticationRequired = 407,
    RequestTimeout = 408,
    Conflict = 409,
    Gone = 410,
    LengthRequired = 411,
    PreconditionFailed = 412,
    RequestEntityTooLarge = 413,
    RequestUriTooLong = 414,
    UnsupportedMediaType = 415,
    RequestedRangeNotSatisfiable = 416,
    Teapot = 418,
    /// server errors 5xx
    ExpectationFailed = 417,
    InternalServerError = 500,
    NotImplemented = 501,
    BadGateway = 502,
    ServiceUnavailable = 503,
    GatewayTimeout = 504,
    HttpVersionNotSupported = 505,

    /// Returns the string value of a `StatusCode`
    fn string(self: @This()) []const u8 {
        return switch (self) {
            .Continue => "Continue",
            .SwitchingProtocols => "Switching Protocols",
            .Ok => "Ok",
            .Created => "Created",
            .Accepted => "Accepted",
            .NonAuthoritativeInformation => "Non Authoritative Information",
            .NoContent => "No Content",
            .ResetContent => "Reset Content",
            .PartialContent => "Partial Content",
            .MultipleChoices => "Multiple Choices",
            .MovedPermanently => "Moved Permanently",
            .Found => "Found",
            .SeeOther => "See Other",
            .NotModified => "Not Modified",
            .UseProxy => "Use Proxy",
            .TemporaryRedirect => "Temporary Redirect",
            .BadRequest => "Bad Request",
            .Unauthorized => "Unauthorized",
            .PaymentRequired => "Payment Required",
            .Forbidden => "Forbidden",
            .NotFound => "Not Found",
            .MethodNotAllowed => "Method Not Allowed",
            .NotAcceptable => "Not Acceptable",
            .ProxyAuthenticationRequired => "Proxy Authentication Required",
            .RequestTimeout => "Request Timeout",
            .Conflict => "Conflict",
            .Gone => "Gone",
            .LengthRequired => "Length Required",
            .PreconditionFailed => "Precondition Failed",
            .RequestEntityTooLarge => "Request Entity Too Large",
            .RequestUriTooLong => "Request-URI Too Long",
            .UnsupportedMediaType => "Unsupported Media Type",
            .RequestedRangeNotSatisfiable => "Requested Range Not Satisfiable",
            .Teapot => "I'm a Teapot",
            .ExpectationFailed => "Expectation Failed",
            .InternalServerError => "Internal Server Error",
            .NotImplemented => "Not Implemented",
            .BadGateway => "Bad Gateway",
            .ServiceUnavailable => "Service Unavailable",
            .GatewayTimeout => "Gateway Timeout",
            .HttpVersionNotSupported => "HTTP Version Not Supported",
        };
    }
};

/// Headers is an alias to `std.StringHashMap([]const u8)`
pub const Headers = req.Headers;

/// Response allows to set the status code and content of the response
pub const Response = struct {
    /// current connection between server and peer
    connection: *net.StreamServer.Connection,
    /// status code of the response, 200 by default
    status_code: u16 = 200,
    /// StringHashMap([]const u8) with key and value of headers
    headers: Headers,
    allocator: *Allocator,

    /// Creates a new Response object with its connection set
    fn init(connection: *net.StreamServer.Connection, allocator: *Allocator) Response {
        return Response{
            .connection = connection,
            .allocator = allocator,
            .headers = Headers.init(allocator),
        };
    }

    /// Writes HTTP Response to the peer
    pub fn write(self: @This(), contents: []const u8) !void {
        var stream = self.connection.file.outStream();
        // reserve 50 bytes for our status line
        var buffer: [50]u8 = undefined;
        const status_code_string = @intToEnum(StatusCode, self.status_code).string();
        const status_line = try std.fmt.bufPrint(&buffer, "HTTP/1.1 {} {}\r\n", .{ self.status_code, status_code_string });
        // write status line
        _ = try stream.write(status_line);
        // write headers
        var it = self.headers.iterator();
        while (it.next()) |header| {
            var header_buffer = try self.allocator.alloc(u8, header.key.len + header.value.len + 4); //4 bytes for ": " and \r\n
            defer self.allocator.free(header_buffer);
            const result = try std.fmt.bufPrint(header_buffer, "{}: {}\r\n", .{ header.key, header.value });
            _ = try stream.write(result);
        }

        if (!self.headers.contains("Content-Length")) {
            var content_header: [50]u8 = undefined;
            const result = try std.fmt.bufPrint(&content_header, "Content-Length: {}\r\n", .{contents.len});
            _ = try stream.write(result);
        }

        // Carrot Return after headers to tell clients where headers end and body starts
        _ = try stream.write("\r\n");

        _ = try stream.writeAll(contents);
    }

    /// frees memory of `headers`
    fn deinit(self: @This()) void {
        self.headers.deinit();
    }
};

/// Starts a new server on the given `address` and listens for new connections.
/// Each request will call `handler.serve` to serve the response to the requester.
pub fn listenAndServe(
    allocator: *Allocator,
    address: net.Address,
    comptime handler: var,
) !void {
    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(address);

    while (true) {
        // definitely make this async/threaded as we move on
        try serveRequest(allocator, &server, handler);
    }
}

/// Handles a request and returns a response based on the given handler function
fn serveRequest(allocator: *Allocator, server: *net.StreamServer, comptime handlerFn: var) !void {
    // if it fails to accept connection, simply return and don't handle it
    var connection: net.StreamServer.Connection = server.accept() catch return;

    // use an arena allocator to free all memory at once as it performs better than
    // freeing everything individually.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (req.parse(&arena.allocator, connection.file.inStream())) |*parsed_request| {
        var response = Response.init(&connection, &arena.allocator);

        handlerFn.serve(&response, parsed_request.*);
        connection.file.close();
    } else |_| {}
    // for now, don't handle the error
}

/// Generic Function to serve, needs to be implemented by the caller
pub fn Handler(
    comptime Context: type,
    /// Implementee's serve function to handle the request
    comptime serveFn: fn (
        /// The context responsible of the serve function
        context: Context,
        /// Response object that can be written to
        response: *Response,
        /// Request object containing the original request with its data such as headers, url etc.
        request: Request,
    ) void,
) type {
    return struct {
        context: Context,

        /// calls the implementation function to serve the request
        pub fn serve(self: @This(), response: *Response, request: Request) void {
            return serveFn(self.context, response, request);
        }
    };
}
