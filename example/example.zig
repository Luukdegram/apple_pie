const std = @import("std");
const http = @import("apple_pie");

pub fn main() !void {
    const default = DefaultHandler{};
    try http.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        default.handle(),
    );
}

const DefaultHandler = struct {
    fn serve(self: @This(), response: *http.Response, request: http.Request) void {
        std.debug.warn("path: {}\n", .{request.url.path});
        response.write("Hello world, from Zig!") catch {
            std.debug.warn("Couldn't write to stream", .{});
        };
    }

    fn handle(self: @This()) http.Handler(DefaultHandler, serve) {
        return .{ .context = self };
    }
};
