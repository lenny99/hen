const std = @import("std");
const instance = @import("instance");
const provider = @import("provider");
const http = @import("http");
const ztf = @import("zig_test_framework");
const mock_server = @import("mock_server.zig");

const OpencodeProvider = provider.OpencodeProvider;
const OpenAIProvider = provider.OpenAIProvider;
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

test "that 'x-opencode-session' get sent to endpoint" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var server = try mock_server.MockServer.init(io);
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

    opencode.impl.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try opencode.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = mock_server.UUID,
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

test "opencode provider defaults to the zen endpoints" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    const token = instance.Secret{ .name = "opencode", .value = "test-token" };
    var opencode = try OpencodeProvider.init(gpa, &transport, &token);
    defer opencode.deinit(gpa);

    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/models", opencode.impl.endpoints.models);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", opencode.impl.endpoints.go);
}
