const std = @import("std");
const http = @import("apple_pie");

pub fn main() !void {
    try http.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        http.Handler(serve),
    );
}

pub fn serve(response: http.Response, request: http.Request) void {
    std.debug.warn("Request path: {}\n", .{request.url.path});
}
