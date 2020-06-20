const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

pub fn main() !void {
    http.server.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        index,
    ) catch |err| {
        std.debug.print("Error: {}\n", .{err});
    };
}

fn index(response: *http.Response, request: http.Request) !void {
    try response.write("Hello Zig!");
}
