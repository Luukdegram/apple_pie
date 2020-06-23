const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const RequestHandler = @import("server.zig").RequestHandler;

pub const CacheMode = enum {
    Memory,
    KeepOpen,
    Close,
};

/// Threadsafe hashmap that contains `StaticFile`s by its name
const FileCache = struct {
    map: std.StringHashMap(*StaticFile),
    mutex: std.Mutex,
    allocator: *Allocator,
    base_path: []const u8,

    pub fn get(self: *FileCache, path: []const u8) ?*StaticFile {
        var lock = self.mutex.acquire();
        defer lock.release();

        return self.map.getValue(path);
    }

    pub fn put(self: *FileCache, file: *StaticFile) !void {
        var lock = self.mutex.acquire();
        defer lock.release();
        _ = try self.map.put(file.name, file);
    }

    pub fn has(self: *FileCache, path: []const u8) bool {
        var lock = self.mutex.acquire();
        defer lock.release();

        return self.map.contains(path);
    }

    /// Frees all memory of the file cache
    /// This function is not threadsafe as it destroys itself and shouldn't be called afterwards
    pub fn deinit(self: *FileCache) void {
        self.mutex.deinit();

        for (self.map.entries) |entry| {
            var file = entry.kv.value;
            self.allocator.free(file.path);
            self.allocator.free(file.name);

            if (file.cache_mode == .Memory and file.data != null) {
                self.allocator.free(file.data.?);
            }

            file.close();
            self.allocator.destroy(file);
        }
        self.map.deinit();
        self.* = undefined;
    }
};

var file_cache: FileCache = undefined;
var allocator: *Allocator = undefined;
var cache_mode: CacheMode = .KeepOpen;

/// Creates a new static file server handler
/// Memory is owned by the cache or, incase of an ArenaAllocator, the caller.
/// Clearing the memory using the cache can be done calling `file_cache.deinit()` which is a
/// public struct of this file.
pub fn init(alloc: *Allocator, path: []const u8, mode: CacheMode) !void {
    file_cache = FileCache{
        .map = std.StringHashMap(*StaticFile).init(alloc),
        .mutex = std.Mutex.init(),
        .allocator = alloc,
        .base_path = path,
    };

    cache_mode = mode;
    allocator = alloc;

    const cwd: std.fs.Dir = std.fs.cwd();
    var dir = try cwd.openDir(path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .File) {
            continue;
        }

        const name = try allocator.dupe(u8, entry.name);
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{
            path,
            name,
        });

        var static_file = try allocator.create(StaticFile);
        static_file.* = StaticFile.init(name, file_path, mode);
        errdefer allocator.destroy(static_file);

        try file_cache.put(static_file);
    }
}

pub fn deinit() void {
    file_cache.deinit();
}

