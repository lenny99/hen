const std = @import("std");
const instance = @import("instance");
const ztf = @import("zig_test_framework");

/// `ztf.expect` asks for an allocator, but it never uses it. The matchers only
/// call `std.debug.print`. Keep that argument out of the tests with this
/// helper. It still passes `std.testing.allocator`, so a leak inside the
/// framework still fails the test run.
inline fn expect(actual: anytype) @TypeOf(ztf.expect(std.testing.allocator, actual)) {
    return ztf.expect(std.testing.allocator, actual);
}

const MockProvider = struct {
    const Error = instance.Provider.Error;

    allocator: std.mem.Allocator,
    /// The framework mocks record every call to the provider functions, so the
    /// tests can count the calls.
    mocks: struct {
        stream: ztf.Mock(instance.Provider.DeltaStream),
    },
    /// The arguments of the last call. The framework mock stores call
    /// arguments as text, so the typed values go here.
    call: ?instance.Provider.SessionArgs = null,
    /// How many times the session released the stream.
    deinits: usize = 0,
    /// The deltas the stream hands out, in order. After the last one the
    /// stream ends, and `next` returns null.
    replies: std.ArrayList(instance.Delta) = .empty,
    /// Multi-round mode: stream call n gets `rounds[n]`, the last one repeats.
    rounds: std.ArrayList(std.ArrayList(instance.Delta)) = .empty,
    queue_index: usize = 0,
    calls: usize = 0,
    active: ?*std.ArrayList(instance.Delta) = null,

    fn init(alloc: std.mem.Allocator) MockProvider {
        return .{
            .allocator = alloc,
            .mocks = .{
                .stream = ztf.Mock(instance.Provider.DeltaStream).init(alloc),
            },
        };
    }

    fn deinit(self: *MockProvider) void {
        for (self.rounds.items) |*list| list.deinit(self.allocator);
        self.rounds.deinit(self.allocator);
        self.replies.deinit(self.allocator);
        self.mocks.stream.deinit();
    }

    /// Make the stream hand out these deltas, in order.
    fn returns(self: *MockProvider, replies: []const instance.Delta) !void {
        self.replies.clearRetainingCapacity();
        try self.replies.appendSlice(self.allocator, replies);
    }

    /// Queue the replies of each round: stream call n gets round n, the
    /// last round repeats.
    fn queue(self: *MockProvider, alloc: std.mem.Allocator, rounds: []const []const instance.Delta) !void {
        self.calls = rounds.len;
        for (rounds) |round| {
            var list: std.ArrayList(instance.Delta) = .empty;
            try list.appendSlice(self.allocator, round);
            try self.rounds.append(alloc, list);
        }
    }

    fn supplyNext(impl: *anyopaque, _: std.Io) instance.Provider.DeltaStream.Error!?instance.Delta {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        const list = self.active orelse &self.replies;
        if (list.items.len == 0) return null;
        return list.orderedRemove(0);
    }

    fn supplyDeinit(impl: *anyopaque, _: std.Io) void {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.deinits += 1;
    }

    fn stream(impl: *anyopaque, args: instance.Provider.SessionArgs) Error!instance.Provider.DeltaStream {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.call = args;
        if (self.rounds.items.len > 0) {
            if (self.queue_index >= self.rounds.items.len) self.queue_index = self.rounds.items.len - 1;
            self.active = &self.rounds.items[self.queue_index];
            self.queue_index += 1;
        }
        self.mocks.stream.recordCall("stream") catch return error.Canceled;
        return .{ .impl = self, .next_fn = supplyNext, .deinit_fn = supplyDeinit };
    }

    fn asProvider(self: *MockProvider, alloc: std.mem.Allocator) !*const instance.Provider {
        const ref = try alloc.create(instance.Provider);
        ref.* = instance.Provider.init(self, stream);
        return ref;
    }
};

