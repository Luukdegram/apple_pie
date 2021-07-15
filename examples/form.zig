const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try http.listenAndServe(
        &gpa.allocator,
        try std.net.Address.parseIp("0.0.0.0", 8080),
        {},
        index,
    );
}

fn index(ctx: void, response: *http.Response, request: http.Request) !void {
    _ = ctx;
    if (request.context.method != .post) return response.writer().writeAll("Send me a POST form!");

    var form_iterator = request.formIterator();
    // use request's arena so it frees all memory once the request has been completed.
    while (try form_iterator.next(request.arena)) |field| {
        // if we had our own allocator, we could do
        // defer field.deinit(some_allocator);
        try response.writer().print("Field '{s}' has value: '{s}'\n", .{ field.key, field.value });
    }
}
