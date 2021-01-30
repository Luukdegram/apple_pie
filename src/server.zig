const std = @import("std");
const root = @import("root");
const req = @import("request.zig");
const resp = @import("response.zig");
const net = std.net;
const os = std.os;
const log = std.log.scoped(.apple_pie);
const Response = resp.Response;
const Request = req.Request;
const Allocator = std.mem.Allocator;
const Queue = std.atomic.Queue;

/// User API function signature of a request handler
pub const RequestHandler = fn handle(*Response, Request) anyerror!void;

/// Allows users to set the max buffer size before we allocate memory on the heap to store our data
const max_buffer_size: usize = if (@hasField(root, "buffer_size")) root.buffer_size else 4096;

pub fn listenAndServe(
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

    try stream.listen(address);

    while (true) {
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
            data.stream.close();
            gpa.destroy(data);
        }
    }
}

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
            };
        }

        fn handle(self: *Self, gpa: *Allocator, clients: *Queue(*Self)) !void {
            defer clients.put(&self.node);

            while (true) {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();

                var stack_allocator = std.heap.stackFallback(max_buffer_size, &arena.allocator);

                const parsed_request = req.parse(
                    stack_allocator.get(),
                    self.stream.reader(),
                ) catch |err| switch (err) {
                    // not an error, client disconnected
                    error.EndOfStream, error.ConnectionResetByPeer => return,
                    else => return err,
                };

                var body = std.ArrayList(u8).init(stack_allocator.get());
                defer body.deinit();

                var response = Response{
                    .headers = resp.Headers.init(stack_allocator.get()),
                    .socket_writer = std.io.bufferedWriter(self.stream.writer()),
                    .is_flushed = false,
                    .body = body.writer(),
                };
                defer response.headers.deinit();

                try handler(&response, parsed_request);

                if (parsed_request.protocol == .http1_1 and parsed_request.host == null) {
                    return response.writeHeader(.bad_request);
                }

                if (!response.is_flushed) try response.flush();

                if (parsed_request.should_close) return; // close connection
            }
        }
    };
}
