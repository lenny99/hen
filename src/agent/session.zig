const std = @import("std");
const uuid = @import("uuid");
const provider_mod = @import("provider.zig");
const message_mod = @import("message.zig");

const Provider = provider_mod.Provider;
const Message = message_mod.Message;

pub const Session = struct {
    pub const Id = uuid.UUID;

    allocator: std.mem.Allocator,
    id: Id,
    provider: Provider,
    messages: std.ArrayList(Message),

    pub fn init(allocator: std.mem.Allocator, id: Id, provider: Provider) Session {
        return .{
            .allocator = allocator,
            .id = id,
            .provider = provider,
            .messages = .empty,
        };
    }

    pub fn appendMessage(self: *Session, message: []const u8) !void {
        const userMessage = Message{ .userMessage = .{ .content = message } };
        try self.messages.append(self.allocator, userMessage);
    }

    pub fn deinit(self: *Session) void {
        self.messages.deinit(self.allocator);
    }
};
