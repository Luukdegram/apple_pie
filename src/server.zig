const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const pike = @import("pike");
const zap = @import("zap");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
const Request = req.Request;
const Response = resp.Response;

const log = std.log.scoped(.server);

const Clients = std.atomic.Queue(*Server.Client);

/// Function signature of what the handler function must match
pub const RequestHandler = fn handle(*Response, Request) anyerror!void;

pub const Server = struct {
    /// The connection clients will connect to
    socket: pike.Socket,
    /// The buffer size we accept for requests, anything bigger than this
    /// will be manually allocated
    request_buffer_size: usize = 4096,
    /// The address the server can be reached on
    address: net.Address,
    /// The function pointer to handle the requests
    request_handler: RequestHandler,
    /// Allocator to heap allocate our frames and request data
    allocator: *Allocator,
    /// Connections ready to be cleaned up
    clients: Clients,
    /// Server's frame for running async
    frame: @Frame(Server.run),

    const Client = struct {
        /// Pike's socket we're connected to
        socket: pike.Socket,
        /// The actual connection
        address: net.Address,
    };

    /// Initializes a new Server with its default values,
    pub fn init(
        allocator: *Allocator,
        address: net.Address,
        handlerFn: RequestHandler,
    ) !Server {
        try pike.init();

        var socket = try pike.Socket.init(
            std.os.AF_INET,
            std.os.SOCK_STREAM,
            std.os.IPPROTO_TCP,
            0,
        );
        try socket.set(.reuse_address, true);

        return Server{
            .address = address,
            .request_handler = handlerFn,
            .allocator = allocator,
            .socket = socket,
            .frame = undefined,
            .clients = Clients.init(),
        };
    }

    /// Frees the server resources and closes all connections
    pub fn deinit(self: *Server) void {
        defer pike.deinit();
        self.socket.deinit();

        await self.frame;

        while (self.clients.get()) |node| {
            node.data.socket.deinit();

            await node.data.frame catch {};
            self.allocator.destroy(node.data);
        }
    }

    /// Starts listening for connections and serves responses
    pub fn start(self: *Server) !void {
        try try zap.runtime.run(.{}, startRuntime, .{self});
    }

    fn startRuntime(self: *Server) !void {
        try self.socket.bind(self.address);
        try self.socket.listen(128);

        const notifier = try pike.Notifier.init();
        defer notifier.deinit();

        try self.socket.registerTo(&notifier);

        var shutdown = false;
        self.frame = async self.run(&notifier);

        var signal_frame = async awaitSignal(&notifier, &shutdown);

        while (!shutdown) {
            try notifier.poll(10_000);
        }

        try nosuspend await signal_frame;
    }

    /// Main server loop that awaits for new connections and dispatches them
    fn run(self: *Server, notifier: *const pike.Notifier) callconv(.Async) !void {
        var retries: usize = 0;
        while (true) {
            var connection = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening => return,
                else => {
                    if (retries > 4) return err;
                    log.warn("Could not accept connection: {}\nRetrying...", .{err});

                    // sleep for 100 ms extra per retry
                    std.time.sleep(std.time.ns_per_ms * 100 * (retries + 1));
                    retries += 1;
                    continue;
                },
            };

            zap.runtime.spawn(.{}, runClient, .{ self, notifier, connection.socket, connection.address }) catch |err| {
                log.err("Failed to spawn client: {}", @errorName(err));
                continue;
            };
        }
    }

    /// Awaits for the notifier to trigger an interrupt/quit signal
    fn awaitSignal(notifier: *const pike.Notifier, shutdown: *bool) !void {
        // ensure that even in case of error, we shutdown
        defer shutdown.* = true;

        var signal = try pike.Signal.init(.{ .interrupt = true });
        defer signal.deinit();

        try signal.wait();
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

fn runClient(
    server: *Server,
    notifier: *const pike.Notifier,
    socket: pike.Socket,
    address: net.Address,
) void {
    serveRequest(server, notifier, socket, address) catch |err| {
        log.err("Unable to run client {}", @errorName(err));
    };
}

/// Handles a request and returns a response based on the given handler function
fn serveRequest(
    server: *Server,
    notifier: *const pike.Notifier,
    socket: pike.Socket,
    address: net.Address,
) !void {
    zap.runtime.yield();

    var client = Server.Client{ .socket = socket, .address = address };
    var node = Clients.Node{ .data = client };

    server.clients.put(&node);

    // free up client resources
    defer if (server.clients.remove(&node)) {
        client.socket.deinit();
    };

    try client.socket.registerTo(notifier);

    // keep-alive by default, we will break out if Connection: close is set
    // or if `io_mode` is not set to '.evented'
    while (true) {
        // use an arena allocator to free all memory at once as it performs better than
        // freeing everything individually.
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();

        // create on the stack and allow the user to write to its writer
        var body = std.ArrayList(u8).init(&arena.allocator);
        // 'var' as we allocate it on the stack of the loop and we need to modify it
        var response = Response{
            .headers = resp.Headers.init(&arena.allocator),
            .socket_writer = std.io.bufferedWriter(
                resp.SocketWriter{ .handle = &client.socket },
            ),
            .is_flushed = false,
            .body = body.writer(),
        };

        // parse the HTTP Request and if successful, call the handler function asynchronous
        var request = req.parse(
            &arena.allocator,
            &client.socket,
            server.request_buffer_size,
        );

        if (request) |parsed_request| {
            @call(.{}, server.request_handler, .{ &response, parsed_request }) catch |err| {
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

            // if the client requests to close the connection
            if (parsed_request.headers.contains("Connection")) {
                const header = parsed_request.headers.get("Connection").?;
                if (std.ascii.eqlIgnoreCase(header, "close")) {
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
