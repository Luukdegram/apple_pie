const std = @import("std");
const http = @import("apple_pie");
const fs = http.FileServer;
const router = http.router;

pub const io_mode = .evented;

const Context = struct {
    last_route: ?[]const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try fs.init(allocator, .{ .dir_path = "src", .base_path = "files" });
    defer fs.deinit();

    var context: Context = .{ .last_route = null };
    const builder = router.Builder(*Context);

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        &context,
        comptime router.Router(*Context, &.{
            builder.get("/", null, index),
            builder.get("/headers", null, headers),
            builder.get("/files/*", null, serveFs),
            builder.get("/hello/:name", []const u8, hello),
            builder.get("/route", null, route),
            builder.get("/posts/:post/messages/:message", struct {
                post: []const u8,
                message: []const u8,
            }, messages),
        }),
    );
}

/// Very basic text-based response, it's up to implementation to set
/// the correct content type of the message
fn index(ctx: *Context, response: *http.Response, request: http.Request, captures: ?*const anyopaque) !void {
    std.debug.assert(captures == null);
    _ = request;
    ctx.last_route = "Index";
    try response.writer().writeAll("Hello Zig!\n");
}

fn route(ctx: *Context, resp: *http.Response, request: http.Request, captures: ?*const anyopaque) !void {
    std.debug.assert(captures == null);
    _ = request;
    defer ctx.last_route = null;

    if (ctx.last_route) |last_route| {
        try resp.writer().print("Last route: {s}\n", .{last_route});
    } else {
        try resp.writer().writeAll("The index route hasn't been visited yet\n");
    }
}

fn headers(ctx: *Context, response: *http.Response, request: http.Request, captures: ?*const anyopaque) !void {
    std.debug.assert(captures == null);
    _ = ctx;
    try response.writer().print("Path: {s}\n", .{request.path()});
    var it = request.iterator();
    while (it.next()) |header| {
        try response.writer().print("{s}: {s}\n", .{ header.key, header.value });
    }
}

/// Shows "Hello {name}" where {name} is /hello/:name
fn hello(ctx: *Context, resp: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    _ = req;
    _ = ctx;
    const name = @ptrCast(
        *const []const u8,
        @alignCast(
            @alignOf(*const []const u8),
            captures,
        ),
    );
    try resp.writer().print("Hello {s}\n", .{name.*});
}

/// Serves a file
fn serveFs(ctx: *Context, resp: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    std.debug.assert(captures == null);
    _ = ctx;
    try fs.serve({}, resp, req);
}

/// Shows the post number and message text
fn messages(ctx: *Context, resp: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    _ = ctx;
    _ = req;
    const Args = struct { post: usize, message: []const u8 };
    const args = @ptrCast(*const Args, @alignCast(@alignOf(*const Args), captures));
    try resp.writer().print("Post {d}, message: '{s}'\n", .{
        args.post,
        args.message,
    });
}
