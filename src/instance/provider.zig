const std = @import("std");
const uuid = @import("uuid");
const session = @import("session.zig");

pub const ModelId = []const u8;
pub const SystemPrompt = []const u8;

/// One function tool in the request `tools` array.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
};

pub const Tool = struct {
    pub const Status = enum { running, completed, failed, canceled };

    pub const Timing = struct {
        started_at_ms: i64 = 0,
        duration_ms: i64 = 0,
    };

    /// One tool call as the provider assembled it from its streamed deltas.
    pub const Invocation = struct {
        /// The provider's id for the call. Stable across the call's deltas, and
        /// the value a tool result is matched against.
        id: []const u8,
        name: []const u8,
        /// The call arguments as the provider sent them: the model's action
        /// text carried as the single string parameter; the session decodes
        /// the {"source": ...} JSON envelope real models send before
        /// evaluation.
        arguments: []const u8,
    };

    /// One tool result to hand back to the provider.
    pub const Output = struct {
        /// The id of the invocation this answers.
        id: []const u8,
        name: []const u8 = "",
        content: []const u8,
        status: Status = .completed,
        timing: Timing = .{},
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



pub const Provider = struct {
    pub const Error = error{ConnectionError} || std.Io.Cancelable || std.mem.Allocator.Error;

    pub const SessionArgs = struct {
        model: ModelId,
        system: SystemPrompt,
        /// The conversation so far. The slices are valid only for the duration
        /// of the `stream` call; a provider that keeps them must copy them.
        messages: []const session.Message,
        tools: []const ToolSpec,
        session: uuid.UUID,
    };

    pub const StreamFn = *const fn (impl: *anyopaque, args: SessionArgs) Error!DeltaStream;

    pub const DeltaStream = Stream(Delta);

    impl: *anyopaque,
    vtable: struct {
        stream: StreamFn,
    },

    pub fn init(impl: *anyopaque, stream_fn: StreamFn) Provider {
        return .{
            .impl = impl,
            .vtable = .{ .stream = stream_fn },
        };
    }

    /// Open one streamed response. The caller owns the returned stream and
    /// releases it with `Stream.deinit`.
    pub fn stream(self: Provider, args: SessionArgs) Error!DeltaStream {
        return self.vtable.stream(self.impl, args);
    }
};

pub fn Stream(comptime t: type) type {
    return struct {
        const Self = @This();
        pub const Item = t;

        pub const Error = error{ Failed, ResponseError } || std.Io.Cancelable || std.mem.Allocator.Error;

        pub const NextFn = *const fn (impl: *anyopaque, io: std.Io) Error!?Item;
        pub const DeinitFn = *const fn (impl: *anyopaque, io: std.Io) void;

        impl: *anyopaque,
        next_fn: NextFn,
        deinit_fn: DeinitFn,

        /// Advance the stream. `null` ends it. The item is owned by the stream
        /// and stays valid until `deinit`; copy anything that must outlive it.
        pub fn next(self: Self, io: std.Io) Error!?Item {
            return self.next_fn(self.impl, io);
        }

        /// Close the response and release what the stream owns. Every item
        /// that `next` returned becomes invalid. Safe to call at any point.
        pub fn deinit(self: Self, io: std.Io) void {
            self.deinit_fn(self.impl, io);
        }
    };
}
