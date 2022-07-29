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
        handler: Handler,
        /// http method
        method: Request.Method,

        const Handler = fn handle(Context, *Response, Request, params: []const Entry) anyerror!void;
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

/// Will automatically convert router captures to function parameter types
pub fn wrap(comptime Context: type, comptime handler: anytype) Route(Context).Handler {
    const info = @typeInfo(@TypeOf(handler));
    if (info != .Fn)
        @compileError("router.wrap expects a function type");

    const function_info = info.Fn;
    if (function_info.is_generic)
        @compileError("Cannot create handler wrapper for generic function");
    if (function_info.is_var_args)
        @compileError("Cannot create handler wrapper for variadic function");

    assertIsType("Expected first argument of handler to be", Context, function_info.args[0].arg_type.?);
    assertIsType("Expected first argument of handler to be", *Response, function_info.args[1].arg_type.?);
    assertIsType("Expected first argument of handler to be", Request, function_info.args[2].arg_type.?);

    const capture_args_info = function_info.args[3..];
    var capture_arg_types: [capture_args_info.len]type = undefined;
    for (capture_args_info) |arg, i| {
        capture_arg_types[i] = arg.arg_type.?;
    }
    const CaptureArgs = std.meta.Tuple(&capture_arg_types);

    const X = struct {
        fn wrapper(ctx: Context, res: *Response, req: Request, params: []const trie.Entry) anyerror!void {
            var capture_args: CaptureArgs = undefined;

            std.debug.assert(params.len == capture_args.len); // Number of captures must equal the number of extra parameters in the Handler function

            if (capture_args.len == 0) return handler(ctx, res, req);

            comptime var arg_index = 0;
            inline while (arg_index < capture_args.len) : (arg_index += 1) {
                capture_args[arg_index] = switch (@TypeOf(capture_args[arg_index])) {
                    []const u8 => params[arg_index].value,
                    //?[]const u8 => if (params.len > 0) params[0].value else null,
                    else => |ArgType| switch (@typeInfo(ArgType)) {
                        .Int => std.fmt.parseInt(ArgType, params[arg_index].value, 10) catch {
                            return res.notFound();
                        },
                        .Optional => |child| if (@typeInfo(child) == .Int)
                            std.fmt.parseInt(ArgType, params[arg_index].value, 10) catch null
                        else
                            @compileError("Unsupported optional type " ++ @typeName(child)),
                        else => @compileError("Unsupported type " ++ @typeName(ArgType)),
                    },
                };
            }

            return @call(.{}, handler, .{ ctx, res, req } ++ capture_args);
        }
    };

    return X.wrapper;
}

fn assertIsType(comptime text: []const u8, expected: type, actual: type) void {
    if (actual != expected)
        @compileError(text ++ " " ++ @typeName(expected) ++ ", but found type " ++ @typeName(actual) ++ " instead");
}

/// Creates a builder namespace, generic over the given `Context`
/// This makes it easy to create the routers without having to passing
/// a lot of the types.
pub fn Builder(comptime Context: type) type {
    return struct {
        const Handler = Route(Context).Handler;

        pub fn get(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .get,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn post(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .post,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn patch(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .patch,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn put(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .put,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn any(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .any,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn head(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .head,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn delete(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .delete,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn connect(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .connect,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn options(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .options,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        pub fn trace(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return Route(Context){
                .method = .trace,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
