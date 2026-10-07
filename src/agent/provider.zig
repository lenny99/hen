const std = @import("std");
const uuid = @import("uuid");

const msg = @import("message.zig");

const Message = msg.Message;
const Delta = msg.Delta;

const session_mod = @import("session.zig");
const Session = session_mod.Session;
pub const ToolDef = session_mod.ToolDef;

pub const ModelId = []const u8;
pub const SystemPrompt = []const u8;

pub const Provider = struct {
    pub const Error = error{ConnectionError} || std.Io.Cancelable || std.mem.Allocator.Error;

    pub const SessionArgs = struct {
        model: ModelId,
        system: SystemPrompt,
        messages: []const Message,
        tools: []const ToolDef,
        session: uuid.UUID,
    };

    pub const StreamFn = *const fn (impl: *anyopaque, args: SessionArgs) Error!DeltaStream;

    pub const MessageFn = *const fn (impl: *anyopaque, args: SessionArgs) Error!MessageStream;

    pub const CancelFn = *const fn (impl: *anyopaque, io: std.Io) Error!void;

    pub const MessageStream = Stream(Message);
    pub const DeltaStream = Stream(Delta);

    impl: *anyopaque,
    vtable: struct {
        stream: StreamFn,
        messages: MessageFn,
    },

    pub fn init(impl: *anyopaque, stream_fn: StreamFn, message_fn: MessageFn) Provider {
        return .{
            .impl = impl,
            .vtable = .{
                .stream = stream_fn,
                .messages = message_fn,
            },
        };
    }

    pub fn stream(self: Provider, args: SessionArgs) Error!Stream(Delta) {
        return self.vtable.stream(self.impl, args);
    }

    pub fn messages(self: Provider, args: SessionArgs) Error!Stream(Message) {
        return self.vtable.messages(self.impl, args);
    }

    pub fn close(self: Provider, io: std.Io) Error!void {
        return self.vtable.close(self.impl, io);
    }
};

pub fn Stream(comptime t: type) type {
    return struct {
        const Self = @This();
        pub const Item = t;

        pub const Error = error{Failed, ResponseError} || std.Io.Cancelable || std.mem.Allocator.Error;

        pub const NextFn = *const fn (
            impl: *anyopaque,
            io: std.Io,
        ) Error!?Item;

        impl: *anyopaque,
        next_fn: NextFn,

        pub fn next(self: Self, io: std.Io) Error!?Item {
            return self.next_fn(self.impl, io);
        }
    };
}
