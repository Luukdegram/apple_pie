const std = @import("std");
const http = @import("apple_pie");

pub const pike_dispatch = http.dispatch;
pub const pike_batch = http.batch;
pub const pike_task = http.task;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try http.listenAndServe(
        &gpa.allocator,
        try std.net.Address.parseIp("0.0.0.0", 8080),
        index,
    );
}

fn index(response: *http.Response, request: http.Request) !void {
    try response.writer().writeAll("Hello Zig!");
}
