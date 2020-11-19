const std = @import("std");
const http = @import("apple_pie");
const file_server = http.FileServer;

pub const pike_dispatch = http.dispatch;
pub const pike_batch = http.batch;
pub const pike_task = http.task;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    try file_server.init(allocator, .{ .dir_path = "src", .base_path = "fs" });
    defer file_server.deinit();

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        file_server.serve,
    );
}
