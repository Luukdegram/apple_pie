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
    /// The stream and its socket it's connected through
    stream: net.Stream,
    /// Frame to client's handler
    frame: @Frame(Client.run),

    /// Wrapper run function and log any errors that occur
    fn run(self: *Client, server: *Server) void {
        inlineRun(self, server) catch |err| {
            log.err("An error occured while handling a request: {}", .{@errorName(err)});
        };
    }

    /// Inner inlined function that runs the actual client logic
    /// First yields to the event loop to give control back to frame owner.
    /// Secondly, creates a new client and sets up its resources (including cleanup)
    /// Finally, it starts the client loop (keep-alive) and parses the incoming requests
    /// and then calls the user provided request handler.
    inline fn inlineRun(
        self: *Client,
        server: *Server,
    ) !void {
        // if (std.event.Loop.instance) |instance| instance.yield();
        var node = Clients.Node{ .data = self };

        server.clients.put(&node);
        defer if (server.clients.remove(&node)) {
            self.stream.close();
        };

        // we allocate the body and allocate a buffer for our response to save syscalls
        var arena = std.heap.ArenaAllocator.init(server.gpa);
        defer arena.deinit();

        // max byte size per stack before we allocate more memory
        const buffer_size: usize = 4096;
        var stack_allocator = std.heap.stackFallback(buffer_size, &arena.allocator);

        while (true) {
            const parsed_request = req.parse(
                stack_allocator.get(),
                self.stream.reader(),
                buffer_size,
            ) catch |err| switch (err) {
                // not an error, client disconnected
                req.ParseError.EndOfStream => return,
                else => return err,
            };

            // create on the stack and allow the user to write to its writer
            var body = std.ArrayList(u8).init(server.gpa);
            defer body.deinit();

            var response = Response{
                .headers = resp.Headers.init(server.gpa),
                .socket_writer = std.io.bufferedWriter(
                    self.stream.writer(),
                ),
                .is_flushed = false,
                .body = body.writer(),
            };
            defer response.headers.deinit();

            if (parsed_request.protocol == .http1_1 and parsed_request.host == null) {
                return response.writeHeader(.BadRequest);
            }

            // async runtime functions require a stack
            // provides a 100kb stack
            var stack: [100 * 1024]u8 align(16) = undefined;
            try nosuspend await @asyncCall(&stack, {}, server.handler, .{ &response, parsed_request });

            if (!response.is_flushed) try response.flush();

            if (parsed_request.should_close) return; // close connection

            if (!std.io.is_async) return; // No keep-alive for blocking connections
        }
    }
};

const Server = struct {
    stream: net.StreamServer,
    clients: Clients,
    handler: RequestHandler,
    gpa: *std.mem.Allocator,

    /// Initializes a new `net.Stream` and creates a new `Server` object
    fn init(gpa: *std.mem.Allocator, handler: RequestHandler) Server {
        var stream = net.StreamServer.init(.{ .reuse_address = true });
        errdefer stream.deinit();

        return Server{
            .stream = stream,
            .clients = Clients.init(),
            .handler = handler,
            .gpa = gpa,
        };
    }

    /// First disconnects its socket to close all connections,
    /// secondly awaits itself to ensure its finished state and then cleansup
    /// any remaining clients
    fn deinit(self: *Server) void {
        while (self.clients.get()) |node| {
            node.data.stream.close();
        }
        self.stream.deinit();
    }

    /// Binds the socket to the address and registers itself to the `notifier`
    fn start(self: *Server, address: net.Address) !void {
        try self.stream.listen(address);
        try self.run();
    }

    /// Enters the listener loop and awaits for new connections
    /// On new connection spawns a task on Zap's runtime to create a `Client`
    fn run(self: *Server) !void {
        while (true) {
            var conn = self.stream.accept() catch |err| switch (err) {
                error.SocketNotListening, error.ConnectionAborted => return,
                else => {
                    log.err("Server - stream.accept(): {s}", .{@errorName(err)});
                    continue;
                },
            };

            const client = try self.gpa.create(Client);

            client.* = .{
                .stream = conn.stream,
                .frame = async client.run(self),
            };
        }
    }
};

/// Creates a new server and starts listening for new connections.
/// On connection, parses its request and sends it to the given `handler`
pub fn listenAndServe(gpa: *std.mem.Allocator, address: net.Address, handler: RequestHandler) !void {
    var server = Server.init(gpa, handler);
    defer server.deinit();

    try server.start(address);
}
