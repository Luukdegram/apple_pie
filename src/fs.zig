const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const MimeType = @import("mime_type.zig").MimeType;
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const FileServer = @This();

var dir: fs.Dir = undefined;
var alloc: *std.mem.Allocator = undefined;
var initialized: bool = false;
var base_path: ?[]const u8 = null;

pub const Config = struct {
    dir_path: []const u8,
    base_path: ?[]const u8 = null,
};

/// Sets the directory of the file server to the given path
/// Note that this function must be called before passing the serve
/// function to the `Server`.
///
/// deinit() must be called to close the dir handler
pub fn init(allocator: *Allocator, config: Config) !void {
    dir = try fs.cwd().openDir(config.dir_path, .{});
    alloc = allocator;
    initialized = true;
    base_path = config.base_path;
}

/// Closes the dir handler
pub fn deinit() void {
    dir.close();
}

/// Servers a file based on the path of the request
pub fn serve(response: *Response, request: Request) !void {
    std.debug.assert(initialized);
    const index = "index.html";
    var path = request.url.path[1..];

    if (std.mem.endsWith(u8, path, index)) {
        return localRedirect(response, request, "./", alloc);
    }

    if (base_path) |b_path| {
        if (std.mem.startsWith(u8, path, b_path)) {
            path = path[b_path.len..];
            if (path.len > 0 and path[0] == '/') path = path[1..];
        }
    }

    var file = dir.openFile(path, .{}) catch |_| {
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
    // const buffer = try allocator.alloc(u8, stat.size);
    // _ = try file.readAll(buffer);
    // defer allocator.free(buffer);

    _ = try response.headers.put("Content-Type", MimeType.fromFileName(file_name).toType());
    try response.sendFile(file);
    //try response.write(buffer);
}