pub fn handle2(response: *Response, request: Request) !void {
    errdefer sendNotFound(response) catch {};
    if (file_cache.get(request.url.path[1..])) |f| {
        var data = try f.read(allocator);
        defer if (f.cache_mode != .Memory) allocator.free(data);
        _ = try response.headers.put("Content-Type", f.mime_type.toType());

        return response.write(data);
    }

    var full_path = try std.fs.path.join(allocator, &[_][]const u8{
        file_cache.base_path,
        request.url.path[1..],
    });
    errdefer allocator.free(full_path);

    const name = try allocator.dupe(u8, request.url.path[1..]);
    errdefer allocator.free(name);

    var static_file = try allocator.create(StaticFile);
    errdefer allocator.destroy(static_file);
    static_file.* = StaticFile.init(name, full_path, cache_mode);
    var data = static_file.read(allocator) catch |err| {
        switch (err) {
            error.IsDir => {
                try sendNotFound(response);
                allocator.free(full_path);
                allocator.free(name);
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(data);
    try file_cache.put(static_file);
    _ = try response.headers.put("Content-Type", static_file.mime_type.toType());
    return response.write(data);
}

/// The handler function that will be called each request.
/// Make sure to call init() before using this function.
pub fn handle(response: *Response, request: Request) callconv(.Async) !void {
    var file: ?std.fs.File = null;
    var static_file: StaticFile = undefined;
    var cache_allocator = allocator;

    errdefer {
        sendNotFound(response) catch {};
    }

    if (file_cache.get(request.url.path[1..])) |f| {
        static_file = f.*;
        file = try std.fs.cwd().openFile(f.path, .{});
    } else {
        var full_path = try std.fs.path.join(cache_allocator, &[_][]const u8{
            file_cache.base_path,
            request.url.path,
        });
        errdefer cache_allocator.free(full_path);

        var possible_file = try findFile(full_path);

        if (possible_file) |f| {
            file = f;
            errdefer f.close();

            const name = try cache_allocator.dupe(u8, request.url.path);
            errdefer cache_allocator.free(name);

            static_file = StaticFile.init(name, full_path, cache_mode);
            try file_cache.put(&static_file);
        }
    }

    if (file) |f| {
        defer f.close();
        const size = try f.getEndPos();

        var buffer = try cache_allocator.alloc(u8, size);
        defer cache_allocator.free(buffer);

        _ = f.inStream().read(buffer) catch |err| {
            switch (err) {
                error.IsDir => return,
                else => std.debug.print("Error reading from the file: {}\n", .{err}),
            }
            return err;
        };

        // static_file is set if file is also not null
        _ = try response.headers.put("Content-Type", static_file.mime_type.toType());

        try response.write(buffer);
    } else {
        try sendNotFound(response);
    }
}

/// Sends a 404 Resource not found response
fn sendNotFound(response: *Response) !void {
    response.status_code = 404;
    try response.write("Resource not found");
}

/// Tries to find the file on the host's system
fn findFile(path: []const u8) !?std.fs.File {
    var tmp: std.fs.Dir = std.fs.cwd();
    if (std.fs.path.dirname(path) == null) {
        var file: std.fs.File = tmp.openFile(path, .{}) catch {
            return null;
        };
        return file;
    }
    return null;
}

/// Static File is an abtraction layer over std.fs.File
/// This allows us to save the mimetype and extension
/// as well as provide logic to cache the file based on the setting
const StaticFile = struct {
    /// Relative path to the file based on cwd
    path: []const u8,
    /// the file extension of the file
    extension: []const u8,
    /// Name of the file
    name: []const u8,
    /// mime type of the file, (if supported)
    mime_type: MimeType,
    /// internal handle to the file
    internal: std.fs.File,
    /// used to check if we closed the fd so we can tell to reopen when reading its data
    open: bool = false,
    /// The mode the file could be cached in
    cache_mode: CacheMode,
    /// Contents of the file, this is only available if `cache_mode` is `.Memory`
    /// and `read()` has been called once
    data: ?[]const u8,

    /// Creates a `StaticFile` from the name and its path,
    /// it determines its extension and `MimeType`.
    /// If no extension is found, this is an empty slice,
    /// and the `mimeType` will be set to .Unknown
    pub fn init(name: []const u8, path: []const u8, mode: CacheMode) StaticFile {
        const extension = blk: {
            var ext: []const u8 = undefined;
            if (std.mem.indexOf(u8, name, ".")) |index| {
                ext = name[index..];
            } else {
                ext = "";
            }
            break :blk ext;
        };

        return StaticFile{
            .path = path,
            .name = name,
            .extension = extension,
            .mime_type = MimeType.fromExtension(extension),
            .cache_mode = mode,
            .internal = undefined,
            .data = null,
        };
    }

    /// Reads the contents of the file
    /// This also reads the data into memory if `cache_mode` is `.Memory`
    /// This will also call close() when cache_mode is not `.KeepOpen`
    /// NOTE that in cases where cache_mode is not `Memory` the memory must be freed manually.
    pub fn read(self: *StaticFile, alloc: *Allocator) ![]const u8 {
        if (self.cache_mode == .Memory and self.data != null) {
            return self.data.?;
        }

        if (!self.open) {
            self.internal = try fs.cwd().openFile(self.path, .{});
            self.open = true;
        }
        defer if (self.cache_mode != .KeepOpen) self.close();
        errdefer if (self.cache_mode == .KeepOpen) self.close();

        const size = try self.internal.getEndPos();
        var buffer = try alloc.alloc(u8, size);
        errdefer alloc.free(buffer);
        _ = try self.internal.readAll(buffer);

        if (self.cache_mode == .Memory) {
            self.data = buffer;
        }

        return buffer;
    }

    /// Force Closes the file descriptor and sets the `open` member to false
    /// Note that this will also close the file incase of .KeepOpen
    pub fn close(self: *StaticFile) void {
        if (!self.open) return;

        self.internal.close();
        self.open = false;
    }
};

pub const MimeType = enum {
    Js,
    Html,
    Png,
    Jpeg,
    Text,
    Unknown,

    /// The supported extensions
    pub const extensions = &[_][]const u8{
        ".js",
        ".html",
        ".png",
        ".jpeg",
        ".txt",
    };

    /// Returns the content-type of a MimeType
    pub fn toType(self: MimeType) []const u8 {
        return switch (self) {
            .Js => "application/javascript",
            .Html => "text/html",
            .Png => "image/png",
            .Jpeg => "image/jpeg",
            .Text, .Unknown => "text/plain",
        };
    }

    /// Returns the extension that belongs to a MimeType
    pub fn toExtension(self: MimeType) []const u8 {
        return extensions[@enumToInt(self)];
    }

    /// Returns the MimeType based on the extension
    pub fn fromExtension(extension: []const u8) MimeType {
        for (extensions) |ext, i| {
            if (std.mem.eql(u8, ext, extension)) {
                return @intToEnum(MimeType, @truncate(u3, i));
            }
        }
        return MimeType.Unknown;
    }

    /// Returns the MimeType based on the file name
    pub fn fromFileName(name: []const u8) MimeType {
        const index = std.mem.lastIndexOf(u8, name, ".") orelse return MimeType.Unknown;

        const extension = name[index..];
        return fromExtension(extension);
    }
};

test "Init Static Server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try init(&arena.allocator, "src", .Close);
}
