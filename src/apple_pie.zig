pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const server = @import("server.zig");
pub const Server = server.Server;
pub const RequestHandler = server.RequestHandler;
pub const FileServer = @import("fs.zig").FileServer;
pub const MimeType = @import("mime_type.zig");
pub const Template = @import("template.zig").Template;
pub const router = @import("router.zig");

const zap = @import("zap");

/// Dispatches a pike Task on the Zap scheduler
pub fn dispatch(pike_task: *@import("pike").Task) void {
    zap.runtime.schedule(pike_task);
}

pub const task = zap.runtime.executor.Task;
