const std = @import("std");
const instance = @import("instance");
const provider = @import("provider");
const http = @import("http");
const mock_server = @import("mock_server.zig");

const OpenAIProvider = provider.OpenAIProvider;
const openai = provider.openai;

test "openai parses a text delta event" {
    const frame =
        "{\"type\":\"response.output_text.delta\",\"sequence_number\":4," ++
        "\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0," ++
        "\"delta\":\"hello\"}\n";

    var parsed = try openai.parse(std.testing.allocator, frame);
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .text_delta => |delta| try std.testing.expectEqualStrings("hello", delta),
        else => return error.UnexpectedKind,
    }
}

test "openai parses a text done event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.output_text.done\",\"text\":\"the answer\"}\n");
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .text_done => |text| try std.testing.expectEqualStrings("the answer", text),
        else => return error.UnexpectedKind,
    }
}

test "openai parses a function call arguments delta event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.function_call_arguments.delta\"," ++
        "\"arguments\":\"{\\\"city\\\":\"}\n");
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .arguments_delta => |arguments| try std.testing.expectEqualStrings("{\"city\":", arguments),
        else => return error.UnexpectedKind,
    }
}

test "openai parses a function call arguments done event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.function_call_arguments.done\"," ++
        "\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}\n");
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .arguments_done => |arguments| try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", arguments),
        else => return error.UnexpectedKind,
    }
}

test "openai parses an output item done event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"call_1\"," ++
        "\"type\":\"function_call\",\"name\":\"weather\",\"call_id\":\"c1\"," ++
        "\"arguments\":\"{}\"}}\n");
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .item => |item| {
            try std.testing.expectEqualStrings("function_call", item.type.?);
            try std.testing.expectEqualStrings("weather", item.name.?);
            try std.testing.expectEqualStrings("c1", item.call_id.?);
        },
        else => return error.UnexpectedKind,
    }
}

test "openai parses a completed event" {
    const frame =
        "{\"type\":\"response.completed\",\"sequence_number\":9," ++
        "\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-6-astra\",\"status\":\"completed\"," ++
        "\"usage\":{\"input_tokens\":3,\"output_tokens\":1,\"total_tokens\":4}}}\n";

    var parsed = try openai.parse(std.testing.allocator, frame);
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .completed => |body| {
            try std.testing.expectEqualStrings("gpt-6-astra", body.model.?);
            try std.testing.expectEqual(@as(?u64, 4), body.usage.?.total_tokens);
        },
        else => return error.UnexpectedKind,
    }
}

test "openai parses an incomplete event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.incomplete\"," ++
        "\"response\":{\"id\":\"resp_1\",\"status\":\"incomplete\"}}\n");
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .incomplete => |body| try std.testing.expectEqualStrings("incomplete", body.status.?),
        else => return error.UnexpectedKind,
    }
}

test "openai parses a failed event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.failed\",\"response\":{\"id\":\"resp_1\"," ++
        "\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}\n");
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .failed => |body| try std.testing.expectEqualStrings("boom", body.@"error".?.message),
        else => return error.UnexpectedKind,
    }
}

test "openai parses an error event" {
    const frame =
        "{\"type\":\"error\",\"code\":\"server_error\",\"message\":\"boom\"," ++
        "\"param\":null,\"sequence_number\":2}\n";

    var parsed = try openai.parse(std.testing.allocator, frame);
    defer parsed.deinit();

    switch (parsed.value.kind()) {
        .error_message => |message| try std.testing.expectEqualStrings("boom", message),
        else => return error.UnexpectedKind,
    }
}

test "openai classifies an unmodelled event" {
    var parsed = try openai.parse(std.testing.allocator,
        "{\"type\":\"response.created\",\"sequence_number\":1}\n");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.kind() == .other);
}

test "openai parses a chat completions keepalive chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const frame =
        "{\"id\":\"chatcmpl-9rXvcQMDINztJYKDFUVkav7rxxQNr\",\"object\":\"chat.completion.chunk\"," ++
        "\"created\":1791901445,\"model\":\"glm-5.3-flash\",\"choices\":[{\"index\":0," ++
        "\"finish_reason\":null,\"logprobs\":null,\"delta\":{\"role\":\"assistant\"," ++
        "\"content\":\"\",\"refusal\":null}}],\"usage\":null}\n";

    const chunk = try openai.parseChunkLeaky(arena.allocator(), frame);

    try std.testing.expectEqualStrings("chatcmpl-9rXvcQMDINztJYKDFUVkav7rxxQNr", chunk.id.?);
    try std.testing.expect(chunk.text() == null);
    try std.testing.expect(chunk.finishReason() == null);
}

