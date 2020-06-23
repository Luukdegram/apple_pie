const std = @import("std");

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
