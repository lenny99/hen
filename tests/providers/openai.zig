const std = @import("std");
const provider = @import("provider");

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
