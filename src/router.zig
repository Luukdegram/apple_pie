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

/// Contains a path and a handler function that
pub const Route = struct {
    /// Path by which the route is triggered
    path: []const u8,
    /// The handler function that will be called when triggered
    handler: anytype,
    /// http method
    method: Request.Method,
};

/// Generic function that inserts each route's path into a radix tree
/// to retrieve the right route when a request has been made
pub fn router(comptime routes: []const Route) RequestHandler {
    comptime var trees: [10]trie.Trie(u8) = undefined;
    inline for (trees) |*t| t.* = trie.Trie(u8){};

    inline for (routes) |r, i| {
        if (@typeInfo(@TypeOf(r.handler)) != .Fn) @compileError("Handler must be a function");

        const args = @typeInfo(@TypeOf(r.handler)).Fn.args;

        if (args.len < 2) @compileError("Handler must have atleast 2 arguments");
        if (args[0].arg_type.? != *Response) @compileError("First parameter must be of type " ++ @typeName(*Response));
        if (args[1].arg_type.? != Request) @compileError("Second parameter must be of type " ++ @typeName(Request));

        trees[@enumToInt(r.method)].insert(r.path, i);
    }

    return struct {
        fn handle(comptime route: Route, params: []const trie.Entry, res: *Response, req: Request) !void {
            const Fn = @typeInfo(@TypeOf(route.handler)).Fn;
            const args = Fn.args;
            if (args.len == 2) return route.handler(res, req);

            comptime const ArgType = args[2].arg_type orelse return route.handler(res, req, {});

            const param: ArgType = switch (ArgType) {
                []const u8 => if (params.len > 0) params[0].value else &[_]u8{},
                ?[]const u8 => if (params.len > 0) params[0].value else null,
                else => switch (@typeInfo(ArgType)) {
                    .Struct => |info| blk: {
                        var new_struct: ArgType = undefined;
                        inline for (info.fields) |field| {
                            for (params) |p| {
                                if (std.mem.eql(u8, field.name, p.key)) {
                                    const FieldType = @TypeOf(@field(new_struct, field.name));

                                    @field(new_struct, field.name) = switch (FieldType) {
                                        []const u8, ?[]const u8 => p.value,
                                        else => switch (@typeInfo(FieldType)) {
                                            .Int => std.fmt.parseInt(FieldType, p.value, 10) catch 0,
                                            .Optional => |child| if (@typeInfo(child) == .Int)
                                                std.fmt.parseInt(FieldType, p.value, 10) catch null
                                            else
                                                @compileError("Unsupported optional type " ++ @typeName(child)),
                                            else => @compileError("Unsupported type " ++ @typeName(FieldType)),
                                        },
                                    };
                                }
                            }
                        }
                        break :blk new_struct;
                    },
                    .Int => std.fmt.parseInt(ArgType, params[0].value, 10) catch 0,
                    .Optional => |child| if (@typeInfo(child) == .Int)
                        std.fmt.parseInt(ArgType, params[0].value, 10) catch null
                    else
                        @compileError("Unsupported optional type " ++ @typeName(child)),
                    else => @compileError("Unsupported type " ++ @typeName(ArgType)),
                },
            };
            return route.handler(res, req, param);
        }

        fn serve(response: *Response, request: Request) !void {
            switch (trees[@enumToInt(request.method())].get(request.path())) {
                .none => {
                    // if nothing was found for current method, try the wildcard
                    switch (trees[9].get(request.path())) {
                        .none => return response.notFound(),
                        .static => |index| {
                            inline for (routes) |route, i|
                                if (index == i) return handle(route, &.{}, response, request);
                        },
                        .with_params => |object| {
                            inline for (routes) |route, i| {
                                if (object.data == i)
                                    return handle(route, object.params[0..object.param_count], response, request);
                            }
                        },
                    }
                },
                .static => |index| {
                    inline for (routes) |route, i| {
                        if (index == i) return handle(route, &.{}, response, request);
                    }
                },
                .with_params => |object| {
                    inline for (routes) |route, i| {
                        if (object.data == i)
                            return handle(route, object.params[0..object.param_count], response, request);
                    }
                },
            }
        }
    }.serve;
}

/// Creates a new `Route` for the given HTTP Method that will be
/// triggered based on its path conditions
/// the `handler` function must have atleast 2 arguments where
/// @TypeOf(arg[0]) == *Response
/// @TypeOf(arg[1]) == Request
///
/// It's allowed to provide a 3rd argument if path contains parameters such as ':<name>'
/// The caught parameters will be parsed into the type of the argument
pub fn handle(
    comptime method: Request.Method,
    comptime path: []const u8,
    comptime handler: anytype,
) Route {
    return Route{
        .path = path,
        .handler = handler,
        .method = method,
    };
}

/// Shorthand function to create a `Route` where method is 'GET'
pub fn get(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.get, path, handler);
}

/// Shorthand function to create a `Route` where method is 'POST'
pub fn post(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.post, path, handler);
}

/// Shorthand function to create a `Route` where method is 'PATCH'
pub fn patch(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.patch, path, handler);
}

/// Shorthand function to create a `Route` where method is 'PUT'
pub fn put(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.put, path, handler);
}

/// Shorthand function to create a `Route` where method is 'HEAD'
pub fn head(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.head, path, handler);
}

/// Shorthand function to create a `Route` where method is 'DELETE'
pub fn delete(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.delete, path, handler);
}

/// Shorthand function to create a `Route` where method is 'CONNECT'
pub fn connect(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.connect, path, handler);
}

/// Shorthand function to create a `Route` where method is 'OPTIONS'
pub fn options(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.options, path, handler);
}

/// Shorthand function to create a `Route` where method is 'TRACE'
pub fn trace(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.trace, path, handler);
}

/// Shorthand function to create a `Route` which will be matched to any
/// request method. It is still recommended to use the other specific methods
pub fn any(comptime path: []const u8, comptime handler: anytype) Route {
    return handle(.any, path, handler);
}
