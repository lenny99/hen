const std = @import("std");
const instance = @import("instance");

pub const MockServer = struct {
    const net = std.Io.net;
    const LOCALHOST = "127.0.0.1";
    const Request = struct { headers: []const []const u8, body: ?[]const u8 };

    server: net.Server,
    recorder: std.ArrayList(Request),
    responses: std.Deque([]const u8),

    worker: ?std.Io.Future(anyerror!void),

    pub fn init(io: std.Io) !MockServer {
        const addr = try net.IpAddress.parseIp4(LOCALHOST, 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{
            .server = server,
            .recorder = .empty,
            .responses = .empty,
            .worker = null,
        };
    }

    pub fn deinit(self: *MockServer, io: std.Io, allocator: std.mem.Allocator) void {
        self.await(io) catch |err| std.log.err("mock server failed: {t}", .{err});
        self.server.deinit(io);
        for (self.recorder.items) |request| {
            for (request.headers) |header| allocator.free(header);
            allocator.free(request.headers);
            if (request.body) |body| allocator.free(body);
        }
        self.recorder.deinit(allocator);
        self.responses.deinit(allocator);
    }

    pub fn port(self: *MockServer) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn spawn(self: *MockServer, io: std.Io, allocator: std.mem.Allocator) !void {
        self.worker = try io.concurrent(serve, .{ self, io, allocator });
    }

    /// Wait for the worker and report its error, if any.
    pub fn await(self: *MockServer, io: std.Io) !void {
        const worker = if (self.worker) |*worker| worker else return;
        const result = worker.await(io);
        self.worker = null;
        return result;
    }

    fn serve(self: *MockServer, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
        const connection = try self.server.accept(io);
        defer connection.close(io);

        { // Request
            var buffer: [4096]u8 = undefined;
            var reader = connection.reader(io, &buffer);

            var content_length: usize = 0;

            var headers: std.ArrayList([]const u8) = .empty;
            while (true) {
                const LENGTH_HEADER = "content-length:";
                const raw = try reader.interface.takeDelimiterInclusive('\n');
                const line = std.mem.trimEnd(u8, raw, "\r\n");
                if (line.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(line, LENGTH_HEADER)) {
                    const value = std.mem.trim(u8, line[LENGTH_HEADER.len..], " ");
                    content_length = try std.fmt.parseInt(usize, value, 10);
                }
                try headers.append(allocator, try allocator.dupe(u8, line));
            }

            var body: ?[]const u8 = null;
            if (content_length > 0) {
                const body_buffer = try allocator.alloc(u8, content_length);
                try reader.interface.readSliceAll(body_buffer);
                body = body_buffer;
            }
            try self.recorder.append(allocator, .{ .headers = try headers.toOwnedSlice(allocator), .body = body });
        }
        { // Response
            var buffer: [4096]u8 = undefined;
            var writer = connection.writer(io, &buffer);

            if (self.responses.popFront()) |response| {
                try writer.interface.print("HTTP/1.1 200 OK\r\n", .{});
                try writer.interface.print("content-type: text/event-stream\r\n", .{});
                try writer.interface.print("content-length: {d}\r\n", .{response.len});
                try writer.interface.print("connection: close\r\n", .{});
                try writer.interface.print("\r\n", .{});
                try writer.interface.writeAll(response);
            } else {
                try writer.interface.print("HTTP/1.1 404 NOT_FOUND\r\n", .{});
            }
            try writer.interface.flush();
        }
    }
};

pub const UUID = instance.Session.Id.fromBytes(.{
    0x01, 0x02, 0x03, 0x04,
    0x05, 0x06, 0x07, 0x08,
    0x09, 0x0a, 0x0b, 0x0c,
    0x0d, 0x0e, 0x0f, 0x10,
});
