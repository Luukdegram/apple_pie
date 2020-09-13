const std = @import("std");

/// Counts the amount of `{` tokens insi
fn countCaptures(buffer: []const u8) usize {
    var result: usize = 0;
    for (buffer) |c| {
        if (c == '{') result += 1;
    }
    return result;
}

/// Creates a new Template engine based on the given input
fn Template(comptime fmt: []const u8) type {
    comptime const num_captures = countCaptures(fmt);
    comptime var captures: [num_captures][]const u8 = undefined;

    comptime var level = 0;
    comptime var start = 0;
    comptime var index = 0;

    for (fmt) |c, i| {
        switch (c) {
            '{' => {
                level += 1;
                start = i + 1;
            },
            '}' => {
                if (start > i) continue;

                level -= 1;
                captures[index] = fmt[start..i];
                index += 1;
            },
            else => {},
        }
    }

    if (level != 0) @compileError("Incorrect capture level");

    return struct {
        const Self = @This();

        /// Parses the template with the input and writes it to the stream
        pub fn write(comptime T: type, value: T, writer: anytype) @TypeOf(writer).Error!void {
            comptime var write_index = 0;
            comptime var capture_index = 0;

            inline for (fmt) |c, i| {
                switch (c) {
                    '{' => try writer.writeAll(fmt[write_index..i]),
                    '}' => {
                        write_index = i + 1;
                        switch (@typeInfo(T)) {
                            .Struct => |info| {
                                if (@hasField(T, captures[capture_index])) {
                                    try writeTyped(writer, @field(value, captures[capture_index]));
                                }
                            },
                            else => {
                                @compileError("Implement for type: " ++ @typeName(T));
                            },
                        }
                        capture_index += 1;
                    },
                    else => {},
                }
            }

            // Write the remaining
            try writer.writeAll(fmt[write_index..]);
        }

        /// Writes the value to the stream based on the type of the given value
        fn writeTyped(writer: anytype, arg: anytype) @TypeOf(writer).Error!void {
            switch (@TypeOf(arg)) {
                []u8, []const u8 => try writer.writeAll(arg),
                else => switch (@typeInfo(@TypeOf(arg))) {
                    .ComptimeInt, .Int => try std.fmt.formatIntValue(arg, "d", .{}, writer),
                    .ComptimeFloat, .Float => try std.fmt.formatFloatDecimal(arg, .{ .precision = 2 }, writer),
                    .Bool => try writer.writeAll(if (arg) "true" else "false"),
                    else => @compileError("TODO: Implement for type: " ++ @typeName(@TypeOf(arg))),
                },
            }
        }
    };
}

test "Basic parse" {
    const input = "<html>{name} 371178 + 371178 = {number} {float} {boolean}</html>";
    const expected = "<html>apple_pie 371178 + 371178 = 742356 1.24 true</html>";

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const template = Template(input);

    try template.write(struct {
        name: []const u8,
        number: u32,
        float: f32,
        boolean: bool,
    }, .{
        .name = "apple_pie",
        .number = 742356,
        .float = 1.235235,
        .boolean = true,
    }, stream.writer());

    std.testing.expectEqualStrings(expected, stream.getWritten());
}
