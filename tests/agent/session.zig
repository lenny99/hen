const std = @import("std");
const agent = @import("agent");


const Message = agent.Message;
const MessageStream = agent.Stream(Message);

const MockProvider = struct {
    const Error = agent.Provider.Error;

    calls: usize = 0,
    model: agent.ModelId = "",
    system: agent.SystemPrompt = "",
    session: agent.Session.Id = .nil,

    fn supplyNext(io: std.Io) MessageStream.Error!?Message {
        _ = io;
        return Message{.userMessage = .{.content = "Hello World"}};
    }

    fn stream(
        impl: *anyopaque,
        _: std.Io,
        model: agent.ModelId,
        system: agent.SystemPrompt,
        _: []const Message,
        _: []const agent.Tool,
        session: agent.Session.Id,
    ) Error!MessageStream {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.calls += 1;
        self.model = model;
        self.system = system;
        self.session = session;
        return MessageStream {
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
        self.mock = .{};
        self.provider = try self.mock.asProvider(allocator);
        self.session = try agent.Session.init(allocator, id, self.provider);
    }

    fn deinit(self: *Fixture) void {
        self.session.deinit();
        self.allocator.destroy(self.provider);
    }

    fn appendMessage(self: *Fixture, text: []const u8) !void {
        try self.session.appendMessage(text);
    }

    fn run(self: *Fixture) !void {
        try self.session.run(std.testing.io);
    }
};

test "session initializes" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqual(Fixture.id, session.id);
}

test "message added to the session is present in the history" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try f.appendMessage("Hello, Agent!");

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqualStrings("Hello, Agent!", session.messages.items[0].userMessage.content);
}

test "session with message sends system prompt and message" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    const session = &f.session;

    try f.appendMessage("Hello, Agent!");
    try f.run();

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqualStrings("Hello, Agent!", session.messages.items[0].userMessage.content);
    try std.testing.expectEqual(@as(usize, 1), f.mock.calls);
    try std.testing.expectEqual(Fixture.id, f.mock.session);
}
