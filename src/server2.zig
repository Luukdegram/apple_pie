const pike = @import("pike");
const zap = @import("zap");
const std = @import("std");
const net = std.net;
const log = std.log.scoped(.apple_pie);
const req = @import("request.zig");
const resp = @import("response.zig");
const Request = req.Request;
const Response = resp.Response;
const os = std.os;

const Clients = std.atomic.Queue(*Client);
pub const RequestHandler = fn handle(*Response, Request) anyerror!void;

pub const Client = struct {
    socket: pike.Socket,
    address: net.Address,

    fn run(server: *Server, notifier: *const pike.Notifier, socket: pike.Socket, address: net.Address) void {
        inlineRun(server, notifier, socket, address) catch |err| {
            log.err("Could not run client {}", .{@errorName(err)});
        };
    }

    inline fn inlineRun(
        server: *Server,
        notifier: *const pike.Notifier,
        socket: pike.Socket,
        address: net.Address,
    ) !void {
        zap.runtime.yield();

        var client = Client{ .socket = socket, .address = address };
        var node = Clients.Node{ .data = &client };

        server.clients.put(&node);
        defer if (server.clients.remove(&node)) {
            client.socket.deinit();
        };

        try client.socket.registerTo(notifier);

        var arena = std.heap.ArenaAllocator.init(server.gpa);
        defer arena.deinit();
        while (true) {
            var parsed_request = try req.parse(&arena.allocator, &client.socket, 4096);

            //create on the stack and allow the user to write to its writer
            var body = std.ArrayList(u8).init(&arena.allocator);
            var response = Response{
                .headers = resp.Headers.init(&arena.allocator),
                .socket_writer = std.io.bufferedWriter(
                    resp.SocketWriter{ .handle = &client.socket },
                ),
                .is_flushed = false,
                .body = body.writer(),
            };

            @call(.{}, server.handler, .{ &response, parsed_request }) catch |err| {
                log.err("Error sending request {}", .{@errorName(err)});
                break;
            };

            if (!response.is_flushed) try response.flush();
        }
    }
};

pub const Server = struct {
    socket: pike.Socket,
    clients: Clients,
    frame: @Frame(run),
    handler: RequestHandler,
    gpa: *std.mem.Allocator,

    pub fn init(gpa: *std.mem.Allocator, handler: RequestHandler) !Server {
        var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
        errdefer socket.deinit();

        try socket.set(.reuse_address, true);

        return Server{
            .socket = socket,
            .clients = Clients.init(),
            .frame = undefined,
            .handler = handler,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();

        await self.frame;

        while (self.clients.get()) |node| {
            node.data.socket.deinit();
        }
    }

    pub fn start(self: *Server, notifier: *const pike.Notifier, address: net.Address) !void {
        try self.socket.bind(address);
        try self.socket.listen(128);
        try self.socket.registerTo(notifier);

        self.frame = async self.run(notifier);
    }

    fn run(self: *Server, notifier: *const pike.Notifier) callconv(.Async) void {
        while (true) {
            var conn = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening,
                error.OperationCancelled,
                => return,
                else => {
                    log.err("Server - socket.accept(): {}", .{@errorName(err)});
                    continue;
                },
            };

            zap.runtime.spawn(.{}, Client.run, .{ self, notifier, conn.socket, conn.address }) catch |err| {
                log.err("Server - runtime.spawn(): {}", .{@errorName(err)});
                continue;
            };
        }
    }
};

pub fn listenAndServe(gpa: *std.mem.Allocator, handler: RequestHandler) !void {
    try pike.init();
    defer pike.deinit();

    var signal = try pike.Signal.init(.{ .interrupt = true });
    try try zap.runtime.run(.{}, serve, .{ gpa, &signal, handler });
}

fn serve(gpa: *std.mem.Allocator, signal: *pike.Signal, handler: RequestHandler) !void {
    defer signal.deinit();

    var event = try pike.Event.init();
    defer event.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    try signal.registerTo(&notifier);
    try event.registerTo(&notifier);

    var stopped = false;

    var frame = async run(&notifier, signal, &event, &stopped, handler, gpa);
    while (!stopped) {
        try notifier.poll(1_000_000);
    }

    try nosuspend await frame;

    defer log.info("Apple pie has been shutdown", .{});
}

fn run(
    notifier: *const pike.Notifier,
    signal: *pike.Signal,
    event: *pike.Event,
    stopped: *bool,
    handler: RequestHandler,
    gpa: *std.mem.Allocator,
) !void {
    defer {
        stopped.* = true;
        event.post() catch {};
    }

    var server = try Server.init(gpa, handler);
    defer server.deinit();

    try server.start(notifier, try net.Address.parseIp("0.0.0.0", 8080));
    try signal.wait();
}
