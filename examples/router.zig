const std = @import("std");
const http = @import("apple_pie");
const fs = http.FileServer;
const router = http.router;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    try fs.init(allocator, .{ .dir_path = "src", .base_path = "files" });
    defer fs.deinit();

    try http.server.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        comptime router.router(&[_]router.Route{
            .{
                .path = "/",
                .handler = index,
            },
            .{
                .path = "/files",
                .handler = serveFs,
            },
            .{
                .path = "/hello/{id}",
                .handler = hello,
            },
        }),
    );
}

/// Very basic text-based response, it's up to implementation to set
/// the correct content type of the message
fn index(response: *http.Response, request: http.Request, captures: anytype) !void {
    try response.writer().writeAll("Hello Zig!");
}

fn hello(resp: *http.Response, req: http.Request, captures: anytype) !void {
    const name = if (captures.len > 0) captures[0] else "world";
    try resp.writer().print("Hello {}\n", .{name});
}

fn serveFs(resp: *http.Response, req: http.Request, captures: anytype) !void {
    return fs.serve(resp, req);
}
