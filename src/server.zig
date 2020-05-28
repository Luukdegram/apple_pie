const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = req.Request;
pub const Response = resp.Response;

/// Starts a new server on the given `address` and listens for new connections.
/// Each request will call `handler.serve` to serve the response to the requester.
pub fn listenAndServe(
    allocator: *Allocator,
    address: net.Address,
    comptime handler: var,
) !void {
    var server = net.StreamServer.init(.{});
    defer server.deinit();

    server.listen(address) catch |err| switch (err) {
        error.AddressInUse,
        error.AddressNotAvailable,
        => return err,
        else => return error.ListenError,
    };

    var retries: usize = 0;
    while (true) {
        var connection: net.StreamServer.Connection = server.accept() catch |err| {
            if (retries > 4) return err;
            std.debug.warn("Could not accept connection: {}\nRetrying...\n", .{err});

            // sleep for 5 ms extra per retry
            std.time.sleep(5000000 * (retries + 1));
            retries += 1;
            continue;
        };

        _ = async serveRequest(allocator, &connection, handler);
    }
}

/// Handles a request and returns a response based on the given handler function
fn serveRequest(
    allocator: *Allocator,
    connection: *net.StreamServer.Connection,
    comptime handler: var,
) void {
    // if it fails to accept connection, simply return and don't handle it
    defer connection.file.close();

    // use an arena allocator to free all memory at once as it performs better than
    // freeing everything individually.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var response = Response.init(connection, &arena.allocator);

    if (req.parse(&arena.allocator, connection.file.inStream())) |parsed_request| {
        handler.serve(&response, parsed_request);
    } else |err| {
        _ = response.headers.put("Content-Type", "text/plain;charset=utf-8") catch |e| {
            std.debug.warn("Error setting Content-Type: {}\n", .{e});
            return;
        };

        switch (err) {
            error.StreamTooLong => {
                response.status_code = 431;
                response.write("431 Request Header Fields Too Large") catch |e| {
                    std.debug.warn("Error writing response: {}\n", .{e});
                    return;
                };
            },
            else => {
                response.status_code = 400;
                response.write("400 Bad Request") catch |e| {
                    std.debug.warn("Error writing response: {}\n", .{e});
                    return;
                };
            },
        }
    }
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
