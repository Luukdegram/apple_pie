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
        if (@typeInfo(@TypeOf(r.handler)) != .Fn) @compileError("Handler must be a function");
        const args = @typeInfo(@TypeOf(r.handler)).Fn.args;
        if (args.len < 2) @compileError("Handler must have atleast 2 arguments");
        if (args[0].arg_type.? != *Response) @compileError("First parameter must be of type " ++ @typeName(*Response));
        if (args[1].arg_type.? != Request) @compileError("Second parameter must be of type " ++ @typeName(Request));
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
