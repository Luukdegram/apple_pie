//! Basic file server that allows for exposing a directory
//! to the web. the `serve` function ensures the directory is not escaped
//! using a path. It also allows for providing a `base_path` which it ignores
//! when parsing the path.

const std = @import("std");
const Request = @import("Request.zig");
const Response = @import("response.zig").Response;
const MimeType = @import("mime_type.zig").MimeType;
const Uri = @import("Uri.zig");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const FileServer = @This();

var dir: fs.Dir = undefined;
var alloc: Allocator = undefined;
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
pub fn init(allocator: Allocator, config: Config) fs.Dir.OpenError!void {
    dir = try fs.cwd().openDir(config.dir_path, .{});
    alloc = allocator;
    initialized = true;
    base_path = config.base_path;
}

/// Closes the dir handler
pub fn deinit() void {
    dir.close();
}

pub const ServeError = error{
    NotAFile,
} || Response.Error || std.os.SendFileError || std.fs.File.OpenError;

/// Servers a file based on the path of the request
pub fn serve(ctx: void, response: *Response, request: Request) ServeError!void {
    _ = ctx;
    std.debug.assert(initialized);
    const index = "index.html";
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var path = Uri.resolvePath(request.path(), &buffer);

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

    const file = dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return response.notFound(),
        else => |e| return e,
    };
    defer file.close();

    serveFile(response, request.path(), file) catch |err| switch (err) {
        error.NotAFile => return response.notFound(),
        else => return err,
    };
}

/// Notifies the client with a Moved Permanently header
/// The memory allocated by this is freed
fn localRedirect(
    response: *Response,
    request: Request,
    path: []const u8,
    allocator: Allocator,
) (Response.Error)!void {
    const new_path = if (request.context.uri.query) |query| blk: {
        break :blk try std.mem.concat(allocator, u8, &.{ path, query });
    } else path;
    defer if (request.context.uri.query != null) {
        allocator.free(new_path);
    };

    try response.headers.put("Location", new_path);
    try response.writeHeader(.moved_permanently);
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
    var stream = response.buffered_writer.writer();
    const len = stat.size;

    // write status line
    try stream.writeAll("HTTP/1.1 200 OK\r\n");

    //write headers
    var header_it = response.headers.iterator();
    while (header_it.next()) |header| {
        try stream.print("{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.* });
    }

    try stream.print("Content-Length: {d}\r\n", .{len});
    try stream.print("Content-Type: {s}\r\n", .{MimeType.fromFileName(file_name).toString()});

    if (!std.io.is_async) {
        try stream.writeAll("Connection: close\r\n");
    }

    //Carrot Return after headers to tell clients where headers end, and body starts
    try stream.writeAll("\r\n");
    try response.buffered_writer.flush();

    const out = response.buffered_writer.unbuffered_writer.context.handle;
    var remaining: u64 = len;
    while (remaining > 0) {
        remaining -= try std.os.sendfile(out, file.handle, len - remaining, remaining, &.{}, &.{}, 0);
    }
}
