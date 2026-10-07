const std = @import("std");

pub const Role = enum { system, user, assistant, tool, developer };

pub const Message = struct { role: Role, content: []const u8 };

pub const Create = struct {
    model: []const u8,
    stream: bool,
    messages: []Message,
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
/// may include the trailing newline that `SseParser` adds. Unknown fields
/// are ignored. The caller owns the result and calls `deinit`.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Response) {
    return std.json.parseFromSlice(Response, allocator, data, .{ .ignore_unknown_fields = true });
}
