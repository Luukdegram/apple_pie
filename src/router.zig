//! Comptime Trie based router that creates a Trie
//! for each HTTP method and a catch-all one that works
//! on any method, granted it has a handler defined.
//! The router parses params into a type defined as the 3rd
//! argument of the handler function. Any other argument is ignored for parsing.
//! multi-params require a struct as argument type.

const std = @import("std");
const trie = @import("trie.zig");
const Request = @import("Request.zig");
const Response = @import("response.zig").Response;
const RequestHandler = @import("server.zig").RequestHandler;

pub const Entry = trie.Entry;

/// Route defines the path, method and how to parse such path
/// into a type that the handler can accept.
pub fn Route(comptime Context: type) type {
    return struct {
        /// Path by which the route is triggered
        path: []const u8,
        /// The handler function that will be called when triggered
        handler: fn handle(Context, *Response, Request, params: []const Entry) anyerror!void,
        /// http method
        method: Request.Method,
    };
}

/// Generic function that inserts each route's path into a radix tree
/// to retrieve the right route when a request has been made
pub fn Router(comptime Context: type, comptime routes: []const Route(Context)) RequestHandler(Context) {
    comptime var trees: [10]trie.Trie(u8) = undefined;
    inline for (trees) |*t| t.* = trie.Trie(u8){};

    inline for (routes) |r, i| {
        if (@typeInfo(@TypeOf(r.handler)) != .Fn) @compileError("Handler must be a function");

        const args = @typeInfo(@TypeOf(r.handler)).Fn.args;

        if (args.len < 3) {
            @compileError("Handler must have atleast 3 arguments");
        }
        if (args[0].arg_type.? != Context) {
            @compileError("Expected type '" ++ @typeName(Context) ++ "', but found type '" ++ @typeName(args[0].arg_type.?) ++ "'");
        }
        if (args[1].arg_type.? != *Response) {
            @compileError("Second parameter must be of type " ++ @typeName(*Response));
        }
        if (args[2].arg_type.? != Request) {
            @compileError("Third parameter must be of type " ++ @typeName(Request));
        }

        trees[@enumToInt(r.method)].insert(r.path, i);
    }

    return struct {
        const Self = @This();

        pub fn serve(context: Context, response: *Response, request: Request) !void {
            switch (trees[@enumToInt(request.method())].get(request.path())) {
                .none => {
                    // if nothing was found for current method, try the wildcard
                    switch (trees[9].get(request.path())) {
                        .none => return response.notFound(),
                        .static => |index| {
                            inline for (routes) |route, i|
                                if (index == i) return route.handler(context, response, request, &.{});
                        },
                        .with_params => |object| {
                            inline for (routes) |route, i| {
                                if (object.data == i)
                                    return route.handler(context, response, request, object.params[0..object.param_count]);
                            }
                        },
                    }
                },
                .static => |index| {
                    inline for (routes) |route, i| {
                        if (index == i) return route.handler(context, response, request, &.{});
                    }
                },
                .with_params => |object| {
                    inline for (routes) |route, i| {
                        if (object.data == i)
                            return route.handler(context, response, request, object.params[0..object.param_count]);
                    }
                },
            }
        }
    }.serve;
}

test {
    std.testing.refAllDecls(@This());
}
