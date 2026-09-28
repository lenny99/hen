const std = @import("std");
const agent = @import("agent");
const ztf = @import("zig_test_framework");

const Message = agent.Message;
const MessageStream = agent.Stream(Message);

const MockProvider = struct {
    const Error = agent.Provider.Error;

    /// The framework mock records every call to `stream`.
    stream_calls: ztf.Mock(MessageStream),

    model: agent.ModelId = "",
    system: agent.SystemPrompt = "",
    session: agent.Session.Id = .nil,

    /// The framework keeps call arguments as text, so the typed history goes
    /// in these two fields.
    messages: []const Message = &.{},
    tools: []const agent.Tool = &.{},
    allocator: std.mem.Allocator,

    /// The messages the mocked stream hands out, in order. After the last
    /// one the stream ends, and `next` returns null.
    replies: std.ArrayList(Message) = .empty,

    fn init(alloc: std.mem.Allocator) MockProvider {
        return .{
            .allocator = alloc,
            .stream_calls = ztf.Mock(MessageStream).init(alloc),
        };
    }

    fn deinit(self: *MockProvider) void {
        self.replies.deinit(self.allocator);
        self.stream_calls.deinit();
    }

    fn supplyNext(impl: *anyopaque, io: std.Io) MessageStream.Error!?Message {
        _ = io;
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        if (self.replies.items.len == 0) return null;
        return self.replies.orderedRemove(0);
    }

    /// Make the stream hand out these messages, in order.
    fn returns(self: *MockProvider, messages: []const Message) !void {
        self.replies.clearRetainingCapacity();
        try self.replies.appendSlice(self.allocator, messages);
    }

    fn stream(
        impl: *anyopaque,
        _: std.Io,
        model: agent.ModelId,
        system: agent.SystemPrompt,
        messages: []const Message,
        tools: []const agent.Tool,
        session: agent.Session.Id,
    ) Error!MessageStream {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.model = model;
        self.system = system;
        self.messages = messages;
        self.tools = tools;
        self.session = session;
        self.stream_calls.recordCall("stream") catch return error.ProviderError;
        return self.stream_calls.getReturnValue() orelse MessageStream {
            .impl = self,
            .next_fn = supplyNext
        };
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

    allocator: std.mem.Allocator,
    mock: MockProvider,
    provider: *const agent.Provider,
    session: agent.Session,

    /// Fill in the fields. Do not return a Fixture by value. The provider
    /// points at the mock, and a returned value leaves that pointer on a copy.
    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.mock = MockProvider.init(allocator);
        errdefer self.mock.deinit();
        self.provider = try self.mock.asProvider(allocator);
        errdefer self.allocator.destroy(self.provider);
        self.session = try agent.Session.init(allocator, id, self.provider);
    }

    fn deinit(self: *Fixture) void {
        self.session.deinit();
        self.allocator.destroy(self.provider);
        self.mock.deinit();
    }

};

test "session initializes" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try ztf.expect(std.testing.allocator, session.messages.items).toBeEmpty();
    try ztf.expect(std.testing.allocator, Fixture.id).toEqual(session.id);
}

test "message added to the session is present in the history" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try session.appendMessage("Hello, Agent!");

    try ztf.expect(std.testing.allocator, session.messages.items).toHaveLength(1);
    try ztf.expect(std.testing.allocator, session.messages.items[0].userMessage.content).toEqual("Hello, Agent!");
}

test "run calls the provider once per run" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try session.appendMessage("Hello, Agent!");
    try session.run(std.testing.io);
    
    try f.mock.stream_calls.toHaveBeenCalledTimes(1);
    try ztf.expect(std.testing.allocator, f.mock.session).toEqual(Fixture.id);
    try ztf.expect(std.testing.allocator, f.mock.model).toEqual(session.model.id());
    try ztf.expect(std.testing.allocator, f.mock.system).toEqual(session.system);
}

test "run hands the provider the whole history in order" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try session.appendMessage("first");
    try session.appendMessage("second");
    try session.run(std.testing.io);

    try f.mock.stream_calls.toHaveBeenCalledTimes(1);
    try ztf.expect(std.testing.allocator, f.mock.messages).toHaveLength(2);
    try ztf.expect(std.testing.allocator, f.mock.messages[0].userMessage.content).toEqual("first");
    try ztf.expect(std.testing.allocator, f.mock.messages[1].userMessage.content).toEqual("second");
    try ztf.expect(std.testing.allocator, f.mock.tools).toBeEmpty();
}

test "the mocked stream hands out the messages the test asked for" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .assistantMessage = .{ .content = "Hi!" } },
        .{ .assistantMessage = .{ .content = "How can I help?" } },
    });

    try session.appendMessage("Hello, Agent!");
    try session.run(std.testing.io);

    // The session drops the stream, so ask the provider for it again.
    const stream = try f.provider.stream(
        std.testing.io,
        session.model.id(),
        session.system,
        session.messages.items,
        session.tools.items,
        session.id,
    );

    const first = (try stream.next(std.testing.io)).?;
    const second = (try stream.next(std.testing.io)).?;

    try ztf.expect(std.testing.allocator, first.assistantMessage.content).toEqual("Hi!");
    try ztf.expect(std.testing.allocator, second.assistantMessage.content).toEqual("How can I help?");
    try ztf.expect(std.testing.allocator, try stream.next(std.testing.io)).toBe(null);
}
