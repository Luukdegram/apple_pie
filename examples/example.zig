const std = @import("std");
const http = @import("apple_pie");

pub fn main() !void {
    try http.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        index,
    );
}

fn index(response: *http.Response, request: http.Request) callconv(.Async) void {
    response.write("Hello Zig!") catch {
        // do something with the error
    };
}
