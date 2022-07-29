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

/// Will automatically convert router captures from a list of key-values pairs (`[]Entry`) to one of the following:
///
/// - nothing, if the `handler` function has only 3 arguments (`fn(Context, *Resposne, Request)`)
/// - a single string, if the `handler` function looks like `fn(Context, *Resposne, Request, []const u8)`
/// - a struct where:
///   - each field is a `[]const u8`
///   - each field name is one of the parameters in Route `path`
///
/// For example, to capture a multiple parameters:
///
/// ```zig
/// const messagesWrapped = wrap(void, messages);
/// // Path is "/posts/:post/messages/:message"
/// fn messages(_: void, res: *http.Response, _: http.Request, captures: struct { post: []const u8, message: []const u8 }) !void {
///     const post = std.fmt.parseInt(usize, captures.post, 10) catch return resp.notFound();
///     try res.writer().print("Post {d}, message: '{s}'\n", .{ post, captures.message });
/// }
/// ```
pub fn wrap(comptime Context: type, comptime handler: anytype) Route(Context).Handler {
    const info = @typeInfo(@TypeOf(handler));
    if (info != .Fn)
        @compileError("router.wrap expects a function type");

    const function_info = info.Fn;
    if (function_info.is_generic)
        @compileError("Cannot create handler wrapper for generic function");
    if (function_info.is_var_args)
        @compileError("Cannot create handler wrapper for variadic function");

    if (function_info.args.len < 3)
        @compileError("Expected at least 3 args in Handler function; (" ++ @typeName(Context) ++ ", " ++ @typeName(*Response) ++ ", " ++ @typeName(Request) ++ ")]");

    assertIsType("Expected first argument of handler to be", Context, function_info.args[0].arg_type.?);
    assertIsType("Expected second argument of handler to be", *Response, function_info.args[1].arg_type.?);
    assertIsType("Expected third argument of handler to be", Request, function_info.args[2].arg_type.?);

    if (function_info.args.len < 4) {
        // There is no 4th parameter, we can just ignore `params`
        const X = struct {
            fn wrapped(ctx: Context, res: *Response, req: Request, params: []const trie.Entry) anyerror!void {
                std.debug.assert(params.len == 0);
                return handler(ctx, res, req);
            }
        };
        return X.wrapped;
    }

    const ArgType = function_info.args[3].arg_type.?;

    if (ArgType == []const u8) {
        // There 4th parameter is a string
        const X = struct {
            fn wrapped(ctx: Context, res: *Response, req: Request, params: []const trie.Entry) anyerror!void {
                std.debug.assert(params.len == 1);
                return handler(ctx, res, req, params[0].value);
            }
        };
        return X.wrapped;
    }

    if (@typeInfo(ArgType) == .Struct) {
        // There 4th parameter is a struct
        const X = struct {
            fn wrapped(ctx: Context, res: *Response, req: Request, params: []const trie.Entry) anyerror!void {
                const CaptureStruct = function_info.args[3].arg_type.?;
                var captures: CaptureStruct = undefined;

                std.debug.assert(params.len == @typeInfo(CaptureStruct).Struct.fields.len);

                for (params) |param| {
                    // Using a variable here instead of something like `continue :params_loop` because that causes the compiler to crash with exit code 11.
                    var matched_a_field = false;
                    inline for (@typeInfo(CaptureStruct).Struct.fields) |field| {
                        assertIsType("Expected field " ++ field.name ++ " of " ++ @typeName(CaptureStruct) ++ " to be", []const u8, field.field_type);
                        if (std.mem.eql(u8, param.key, field.name)) {
                            @field(captures, field.name) = param.value;
                            matched_a_field = true;
                        }
                    }
                    if (!matched_a_field)
                        std.debug.panic("Unexpected capture \"{}\", no such field in {s}", .{ std.zig.fmtEscapes(param.key), @typeName(CaptureStruct) });
                }

                return handler(ctx, res, req, captures);
            }
        };
        return X.wrapped;
    }

    @compileError("Unsupported type `" ++ @typeName(ArgType) ++ "`. Must be `[]const u8` or a struct whose fields are `[]const u8`.");
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
        /// Creates a new `Route` for the given HTTP Method that will be
        /// triggered based on its path conditions
        ///
        /// When the path contains parameters such as ':<name>' it will be captured
        /// and passed into the handlerFn as the 4th parameter. See the `wrap` function
        /// for more information on how captures are passed down.
        pub fn basicRoute(
            comptime method: Request.Method,
            comptime path: []const u8,
            comptime handlerFn: anytype,
        ) Route(Context) {
            return Route(Context){
                .method = method,
                .path = path,
                .handler = wrap(Context, handlerFn),
            };
        }

        /// Shorthand function to create a `Route` where method is 'GET'
        pub fn get(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.get, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'POST'
        pub fn post(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.post, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'PATCH'
        pub fn patch(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.patch, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'PUT'
        pub fn put(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.put, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'ANY'
        pub fn any(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.any, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'HEAD'
        pub fn head(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.head, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'DELETE'
        pub fn delete(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.delete, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'CONNECT'
        pub fn connect(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.connect, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'OPTIONS'
        pub fn options(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.options, path, handlerFn);
        }
        /// Shorthand function to create a `Route` where method is 'TRACE'
        pub fn trace(path: []const u8, comptime handlerFn: anytype) Route(Context) {
            return basicRoute(.trace, path, handlerFn);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
