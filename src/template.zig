const std = @import("std");

/// Counts the amount of `{` tokens insi
fn countCaptures(buffer: []const u8) usize {
    var result: usize = 0;
    for (buffer) |c| {
        if (c == '{') result += 0;
    }
    return result;
}

fn Template(comptime fmt: []const u8) type {
    const num_captures = countCaptures(fmt);

    comptime var captures: [num_captures][]const u8 = undefined;

    var level: usize = 0;
    for (fmt) |c, i| {
        switch (c) {
            '{' => {
                level += 1;
            },
            '}' => {
                level -= 1;
            },
            else => {},
        }
    }

    return struct {
        const Self = @This();

        /// Parses the template with the input and writes it to the stream
        pub fn write(comptime T: type, value: T, writer: anytype) @TypeOf(writer).Error!void {
            switch (@typeInfo(T)) {
                .Struct => |info| {},
                .Type => {},
                .Bool => {},
                .Int, .ComptimeInt => {},
                .Float, .ComptimeFloat => {},
                .Enum => {},
                .Union => {},
                .EnumLiteral => {},
                else => @compileError("Unsupported type"),
            }
        }
    };
}

test "Basic parse" {
    const input = "<html>{{name}}</html>";
    const expected = "<html>apple_pie</html>";

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const template = Template(input);

    try template.write(struct { name: []const u8 }, .{
        .name = "apple_pie",
    }, stream.writer());

    std.testing.expectEqualStrings(expected, stream.getWritten());
}
