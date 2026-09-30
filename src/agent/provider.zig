const std = @import("std");
const uuid = @import("uuid");

const message_mod = @import("message.zig");

const Message = message_mod.Message;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
pub const Tool = session_mod.Tool;

pub const ModelId = []const u8;
pub const SystemPrompt = []const u8;

pub const Provider = struct {
    pub const Error = error{ProviderError} || std.Io.Cancelable;

    pub const StreamFn = *const fn (
        impl: *anyopaque,
        io: std.Io,
        model: ModelId,
        system: SystemPrompt,
        messages: []const Message,
        tools: []const Tool,
        session: uuid.UUID,
    ) Error!Stream(Message);

    pub const CancelFn = *const fn (impl: *anyopaque, io: std.Io) Error!void;

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
        io: std.Io,
        model: ModelId,
        system: SystemPrompt,
        messages: []const Message,
        tools: []const Tool,
        session: Session.Id,
    ) Error!Stream(Message) {
        return self.table.stream(self.impl, io, model, system, messages, tools, session);
    }

    pub fn close(self: Provider, io: std.Io) Error!void {
        return self.table.close(self.impl, io);
    }
};

pub fn Stream(comptime t: type) type {
    return struct {
        const Self = @This();
        pub const Item = t;

        pub const Error = error{Failed} || std.Io.Cancelable;

        pub const NextFn = *const fn (
            impl: *anyopaque,
            io: std.Io,
        ) (Error || std.Io.Cancelable)!?Item;

        impl: *anyopaque,
        next_fn: NextFn,

        pub fn next(self: Self, io: std.Io) Error!?Item {
            return self.next_fn(self.impl, io);
        }
    };
}
