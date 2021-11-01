const std = @import("std");

/// Entry in the param list
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Small radix trie used for routing
/// This radix trie works different from regular radix tries
/// as each node is made up from a piece rather than a singular character
pub fn Trie(comptime T: type) type {
    return struct {
        const Self = @This();

        const max_params: usize = 10;

        /// Node within the Trie, contains links to child nodes
        /// also contains a path piece and whether it's a wildcard
        const Node = struct {
            childs: []*Node,
            label: enum { none, all, param },
            path: []const u8,
            data: ?T,
        };

        /// Root node, which is '/'
        root: Node = Node{
            .childs = &.{},
            .label = .none,
            .path = "/",
            .data = null,
        },
        size: usize = 0,

        /// Result is an union which is returned when trying to find
        /// from a path
        const Result = union(ResultTag) {
            none: void,
            static: T,
            with_params: struct {
                data: T,
                params: [max_params]Entry,
                param_count: usize,
            },

            const ResultTag = enum { none, static, with_params };
        };

        /// Inserts new nodes based on the given path
        /// `path`[0] must be '/'
        pub fn insert(comptime self: *Self, comptime path: []const u8, comptime data: T) void {
            if (path.len == 1 and path[0] == '/') {
                self.root.data = data;
                return;
            }

            if (path[0] != '/') @compileError("Path must start with /");
            if (comptime std.mem.count(u8, path, ":") > max_params) @compileError("This path contains too many parameters");

            comptime var it = std.mem.split(u8, path[1..], "/");
            comptime var current = &self.root;
            comptime {
                loop: while (it.next()) |component| {
                    for (current.childs) |child| {
                        if (std.mem.eql(u8, child.path, component)) {
                            current = child;
                            continue :loop;
                        }
                    }

                    self.size += 1;
                    var new_node = Node{
                        .path = component,
                        .childs = &[_]*Node{},
                        .label = .none,
                        .data = null,
                    };

                    if (component.len > 0) {
                        new_node.label = switch (component[0]) {
                            ':' => .param,
                            '*' => .all,
                            else => .none,
                        };
                    }

                    var childs: [current.childs.len + 1]*Node = undefined;
                    std.mem.copy(*Node, &childs, current.childs ++ [_]*Node{&new_node});
                    current.childs = &childs;
                    current = &new_node;

                    if (current.label == .all) break;
                }
            }
            current.data = data;
        }

        /// Retrieves T based on the given path
        /// when a wildcard such as * is found, it will return T
        /// If a colon is found, it will add the path piece onto the param list
        pub fn get(self: *Self, path: []const u8) Result {
            if (path.len == 1) {
                if (self.root.data) |data| {
                    return .{ .static = data };
                } else {
                    return .none;
                }
            }

            var params: [max_params]Entry = undefined;
            var param_count: usize = 0;
            var current = &self.root;
            var it = std.mem.split(u8, path[1..], "/");
            var index: usize = 0;

            loop: while (it.next()) |component| {
                index += component.len + 1;
                for (current.childs) |child| {
                    if (std.mem.eql(u8, component, child.path) or child.label == .param or child.label == .all) {
                        if (child.label == .all) {
                            if (child.data == null) return .none;

                            var result = Result{
                                .with_params = .{
                                    .data = child.data.?,
                                    .params = undefined,
                                    .param_count = param_count,
                                },
                            };

                            // Add the wildcard as param as well
                            // returns full result from wildcard onwards
                            params[param_count] = .{ .key = child.path, .value = path[index - component.len ..] };
                            std.mem.copy(Entry, &result.with_params.params, &params);
                            return result;
                        }
                        if (child.label == .param) {
                            params[param_count] = .{ .key = child.path[1..], .value = component };
                            param_count += @boolToInt(param_count < max_params);
                        }
                        current = child;
                        continue :loop;
                    }
                }
                return .none;
            }

            if (current.data == null) return .none;
            if (param_count == 0) return .{ .static = current.data.? };

            var result = Result{
                .with_params = .{
                    .data = current.data.?,
                    .params = undefined,
                    .param_count = param_count,
                },
            };

            std.mem.copy(Entry, &result.with_params.params, &params);
            return result;
        }
    };
}

test "Insert and retrieve" {
    comptime var trie = Trie(u32){};
    comptime trie.insert("/posts/:id", 1);
    comptime trie.insert("/messages/*", 2);
    comptime trie.insert("/topics/:id/messages/:msg", 3);
    comptime trie.insert("/topics/:id/*", 4);
    comptime trie.insert("/bar", 5);

    const res = trie.get("/posts/5");
    const res2 = trie.get("/messages/bla");
    const res2a = trie.get("/messages/bla/bla");
    const res3 = trie.get("/topics/25/messages/20");
    const res4 = trie.get("/foo");
    const res5 = trie.get("/topics/5/foo");
    const res6 = trie.get("/topics/5/");
    const res7 = trie.get("/bar");

    try std.testing.expectEqual(@as(u32, 1), res.with_params.data);
    try std.testing.expectEqual(@as(u32, 2), res2.with_params.data);
    try std.testing.expectEqual(@as(u32, 2), res2a.with_params.data);
    try std.testing.expectEqual(@as(u32, 3), res3.with_params.data);
    try std.testing.expect(res4 == .none);
    try std.testing.expectEqual(@as(u32, 4), res5.with_params.data);
    try std.testing.expectEqual(@as(u32, 4), res6.with_params.data);
    try std.testing.expectEqual(@as(u32, 5), res7.static);

    try std.testing.expectEqualStrings("5", res.with_params.params[0].value);
    try std.testing.expectEqualStrings("bla", res2.with_params.params[0].value);
    try std.testing.expectEqualStrings("bla/bla", res2a.with_params.params[0].value);
    try std.testing.expectEqualStrings("25", res3.with_params.params[0].value);
    try std.testing.expectEqualStrings("20", res3.with_params.params[1].value);
    try std.testing.expectEqualStrings("5", res5.with_params.params[0].value);
    try std.testing.expectEqualStrings("foo", res5.with_params.params[1].value);
}

test "Insert and retrieve paths with same prefix" {
    comptime var trie = Trie(u32){};
    comptime trie.insert("/api", 1);
    comptime trie.insert("/api/users", 2);
    comptime trie.insert("/api/events", 3);
    comptime trie.insert("/api/events/:id", 4);

    const res = trie.get("/api");
    const res2 = trie.get("/api/users");
    const res3 = trie.get("/api/events");
    const res4 = trie.get("/api/events/1337");
    const res5 = trie.get("/foo");
    const res6 = trie.get("/api/api/events");

    try std.testing.expectEqual(@as(u32, 1), res.static);
    try std.testing.expectEqual(@as(u32, 2), res2.static);
    try std.testing.expectEqual(@as(u32, 3), res3.static);
    try std.testing.expectEqual(@as(u32, 4), res4.with_params.data);
    try std.testing.expect(res5 == .none);
    try std.testing.expect(res6 == .none);

    try std.testing.expectEqualStrings("1337", res4.with_params.params[0].value);
}

test "Get root" {
    comptime var trie = Trie(u32){};
    comptime trie.insert("/api", 1);

    const res = trie.get("/");
    try std.testing.expect(res == .none);
}
