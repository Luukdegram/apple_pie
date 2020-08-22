const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try http.server.listenAndServe(
        &gpa.allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        index,
    );
}

fn index(response: *http.Response, request: http.Request) !void {
    try response.write("Hello Zig!");
}
