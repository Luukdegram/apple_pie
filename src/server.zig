const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = req.Request;
pub const Response = resp.Response;

pub const RequestHandler = fn handle(*Response, Request) callconv(.Async) anyerror!void;

pub const Server = struct {
    const Self = @This();

    host_connection: net.StreamServer,
    request_buffer_size: usize = 4096,
    should_stop: std.atomic.Int(u1),
    address: net.Address,
    request_handler: RequestHandler,
    allocator: *Allocator,
    resolved: std.atomic.Stack(*Connection),

    const Connection = struct {
        frame_stack: []align(16) u8,
        server: *Server,
        conn: net.StreamServer.Connection,
        frame: @Frame(serveRequest),
        node: std.atomic.Stack(*Connection).Node,

        fn init(server: *Server, conn: net.StreamServer.Connection) !*Connection {
            var connection = try server.allocator.create(Connection);
            errdefer server.allocator.destroy(connection);

            var stack = try server.allocator.alignedAlloc(u8, 16, @frameSize(server.request_handler));

            connection.* = .{
                .frame_stack = stack,
                .server = server,
                .conn = conn,
                .frame = undefined,
                .node = .{
                    .next = null,
                    .data = connection,
                },
            };

            return connection;
        }

        fn deinit(self: *Connection) void {
            self.conn.file.close();
            self.server.allocator.free(self.frame_stack);
        }
    };

    /// Initializes a new Server with its default values,
    pub fn init(
        allocator: *Allocator,
        address: net.Address,
        handlerFn: RequestHandler,
    ) !Server {
        return Server{
            .address = address,
            .request_handler = handlerFn,
            .allocator = allocator,
            .should_stop = std.atomic.Int(u1).init(0),
            // default options, users can set backlog using `setMaxConnections`
            .host_connection = net.StreamServer.init(.{ .reuse_address = true }),
            .resolved = std.atomic.Stack(*Connection).init(),
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
    pub fn deinit(self: Self) void {}

    /// Starts listening for connections and serves responses
    pub fn start(self: *Self) !void {
        var server = self.host_connection;
        // deinit also closes the connection
        defer server.deinit();

        try server.listen(self.address);

        var retries: usize = 0;
        while (true) {
            var connection = server.accept() catch |err| {
                if (retries > 4) return err;
                std.debug.warn("Could not accept connection: {}\nRetrying...\n", .{err});

                // sleep for 5 ms extra per retry
                std.time.sleep(5000000 * (retries + 1));
                retries += 1;
                continue;
            };

            var conn = Connection.init(self, connection) catch {
                connection.file.close();
                continue;
            };

            conn.frame = async serveRequest(conn);

            while (self.resolved.pop()) |node| {
                node.data.deinit();
                self.allocator.destroy(node.data);
            }
        }
    }
};

/// Starts a new server on the given `address` and listens for new connections.
/// Each request will call `request_handler` to serve the response to the requester.
pub fn listenAndServe(
    allocator: *Allocator,
    address: net.Address,
    request_handler: RequestHandler,
) !void {
    var server = try Server.init(allocator, address, request_handler);
    try server.start();
}

/// Handles a request and returns a response based on the given handler function
fn serveRequest(
    connection: *Server.Connection,
) !void {
    defer connection.server.resolved.push(&connection.node);
    // keep-alive
    while (true) {
        // use an arena allocator to free all memory at once as it performs better than
        // freeing everything individually.
        var arena = std.heap.ArenaAllocator.init(connection.server.allocator);
        defer arena.deinit();
        var response = Response.init(connection.conn.file.handle, &arena.allocator);

        // parse the HTTP Request and if successful, call the handler function asynchronous
        var request = req.parse(
            &arena.allocator,
            connection.conn.file.reader(),
            connection.server.request_buffer_size,
        );

        if (request) |parsed_request| {
            var frame = @asyncCall(
                connection.frame_stack,
                {},
                connection.server.request_handler,
                .{ &response, parsed_request },
            );

            await frame catch |err| {
                switch (err) {
                    std.os.SendError.BrokenPipe => break,
                    else => {
                        std.debug.print("Unexpected error: {}\n", .{err});
                        break;
                    },
                }
            };

            // if user did not call response.write(), create a 404 resource not found
            // to ensure the client receives a response but no valid reply is possible.
            if (!response.is_dirty) {
                try response.notFound();
            }

            // We don't support keep-alive in blocking mode as it would block
            // other requests
            if (!std.io.is_async) break;

            // if the client requests to close the connection
            if (parsed_request.headers.contains("Connection")) {
                const entries = (try parsed_request.headers.get(&arena.allocator, "Connection")).?;
                arena.allocator.free(entries);
                if (std.ascii.eqlIgnoreCase(entries[0].value, "close")) {
                    break;
                }
            }

            // if the handler function requests to close the connection
            if (response.headers.contains("Connection")) {
                if (std.ascii.eqlIgnoreCase(response.headers.get("Connection").?, "close")) {
                    break;
                }
            }
        } else |err| {
            _ = try response.headers.put("Content-Type", "text/plain;charset=utf-8");

            response.status_code = .BadRequest;
            try response.write("400 Bad Request");
            break;
        }
    }
}
