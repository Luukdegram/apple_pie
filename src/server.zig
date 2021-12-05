//! Server handles the connection between the host and the clients.
//! After a client has succesfully connected, the server will ensure
//! the request is being parsed and handled correctly before dispatching
//! it to the user. The server also ensures a body is flushed to the client
//! before ending a cycle.

const std = @import("std");
const root = @import("root");
const Request = @import("Request.zig");
const resp = @import("response.zig");
const net = std.net;
const atomic = std.atomic;
const log = std.log.scoped(.apple_pie);
const Response = resp.Response;
const Allocator = std.mem.Allocator;
const Queue = atomic.Queue;

/// User API function signature of a request handler
pub fn RequestHandler(comptime Context: type) type {
    return fn handle(Context, *Response, Request) anyerror!void;
}

/// Allows users to set the max buffer size before we allocate memory on the heap to store our data
const max_buffer_size = blk: {
    const given = if (@hasDecl(root, "buffer_size")) root.buffer_size else 1024 * 64; // 64kB
    break :blk std.math.min(given, 1024 * 1024 * 16); // max stack size (16MB)
};

/// Allows users to set the max request header buffer size before we return error.RequestTooLarge.
const max_request_size = blk: {
    const given = if (@hasDecl(root, "request_buffer_size")) root.request_buffer_size else 1024 * 64;
    break :blk std.math.min(given, 1024 * 1024 * 16); // max stack size (16MB)
};

/// Creates a new `Server` instance and starts listening to new connections
/// Afterwards cleans up any resources.
///
/// This creates a `Server` with default options, meaning it uses 4096 bytes
/// max for parsing request headers and 4096 bytes as a stack buffer before it
/// will allocate any memory
///
/// If the server needs the ability to be shutdown on command, use `Server.init()`
/// and then start it by calling `run()`.
pub fn listenAndServe(
    /// Memory allocator, for general usage.
    /// Will be used to setup an arena to free any request/response data.
    gpa: Allocator,
    /// Address the server is listening at
    address: net.Address,
    /// Allows passing a context that is available to all handler function pointers.
    /// User must ensure thread-safety when accessing the context.
    context: anytype,
    /// User defined `Request`/`Response` handler
    comptime handler: RequestHandler(@TypeOf(context)),
) !void {
    try (Server.init()).run(gpa, address, context, handler);
}

pub const Server = struct {
    should_quit: atomic.Atomic(bool),

    /// Initializes a new `Server` instance
    pub fn init() Server {
        return .{ .should_quit = atomic.Atomic(bool).init(false) };
    }

    /// Starts listening to new connections and serves the responses
    /// Cleans up any resources that were allocated during the connection
    pub fn run(
        self: *Server,
        /// Memory allocator, for general usage.
        /// Will be used to setup an arena to free any request/response data.
        gpa: Allocator,
        /// Address the server is listening at
        address: net.Address,
        /// Runtime context allowing to pass data between handlers.
        /// Thread-safety must be guaranteed by the caller.
        context: anytype,
        /// User defined `Request`/`Response` handler
        comptime handler: RequestHandler(@TypeOf(context)),
    ) !void {
        var stream = net.StreamServer.init(.{ .reuse_address = true });
        defer stream.deinit();

        // client queue to clean up clients after connection is broken/finished
        const Client = ClientFn(@TypeOf(context), handler);
        var clients = Queue(*Client).init();

        // Force clean up any remaining clients that are still connected
        // if an error occured
        defer while (clients.get()) |node| {
            const data = node.data;
            data.stream.close();
            gpa.destroy(data);
        };

        try stream.listen(address);

        while (!self.should_quit.load(.SeqCst)) {
            var connection = stream.accept() catch |err| switch (err) {
                error.ConnectionResetByPeer, error.ConnectionAborted => {
                    log.err("Could not accept connection: '{s}'", .{@errorName(err)});
                    continue;
                },
                else => return err,
            };

            // setup client connection and handle it
            const client = try gpa.create(Client);
            client.* = Client{
                .stream = connection.stream,
                .node = .{ .data = client },
                .frame = async client.run(gpa, &clients, context),
            };

            while (clients.get()) |node| {
                const data = node.data;
                await data.frame;
                gpa.destroy(data);
            }
        }
    }

    /// Tells the server to shutdown
    pub fn shutdown(self: *Server) void {
        self.should_quit.store(true, .SeqCst);
    }
};

