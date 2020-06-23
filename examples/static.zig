const std = @import("std");
const http = @import("apple_pie");
const file_server = http.file_server;

pub const io_mode = .evented;

pub fn main() !void {
    try file_server.init("src/", std.heap.page_allocator);
    defer file_server.deinit();

    try http.server.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        file_server.serve,
    );
}
