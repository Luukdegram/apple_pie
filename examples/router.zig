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
                .path = "/files/*",
                .handler = serveFs,
            },
            .{
                .path = "/hello/:name",
                .handler = hello,
            },
            .{
                .path = "/posts/:post/messages/:message",
                .handler = messages,
            },
        }),
    );
}

/// Very basic text-based response, it's up to implementation to set
/// the correct content type of the message
fn index(response: *http.Response, request: http.Request) !void {
    try response.writer().writeAll("Hello Zig!");
}

fn hello(resp: *http.Response, req: http.Request, name: []const u8) !void {
    try resp.writer().print("Hello {}\n", .{name});
}

fn serveFs(resp: *http.Response, req: http.Request) !void {
    return fs.serve(resp, req);
}

fn messages(resp: *http.Response, req: http.Request, args: struct {
    post: usize,
    message: []const u8,
}) !void {
    try resp.writer().print("Post nr.{}, message '{}'\n", .{
        args.post,
        args.message,
    });
}
