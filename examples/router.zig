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

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        comptime router.router(&.{
            router.get("/", index),
            router.get("/headers", headers),
            router.get("/files/*", serveFs),
            router.get("/hello/:name", hello),
            router.get("/posts/:post/messages/:message", messages),
        }),
    );
}

/// Very basic text-based response, it's up to implementation to set
/// the correct content type of the message
fn index(response: *http.Response, request: http.Request) !void {
    _ = request;
    try response.writer().writeAll("Hello Zig!\n");
}

fn headers(response: *http.Response, request: http.Request) !void {
    try response.writer().print("Path: {s}\n", .{request.path()});
    var it = request.iterator();
    while (it.next()) |header| {
        try response.writer().print("{s}: {s}\n", .{ header.key, header.value });
    }
}

/// Shows "Hello {name}" where {name} is /hello/:name
fn hello(resp: *http.Response, req: http.Request, name: []const u8) !void {
    _ = req;
    try resp.writer().print("Hello {s}\n", .{name});
}

/// Serves a file
fn serveFs(resp: *http.Response, req: http.Request) !void {
    try fs.serve(resp, req);
}

/// Shows the post number and message text
fn messages(resp: *http.Response, req: http.Request, args: struct {
    post: usize,
    message: []const u8,
}) !void {
    _ = req;
    try resp.writer().print("Post {d}, message: '{s}'\n", .{
        args.post,
        args.message,
    });
}
