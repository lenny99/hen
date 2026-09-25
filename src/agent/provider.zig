const std = @import("std");
const uuid = @import("uuid");

pub const ModelId = []const u8;
pub const SystemPrompt = []const u8;

pub const Tool = struct {};

pub const Provider = struct {
    pub const Error = error{ProviderError};
    pub const StreamFn = *const fn (
        impl: *anyopaque,
        model: ModelId,
        system: SystemPrompt,
        messages: *const std.DoublyLinkedList,
        tools: *const std.ArrayList(Tool),
        session: uuid.UUID,
    ) (std.Io.Cancelable || Error)!void;

    impl: *anyopaque,
    table: struct {
        stream: StreamFn,
    },

    pub fn init(impl: *anyopaque, stream_fn: StreamFn) Provider {
        return .{
            .impl = impl,
            .table = .{ .stream = stream_fn },
        };
    }

    pub fn stream(
        self: Provider,
        model: ModelId,
        system: SystemPrompt,
        messages: *const std.DoublyLinkedList,
        tools: *const std.ArrayList(Tool),
        session: uuid.UUID,
    ) (std.Io.Cancelable || Error)!void {
        try self.table.stream(self.impl, model, system, messages, tools, session);
    }
};
