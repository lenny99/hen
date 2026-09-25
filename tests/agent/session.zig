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

test "session delegates stream calls to its provider" {
    const session_id = agent.Session.Id.fromBytes(.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10,
    });
    var mock = MockProvider{};
    var session = agent.Session.init(std.testing.allocator, session_id, mock.asProvider());
    var tools: std.ArrayList(agent.Tool) = .empty;
    defer tools.deinit(std.testing.allocator);

    try session.stream("test-model", "test-system", &tools);

    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqualStrings("test-model", mock.model);
    try std.testing.expectEqualStrings("test-system", mock.system);
    try std.testing.expect(session_id.eql(mock.session));
}
