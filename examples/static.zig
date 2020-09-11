const std = @import("std");
const http = @import("apple_pie");
const file_server = http.FileServer;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    try file_server.init(allocator, .{ .dir_path = "src", .base_path = "fs" });
    defer file_server.deinit();

    try http.server.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        file_server.serve,
    );
}
