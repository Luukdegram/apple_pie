const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

/// HTTP Status codes according to `rfc7231`
/// https://tools.ietf.org/html/rfc7231#section-6
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
    TemporaryRedirect = 307,
    /// Client errors 4xx
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
    ExpectationFailed = 417,
    /// Teapot is an extension Status Code and not required for clients to support
    Teapot = 418,
    UpgradeRequired = 426,
    /// Extra Status Code according to `https://tools.ietf.org/html/rfc6585#section-5`
    RequestHeaderFieldsTooLarge = 431,
    /// server errors 5xx
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
            .UpgradeRequired => "Upgrade Required",
            .RequestHeaderFieldsTooLarge => "Request Header Fields Too Large",
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
pub const Headers = std.StringHashMap([]const u8);

/// SocketWriter writes to a socket and sets the
/// MSG_NOSIGNAL flag to ignore BrokenPipe signals
/// This is needed so the server does not get interrupted
pub const SocketWriter = struct {
    handle: std.os.fd_t,

    /// Use os' SendError
    pub const Error = std.os.SendError;

    /// Uses fmt to format the given bytes and writes to the socket
    pub fn print(self: SockerWriter, comptime format: []const u8, args: var) Error!usize {
        return std.fmt.format(self, format, args);
    }

    /// writes to the socket
    /// Note that this may not write all bytes, use writeAll for that
    pub fn write(self: SocketWriter, bytes: []const u8) Error!usize {
        return std.os.send(self.handle, bytes, std.os.MSG_NOSIGNAL);
    }

    /// Loops untill all bytes have been written to the socket
    pub fn writeAll(self: SocketWriter, bytes: []const u8) Error!void {
        var index: usize = 0;
        while (index != bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }
};

/// Response allows to set the status code and content of the response
pub const Response = struct {
    /// status code of the response, 200 by default
    status_code: u16 = 200,
    /// StringHashMap([]const u8) with key and value of headers
    headers: Headers,
    /// Buffered writer that writes to our socket
    writer: std.io.BufferedWriter(4096, SocketWriter),
    /// True when write() has been called
    is_dirty: bool = false,

    /// Creates a new Response object with its connection set
    pub fn init(handle: std.os.fd_t, allocator: *Allocator) Response {
        return Response{
            .headers = Headers.init(allocator),
            .writer = std.io.bufferedOutStream(SocketWriter{ .handle = handle }),
        };
    }

    /// Writes HTTP Response to the peer
    pub fn write(self: *@This(), contents: []const u8) !void {
        self.is_dirty = true;
        var stream = self.writer.outStream();

        // write status line
        const status_code_string = @intToEnum(StatusCode, self.status_code).string();
        try stream.print("HTTP/1.1 {} {}\r\n", .{ self.status_code, status_code_string });

        // write headers
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try stream.print("{}: {}\r\n", .{ header.key, header.value });
        }

        // Unless specified by the user, write content length
        if (!self.headers.contains("Content-Length")) {
            try stream.print("Content-Length: {}\r\n", .{contents.len});
        }

        // Carrot Return after headers to tell clients where headers end, and body starts
        _ = try stream.write("\r\n");

        _ = try stream.writeAll(contents);
        try self.writer.flush();
    }

    /// frees memory of `headers`
    fn deinit(self: @This()) void {
        self.headers.deinit();
    }
};
