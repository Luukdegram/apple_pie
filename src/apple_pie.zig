pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const FileServer = @import("fs.zig").FileServer;
pub const MimeType = @import("mime_type.zig");
pub const Template = @import("template.zig").Template;
pub const router = @import("router.zig");
pub usingnamespace @import("server.zig");

const zap = @import("zap");

/// Dispatches a pike Task on the Zap scheduler
pub inline fn dispatch(batchable: anytype, args: anytype) void {
    zap.runtime.schedule(batchable, args);
}

pub const task = zap.runtime.executor.Task;
pub const batch = zap.runtime.executor.Batch;

comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
