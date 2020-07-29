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
    const index = "index.html";

    if (std.mem.endsWith(u8, request.url.path, index)) {
        return localRedirect(response, request, "./", alloc);
    }

    var file = dir.openFile(request.url.path[1..], .{}) catch {
        return response.notFound();
    };
    defer file.close();

    try serveFile(response, request.url.path, file, alloc);
}

/// Notifies the client with a Moved Permanently header
/// The memory allocated by this is freed
fn localRedirect(response: *Response, request: Request, path: []const u8, allocator: *Allocator) !void {
    const new_path = try std.mem.concat(allocator, u8, &[_][]const u8{
        path,
        request.url.raw_query,
    });
    defer allocator.free(new_path);

    _ = try response.headers.put("Location", new_path);
    try response.writeHeader(.MovedPermanently);
}

/// Serves a file to the client
/// Opening and closing of the file must be handled by the user
pub fn serveFile(
    response: *Response,
    file_name: []const u8,
    file: fs.File,
    allocator: *Allocator,
) !void {
    var stat = try file.stat();
    if (stat.kind != .File) {
        return error.NotAFile;
    }

    // read contents and write to response
    const buffer = try file.readAllAlloc(alloc, stat.size, stat.size);
    defer alloc.free(buffer);

    _ = try response.headers.put("Content-Type", MimeType.fromFileName(file_name).toType());
    try response.write(buffer);
}
