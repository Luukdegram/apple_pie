const pike = @import("pike");
const zap = @import("zap");
const std = @import("std");
const net = std.net;
const log = std.log.scoped(.apple_pie);
const req = @import("request.zig");
const resp = @import("response.zig");
const Request = req.Request;
const Response = resp.Response;
const os = std.os;

/// Alias for an atomic queue of Clients
const Clients = std.atomic.Queue(*Client);

/// User API function signature of a request handler
pub const RequestHandler = fn handle(*Response, Request) callconv(.Async) anyerror!void;

/// Represents a peer that is connected to our server
const Client = struct {
    /// The socket its connected through
    socket: pike.Socket,
    /// The address of the peer
    address: net.Address,

    /// Wrapper run function as Zap's runtime enforces us to not return any errors
    fn run(server: *Server, notifier: *const pike.Notifier, socket: pike.Socket, address: net.Address) void {
        inlineRun(server, notifier, socket, address) catch |err| {
            log.err("An error occured while handling a request {}", .{@errorName(err)});
        };
    }

    /// Inner inlined function that runs the actual client logic
    /// First yields to the Zap runtime to give control back to frame owner.
    /// Secondly, creates a new client and sets up its resources (including cleanup)
    /// Finally, it starts the client loop (keep-alive) and parses the incoming requests
    /// and then calls the user provided request handler.
    inline fn inlineRun(
        server: *Server,
        notifier: *const pike.Notifier,
        socket: pike.Socket,
        address: net.Address,
    ) !void {
        zap.runtime.yield();

        var client = Client{ .socket = socket, .address = address };
        var node = Clients.Node{ .data = &client };

        server.clients.put(&node);
        defer if (server.clients.remove(&node)) {
            client.socket.deinit();
        };

        try client.socket.registerTo(notifier);

        // we allocate the body and allocate a buffer for our response to save syscalls
        var arena = std.heap.ArenaAllocator.init(server.gpa);
        defer arena.deinit();

        while (true) {
            const parsed_request = req.parse(
                &arena.allocator,
                client.socket.reader(),
                4096,
            ) catch |err| switch (err) {
                req.ParseError.EndOfStream => return, // not an error, client disconnected
                else => return err,
            };

            // create on the stack and allow the user to write to its writer
            var body = std.ArrayList(u8).init(&arena.allocator);

            var response = Response{
                .headers = resp.Headers.init(&arena.allocator),
                .socket_writer = std.io.bufferedWriter(
                    resp.SocketWriter{ .handle = &client.socket },
                ),
                .is_flushed = false,
                .body = body.writer(),
            };

            if (parsed_request.protocol == .http1_1 and parsed_request.host == null) {
                return response.writeHeader(.BadRequest);
            }

            // async runtime functions require a stack
            // provides a 100kb stack
            var stack: [100 * 1024]u8 align(16) = undefined;
            try nosuspend await @asyncCall(&stack, {}, server.handler, .{ &response, parsed_request });

            if (!response.is_flushed) try response.flush();

            if (parsed_request.should_close) return; // close connection
        }
    }
};

const Server = struct {
    socket: pike.Socket,
    clients: Clients,
    frame: @Frame(run),
    handler: RequestHandler,
    gpa: *std.mem.Allocator,

    /// Initializes a new `pike.Socket` and creates a new `Server` object
    fn init(gpa: *std.mem.Allocator, handler: RequestHandler) !Server {
        var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
        errdefer socket.deinit();

        try socket.set(.reuse_address, true);

        return Server{
            .socket = socket,
            .clients = Clients.init(),
            .frame = undefined,
            .handler = handler,
            .gpa = gpa,
        };
    }

    /// First disconnects its socket to close all connections,
    /// secondly awaits itself to ensure its finished state and then cleansup
    /// any remaining clients
    fn deinit(self: *Server) void {
        self.socket.deinit();

        await self.frame;

        while (self.clients.get()) |node| {
            node.data.socket.deinit();
        }
    }

    /// Binds the socket to the address and registers itself to the `notifier`
    fn start(self: *Server, notifier: *const pike.Notifier, address: net.Address) !void {
        try self.socket.bind(address);
        try self.socket.listen(128);
        try self.socket.registerTo(notifier);

        self.frame = async self.run(notifier);
    }

    /// Enters the listener loop and awaits for new connections
    /// On new connection spawns a task on Zap's runtime to create a `Client`
    fn run(self: *Server, notifier: *const pike.Notifier) callconv(.Async) void {
        while (true) {
            var conn = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening,
                error.OperationCancelled,
                => return,
                else => {
                    log.err("Server - socket.accept(): {}", .{@errorName(err)});
                    continue;
                },
            };

            zap.runtime.spawn(.{}, Client.run, .{ self, notifier, conn.socket, conn.address }) catch |err| {
                log.err("Server - runtime.spawn(): {}", .{@errorName(err)});
                continue;
            };
        }
    }
};

/// Creates a new server and starts listening for new connections.
/// On connection, parses its request and sends it to the given `handler`
pub fn listenAndServe(gpa: *std.mem.Allocator, address: net.Address, handler: RequestHandler) !void {
    try pike.init();
    defer pike.deinit();

    var signal = try pike.Signal.init(.{ .interrupt = true });
    try try zap.runtime.run(.{}, serve, .{ gpa, &signal, address, handler });
}

/// Creates event listener, notifier and registers the signal handler and event handler to the notifier
/// Finally, creates a new server object and starts listening to new connections
fn serve(gpa: *std.mem.Allocator, signal: *pike.Signal, address: net.Address, handler: RequestHandler) !void {
    defer signal.deinit();

    var event = try pike.Event.init();
    defer event.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    try signal.registerTo(&notifier);
    try event.registerTo(&notifier);

    var stopped = false;

    var server = try Server.init(gpa, handler);
    defer server.deinit();

    try server.start(&notifier, address);

    var frame = async awaitSignal(signal, &event, &stopped, &server);
    while (!stopped) {
        try notifier.poll(1_000_000);
    }

    try nosuspend await frame;

    defer log.info("Apple pie has been shutdown", .{});
}

/// Awaits for a signal to be provided for shutdown
fn awaitSignal(signal: *pike.Signal, event: *pike.Event, stopped: *bool, server: *Server) !void {
    defer {
        stopped.* = true;
        event.post() catch {};
    }

    try signal.wait();
}
