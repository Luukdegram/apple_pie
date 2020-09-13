const std = @import("std");

pub const MimeType = enum {
    js,
    html,
    png,
    jpeg,
    text,
    unknown,

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
            .js => "application/javascript",
            .html => "text/html",
            .png => "image/png",
            .jpeg => "image/jpeg",
            .text, .unknown => "text/plain",
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
                return @intToEnum(MimeType, @intCast(u3, i));
            }
        }
        return .unknown;
    }

    /// Returns the MimeType based on the file name
    pub fn fromFileName(name: []const u8) MimeType {
        const index = std.mem.lastIndexOf(u8, name, ".") orelse return .unknown;

        const extension = name[index..];
        return fromExtension(extension);
    }
};
