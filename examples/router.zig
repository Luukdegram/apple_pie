const std = @import("std");
const http = @import("apple_pie");
const fs = http.FileServer;
const router = http.router;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    try fs.init(allocator, .{ .dir_path = "src", .base_path = "fs" });
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
                .handler = fs.serve,
            },
        }),
    );
}

/// Very basic text-based response, it's up to implementation to set
/// the correct content type of the message
fn index(response: *http.Response, request: http.Request) !void {
    try response.writer().writeAll("Hello Zig!");
}

/// A very basic router that only checks for exact matches of a path
/// You will probably want to implement your own router
fn MiniRouter(comptime routes: []const Route) http.server.RequestHandler {
    std.debug.assert(routes.len > 0);

    return struct {
        fn serve(response: *http.Response, request: http.Request) callconv(.Async) !void {
            inline for (routes) |route| {
                if (std.mem.startsWith(u8, request.url.path, route.path)) {
                    return route.serveFn(response, request);
                }
            }
        }
    }.serve;
}

const Route = struct {
    path: []const u8,
    serveFn: http.server.RequestHandler,

    fn init(path: []const u8, serveFn: http.server.RequestHandler) Route {
        return Route{
            .path = path,
            .serveFn = serveFn,
        };
    }
};
