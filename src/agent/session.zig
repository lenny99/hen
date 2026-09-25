const std = @import("std");
const uuid = @import("uuid");
const provider = @import("provider.zig");
const Provider = provider.Provider;

pub const Session = struct {
    pub const Id = uuid.UUID;

    allocator: std.mem.Allocator,
    id: Id,
    provider: Provider,
    messages: std.DoublyLinkedList,

    pub fn init(allocator: std.mem.Allocator, id: Id, provider_value: Provider) Session {
        return .{
            .allocator = allocator,
            .id = id,
            .provider = provider_value,
            .messages = .{},
        };
    }

    pub fn stream(
        self: *const Session,
        model: provider.ModelId,
        system: provider.SystemPrompt,
        tools: *const std.ArrayList(provider.Tool),
    ) (std.Io.Cancelable || Provider.Error)!void {
        return self.provider.stream(model, system, &self.messages, tools, self.id);
    }
};
