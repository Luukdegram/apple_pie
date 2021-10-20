//! Handles the logic for sending a response to the client.
//! Although it provides access to the direct stream,
//! it is suggested to use the helper methods such as `writer()` to ensure
//! for correct handling.

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

/// HTTP Status codes according to `rfc7231`
/// https://tools.ietf.org/html/rfc7231#section-6
pub const StatusCode = enum(u16) {
    // Informational 1xx
    @"continue" = 100,
    // Successful 2xx
    switching_protocols = 101,
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    // redirections 3xx
    partial_content = 206,
    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    // client errors 4xx
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    request_entity_too_large = 413,
    request_uri_too_long = 414,
    unsupported_mediatype = 415,
    requested_range_not_satisfiable = 416,
    expectation_failed = 417,
    /// teapot is an extension status code and not required for clients to support
    teapot = 418,
    upgrade_required = 426,
    /// extra status code according to `https://tools.ietf.org/html/rfc6585#section-5`
    request_header_fields_too_large = 431,
    // server errors 5xx
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    _,

    /// Returns the string value of a `StatusCode`
    /// for example: .ResetContent returns "Returns Content".
    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .ok => "Ok",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_information => "Non Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .request_entity_too_large => "Request Entity Too Large",
            .request_uri_too_long => "Request-URI Too Long",
            .unsupported_mediatype => "Unsupported Media Type",
            .requested_range_not_satisfiable => "Requested Range Not Satisfiable",
            .teapot => "I'm a Teapot",
            .upgrade_required => "Upgrade Required",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .expectation_failed => "Expectation Failed",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            _ => "",
        };
    }
};

/// Headers is an alias to `std.StringHashMap([]const u8)`
pub const Headers = std.StringArrayHashMap([]const u8);

/// Response allows to set the status code and content of the response
pub const Response = struct {
    pub const Status = StatusCode;

    /// status code of the response, 200 by default
    status_code: StatusCode = .ok,
    /// StringHashMap([]const u8) with key and value of headers
    headers: Headers,
    /// Buffered writer that writes to our socket
    buffered_writer: std.io.BufferedWriter(4096, net.Stream.Writer),
    /// True when write() has been called
    is_flushed: bool,
    /// Response body, can be written to through the writer interface
    body: std.ArrayList(u8).Writer,

    /// True if the connection must be closed, false otherwise.
    /// When the response is provided to the handler, it is true if either:
    /// * the client requests the connection to close
    /// * std.io.is_async is false
    close: bool,

    pub const Error = net.Stream.WriteError || error{OutOfMemory};

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
        // reset body to wipe any user written data
        self.body.context.items.len = 0;
        try self.body.print("{s}\n", .{self.status_code.toString()});
        try self.flush();
    }

    /// Sends the response to the client, can only be called once
    /// Any further calls is a panic
    pub fn flush(self: *Response) Error!void {
        std.debug.assert(!self.is_flushed);
        self.is_flushed = true;

        const body = self.body.context.items;
        var socket = self.buffered_writer.writer();

        // Print the status line, we only support HTTP/1.1 for now
        try socket.print("HTTP/1.1 {d} {s}\r\n", .{ @enumToInt(self.status_code), self.status_code.toString() });

        // write headers
        var header_it = self.headers.iterator();
        while (header_it.next()) |header| {
            try socket.print("{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.* });
        }

        // If user has not set content-length, we add it calculated by the length of the body
        if (!self.headers.contains("Content-Length")) {
            try socket.print("Content-Length: {d}\r\n", .{body.len});
        }

        // set default Content-Type.
        // Adding headers is expensive so add it as default when we write to the socket
        if (!self.headers.contains("Content-Type")) {
            try socket.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
        }

        if (self.close) {
            try socket.writeAll("Connection: close\r\n");
        } else {
            try socket.writeAll("Connection: keep-alive\r\n");
        }

        try socket.writeAll("\r\n");
        if (body.len > 0) try socket.writeAll(body);
        try self.buffered_writer.flush(); // ensure everything is written
    }

    /// Sends a `404 - Resource not found` response
    pub fn notFound(self: *Response) Error!void {
        self.status_code = .not_found;
        try self.body.writeAll("Resource not found\n");
    }
};
