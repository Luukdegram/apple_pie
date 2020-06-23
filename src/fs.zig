const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const MimeType = @import("mime_type.zig").MimeType;
const Allocator = std.mem.Allocator;
const fs = std.fs;

var dir: fs.Dir = undefined;
var alloc: *std.mem.Allocator = undefined;
var initialized: bool = false;

/// Sets the directory of the file server to the given path
/// Note that this function must be called before passing the serve
/// function to the `Server`.
///
/// deinit() must be called to close the dir handler
pub fn init(path: []const u8, allocator: *Allocator) !void {
    dir = try fs.cwd().openDir(path, .{});
    alloc = allocator;
    initialized = true;
}

/// Closes the dir handler
pub fn deinit() void {
    dir.close();
}

/// Servers a file based on the path of the request
pub fn serve(response: *Response, request: Request) !void {
    std.debug.assert(initialized);

    var file = dir.openFile(request.url.path[1..], .{}) catch {
        return response.notFound();
    };
    defer file.close();

    var stat = try file.stat();
    if (stat.kind != .File) {
        return response.notFound();
    }

    // read contents and write to response
    const buffer = try file.readAllAlloc(alloc, stat.size, stat.size);
    defer alloc.free(buffer);

    _ = try response.headers.put("Content-Type", MimeType.fromFileName(request.url.path).toType());
    try response.write(buffer);
}