/// Generic Client handler wrapper around the given `T` of `RequestHandler`.
/// Allows us to wrap our client connection base around the given user defined handler
/// without allocating data on the heap for it
fn ClientFn(comptime Context: type, comptime handler: RequestHandler(Context)) type {
    return struct {
        const Self = @This();

        /// Frame of the client, used to ensure its lifetime along the Client's
        frame: @Frame(run),
        /// Streaming connection to the peer
        stream: net.Stream,
        /// Node used to cleanup itself after a connection is finished
        node: Queue(*Self).Node,

        /// Handles the client connection. First parses the client into a `Request`, and then calls the user defined
        /// client handler defined in `T`, and finally sends the final `Response` to the client.
        /// If the connection is below version HTTP1/1, the connection will be broken and no keep-alive is supported.
        /// Same for blocking instances, to ensure multiple clients can connect (synchronously).
        /// NOTE: This is a wrapper function around `handle` so we can catch any errors and handle them accordingly
        /// as we do not want to crash the server when an error occurs.
        fn run(self: *Self, gpa: Allocator, clients: *Queue(*Self), context: Context) void {
            self.handle(gpa, clients, context) catch |err| {
                log.err("An error occured handling request: '{s}'", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
        }

        fn handle(self: *Self, gpa: Allocator, clients: *Queue(*Self), context: Context) !void {
            defer {
                self.stream.close();
                clients.put(&self.node);
            }

            while (true) {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();

                var stack_allocator = std.heap.stackFallback(max_buffer_size, arena.allocator());
                const stack_ally = stack_allocator.get();

                var body = std.ArrayList(u8).init(stack_ally);
                defer body.deinit();

                var response = Response{
                    .headers = resp.Headers.init(stack_ally),
                    .buffered_writer = std.io.bufferedWriter(self.stream.writer()),
                    .is_flushed = false,
                    .body = body.writer(),
                    .close = false,
                };

                var buffer: [max_request_size]u8 = undefined;
                const parsed_request = Request.parse(
                    stack_allocator.get(),
                    std.io.bufferedReader(self.stream.reader()).reader(),
                    &buffer,
                ) catch |err| switch (err) {
                    // not an error, client disconnected
                    error.EndOfStream, error.ConnectionResetByPeer => return,
                    error.HeadersTooLarge => return response.writeHeader(.request_header_fields_too_large),
                    else => return response.writeHeader(.bad_request),
                };

                // Default close to true if the client requests the connection to close or if the io_mode == blocking.
                response.close = parsed_request.context.connection_type == .close or !std.io.is_async;

                handler(context, &response, parsed_request) catch |err| {
                    try response.writeHeader(.internal_server_error);
                    return err;
                };

                if (!response.is_flushed) try response.flush(); // ensure data is flushed
                if (response.close) return; // close connection
            }
        }
    };
}

test "Basic server test" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const test_message = "Hello, Apple pie!";
    const address = try net.Address.parseIp("0.0.0.0", 8080);
    var server = Server.init();

    const server_thread = struct {
        var _addr: net.Address = undefined;

        fn index(ctx: void, response: *Response, request: Request) !void {
            _ = request;
            _ = ctx;
            try response.writer().writeAll(test_message);
        }
        fn runServer(context: *Server) !void {
            try context.run(alloc, _addr, {}, index);
        }
    };
    server_thread._addr = address;

    const thread = try std.Thread.spawn(.{}, server_thread.runServer, .{&server});
    errdefer server.shutdown();

    var stream = while (true) {
        var conn = net.tcpConnectToAddress(address) catch |err| switch (err) {
            error.ConnectionRefused => continue,
            else => return err,
        };

        break conn;
    } else unreachable;
    errdefer stream.close();
    // tell server to shutdown
    // fill finish current request and then shutdown
    server.shutdown();
    try stream.writer().writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var buf: [512]u8 = undefined;
    const len = try stream.reader().read(&buf);
    stream.close();
    thread.join();

    const index = std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") orelse return error.Unexpected;

    const answer = buf[index + 4 .. len];
    try std.testing.expectEqualStrings(test_message, answer);
}
