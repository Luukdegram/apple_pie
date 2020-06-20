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
) void {
    defer connection.server.resolved.push(&connection.node);

    // use an arena allocator to free all memory at once as it performs better than
    // freeing everything individually.
    var arena = std.heap.ArenaAllocator.init(connection.server.allocator);
    defer arena.deinit();
    // keep-alive
    while (true) {
        var response = Response.init(connection.conn.file.handle, &arena.allocator);

        // parse the HTTP Request and if successful, call the handler function asynchronous
        var req_frame = req.parse(
            &arena.allocator,
            connection.conn.file.inStream(),
            connection.server.request_buffer_size,
        );

        if (req_frame) |parsed_request| {
            var frame = @asyncCall(
                connection.frame_stack,
                {},
                connection.server.request_handler,
                &response,
                parsed_request,
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

            // TODO, if connection is Close or if single threaded mode, break out of while
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
            break;
        }
        arena.deinit();
        arena = std.heap.ArenaAllocator.init(connection.server.allocator);
    }
}
