const std = @import("std");
const agent = @import("agent");

const MockProvider = struct {
    calls: usize = 0,
    model: agent.ModelId = "",
    system: agent.SystemPrompt = "",
    session: agent.Session.Id = .nil,

    fn stream(
        impl: *anyopaque,
        model: agent.ModelId,
        system: agent.SystemPrompt,
        _: *const std.DoublyLinkedList,
        _: *const std.ArrayList(agent.Tool),
        session: agent.Session.Id,
    ) (std.Io.Cancelable || agent.Provider.Error)!void {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.calls += 1;
        self.model = model;
        self.system = system;
        self.session = session;
    }

    fn asProvider(self: *MockProvider) agent.Provider {
        return agent.Provider.init(self, stream);
    }
};

test "session initializes" {
    const session_id = agent.Session.Id.fromBytes(.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10,
    });
    var mock = MockProvider{};
    const session = agent.Session.init(std.testing.allocator, session_id, mock.asProvider());

    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqual(session_id, session.id);
}

test "message added to the session is present in the history" {
    const session_id = agent.Session.Id.fromBytes(.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10,
    });
    var mock = MockProvider{};
    var session = agent.Session.init(std.testing.allocator, session_id, mock.asProvider());
    
    defer session.deinit();

    try session.appendMessage("Hello, Agent!");

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqualStrings("Hello, Agent!", session.messages.items[0].userMessage.content);
}
