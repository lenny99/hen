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

    /// The text fragment of a `response.output_text.delta` event.
    pub fn textDelta(self: *const Response) ?[]const u8 {
        if (!std.mem.eql(u8, self.type, "response.output_text.delta")) return null;
        return self.delta;
    }

    /// The finished text of a `response.output_text.done` event.
    pub fn doneText(self: *const Response) ?[]const u8 {
        if (!std.mem.eql(u8, self.type, "response.output_text.done")) return null;
        return self.text;
    }

    /// The message of an `error` event or of a failed response.
    pub fn errorMessage(self: *const Response) ?[]const u8 {
        if (std.mem.eql(u8, self.type, "error")) return self.message;
        if (std.mem.eql(u8, self.type, "response.failed")) {
            const body = self.response orelse return null;
            const failure = body.@"error" orelse return null;
            return failure.message;
        }
        return null;
    }

    /// True for the events that end the stream.
    pub fn isFinal(self: *const Response) bool {
        return std.mem.eql(u8, self.type, "response.completed") or
            std.mem.eql(u8, self.type, "response.incomplete") or
            std.mem.eql(u8, self.type, "response.failed") or
            std.mem.eql(u8, self.type, "error");
    }
};

/// Parse one SSE `data` payload into a streamed response event. The payload
/// may include the trailing newline that `SseParser` adds. Unknown fields
/// are ignored. The caller owns the result and calls `deinit`.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Response) {
    return std.json.parseFromSlice(Response, allocator, data, .{ .ignore_unknown_fields = true });
}
