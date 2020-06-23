const std = @import("std");
const http = @import("apple_pie");

pub fn main() !void {
    try http.server.listenAndServe(
        std.heap.page_allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        comptime MiniRouter(&[_]Route{
            .{
                .path = "/",
                .serveFn = index,
            },
        }),
    );
}

/// Very basic text-based response, it's up to implementation to set
/// the correct content type of the message
fn index(response: *http.Response, request: http.Request) !void {
    try response.write("Hello Zig!");
}

/// A very basic router that only checks for exact matches of a path
/// You will probably want to implement your own router
fn MiniRouter(comptime routes: []const Route) http.server.RequestHandler {
    std.debug.assert(routes.len > 0);

    return struct {
        fn serve(response: *http.Response, request: http.Request) callconv(.Async) !void {
            inline for (routes) |route| {
                if (std.mem.eql(u8, request.url.path, route.path)) {
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
