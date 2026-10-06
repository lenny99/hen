const std = @import("std");
const agent = @import("agent");
const provider = @import("provider");
const http = @import("http");
const ztf = @import("zig_test_framework");

const OpencodeProvider = provider.OpencodeProvider;

test "opencode provider initializes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    const token = provider.Secret{ .name = "opencode", .value = "test-token" };
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);
}

const MockServer = struct {
    const net = std.Io.net;
    const LOCALHOST = "127.0.0.1";
    const Request = struct { headers: []const []const u8, body: ?[]const u8 };

    server: net.Server,
    recorder: std.ArrayList(Request),
    responses: std.Deque([]const u8),

    worker: ?std.Io.Future(anyerror!void),

    fn init(io: std.Io) !MockServer {
        const addr = try net.IpAddress.parseIp4(LOCALHOST, 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{
            .server = server,
            .recorder = .empty,
            .responses = .empty,
            .worker = null,
        };
    }

    fn deinit(self: *MockServer, io: std.Io, allocator: std.mem.Allocator) void {
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

    fn port(self: *MockServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn spawn(self: *MockServer, io: std.Io, allocator: std.mem.Allocator) !void {
        self.worker = try io.concurrent(serve, .{ self, io, allocator });
    }

    /// Wait for the worker and report its error, if any.
    fn await(self: *MockServer, io: std.Io) !void {
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
                const raw = try reader.interface.takeDelimiterExclusive('\n');
                const line = std.mem.trimEnd(u8, raw, "\r");
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

const UUID = agent.Session.Id.fromBytes(.{
    0x01, 0x02, 0x03, 0x04,
    0x05, 0x06, 0x07, 0x08,
    0x09, 0x0a, 0x0b, 0x0c,
    0x0d, 0x0e, 0x0f, 0x10,
});

test "provider streams the reply from the wire" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var server = try MockServer.init(io);
    defer server.deinit(io, std.testing.allocator);
    try server.responses.pushBack(std.testing.allocator, "data: {\"assistant\":{\"content\":\"hello from fake wire\"}}\n\n");
    try server.spawn(io, std.testing.allocator);

    const token = provider.Secret{ .name = "opencode", .value = "test-token" };
    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    opencode.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(agent.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools: [0]agent.Tool = .{};

    var stream = try opencode.stream(io, "opencode/glm-5.3", "You are a helpful agent", messages.items, &tools, UUID);

    const reply = (try stream.next(io)) orelse return error.MissingReply;
    try std.testing.expectEqualStrings("{\"assistant\":{\"content\":\"hello from fake wire\"}}\n", reply.assistant.content);
    try std.testing.expectEqual(@as(?agent.Message, null), try stream.next(io));

    try server.await(io);
    try std.testing.expectEqual(@as(usize, 1), server.recorder.items.len);
}

test "opencode parses a text delta event" {
    const frame =
        "{\"type\":\"response.output_text.delta\",\"sequence_number\":4," ++
        "\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0," ++
        "\"delta\":\"hello\"}\n";

    var parsed = try provider.openai.parse(std.testing.allocator, frame);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", parsed.value.textDelta().?);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.doneText());
    try std.testing.expect(!parsed.value.isFinal());
}

test "opencode parses a completed event" {
    const frame =
        "{\"type\":\"response.completed\",\"sequence_number\":9," ++
        "\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-6-astra\",\"status\":\"completed\"," ++
        "\"usage\":{\"input_tokens\":3,\"output_tokens\":1,\"total_tokens\":4}}}\n";

    var parsed = try provider.openai.parse(std.testing.allocator, frame);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.isFinal());
    try std.testing.expectEqualStrings("gpt-6-astra", parsed.value.response.?.model.?);
    try std.testing.expectEqual(@as(?u64, 4), parsed.value.response.?.usage.?.total_tokens);
}

test "opencode parses an error event" {
    const frame =
        "{\"type\":\"error\",\"code\":\"server_error\",\"message\":\"boom\"," ++
        "\"param\":null,\"sequence_number\":2}\n";

    var parsed = try provider.openai.parse(std.testing.allocator, frame);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("boom", parsed.value.errorMessage().?);
    try std.testing.expect(parsed.value.isFinal());
}