const Fixture = struct {
    /// One fixed id that every test uses.
    const id = instance.Session.Id.fromBytes(.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10,
    });

    mock: MockProvider,
    provider: *const instance.Provider,
    session: instance.Session,

    /// Fill in the fields. Do not return a Fixture by value. The provider
    /// points at the mock, and a returned value leaves that pointer on a copy.
    fn init(self: *Fixture, alloc: std.mem.Allocator) !void {
        self.mock = MockProvider.init(alloc);
        errdefer self.mock.deinit();
        self.provider = try self.mock.asProvider(alloc);
        errdefer alloc.destroy(self.provider);
        self.session = try instance.Session.init(id, self.provider);
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        self.session.deinit(alloc);
        alloc.destroy(self.provider);
        self.mock.deinit();
    }
};

test "session initializes" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit(std.testing.allocator);
    const session = &f.session;

    try expect(session.messages.items).toBeEmpty();
    try expect(Fixture.id).toEqual(session.id);
}

test "message added to the session is present in the history" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.appendMessage(alloc, "Hello, Agent!");

    try expect(session.messages.items).toHaveLength(1);
    try expect(session.messages.items[0].user.content).toEqual("Hello, Agent!");
}

test "run calls the provider once per run" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc);

    try f.mock.mocks.stream.toHaveBeenCalledTimes(1);
    const call = f.mock.call.?;
    try expect(call.session).toEqual(Fixture.id);
    try expect(call.model).toEqual(session.model.id());
    try expect(call.system).toEqual(session.system);
}

test "run hands the provider the whole history in order" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.appendMessage(alloc, "first");
    try session.appendMessage(alloc, "second");
    try session.run(std.testing.io, alloc);

    try f.mock.mocks.stream.toHaveBeenCalledTimes(1);
    const call = f.mock.call.?;
    try expect(call.messages).toHaveLength(2);
    try expect(call.messages[0].user.content).toEqual("first");
    try expect(call.messages[1].user.content).toEqual("second");
    try expect(call.tools).toBeEmpty();
}

test "run folds the streamed deltas into one assistant message" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "Hi!" },
        .{ .delta = " How can" },
        .{ .delta = " I help?" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc);

    try expect(session.messages.items).toHaveLength(2);
    try expect(session.messages.items[1].assistant.content).toEqual("Hi! How can I help?");
}

test "a done delta replaces the deltas before it" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "partial" },
        .{ .done = "the complete answer" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc);

    try expect(session.messages.items[1].assistant.content).toEqual("the complete answer");
}

test "a completed lifecycle still commits the message" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "done." },
        .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc);

    try expect(session.messages.items).toHaveLength(2);
}

test "a tool call does not become part of the assistant text" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "let me check " },
        .{ .tool_invocation = .{ .id = "call_1", .name = "weather", .arguments = "{}" } },
        .{ .done = "let me check the weather." },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc);

    try expect(session.messages.items[1].assistant.content).toEqual("let me check the weather.");
}

test "an error delta leaves the history unchanged and releases the stream" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "partial" },
        .{ .@"error" = "boom" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try std.testing.expectError(error.ProviderFailed, session.run(std.testing.io, alloc));

    try expect(session.messages.items).toHaveLength(1);
    try std.testing.expectEqual(@as(usize, 1), f.mock.deinits);
}

test "a failed lifecycle leaves the history unchanged" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .lifecycle = .{ .id = "resp_1", .kind = .failed } },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try std.testing.expectError(error.ResponseFailed, session.run(std.testing.io, alloc));

    try expect(session.messages.items).toHaveLength(1);
}

test "the stream is released after a completed turn" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "hi" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 1), f.mock.deinits);
}

const MockEnvironment = struct {
    calls: usize = 0,
    last_name: []const u8 = "",
    last_arguments: []const u8 = "",
    fail: bool = false,

    fn callFn(impl: *anyopaque, _: std.Io, alloc: std.mem.Allocator, name: []const u8, arguments: []const u8) instance.Environment.CallError![]u8 {
        const self: *MockEnvironment = @ptrCast(@alignCast(impl));
        self.calls += 1;
        self.last_name = name;
        alloc.free(self.last_arguments);
        self.last_arguments = try alloc.dupe(u8, arguments);
        if (self.fail) return error.Failed;
        return try alloc.dupe(u8, "observation text");
    }

    fn deinit(self: *MockEnvironment, alloc: std.mem.Allocator) void {
        alloc.free(self.last_arguments);
    }

    fn asEnvironment(self: *MockEnvironment) instance.Environment {
        return .{ .impl = self, .call_fn = callFn };
    }
};

