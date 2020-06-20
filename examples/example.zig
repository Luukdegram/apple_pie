const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

pub fn main() !void {
    var static = try http.StaticFileServer.init(std.heap.page_allocator, "src/");
    defer static.deinit();
    try http.server.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        http.StaticFileServer.handle,
    );
}

fn index(response: *http.Response, request: http.Request) !void {
    try response.write("Hello Zig!");
}
