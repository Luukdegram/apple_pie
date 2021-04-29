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
pub const RequestHandler = fn handle(*Response, Request) anyerror!void;

/// Allows users to set the max buffer size before we allocate memory on the heap to store our data
const max_buffer_size: usize = if (@hasDecl(root, "buffer_size")) root.buffer_size else 4096;
/// Allows users to set the max request header buffer size before we return error.RequestTooLarge.
const max_request_size: usize = if (@hasDecl(root, "request_buffer_size")) root.request_buffer_size else 4096;

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
    gpa: *Allocator,
    /// Address the server is listening at
    address: net.Address,
    /// User defined `Request`/`Response` handler
    comptime handler: RequestHandler,
) !void {
    try (Server.init()).run(gpa, address, handler);
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
        gpa: *Allocator,
        /// Address the server is listening at
        address: net.Address,
        /// User defined `Request`/`Response` handler
        comptime handler: RequestHandler,
    ) !void {
        var stream = net.StreamServer.init(.{ .reuse_address = true });
        defer stream.deinit();

        // client queue to clean up clients after connection is broken/finished
        const Client = ClientFn(handler);
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
                .frame = async client.run(gpa, &clients),
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
fn ClientFn(comptime handler: RequestHandler) type {
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
        fn run(self: *Self, gpa: *Allocator, clients: *Queue(*Self)) void {
            self.handle(gpa, clients) catch |err| {
                log.err("An error occured handling request: '{s}'", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
        }

        fn handle(self: *Self, gpa: *Allocator, clients: *Queue(*Self)) !void {
            defer {
                self.stream.close();
                clients.put(&self.node);
            }

            while (true) {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();

                var stack_allocator = std.heap.stackFallback(max_buffer_size, &arena.allocator);

                var body = std.ArrayList(u8).init(gpa);
                defer body.deinit();

                var response = Response{
                    .headers = resp.Headers.init(stack_allocator.get()),
                    .buffered_writer = std.io.bufferedWriter(self.stream.writer()),
                    .is_flushed = false,
                    .body = body.writer(),
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

                try handler(&response, parsed_request);

                if (parsed_request.protocol == .http_1_1 and parsed_request.host == null) {
                    return response.writeHeader(.bad_request);
                }

                if (!response.is_flushed) try response.flush(); // ensure data is flushed
                if (parsed_request.should_close) return; // close connection
                if (!std.io.is_async) return; // io_mode = blocking
            }
        }
    };
}

test "Basic server test" {
    if (std.builtin.single_threaded) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const test_message = "Hello, Apple pie!";
    const address = try net.Address.parseIp("0.0.0.0", 8080);
    var server = Server.init();

    const server_thread = struct {
        var _addr: net.Address = undefined;

        fn index(response: *Response, request: Request) !void {
            try response.writer().writeAll(test_message);
        }
        fn runServer(context: *Server) !void {
            try context.run(alloc, _addr, index);
        }
    };
    server_thread._addr = address;

    const thread = try std.Thread.spawn(server_thread.runServer, &server);
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
    thread.wait();

    const index = std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") orelse return error.Unexpected;

    const answer = buf[index + 4 .. len];
    std.testing.expectEqualStrings(test_message, answer);
}
