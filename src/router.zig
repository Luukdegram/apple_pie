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

    if (function_info.args.len < 3)
        @compileError("Expected at least 3 args in Handler function; (" ++ @typeName(Context) ++ ", " ++ @typeName(*Response) ++ ", " ++ @typeName(Request) ++ ")]");

    assertIsType("Expected first argument of handler to be", Context, function_info.args[0].arg_type.?);
    assertIsType("Expected second argument of handler to be", *Response, function_info.args[1].arg_type.?);
    assertIsType("Expected third argument of handler to be", Request, function_info.args[2].arg_type.?);

    const CapturesExpected = union(enum) {
        none,
        one_string,
        struct_fields: usize,
    };

    const expected_captures: CapturesExpected = calc_captures_expected: {
        if (function_info.args.len < 4) {
            break :calc_captures_expected .none;
        }

        switch (function_info.args[3].arg_type.?) {
            []const u8 => break :calc_captures_expected .one_string,

            else => |ArgType| if (@typeInfo(ArgType) == .Struct) {
                const struct_info = @typeInfo(ArgType).Struct;
                inline for (struct_info.fields) |field| {
                    assertIsType("Expected all fields of capture to be", []const u8, field.field_type);
                }
                break :calc_captures_expected .{ .struct_fields = struct_info.fields.len };
            } else {
                @compileError("Unsupported type `" ++ @typeName(ArgType) ++ "`. Must be `[]const u8` or a struct whose fields are `[]const u8`.");
            },
        }
    };

    const X = struct {
        fn wrapper(ctx: Context, res: *Response, req: Request, params: []const trie.Entry) anyerror!void {
            switch (expected_captures) {
                .none => {
                    std.debug.assert(params.len == 0);
                    return handler(ctx, res, req);
                },
                .one_string => {
                    std.debug.assert(params.len == 1);
                    return handler(ctx, res, req, params[0].value);
                },
                .struct_fields => |num_fields_expected| {
                    std.debug.assert(params.len == num_fields_expected);

                    const CaptureStruct = function_info.args[3].arg_type.?;
                    var captures: CaptureStruct = undefined;

                    for (params) |param| {
                        // Using a variable here instead of something like `continue :params_loop` because that causes the compiler to crash with exit code 11.
                        var matched_a_field = false;
                        inline for (@typeInfo(CaptureStruct).Struct.fields) |field| {
                            if (std.mem.eql(u8, param.key, field.name)) {
                                @field(captures, field.name) = param.value;
                                matched_a_field = true;
                            }
                        }
                        if (!matched_a_field)
                            std.debug.panic("Unexpected capture \"{}\", no such field in {s}", .{ std.zig.fmtEscapes(param.key), @typeName(CaptureStruct) });
                    }

                    return handler(ctx, res, req, captures);
                },
            }
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
