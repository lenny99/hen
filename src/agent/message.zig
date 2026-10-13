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
    /// One tool call as the provider assembled it from its streamed deltas.
    pub const Invocation = struct {
        /// The provider's id for the call. Stable across the call's deltas, and
        /// the value a tool result is matched against.
        id: []const u8,
        name: []const u8,
        /// The call arguments as the provider sent them: raw JSON text.
        arguments: []const u8,
    };

    /// One tool result to hand back to the provider.
    pub const Output = struct {
        /// The id of the invocation this answers.
        id: []const u8,
        content: []const u8,
    };
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
    output: ?Tool.Output = null,
};

pub const Delta = union(enum) {
    delta: []const u8,
    done: []const u8,
    tool_invocation: Tool.Invocation,
    tool_return: Tool.Output,
    lifecycle: Lifecycle,
    @"error": []const u8,
};
