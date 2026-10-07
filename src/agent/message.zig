const std = @import("std");

pub const Message = union(enum) {
    user: struct {
        content: []const u8,
    },
    assistant: struct {
        content: []const u8,
    },
};

pub const Tool = struct {
    pub const Invocation = struct {};
    pub const Output = struct {};
};

pub const Tokens = u64;

pub const Usage = struct { input: ?Tokens = null, output: ?Tokens = null, total: ?Tokens = null };

pub const Lifecycle = struct {
    pub const Status = enum { completed, incomplete, failed };

    id: []const u8,
    kind: Status,
    model: ?[]const u8 = null,
    status: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    usage: ?Usage = null,
    output: ?[]const Tool.Output = null,
};

pub const Delta = union(enum) {
    delta: []const u8,
    done: []const u8,
    tool_invocation: Tool.Invocation,
    tool_return: Tool.Output,
    lifecycle: Lifecycle,
    @"error": []const u8,
};