test "openai parses a chat completions text chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const chunk = try openai.parseChunkLeaky(arena.allocator(),
        "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"," ++
        "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n");

    try std.testing.expectEqualStrings("hello", chunk.text().?);
    try std.testing.expect(chunk.finishReason() == null);
}

test "openai parses a chat completions finish chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const chunk = try openai.parseChunkLeaky(arena.allocator(),
        "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"," ++
        "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n");

    try std.testing.expectEqualStrings("stop", chunk.finishReason().?);
    try std.testing.expect(chunk.text() == null);
}

test "openai parses a chat completions error chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const chunk = try openai.parseChunkLeaky(arena.allocator(),
        "{\"error\":{\"message\":\"boom\",\"type\":\"server_error\",\"code\":\"server_error\"}}\n");

    try std.testing.expectEqualStrings("boom", chunk.@"error".?.message.?);
}

test "openai parses a chat completions tool call chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const chunk = try openai.parseChunkLeaky(arena.allocator(),
        "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"," ++
        "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0," ++
        "\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"hen-eval\"," ++
        "\"arguments\":\"(+ 1 2)\"}}]},\"finish_reason\":\"tool_calls\"}]}\n");

    const calls = chunk.toolCalls();
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqual(@as(?u32, 0), calls[0].index);
    try std.testing.expectEqualStrings("call_1", calls[0].id.?);
    try std.testing.expectEqualStrings("hen-eval", calls[0].function.?.name.?);
    try std.testing.expectEqualStrings("(+ 1 2)", calls[0].function.?.arguments.?);
    try std.testing.expectEqualStrings("tool_calls", chunk.finishReason().?);
}

test "Endpoints.fromBase composes model and chat completions urls" {
    const gpa = std.testing.allocator;

    const endpoints = try OpenAIProvider.Endpoints.fromBase(gpa, "http://127.0.0.1:8000/v1");
    defer gpa.free(endpoints.models);
    defer gpa.free(endpoints.go);

    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1/models", endpoints.models);
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1/chat/completions", endpoints.go);
}

test "Endpoints.fromBase trims one trailing slash" {
    const gpa = std.testing.allocator;

    const endpoints = try OpenAIProvider.Endpoints.fromBase(gpa, "http://127.0.0.1:8000/v1/");
    defer gpa.free(endpoints.models);
    defer gpa.free(endpoints.go);

    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1/models", endpoints.models);
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1/chat/completions", endpoints.go);
}

test "provider streams the reply from the wire" {
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
    var openai_provider = try OpenAIProvider.init(gpa, &transport, &token);
    defer openai_provider.deinit(gpa);

    openai_provider.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try openai_provider.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = mock_server.UUID,
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

    for (server.recorder.items[0].headers) |header| {
        try std.testing.expect(!std.ascii.startsWithIgnoreCase(header, "x-opencode-session"));
    }
}

test "the request carries the one action tool" {
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
    var openai_provider = try OpenAIProvider.init(gpa, &transport, &token);
    defer openai_provider.deinit(gpa);

    openai_provider.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Hello Agent!" } });
    const tools = [_]instance.ToolDef{.{ .name = "hen-eval", .description = "Run one Scheme expression." }};

    var stream = try openai_provider.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = mock_server.UUID,
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
    var openai_provider = try OpenAIProvider.init(gpa, &transport, &token);
    defer openai_provider.deinit(gpa);

    openai_provider.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Evaluate the sum." } });
    try messages.append(gpa, .{ .assistant = .{
        .content = "",
        .tool_calls = &.{.{ .id = "call_1", .name = "hen-eval", .arguments = "(+ 1 2)" }},
    } });
    try messages.append(gpa, .{ .tool = .{ .id = "call_1", .content = "3" } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try openai_provider.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = mock_server.UUID,
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

    var server = try mock_server.MockServer.init(io);
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
    var openai_provider = try OpenAIProvider.init(gpa, &transport, &token);
    defer openai_provider.deinit(gpa);

    openai_provider.endpoints.go = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});

    var messages: std.ArrayList(instance.Message) = .empty;
    try messages.append(gpa, .{ .user = .{ .content = "Evaluate the sum." } });
    const tools: [0]instance.ToolDef = .{};

    var stream = try openai_provider.asProvider().stream(.{
        .model = "opencode/glm-5.3",
        .system = "You are a helpful instance",
        .messages = messages.items,
        .tools = &tools,
        .session = mock_server.UUID,
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
