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
        try std.net.Address.parseIp("127.0.0.1", 8080),
        index,
    );
}

// Go to "localhost:8080?name=<your_name>"
fn index(response: *http.Response, request: http.Request) !void {
    try response.headers.put("Content-Type", "text/html");
    const html = @embedFile("index.html");
    const template = http.Template(html);

    // for demo purposes, just use page allocator
    const allocator = std.heap.page_allocator;
    var query = try request.url.queryParameters(allocator);
    defer query.deinit();

    const name = query.get("name") orelse "Zig";

    try template.write(
        struct {
            title: []const u8, name: []const u8
        },
        .{ .title = "Apple Pie", .name = name },
        response.writer(),
    );
}
