const std = @import("std");
const req = @import("request.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = req.Request;

pub const Response = struct {
    /// current connection between server and peer
    connection: *net.StreamServer.Connection,
    /// status code of the response, 200 by default
    status_code: u16 = 200,

    /// creates a new Response object with defaults
    fn init(connection: *net.StreamServer.Connection) Response {
        return Response{ .connection = connection };
    }

    /// Writes bytes to the requester
    pub fn write(self: @This(), contents: []const u8) !void {
        var stream = self.connection.file.outStream();
        // reserve 100 bytes for our status line
        var buffer: [50]u8 = undefined;
        const status_line = try std.fmt.bufPrint(&buffer, "HTTP/1.1 {} OK\n\n", .{self.status_code});
        _ = try stream.write(status_line);

        _ = try stream.writeAll(contents);
    }
};

/// Starts a new server on the given `address` and listens for new connections.
/// Each request will call `handler.serve` to serve the response to the requester.
pub fn listenAndServe(
    allocator: *Allocator,
    address: net.Address,
    handler: var,
) !void {
    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(address);

    while (true) {
        var connection: net.StreamServer.Connection = try server.accept();

        const parsed_request = try req.parse(allocator, connection.file.inStream());

        var response = Response.init(&connection);

        handler.serve(&response, parsed_request);
        connection.file.close();
    }
}

/// Generic Function to serve, needs to be implemented by the caller
pub fn Handler(
    /// Implementee's serve function to handle the request
    comptime serveFn: fn (
        /// Response object that can be written to
        response: *Response,
        /// Request object containing the original request with its data such as headers, url etc.
        request: Request,
    ) void,
) type {
    return struct {
        /// calls the implementation function to serve the request
        pub fn serve(response: *Response, request: Request) void {
            return serveFn(response, request);
        }
    };
}
