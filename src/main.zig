const std = @import("std");
const request = @import("request.zig");
const testing = std.testing;
const net = std.net;
const Allocator = std.mem.Allocator;
pub const Request = request.Request;

pub const Response = struct {};

pub fn listenAndServe(
    allocator: *Allocator,
    address: net.Address,
    handler: var,
) !void {
    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(address);

    while (true) {
        var connection: net.StreamServer.Connection = try server.accept();
        var buffer: [1000]u8 = undefined;
        //_ = try connection.file.read(&buffer);
        try connection.file.writeAll(
            \\HTTP/1.1 200 OK
            \\Host: localhost:8080
            \\
            \\Hello World
        );
        const req = try request.parse(allocator, connection.file.inStream());
        connection.file.close();
    }
}

pub fn Handler(
    comptime serveFn: fn (
        response: Response,
        request: Request,
    ) void,
) type {
    return struct {
        pub fn serve(response: Response, request: Request) void {
            return serveFn(response, request);
        }
    };
}
