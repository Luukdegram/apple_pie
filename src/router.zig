const std = @import("std");
const RadixTree = @import("radix.zig").RadixTree;
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
    handler: RouteHandler,
};

/// Used by `Router` to parse the `path` of a `Route` and calculate
/// its captures
const InternalRoute = struct {
    actual: Route,
    capture_names: []const []const u8,
    captures: u8,
};

/// Generic function that inserts each route's path into a radix tree
/// to retrieve the right route when a request has been made
pub fn router(comptime routes: []const Route) HandlerFn {
    var radix = RadixTree(usize){};
    var inner_routes: [routes.len]InternalRoute = undefined;
    const State = enum {
        start,
        cap_start,
        cap_end,
    };

    inline for (routes) |r, i| {
        var state = State.start;
        var index: usize = 0;
        var first_capture_index: usize = 0;
        var cap_names: []const []const u8 = &[_][]const u8{};
        var i_route = InternalRoute{
            .actual = r,
            .captures = 0,
            .capture_names = &[_][]const u8{},
        };

        for (r.path) |c, i_c| {
            switch (state) {
                .start => {
                    if (c == '{') {
                        state = .cap_start;
                        i_route.captures += 1;
                        index = i_c + 1;
                        first_capture_index = i;
                    }
                },
                .cap_start => {
                    if (c == '}') {
                        state = .cap_end;
                        cap_names = (cap_names ++ &[_][]const u8{r.path[index..i_c]});
                        state = .cap_end;
                    }
                },
                .cap_end => {
                    if (c == '{') {
                        state = .cap_start;
                        i_route.captures += 1;
                        index = i_c + 1;
                    }
                },
            }
        }

        i_route.capture_names = cap_names;
        inner_routes[i] = i_route;
        const path = if (first_capture_index != 0) r.path[0..first_capture_index] else r.path;
        _ = radix.insert(path, i);
    }
    return struct {
        fn serve(response: *Response, request: Request) !void {
            if (radix.getLongestPrefix(request.url.path)) |index| inline for (inner_routes) |route, i| {
                if (index == i) {
                    try route.actual.handler(response, request, .{});
                    return;
                }
            } else
                return notFound(response, request);
        }
    }.serve;
}

/// Returns a 404 message
fn notFound(response: *Response, request: Request) !void {
    try response.notFound();
}
