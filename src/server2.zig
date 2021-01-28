const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const net = std.net;
const os = std.os;
const log = std.log.scope(.apple_pie);
const Response = resp.Response;
const Request = resp.Request;
const Allocator = std.mem.Allocator;

/// User API function signature of a request handler
pub const RequestHandler = fn handle(*Response, Request) anyerror!void;

pub fn listenAndServe(gpa: *Allocator, address: net.Address, comptime handler: RequestHandler) !void {
    var stream = net.StreamServer.init(.{ .reuse_address = true });
    defer stream.deinit();

    var clients = Clients.init();

    try stream.listen(address);

    while (true) {
        var connection = stream.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };

        const client = try Client.init(gpa, connection.stream);
        async client.run(clients, handler);
    }
}

/// Alias for an atomic queue of Clients
const Clients = std.atomic.Queue(*Client);

const Client = struct {
    stream: net.Stream,
    node: Clients.Node,
    gpa: *Allocator,

    fn init(gpa: *Allocator, stream: net.Stream) !*Client {
        const client = try gpa.create(Client);
        var node = Clients.Node{ .data = client };
        client.* = .{
            .stream = stream,
            .node = node,
            .gpa = gpa,
        };
        return client;
    }

    fn run(self: *Client, clients: Clients, comptime handler: RequestHandler) !void {
        defer clients.put(&self.node);

        while (true) {
            var buf: [100]u8 = undefined;
            self.stream.reader().read(&buf);

            var response = Response{
                resp.Headers.init(self.gpa),
            };
            defer response.headers.deinit();
        }
    }
};
