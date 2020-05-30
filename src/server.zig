const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = req.Request;
pub const Response = resp.Response;

pub const RequestHandler = fn handle(*Response, Request) callconv(.Async) void;

pub const Server = struct {
    const Self = @This();

    host_connection: net.StreamServer,
    request_buffer_size: usize = 4096,
    should_stop: std.atomic.Int(u1),
    address: net.Address,
    request_handler: RequestHandler,
    allocator: *Allocator,
    frame_stack: []align(16) u8,

    pub fn init(allocator: *Allocator, address: net.Address, comptime handlerFn: RequestHandler) !Server {
        return Server{
            .address = address,
            .request_handler = handlerFn,
            .allocator = allocator,
            .should_stop = std.atomic.Int(u1).init(0),
            // default options, users can set backlog using `setMaxConnections`
            .host_connection = net.StreamServer.init(.{}),
            .frame_stack = try allocator.alignedAlloc(
                u8,
                16,
                @sizeOf(@Frame(handlerFn)),
            ),
        };
    }

    /// Sets the max allowed clients before they receive `Connection Refused`
    /// This function must be called before `start`.
    pub fn setMaxConnections(self: *Self, size: u32) void {
        self.host_connection.kernel_backlog = size;
    }

    /// Gracefully shuts down the server, this function is thread safe
    pub fn shutdown(self: *Self) void {
        self.should_stop.set(1);
    }

    /// Frees the frame stack
    pub fn deinit(self: Self) void {
        self.allocator.free(self.frame_stack);
    }

    /// Starts listening for connections and serves responses
    pub fn start(self: *Self) !void {
        var server = self.host_connection;
        // deinit also closes the connection
        defer server.deinit();

        server.listen(self.address) catch |err| switch (err) {
            error.AddressInUse,
            error.AddressNotAvailable,
            => return err,
            else => return error.ListenError,
        };

        var retries: usize = 0;
        while (self.should_stop.get() == 0) {
            var connection: net.StreamServer.Connection = server.accept() catch |err| {
                if (retries > 4) return err;
                std.debug.warn("Could not accept connection: {}\nRetrying...\n", .{err});

                // sleep for 5 ms extra per retry
                std.time.sleep(5000000 * (retries + 1));
                retries += 1;
                continue;
            };

            _ = async serveRequest(self, &connection);
        }
    }
};

/// Starts a new server on the given `address` and listens for new connections.
/// Each request will call `handler.serve` to serve the response to the requester.
pub fn listenAndServe(
    allocator: *Allocator,
    address: net.Address,
    comptime requestHandler: RequestHandler,
) !void {
    var server = try Server.init(allocator, address, requestHandler);
    try server.start();
}

/// Handles a request and returns a response based on the given handler function
fn serveRequest(
    server: *Server,
    connection: *net.StreamServer.Connection,
) callconv(.Async) void {
    defer connection.file.close();

    // use an arena allocator to free all memory at once as it performs better than
    // freeing everything individually.
    var arena = std.heap.ArenaAllocator.init(server.allocator);
    defer arena.deinit();
    var response = Response.init(connection, &arena.allocator);

    if (req.parse(&arena.allocator, connection.file.inStream())) |*parsed_request| {
        // call the function of the implementer
        var frame = @asyncCall(server.frame_stack, {}, server.request_handler, &response, parsed_request.*);
        await frame;
    } else |err| {
        _ = response.headers.put("Content-Type", "text/plain;charset=utf-8") catch |e| {
            std.debug.warn("Error setting Content-Type: {}\n", .{e});
            return;
        };

        response.status_code = 400;
        response.write("400 Bad Request") catch |e| {
            std.debug.warn("Error writing response: {}\n", .{e});
            return;
        };
    }
}
