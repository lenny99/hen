const std = @import("std");

pub const Message = union(enum) {
    userMessage: struct {
        content: []const u8,
    },
    assistantMessage: struct {
        content: []const u8,
    }
};