test "the request loop runs each action round until a text-only answer" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "weather", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 1), env.calls);
    try std.testing.expectEqualStrings("weather", env.last_name);
    try std.testing.expectEqual(@as(usize, 4), session.messages.items.len);
    const carried = session.messages.items[1].assistant;
    try std.testing.expectEqual(@as(usize, 1), carried.tool_calls.len);
    try std.testing.expectEqualStrings("weather", carried.tool_calls[0].name);
    const observation = session.messages.items[2].tool;
    try std.testing.expectEqualStrings("call_1", observation.id);
    try std.testing.expectEqualStrings("observation text", observation.content);
    try std.testing.expectEqualStrings("All done.", session.messages.items[3].assistant.content);
}

test "a failed action becomes an observation" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{ .fail = true };
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "weather", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "Handled." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqualStrings("Error: Failed", session.messages.items[2].tool.content);
}

test "the session asks for a final answer when the round budget is spent" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;
    session.max_rounds = 1;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "weather", .arguments = "{}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "final answer" }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 2), f.mock.calls);
    try expect(f.mock.call.?.tools).toBeEmpty();
    try expect(session.messages.items[3].user.content).toEqual(instance.Session.final_answer_prompt);
    try expect(session.messages.items[4].assistant.content).toEqual("final answer");
}

test "run hands the provider the one action tool" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "hen-eval", .arguments = "(+ 1 2)" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 2), f.mock.calls);
    const call = f.mock.call.?;
    try expect(call.tools).toHaveLength(1);
    try expect(call.tools[0].name).toEqual(instance.Session.action_tool_name);
    try std.testing.expect(call.tools[0].description.len > 0);
    try std.testing.expect(instance.Session.action_tool_description.len <= 240);

    try std.testing.expectEqual(@as(usize, 4), session.messages.items.len);
    const observation = session.messages.items[2].tool;
    try std.testing.expectEqualStrings("call_1", observation.id);
    try std.testing.expectEqualStrings("hen-eval", observation.name);
    try std.testing.expectEqualStrings("observation text", observation.content);
}

test "an envelope argument hands the environment the decoded source" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "hen-eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 1), env.calls);
    try std.testing.expectEqualStrings("(+ 1 2)", env.last_arguments);
    try std.testing.expectEqualStrings("observation text", session.messages.items[2].tool.content);
}

test "a raw argument reaches the environment unchanged" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "hen-eval", .arguments = "(+ 1 2)" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 1), env.calls);
    try std.testing.expectEqualStrings("(+ 1 2)", env.last_arguments);
    try std.testing.expectEqualStrings("observation text", session.messages.items[2].tool.content);
}

test "an object argument without source yields an error observation without a call" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "hen-eval", .arguments = "{}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 0), env.calls);
    try std.testing.expectEqualStrings("Error: tool call arguments missing source", session.messages.items[2].tool.content);
}

test "a non-string source yields an error observation without a call" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var env = MockEnvironment{};
    const env_holder = env.asEnvironment();
    session.environment = &env_holder;
    defer env.deinit(alloc);

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "hen-eval", .arguments = "{\"source\": 42}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    try std.testing.expectEqual(@as(usize, 0), env.calls);
    try std.testing.expectEqualStrings("Error: tool call arguments source is not a string", session.messages.items[2].tool.content);
}

test "the assistant message keeps the raw arguments the model sent" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "hen-eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc);

    const carried = session.messages.items[1].assistant;
    try std.testing.expectEqual(@as(usize, 1), carried.tool_calls.len);
    try std.testing.expectEqualStrings("{\"source\": \"(+ 1 2)\"}", carried.tool_calls[0].arguments);
}
