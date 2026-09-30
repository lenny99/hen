const std = @import("std");

pub const Message = union(enum) {
    user: struct {
        content: []const u8,
    },
    assistant: struct {
        content: []const u8,
    },
};
