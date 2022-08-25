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

/// Serves a file based on the path of the request
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

    // if the path is '', we should serve the index at root
    var buf_new_path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const new_path = if (path.len == 0) index else blk: {
        // if the path is a directory, we should serve the index inside
        const stat = dir.statFile(path) catch |err| switch (err) {
            error.FileNotFound => return response.notFound(),
            else => |e| return e,
        };
        if (stat.kind == .Directory)
            break :blk try std.fmt.bufPrint(&buf_new_path, "{s}/{s}", .{ path, index });
        // otherwise, we should serve the file at path
        break :blk path;
    };

    const file = dir.openFile(new_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return response.notFound(),
        else => |e| return e,
    };
    defer file.close();

    serveFile(response, new_path, file) catch |err| switch (err) {
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

test "File server test" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const Server = @import("server.zig").Server;
    const net = std.net;

    const test_alloc = std.testing.allocator;
    const test_message = "Hello, Apple pie!";
    const address = try net.Address.parseIp("0.0.0.0", 8080);
    var server = Server.init();

    // setup files to serve
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var buf_dir_path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &buf_dir_path);
    try tmp_dir.dir.writeFile("index.html", test_message);

    // making sure the file was written before continuing
    while (true) {
        var buf: [32]u8 = undefined;
        const content = tmp_dir.dir.readFile("index.html", &buf) catch continue;
        if (std.mem.eql(u8, content, test_message))
            break;
    }

    const server_thread = struct {
        var _addr: net.Address = undefined;
        var _dir: []u8 = undefined;

        fn index(ctx: void, resp: *Response, req: Request) !void {
            _ = ctx;
            try serve({}, resp, req);
        }
        fn runServer(context: *Server) !void {
            // initialize fileserver
            try init(test_alloc, .{ .dir_path = _dir });
            defer deinit();

            try context.run(test_alloc, _addr, {}, index);
        }
    };
    server_thread._addr = address;
    server_thread._dir = dir_path;

    const thread = try std.Thread.spawn(.{}, server_thread.runServer, .{&server});
    errdefer server.shutdown();

    var stream = while (true) {
        var conn = net.tcpConnectToAddress(address) catch |err| switch (err) {
            error.ConnectionRefused => continue,
            else => return err,
        };

        break conn;
    } else unreachable;
    errdefer stream.close();
    // tell server to shutdown
    // will finish current request and then shutdown
    server.shutdown();
    try stream.writer().writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var buf: [512]u8 = undefined;
    var len = try stream.reader().read(&buf);
    const body_start = 4 + (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") orelse return error.Unexpected);

    // making sure we received the entire response body before closing the stream
    var tries: usize = 0;
    while (tries < 3) : (tries += 1) {
        // making sure we find the Content-Length header, otherwise break
        const content_length_start = std.mem.indexOf(u8, buf[0..len], "Content-Length: ") orelse break;
        const content_length_end = content_length_start + (std.mem.indexOf(u8, buf[content_length_start..len], "\r\n") orelse return error.Unexpected);
        const content_length = try std.fmt.parseUnsigned(usize, buf[content_length_start + 16 .. content_length_end], 10);

        // if we received the expected amount of bytes, we break to close the stream
        const expected_len = body_start + content_length;
        if (expected_len == len)
            break;
        len += try stream.reader().read(buf[len..]);
    }
    stream.close();
    thread.join();

    const answer = buf[body_start..len];
    try std.testing.expectEqualStrings(test_message, answer);
}
