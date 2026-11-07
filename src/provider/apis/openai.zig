const std = @import("std");

pub const Role = enum { system, user, assistant, tool, developer };

pub const MessageFn = struct {
    name: []const u8,
    arguments: []const u8,
};

/// One tool call in an assistant message of the conversation payload.
pub const ToolCallEntry = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: MessageFn,
};

/// One function tool in the `tools` array of the request.
pub const FunctionTool = struct {
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        description: []const u8,
        parameters: std.json.Value,
    },
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    /// Assistant messages carry the calls of the action round.
    tool_calls: ?[]const ToolCallEntry = null,
    /// Tool messages carry the id of the call they answer.
    tool_call_id: ?[]const u8 = null,
};

pub const Create = struct {
    model: []const u8,
    stream: bool,
    messages: []Message,
    tools: ?[]const FunctionTool = null,
    tool_choice: ?[]const u8 = null,
};

/// One event from a streamed Responses API response. The server sends one
/// SSE frame per event, and every event carries a distinct `type`.
pub const Response = struct {
    pub const Error = struct {
        code: ?[]const u8 = null,
        message: []const u8,
    };

    pub const Usage = struct {
        input_tokens: ?u64 = null,
        output_tokens: ?u64 = null,
        total_tokens: ?u64 = null,
    };

    /// One output item of the response. Only the fields that the provider
    /// needs for text and for function calls are modelled.
    pub const OutputItem = struct {
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        status: ?[]const u8 = null,
        name: ?[]const u8 = null,
        call_id: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    };

    /// The response object of the lifecycle events.
    pub const Body = struct {
        id: []const u8,
        model: ?[]const u8 = null,
        status: ?[]const u8 = null,
        @"error": ?Error = null,
        usage: ?Usage = null,
        output: ?[]const OutputItem = null,
    };

    type: []const u8,
    sequence_number: ?u64 = null,
    item_id: ?[]const u8 = null,
    output_index: ?u32 = null,
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    text: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?[]const u8 = null,
    response: ?Body = null,
    item: ?OutputItem = null,

    /// The meaning of one streamed response object. Payload fields point
    /// into `self` and stay valid as long as the parsed response does.
    pub const Kind = union(enum) {
        /// A fragment of streamed assistant text
        /// (`response.output_text.delta`).
        text_delta: []const u8,
        /// The complete assistant text of an item
        /// (`response.output_text.done`).
        text_done: []const u8,
        /// A fragment of streamed function call arguments
        /// (`response.function_call_arguments.delta`).
        arguments_delta: []const u8,
        /// The complete function call arguments of an item
        /// (`response.function_call_arguments.done`).
        arguments_done: []const u8,
        /// A finished output item (`response.output_item.done`).
        item: *const OutputItem,
        /// The final response body (`response.completed`).
        completed: *const Body,
        /// The response body of a stream that ended early
        /// (`response.incomplete`).
        incomplete: *const Body,
        /// The response body of a failed response (`response.failed`).
        failed: *const Body,
        /// An `error` event. The payload is the error message.
        error_message: []const u8,
        /// An event that carries no meaning for this provider.
        other,
    };

    /// Classify the response object.
    pub fn kind(self: *const Response) Kind {
        const t = self.type;
        if (std.mem.eql(u8, t, "response.output_text.delta")) {
            return .{ .text_delta = self.delta orelse "" };
        }
        if (std.mem.eql(u8, t, "response.output_text.done")) {
            return .{ .text_done = self.text orelse "" };
        }
        if (std.mem.eql(u8, t, "response.function_call_arguments.delta")) {
            return .{ .arguments_delta = self.arguments orelse "" };
        }
        if (std.mem.eql(u8, t, "response.function_call_arguments.done")) {
            return .{ .arguments_done = self.arguments orelse "" };
        }
        if (std.mem.eql(u8, t, "response.output_item.done")) {
            if (self.item) |*item| return .{ .item = item };
            return .other;
        }
        if (std.mem.eql(u8, t, "response.completed")) {
            if (self.response) |*body| return .{ .completed = body };
            return .other;
        }
        if (std.mem.eql(u8, t, "response.incomplete")) {
            if (self.response) |*body| return .{ .incomplete = body };
            return .other;
        }
        if (std.mem.eql(u8, t, "response.failed")) {
            if (self.response) |*body| return .{ .failed = body };
            return .other;
        }
        if (std.mem.eql(u8, t, "error")) {
            return .{ .error_message = self.message orelse "" };
        }
        return .other;
    }
};

/// Parse one SSE `data` payload into a streamed response event. The payload
/// may include the trailing newline that `SseParser` adds. Unknown fields are
/// ignored. Every string in the result is copied into `allocator`, so the
/// payload can be freed as soon as this returns; the caller owns the result
/// and releases it through the allocator (an arena frees it wholesale).
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Response) {
    return std.json.parseFromSlice(Response, allocator, data, .{
        .ignore_unknown_fields = true,
        // Slice input defaults to `.alloc_if_needed`, which leaves the strings
        // pointing into `data`.
        .allocate = .alloc_always,
    });
}

/// One streamed Chat Completions chunk (`/chat/completions` with
/// `stream: true`). Every SSE frame carries one; the stream ends with
/// `data: [DONE]`. Only the fields the provider reads are modelled.
pub const Chunk = struct {
    pub const Error = struct {
        code: ?[]const u8 = null,
        message: ?[]const u8 = null,
    };

    pub const Function = struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    };

    /// One tool call fragment. A call's `id`, `function.name`, and
    /// `function.arguments` arrive split across chunks and are joined by
    /// `index`.
    pub const ToolCall = struct {
        index: ?u32 = null,
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        function: ?Function = null,
    };

    pub const Delta = struct {
        role: ?[]const u8 = null,
        content: ?[]const u8 = null,
        tool_calls: ?[]const ToolCall = null,
    };

    pub const Choice = struct {
        index: ?u32 = null,
        delta: ?Delta = null,
        finish_reason: ?[]const u8 = null,
    };

    id: ?[]const u8 = null,
    choices: ?[]const Choice = null,
    @"error": ?Error = null,

    /// The first non-empty text fragment of this chunk, or null when it carries
    /// no text: the role-only opener, an empty keepalive, or a tool-call
    /// fragment.
    pub fn text(self: *const Chunk) ?[]const u8 {
        for (self.choices orelse return null) |choice| {
            const content = (choice.delta orelse continue).content orelse continue;
            if (content.len > 0) return content;
        }
        return null;
    }

    /// The first choice's tool call fragments, or none when this chunk carries
    /// no tool call traffic.
    pub fn toolCalls(self: *const Chunk) []const ToolCall {
        for (self.choices orelse return &.{}) |choice| {
            const delta = choice.delta orelse continue;
            const calls = delta.tool_calls orelse continue;
            if (calls.len > 0) return calls;
        }
        return &.{};
    }

    /// The first non-null `finish_reason`, which arrives on the chunk that ends
    /// the choice.
    pub fn finishReason(self: *const Chunk) ?[]const u8 {
        for (self.choices orelse return null) |choice| {
            if (choice.finish_reason) |reason| return reason;
        }
        return null;
    }
};

/// Parse one SSE `data` payload into a Chat Completions chunk, allocating into
/// `allocator` only what the value needs. The returned strings alias `data`, so
/// `data` must stay alive for as long as the chunk is read, which the stream
/// arena guarantees: every payload lives until `Stream.deinit`.
pub fn parseChunkLeaky(allocator: std.mem.Allocator, data: []const u8) !Chunk {
    return std.json.parseFromSliceLeaky(Chunk, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    });
}
