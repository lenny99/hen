const std = @import("std");
const instance = @import("instance");
const provider = @import("provider");
const http = @import("http");
const ztf = @import("zig_test_framework");

const OpencodeProvider = provider.OpencodeProvider;
const openai = provider.openai;

test "opencode provider initializes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
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

const UUID = instance.Session.Id.fromBytes(.{
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
    const stream_body =
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"content\":\"hello from fake wire\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try server.responses.pushBack(std.testing.allocator, stream_body);
    try server.spawn(io, std.testing.allocator);

    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    opencode.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try opencode.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = UUID,
    });
    defer stream.deinit(io);

    const reply = (try stream.next(io)) orelse return error.MissingReply;

    const end = (try stream.next(io)) orelse return error.MissingReply;
    switch (end) {
        .lifecycle => |lifecycle| try std.testing.expectEqual(instance.Lifecycle.Status.completed, lifecycle.kind),
        else => return error.UnexpectedDelta,
    }

    try std.testing.expectEqual(@as(?instance.Delta, null), try stream.next(io));

    try std.testing.expectEqualStrings("hello from fake wire", reply.delta);

    try server.await(io);
    try std.testing.expectEqual(@as(usize, 1), server.recorder.items.len);
}

test "that 'x-opencode-session' get sent to endpoint" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var server = try MockServer.init(io);
    defer server.deinit(io, std.testing.allocator);
    const stream_body =
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"content\":\"hello from fake wire\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try server.responses.pushBack(std.testing.allocator, stream_body);
    try server.spawn(io, std.testing.allocator);
    
    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    opencode.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try opencode.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = UUID,
    });
    defer stream.deinit(io);

    try server.await(io);

    const initial_request = server.recorder.items[0];

    const expected_headers = [_][]const u8{
        "content-type: application/json",
        "authorization: Bearer test-token",
        "x-opencode-session: 01020304-0506-0708-090a-0b0c0d0e0f10",
    };
    for (expected_headers) |expected| {
        var found = false;
        for (initial_request.headers) |header| {
            if (std.mem.eql(u8, header, expected)) found = true;
        }
        try std.testing.expect(found);
    }

}

test "the request carries the one action tool" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var server = try MockServer.init(io);
    defer server.deinit(io, std.testing.allocator);
    const stream_body =
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"content\":\"hello from fake wire\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try server.responses.pushBack(std.testing.allocator, stream_body);
    try server.spawn(io, std.testing.allocator);

    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    opencode.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools = [_]instance.ToolDef{.{ .name = "hen-eval", .description = "Run one Scheme expression." }};

    var stream = try opencode.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = UUID,
    });
    defer stream.deinit(io);

    try server.await(io);

    const body = server.recorder.items[0].body orelse return error.MissingBody;
    const create = try std.json.parseFromSliceLeaky(openai.Create, gpa, body, .{ .ignore_unknown_fields = true });

    const carried = create.tools orelse return error.MissingTools;
    try std.testing.expectEqual(@as(usize, 1), carried.len);
    try std.testing.expectEqualStrings("hen-eval", carried[0].function.name);
    try std.testing.expectEqualStrings("Run one Scheme expression.", carried[0].function.description);

    const parameters = carried[0].function.parameters;
    try std.testing.expect(std.meta.activeTag(parameters) == .object);
    const properties = parameters.object.get("properties") orelse return error.MissingProperties;
    const source = properties.object.get("source") orelse return error.MissingSource;
    try std.testing.expectEqualStrings("string", source.object.get("type").?.string);
    const required = parameters.object.get("required") orelse return error.MissingRequired;
    var contains_source = false;
    for (required.array.items) |item| {
        if (std.meta.activeTag(item) == .string and std.mem.eql(u8, item.string, "source")) contains_source = true;
    }
    try std.testing.expect(contains_source);

    for ([_][]const u8{ "\"tools\":null", "\"tool_calls\":null", "\"tool_call_id\":null", "\"tool_choice\":null" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, body, absent) == null);
    }
}

test "the conversation mapping emits assistant tool calls and tool messages" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var server = try MockServer.init(io);
    defer server.deinit(io, std.testing.allocator);
    const stream_body =
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"content\":\"hello from fake wire\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try server.responses.pushBack(std.testing.allocator, stream_body);
    try server.spawn(io, std.testing.allocator);

    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    opencode.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Evaluate the sum." } });
    try messages.append(gpa, .{ .assistant = .{
        .content = "",
        .tool_calls = &.{.{ .id = "call_1", .name = "hen-eval", .arguments = "(+ 1 2)" }},
    } });
    try messages.append(gpa, .{ .tool = .{ .id = "call_1", .content = "3" } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try opencode.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = UUID,
    });
    defer stream.deinit(io);

    try server.await(io);

    const body = server.recorder.items[0].body orelse return error.MissingBody;
    const create = try std.json.parseFromSliceLeaky(openai.Create, gpa, body, .{ .ignore_unknown_fields = true });

    try std.testing.expectEqual(@as(usize, 4), create.messages.len);
    try std.testing.expectEqual(openai.Role.system, create.messages[0].role);
    try std.testing.expectEqual(openai.Role.user, create.messages[1].role);

    const assistant = create.messages[2];
    try std.testing.expectEqual(openai.Role.assistant, assistant.role);
    const calls = assistant.tool_calls orelse return error.MissingToolCalls;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("function", calls[0].type);
    try std.testing.expectEqualStrings("hen-eval", calls[0].function.name);
    try std.testing.expectEqualStrings("(+ 1 2)", calls[0].function.arguments);

    const tool = create.messages[3];
    try std.testing.expectEqual(openai.Role.tool, tool.role);
    try std.testing.expectEqualStrings("3", tool.content);
    const tool_call_id = tool.tool_call_id orelse return error.MissingToolCallId;
    try std.testing.expectEqualStrings("call_1", tool_call_id);
}

test "the generator assembles tool call fragments by index and ends the turn as an action round" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var server = try MockServer.init(io);
    defer server.deinit(io, std.testing.allocator);
    const stream_body =
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\"," ++
        "\"function\":{\"name\":\"hen-\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"eval\"," ++
        "\"arguments\":\"(+ \"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1 2)\"}}]}," ++
        "\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0," ++
        "\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try server.responses.pushBack(std.testing.allocator, stream_body);
    try server.spawn(io, std.testing.allocator);

    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    opencode.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Evaluate the sum." } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try opencode.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = UUID,
    });
    defer stream.deinit(io);

    const invocation = (try stream.next(io)) orelse return error.MissingInvocation;
    switch (invocation) {
        .tool_invocation => |call| {
            try std.testing.expectEqualStrings("call_1", call.id);
            try std.testing.expectEqualStrings("hen-eval", call.name);
            try std.testing.expectEqualStrings("(+ 1 2)", call.arguments);
        },
        else => return error.UnexpectedDelta,
    }

    const end = (try stream.next(io)) orelse return error.MissingReply;
    switch (end) {
        .lifecycle => |lifecycle| try std.testing.expectEqual(instance.Lifecycle.Status.completed, lifecycle.kind),
        else => return error.UnexpectedDelta,
    }

    try std.testing.expectEqual(@as(?instance.Delta, null), try stream.next(io));

    try server.await(io);
}
