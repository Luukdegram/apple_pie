const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const MimeType = @import("mime_type.zig").MimeType;
const url = @import("url.zig");
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
pub fn init(allocator: *Allocator, config: Config) fs.Dir.OpenError!void {
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
pub fn serve(response: *Response, request: Request) (Response.Error || error{NotAFile} || std.os.SendFileError)!void {
    std.debug.assert(initialized);
    const index = "index.html";
    var path = url.sanitize(request.url.path);

    if (std.mem.endsWith(u8, path, index)) {
        return localRedirect(response, request, "./", alloc);
    }

    if (base_path) |b_path| {
        if (std.mem.startsWith(u8, path[1..], b_path)) {
            path = path[b_path.len + 1 ..];
            if (path.len > 0 and path[0] == '/') path = path[1..];
        }
    } else if (path[0] == '/') path = path[1..];

    // if the sanitized path starts with '..' it means it goes up from the root
    // and therefore has access to outside root.
    if (std.mem.startsWith(u8, path, "..")) return response.notFound();

    var file = dir.openFile(path, .{}) catch |_| {
        return response.notFound();
    };
    defer file.close();

    try serveFile(response, request.url.path, file);
}

/// Notifies the client with a Moved Permanently header
/// The memory allocated by this is freed
fn localRedirect(
    response: *Response,
    request: Request,
    path: []const u8,
    allocator: *Allocator,
) (Response.Error)!void {
    const new_path = try std.mem.concat(allocator, u8, &[_][]const u8{
        path,
        request.url.raw_query,
    });
    defer allocator.free(new_path);

    try response.headers.put("Location", new_path);
    try response.writeHeader(.MovedPermanently);
}

/// Serves a file to the client
/// Opening and closing of the file must be handled by the user
///
/// NOTE: This is a low level implementation utilizing std.os.sendFile()
/// and accesses the response writer's internal socket handle. This does not allow for setting
/// any other headers and/or status codes. Use response.write() for that
pub fn serveFile(
    response: *Response,
    file_name: []const u8,
    file: fs.File,
) (Response.Error || error{NotAFile} || std.os.SendFileError)!void {
    var stat = try file.stat();
    if (stat.kind != .File)
        return error.NotAFile;

    response.is_flushed = true;
    var stream = response.socket_writer.writer();
    const len = stat.size;

    // write status line
    try stream.writeAll("HTTP/1.1 200 OK\r\n");

    //write headers
    for (response.headers.items()) |header| {
        try stream.print("{}: {}\r\n", .{ header.key, header.value });
    }

    try stream.print("Content-Length: {}\r\n", .{len});
    try stream.print("Content-Type: {}\r\n", .{MimeType.fromFileName(file_name).toType()});

    if (!std.io.is_async) {
        try stream.writeAll("Connection: Close\r\n");
    }

    //Carrot Return after headers to tell clients where headers end, and body starts
    try stream.writeAll("\r\n");
    try response.socket_writer.flush();

    const out = response.socket_writer.unbuffered_writer.handle;
    var remaining: u64 = len;
    while (remaining > 0) {
        remaining -= try std.os.sendfile(out.handle.inner, file.handle, len - remaining, remaining, &[_]std.os.iovec_const{}, &[_]std.os.iovec_const{}, 0);
    }
}
