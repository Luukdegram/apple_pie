const std = @import("std");

const mime_database = @import("mime_db.zig").mime_database;

pub const MimeType = struct {
    const Self = @This();

    text: []const u8,

    /// Returns the content-type of a MimeType
    pub fn toString(self: MimeType) []const u8 {
        return self.text;
    }

    /// Returns the extension that belongs to a MimeType
    pub fn toExtension(self: MimeType) ?[]const u8 {
        for (mime_database) |mapping| {
            if (std.mem.eql(u8, mapping.mime_type, self.text)) {
                return mapping.mime_type;
            }
        }
        return null;
    }

    /// Returns the MimeType based on the extension
    pub fn fromExtension(ext: []const u8) Self {
        for (mime_database) |mapping| {
            if (std.mem.eql(u8, mapping.extension, ext)) {
                return MimeType{ .text = mapping.mime_type };
            }
        }
        return MimeType{ .text = "text/plain;charset=UTF-8" };
    }

    /// Returns the MimeType based on the file name
    pub fn fromFileName(name: []const u8) MimeType {
        return fromExtension(std.fs.path.extension(name));
    }
};
