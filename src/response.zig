const std = @import("std");
const pike = @import("pike");
const net = std.net;
const Allocator = std.mem.Allocator;

/// HTTP Status codes according to `rfc7231`
/// https://tools.ietf.org/html/rfc7231#section-6
pub const StatusCode = enum(u16) {
    // Informational 1xx
    Continue = 100,
    // Successful 2xx
    SwitchingProtocols = 101,
    Ok = 200,
    Created = 201,
    Accepted = 202,
    NonAuthoritativeInformation = 203,
    NoContent = 204,
    ResetContent = 205,
    // Redirections 3xx
    PartialContent = 206,
    MultipleChoices = 300,
    MovedPermanently = 301,
    Found = 302,
    SeeOther = 303,
    NotModified = 304,
    UseProxy = 305,
    TemporaryRedirect = 307,
    // Client errors 4xx
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
    // server errors 5xx
    InternalServerError = 500,
    NotImplemented = 501,
    BadGateway = 502,
    ServiceUnavailable = 503,
    GatewayTimeout = 504,
    HttpVersionNotSupported = 505,

    /// Returns the string value of a `StatusCode`
    /// for example: .ResetContent returns "Returns Content".
    pub fn toString(self: StatusCode) []const u8 {
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
pub const Headers = std.StringArrayHashMap([]const u8);

/// SocketWriter writes to a socket and sets the
/// MSG_NOSIGNAL flag to ignore BrokenPipe signals
/// This is needed so the server does not get interrupted
pub const SocketWriter = struct {
    handle: *pike.Socket,

    /// Alias for `std.os.SendError`
    /// Required constant for `std.io.BufferedWriter`
    pub const Error = error{
        DiskQuota,
        FileTooBig,
        InputOutput,
        NoSpaceLeft,
        OperationAborted,
        NotOpenForWriting,
        OperationCancelled,
    } || std.os.SendError;

    /// Uses fmt to format the given bytes and writes to the socket
    pub fn print(self: SockerWriter, comptime format: []const u8, args: anytype) Error!usize {
        return std.fmt.format(self, format, args);
    }

    /// writes to the socket
    /// Note that this may not write all bytes, use writeAll for that
    pub fn write(self: SocketWriter, bytes: []const u8) Error!usize {
        return self.handle.send(bytes, std.os.MSG_NOSIGNAL);
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
    status_code: StatusCode = .Ok,
    /// StringHashMap([]const u8) with key and value of headers
    headers: Headers,
    /// Buffered writer that writes to our socket
    socket_writer: std.io.BufferedWriter(4096, SocketWriter),
    /// True when write() has been called
    is_flushed: bool,
    /// Response body, can be written to through the writer interface
    body: std.ArrayList(u8).Writer,

    pub const Error = SocketWriter.Error || error{OutOfMemory};

    pub const Writer = std.io.Writer(*Response, Error, write);

    /// Returns a writer interface, any data written to the writer
    /// will be appended to the response's body
    pub fn writer(self: *Response) Writer {
        return .{ .context = self };
    }

    /// Appends the buffer to the body of the response
    fn write(self: *Response, buffer: []const u8) Error!usize {
        return self.body.write(buffer);
    }

    /// Sends a status code with an empty body and the current headers to the client
    /// Note that this will complete the response and any further writes are illegal.
    pub fn writeHeader(self: *Response, status_code: StatusCode) Error!void {
        self.status_code = status_code;
        try self.flush();
    }

    /// Sends the response to the client, can only be called once
    /// Any further calls is a panic
    pub fn flush(self: *Response) Error!void {
        std.debug.assert(!self.is_flushed);
        self.is_flushed = true;

        const body = self.body.context.items;
        var socket = self.socket_writer.writer();

        // Print the status line, we only support HTTP/1.1 for now
        try socket.print("HTTP/1.1 {d} {s}\r\n", .{ @enumToInt(self.status_code), self.status_code.toString() });

        // write headers
        for (self.headers.items()) |header| {
            try socket.print("{s}: {s}\r\n", .{ header.key, header.value });
        }

        // If user has not set content-length, we add it calculated by the length of the body
        if (body.len > 0 and !self.headers.contains("Content-Length")) {
            try socket.print("Content-Length: {d}\r\n", .{body.len});
        }

        // set default Content-Type.
        // Adding headers is expensive so add it as default when we write to the socket
        if (!self.headers.contains("Content-Type")) {
            try socket.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
        }

        try socket.writeAll("Connection: keep-alive\r\n");

        try socket.writeAll("\r\n");
        if (body.len > 0) try socket.writeAll(body);
        try self.socket_writer.flush(); // ensure everything is written
    }

    /// Sends a `404 - Resource not found` response
    pub fn notFound(self: *Response) Error!void {
        self.status_code = .NotFound;
        try self.body.writeAll("Resource not found\n");
    }
};
