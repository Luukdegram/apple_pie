const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counter: usize = 0;

    try http.listenAndServe(
        &gpa.allocator,
        try std.net.Address.parseIp("0.0.0.0", 8080),
        &counter,
        index,
    );
}

fn index(context: *usize, response: *http.Response, request: http.Request) !void {
    _ = request;
    try response.writer().writeAll("Hello Zig!\n");
    try response.writer().print("Counter: {d}\n", .{context.*});
    context.* = context.* + 1;
}
