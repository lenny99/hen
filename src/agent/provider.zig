const std = @import("std");
const uuid = @import("uuid");

pub const ModelId = []const u8;
pub const SystemPrompt = []const u8;

pub const Tool = struct {};

pub const Provider = struct {
    impl: *anyopaque,
    table: struct {
        stream: *const fn (
            model: ModelId,
            system: SystemPrompt,
            messages: *const std.DoublyLinkedList,
            tools: *const std.ArrayList(Tool),
            session: uuid.UUID,
        ) (std.Io.Cancelable || error{ProviderError})!void,
    },

    pub fn stream(
        self: Provider,
        model: ModelId,
        system: SystemPrompt,
        messages: *const std.DoublyLinkedList,
        tools: *const std.ArrayList(Tool),
        session: uuid.UUID,
    ) (std.Io.Cancelable || error{ProviderError})!void {
        try self.table.stream(self.impl, model, system, messages, tools, session);
    }
};
