const std = @import("std");
const agent = @import("agent");
const ztf = @import("zig_test_framework");

/// `ztf.expect` asks for an allocator, but it never uses it. The matchers only
/// call `std.debug.print`. Keep that argument out of the tests with this
/// helper. It still passes `std.testing.allocator`, so a leak inside the
/// framework still fails the test run.
inline fn expect(actual: anytype) @TypeOf(ztf.expect(std.testing.allocator, actual)) {
    return ztf.expect(std.testing.allocator, actual);
}

const MockProvider = struct {
    const Error = agent.Provider.Error;

    allocator: std.mem.Allocator,
    /// The framework mocks record every call to the provider functions, so the
    /// tests can count the calls.
    mocks: struct {
        stream: ztf.Mock(agent.Provider.DeltaStream),
    },
    /// The arguments of the last call. The framework mock stores call
    /// arguments as text, so the typed values go here.
    call: ?agent.Provider.SessionArgs = null,
    /// How many times the session released the stream.
    deinits: usize = 0,
    /// The deltas the stream hands out, in order. After the last one the
    /// stream ends, and `next` returns null.
    replies: std.ArrayList(agent.Delta) = .empty,

    fn init(alloc: std.mem.Allocator) MockProvider {
        return .{
            .allocator = alloc,
            .mocks = .{
                .stream = ztf.Mock(agent.Provider.DeltaStream).init(alloc),
            },
        };
    }

    fn deinit(self: *MockProvider) void {
        self.replies.deinit(self.allocator);
        self.mocks.stream.deinit();
    }

    /// Make the stream hand out these deltas, in order.
    fn returns(self: *MockProvider, replies: []const agent.Delta) !void {
        self.replies.clearRetainingCapacity();
        try self.replies.appendSlice(self.allocator, replies);
    }

    fn supplyNext(impl: *anyopaque, _: std.Io) agent.Provider.DeltaStream.Error!?agent.Delta {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        if (self.replies.items.len == 0) return null;
        return self.replies.orderedRemove(0);
    }

    fn supplyDeinit(impl: *anyopaque, _: std.Io) void {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.deinits += 1;
    }

    fn stream(impl: *anyopaque, args: agent.Provider.SessionArgs) Error!agent.Provider.DeltaStream {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.call = args;
        self.mocks.stream.recordCall("stream") catch return error.Canceled;
        return .{ .impl = self, .next_fn = supplyNext, .deinit_fn = supplyDeinit };
    }

    fn asProvider(self: *MockProvider, alloc: std.mem.Allocator) !*const agent.Provider {
        const ref = try alloc.create(agent.Provider);
        ref.* = agent.Provider.init(self, stream);
        return ref;
    }
};

const Fixture = struct {
    /// One fixed id that every test uses.
    const id = agent.Session.Id.fromBytes(.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10,
    });

    mock: MockProvider,
    provider: *const agent.Provider,
    session: agent.Session,

    /// Fill in the fields. Do not return a Fixture by value. The provider
    /// points at the mock, and a returned value leaves that pointer on a copy.
    fn init(self: *Fixture, alloc: std.mem.Allocator) !void {
        self.mock = MockProvider.init(alloc);
        errdefer self.mock.deinit();
        self.provider = try self.mock.asProvider(alloc);
        errdefer alloc.destroy(self.provider);
        self.session = try agent.Session.init(id, self.provider);
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
