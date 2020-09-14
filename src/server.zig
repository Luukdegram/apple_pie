const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = req.Request;
pub const Response = resp.Response;

const log = std.log.scoped(.server);

/// Function signature of what the handler function must match
pub const RequestHandler = fn handle(*Response, Request) callconv(.Async) anyerror!void;

pub const Server = struct {
    /// The connection clients will connect to
    host_connection: net.StreamServer,
    /// The buffer size we accept for requests, anything bigger than this
    /// will be manually allocated
    request_buffer_size: usize = 4096,
    /// whether the server should stop running
    should_stop: std.atomic.Int(u1),
    /// The address the server can be reached on
    address: net.Address,
    /// The function pointer to handle the requests
    request_handler: RequestHandler,

    allocator: *Allocator,
    /// Connections ready to be cleaned up
    resolved: std.atomic.Stack(*Connection),

    const Connection = struct {
        /// Stack size of the async function
        frame_stack: []align(16) u8,
        /// The server we're connected to
        server: *Server,
        /// The actual connection
        conn: net.StreamServer.Connection,
        /// Frame pointer to the request handler
        frame: @Frame(serveRequest),
        /// Allows us to cleanup the connection when finished
        node: std.atomic.Stack(*Connection).Node,

        /// Creates a new connection with a stack big enough to call the request handler
        /// This allocates the `Connection` on the heap
        fn init(server: *Server, conn: net.StreamServer.Connection) !*Connection {
            var connection = try server.allocator.create(Connection);
            errdefer server.allocator.destroy(connection);

            const stack = try server.allocator.allocAdvanced(
                u8,
                16,
                @frameSize(server.request_handler),
                .exact,
            );

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

        /// Cleans up the connection by closing the connection
        /// and then freeing the memory of the frame stack
        ///
        /// NOTE: This will not free the Connection itself yet,
        /// that will be done by the server.
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
    pub fn setMaxConnections(self: *Server, size: u32) void {
        self.host_connection.kernel_backlog = size;
    }

    /// Gracefully shuts down the server, this function is thread safe
    pub fn shutdown(self: *Server) void {
        self.should_stop.set(1);
    }

    /// Frees the frame stack
    pub fn deinit(self: Server) void {}

    /// Starts listening for connections and serves responses
    pub fn start(self: *Server) !void {
        var server = self.host_connection;
        // deinit also closes the connection
        defer server.deinit();

        try server.listen(self.address);

        var retries: usize = 0;
        while (true) {
            var connection = server.accept() catch |err| {
                if (retries > 4) return err;
                log.warn("Could not accept connection: {}\nRetrying...\n", .{err});

                // sleep for 100 ms extra per retry
                std.time.sleep(std.time.ns_per_ms * 100 * (retries + 1));
                retries += 1;
                continue;
            };

            var conn = Connection.init(self, connection) catch |err| {
                log.info("Could not create connection: {}\nClosing and continueing...\n", .{err});
                connection.file.close();
                continue;
            };

            conn.frame = async serveRequest(conn);

            // if any connections are resolved(finished) clean them up
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
) (Response.Error || req.ParseError)!void {
    // Add connection to resolved stack when we are finished with the request
    defer connection.server.resolved.push(&connection.node);

    // keep-alive by default, we will break out if Connection: close is set
    // or if `io_mode` is not set to '.evented'
    while (true) {
        // use an arena allocator to free all memory at once as it performs better than
        // freeing everything individually.
        var arena = std.heap.ArenaAllocator.init(connection.server.allocator);
        defer arena.deinit();

        // create on the stack and allow the user to write to its writer
        var body = std.ArrayList(u8).init(&arena.allocator);
        // 'var' as we allocate it on the stack of the loop and we need to modify it
        var response = Response{
            .headers = resp.Headers.init(&arena.allocator),
            .socket_writer = std.io.bufferedWriter(
                resp.SocketWriter{ .handle = connection.conn.file.handle },
            ),
            .is_flushed = false,
            .body = body.writer(),
        };

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
                        log.err("Unexpected error: {}\n", .{err});
                        break;
                    },
                }
            };

            if (!response.is_flushed) {
                try response.flush();
            }

            // We don't support keep-alive in blocking mode as it would block
            // other requests
            if (!std.io.is_async) break;

            // if the client requests to close the connection
            if (parsed_request.headers.contains("Connection")) {
                const entries = (try parsed_request.headers.get(&arena.allocator, "Connection")).?;
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

            // if http version 1.0, no persistant connection is supported, therefore end connection
            if (std.mem.eql(u8, "HTTP/1.0", parsed_request.protocol)) break;
        } else |err| {
            try response.headers.put("Content-Type", "text/plain;charset=utf-8");

            response.status_code = .BadRequest;
            try response.writer().writeAll("400 Bad Request");
            try response.flush();
            log.debug("An error occured parsing the request: {}\n", .{err});
            break;
        }
    }
}
