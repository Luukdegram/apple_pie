const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const RequestHandler = @import("server.zig").RequestHandler;

/// Threadsafe hashmap that contains `StaticFile`s by its name
const FileCache = struct {
    map: std.StringHashMap(StaticFile),
    mutex: *std.Mutex,
    allocator: *Allocator,
    base_path: []const u8,

    pub fn get(self: FileCache, path: []const u8) ?StaticFile {
        var lock = self.mutex.acquire();
        defer lock.release();

        return self.map.getValue(path);
    }

    pub fn put(self: *FileCache, file: StaticFile) !void {
        var lock = self.mutex.acquire();
        defer lock.release();
        _ = try self.map.put(file.name, file);
    }

    pub fn has(self: FileCache, path: []const u8) bool {
        var lock = self.mutex.acquire();
        defer lock.release();

        return self.map.contains(path);
    }

    /// Frees all memory of the file cache
    /// This function is not threadsafe as it destroys itself and shouldn't be called afterwards
    pub fn deinit(self: *FileCache) void {
        self.mutex.deinit();

        for (self.map.entries) |entry| {
            const file = entry.kv.value;
            self.allocator.free(file.path);
            self.allocator.free(file.name);
        }
        self.map.deinit();
        self.* = undefined;
    }
};

var cache_mutex = std.Mutex.init();

pub const StaticFileServer = struct {
    var file_cache: FileCache = undefined;
    var allocator: *Allocator = undefined;

    /// Creates a new static file server handler
    /// Memory is owned by the cache or, incase of an ArenaAllocator, the caller.
    /// Clearing the memory using the cache can be done calling `file_cache.deinit()` which is a
    /// public struct of this file.
    pub fn init(alloc: *Allocator, path: []const u8) !StaticFileServer {
        file_cache = FileCache{
            .map = std.StringHashMap(StaticFile).init(alloc),
            .mutex = &cache_mutex,
            .allocator = alloc,
            .base_path = path,
        };

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

            try file_cache.put(StaticFile.init(name, file_path));
        }

        return StaticFileServer{};
    }

    pub fn deinit(server: StaticFileServer) void {
        file_cache.deinit();
    }

    /// The handler function that will be called each request.
    /// Make sure to call init() before using this function.
    pub fn handle(response: *Response, request: Request) callconv(.Async) void {
        var file: ?std.fs.File = null;
        var static_file: StaticFile = undefined;
        var cache_allocator = allocator;

        std.debug.warn("Handle called\n", .{});

        if (file_cache.get(request.url.path[1..])) |f| {
            static_file = f;
            file = std.fs.cwd().openFile(f.path, .{}) catch |err| {
                std.debug.warn("Error opening file: {}\n", .{err});
                sendNotFound(response);
                return;
            };
        } else {
            var full_path = std.fs.path.join(cache_allocator, &[_][]const u8{
                file_cache.base_path,
                request.url.path,
            }) catch {
                sendNotFound(response);
                return;
            };

            var possible_file = findFile(full_path) catch {
                cache_allocator.free(full_path);
            };

            if (possible_file) |f| {
                file = f;

                const name = cache_allocator.dupe(u8, request.url.path) catch {
                    cache_allocator.free(full_path);
                    f.close();
                    sendNotFound(response);
                    return;
                };

                static_file = StaticFile.init(name, full_path);
                file_cache.put(static_file) catch {
                    cache_allocator.free(full_path);
                    cache_allocator.free(name);
                    f.close();
                    sendNotFound(response);
                    return;
                };
            }
        }

        if (file) |f| {
            defer f.close();

            const size = f.getEndPos() catch return;
            var buffer = cache_allocator.alloc(u8, size) catch {
                sendNotFound(response);
                return;
            };
            defer cache_allocator.free(buffer);
            _ = f.inStream().read(buffer) catch |err| {
                std.debug.warn("Error reading from the file: {}\n", .{err});
                sendNotFound(response);
                return;
            };

            // static_file is set if file is also not null
            _ = response.headers.put("Content-Type", static_file.mime_type.toType()) catch {
                sendNotFound(response);
                return;
            };

            response.write(buffer) catch {
                sendNotFound(response);
            };
        } else {
            sendNotFound(response);
        }
    }
};

fn sendNotFound(response: *Response) void {
    response.status_code = 404;
    response.write("Resource not found") catch {
        return;
    };
}

/// Tries to find the file on the host's system
fn findFile(path: []const u8) !?std.fs.File {
    var file = std.fs.cwd().openFile(path, .{}) catch {
        return null;
    };
    return file;

    //if file.is
}

pub const StaticFile = struct {
    path: []const u8,
    extension: []const u8,
    name: []const u8,
    mime_type: MimeType,

    /// Creates a `StaticFile` from the name and its path,
    /// it determines its extension and `MimeType`.
    /// If no extension is found, this is an empty slice,
    /// and the `mimeType` will be set to .Unknown
    pub fn init(name: []const u8, path: []const u8) StaticFile {
        const extension = blk: {
            var ext: []const u8 = undefined;
            if (std.mem.indexOf(u8, path, ".")) |index| {
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
        };
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
};

test "Init Static Server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var handle = try StaticFileServer(&arena.allocator, "src");
}
