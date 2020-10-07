const std = @import("std");

pub fn RadixTree(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Represents a node within the tree
        /// Is possible a Leaf or else contains edges to
        /// other nodes
        const Node = struct {
            /// Possible leaf
            leaf: ?Leaf,
            /// Ignored prefix
            prefix: []const u8,
            /// array of other edges
            /// Can only be non-zero in case of non-Leaf
            edges: []Edge,

            /// Adds a new `Edge` in the `edges` list of the `Node`
            fn addEdge(self: *Node, comptime e: Edge) void {
                comptime var edges: [self.edges.len + 1]Edge = undefined;
                std.mem.copy(Edge, &edges, self.edges ++ &[_]Edge{e});

                std.sort.sort(Edge, &edges, {}, lessThan);
                self.edges = &edges;
            }

            /// Updates the edge's node that contains the given label with the new Node
            /// It's a Compiler error if the Edge does not yet exist
            fn updateEdge(self: *Node, comptime label: u8, comptime node: *Node) void {
                const idx = blk: {
                    var i: usize = 0;
                    while (i < self.edges.len) : (i += 1) {
                        if (self.edges[i].label >= label) break;
                    }
                    break :blk i;
                };

                if (idx < self.edges.len and self.edges[idx].label == label) {
                    self.edges[idx].node = node;
                    return;
                }

                @compileError("Edge with label '" ++ &[_]u8{label} ++ "' does not exist\n");
            }

            /// Used for std.sort.sort() function to determine order
            fn lessThan(ctx: void, lhs: Edge, rhs: Edge) bool {
                return lhs.label < rhs.label;
            }

            /// Retrieves a Node based on the given `label`
            /// Returns `null` if no Node exists with given label
            fn edge(self: *Node, label: u8) ?*Node {
                @setEvalBranchQuota(100_000);
                const idx = blk: {
                    var i: usize = 0;
                    while (i < self.edges.len) : (i += 1) {
                        if (self.edges[i].label >= label) break;
                    }
                    break :blk i;
                };

                if (idx < self.edges.len and self.edges[idx].label == label)
                    return self.edges[idx].node;

                return null;
            }
        };

        /// End node of the tree, contains the key and data component
        const Leaf = struct {
            key: []const u8,
            data: T,
        };

        /// Specific node within the tree, contains the label (character)
        /// and reference to another node
        const Edge = struct {
            label: u8,
            node: *Node,
        };

        /// Root node
        root: Node = .{
            .leaf = null,
            .prefix = undefined,
            .edges = &[_]Edge{},
        },

        /// Total edges within the tree
        size: usize = 0,

        /// Inserts or updates a Node based on the `key` and `data` where
        /// `data` is of type `T`
        pub fn insert(self: *Self, comptime key: []const u8, comptime data: T) ?T {
            var parent: *Node = undefined;

            var current: *Node = &self.root;
            var search: []const u8 = key;
            while (true) {
                // reached end of tree, create leaf
                if (search.len == 0) {
                    // leaf exists? update data
                    if (current.leaf) |*leaf| {
                        const temp = leaf.data;
                        leaf.data = data;
                        return temp;
                    }

                    current.leaf = Leaf{
                        .key = key,
                        .data = data,
                    };
                    self.size += 1;
                    return null;
                }

                parent = current;
                // get existing edge if it exists so we can update it
                // else create a new `Edge`
                if (current.edge(search[0])) |n| {
                    current = n;
                } else {
                    var leaf = Leaf{
                        .key = key,
                        .data = data,
                    };

                    var new_node = Node{
                        .leaf = leaf,
                        .prefix = search,
                        .edges = &[_]Edge{},
                    };

                    parent.addEdge(.{
                        .label = search[0],
                        .node = &new_node,
                    });
                    self.size += 1;
                    return null;
                }

                // determine the length of the prefix
                const prefix = longestPrefix(search, current.prefix);
                if (prefix == current.prefix.len) {
                    // basically we jump directly to creating/updating the leaf
                    search = search[prefix..];
                    continue;
                }

                self.size += 1;

                // Split the node into 2 Edges
                var child = Node{
                    .leaf = null,
                    .edges = &[_]Edge{},
                    .prefix = search[0..prefix],
                };

                parent.updateEdge(search[0], &child);

                child.addEdge(.{
                    .label = current.prefix[prefix],
                    .node = current,
                });

                current.prefix = current.prefix[prefix..];

                var leaf = Leaf{
                    .key = key,
                    .data = data,
                };

                search = search[prefix..];
                if (search.len == 0) {
                    child.leaf = leaf;
                    return null;
                }

                var new_node = Node{
                    .leaf = leaf,
                    .prefix = search,
                    .edges = &[_]Edge{},
                };

                child.addEdge(.{
                    .label = search[0],
                    .node = &new_node,
                });

                return null;
            }
        }

        /// Searches for a result using the given `key`
        /// Returns null if key is not found
        /// Returns `T` if found
        pub fn get(self: *Self, key: []const u8) ?T {
            var current = self.root;
            var search = key;
            while (search.len != 0) {
                current = (current.edge(search[0]) orelse return null).*;

                if (std.mem.startsWith(u8, search, current.prefix))
                    search = search[current.prefix.len..]
                else
                    break;
            }

            return if (current.leaf) |leaf| leaf.data else null;
        }

        /// Rather than searching for the exact match, it will return the longest prefix match
        /// i.e. If "hello" exists as leaf, and the given `key` is "helloworld", this will return
        /// `T` that belongs to prefix "hello".
        /// Returns null if nothing was found
        /// Returns `T` if prefix match was found
        pub fn getLongestPrefix(self: *Self, key: []const u8) ?T {
            var last: ?T = null;
            var current = self.root;
            var search = key;

            while (true) {
                if (current.leaf) |leaf| last = leaf.data;

                if (search.len == 0) break;

                current = (current.edge(search[0]) orelse break).*;

                if (std.mem.startsWith(u8, search, current.prefix))
                    search = search[current.prefix.len..]
                else
                    break;
            }

            return last;
        }
    };
}

/// Finds the length of the longest prefix between 2 strings
/// i.e.:
/// lhs: foop
/// rhs: foobar
/// result: 2 -> matches foo as prefix
fn longestPrefix(comptime lhs: []const u8, comptime rhs: []const u8) usize {
    const max = if (lhs.len < rhs.len) lhs.len else rhs.len;

    var i: u8 = 0;
    return while (i < max) : (i += 1) {
        if (lhs[i] != rhs[i]) break i;
    } else i;
}
