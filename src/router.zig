const std = @import("std");
const trie = @import("trie.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const HandlerFn = @import("server.zig").RequestHandler;

/// Route handler which contains the response, request and possible captures
pub const RouteHandler = fn (*Response, Request, anytype) anyerror!void;

/// Contains a path and a handler function that
pub const Route = struct {
    /// Path by which the route is triggered
    path: []const u8,
    /// The handler function that will be called when triggered
    handler: anytype,
};

/// Generic function that inserts each route's path into a radix tree
/// to retrieve the right route when a request has been made
pub fn router(comptime routes: []const Route) HandlerFn {
    var tree = trie.Trie(usize){};

    inline for (routes) |r, i| {
        tree.insert(r.path, i);
    }

    return struct {
        fn handle(
            comptime route: Route,
            params: []const trie.Entry,
            res: *Response,
            req: Request,
        ) !void {
            const Fn = @typeInfo(@TypeOf(route.handler)).Fn;
            const args = Fn.args;

            const arg_type = @TypeOf(args[2].arg_type);
            return route.handler(res, req, 1);
        }

        fn serve(response: *Response, request: Request) !void {
            switch (tree.get(request.url.path)) {
                .none => return notFound(response, request),
                .static => |index| {
                    inline for (routes) |route, i| {
                        if (index == i) return handle(route, &[_]trie.Entry{}, response, request);
                    }
                },
                .with_params => |object| {
                    inline for (routes) |route, i| {
                        if (object.data == i) {
                            return handle(route, object.params[0..object.param_count], response, request);
                        }
                    }
                },
            }
        }
    }.serve;
}

/// Returns a 404 message
fn notFound(response: *Response, request: Request) !void {
    try response.notFound();
}
