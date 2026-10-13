const std = @import("std");
const uuid = @import("uuid");
const provider_mod = @import("provider.zig");
const message_mod = @import("message.zig");

const Provider = provider_mod.Provider;
const SystemPrompt = provider_mod.SystemPrompt;
const Message = message_mod.Message;

pub const Model = struct {
    provider: []const u8,
    name: []const u8,
    context: i32,

    /// The name that a provider expects in a request.
    pub fn id(self: *const Model) []const u8 {
        return self.name;
    }
};

const glm51 = Model{ .provider = "opencode", .name = "glm-5.3-flash", .context = 300.000 };

pub const ToolDef = struct {
    pub const Error = error{ToolFailed} || std.Io.Cancelable;

    /// The agent loop runs calls to this tool one at a time, or all at once.
    pub const ExecutionMode = enum { sequential, parallel };

    /// The final or partial result of one tool call.
    pub const Result = struct {
        content: []const u8 = &.{},
        details: ?std.json.Value = null,
        added_tool_names: ?[]const []const u8 = null,
        terminate: ?bool = null,
    };

    pub const UpdateFn = *const fn (result: Result) void;

    pub const ExecuteFn = *const fn (
        impl: *anyopaque,
        io: std.Io,
        tool_call_id: []const u8,
        arguments: std.json.Value,
        on_update: ?UpdateFn,
    ) Error!Result;

    pub const PrepareArgumentsFn = *const fn (
        impl: *anyopaque,
        arguments: std.json.Value,
    ) std.json.Value;

    pub const RenderCallFn = *const fn (
        impl: *anyopaque,
        arguments: std.json.Value,
    ) ?[]const u8;

    pub const RenderResultFn = *const fn (
        impl: *anyopaque,
        result: Result,
        expanded: bool,
    ) ?[]const u8;

    /// Tool state for the function pointers below. Zig has no closures, so
    /// each one takes this as its first argument.
    impl: *anyopaque,

    name: []const u8,
    label: []const u8,
    description: []const u8,
    /// The JSON Schema for the arguments. A provider reads only this field
    /// and the name.
    parameters: std.json.Value,
    execute: ExecuteFn,
    prompt_snippet: ?[]const u8 = null,
    prompt_guidelines: []const []const u8 = &.{},
    prepare_arguments: ?PrepareArgumentsFn = null,
    execution_mode: ExecutionMode = .parallel,
    render_call: ?RenderCallFn = null,
    render_result: ?RenderResultFn = null,

    /// The name for provider payload builders. The same value as `parameters`.
    pub fn inputSchema(self: *const ToolDef) std.json.Value {
        return self.parameters;
    }
};

pub const Session = struct {
    pub const Id = uuid.UUID;

    id: Id,
    provider: *const Provider,
    model: *const Model,

    system: SystemPrompt,
    messages: std.ArrayList(Message),
    tools: std.ArrayList(ToolDef),

    pub fn init(id: Id, provider: *const Provider) !Session {
        return .{
            .id = id,
            .provider = provider,
            // TODO: need switching to models?
            .model = &glm51,
            .system = "",
            .messages = .empty,
            .tools = .empty,
        };
    }

    /// Append one user message. The session owns a copy of `message`.
    pub fn appendMessage(self: *Session, alloc: std.mem.Allocator, message: []const u8) !void {
        const content = try alloc.dupe(u8, message);
        errdefer alloc.free(content);
        try self.messages.append(alloc, .{ .user = .{ .content = content } });
    }

    /// Run one model turn: stream the provider's deltas, fold the assistant
    /// text into one message, and append it only when the turn ends without an
    /// error. Tool calls are collected, never executed, and never become part
    /// of the assistant text.
    ///
    /// The provider copies whatever it needs from the history, so the history
    /// is safe to grow while the stream is open.
    pub fn run(self: *Session, io: std.Io, alloc: std.mem.Allocator) !void {
        var stream = try self.provider.stream(.{
            .model = self.model.id(),
            .system = self.system,
            .messages = self.messages.items,
            .tools = self.tools.items,
            .session = self.id,
        });
        defer stream.deinit(io);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);

        while (try stream.next(io)) |delta| {
            switch (delta) {
                .delta => |chunk| try text.appendSlice(alloc, chunk),
                // `done` is the provider's complete text for the item, so it
                // replaces whatever the deltas accumulated before it.
                .done => |complete| {
                    text.clearRetainingCapacity();
                    try text.appendSlice(alloc, complete);
                },
                .tool_invocation, .tool_return => {},
                .lifecycle => |lifecycle| switch (lifecycle.kind) {
                    .failed => return error.ResponseFailed,
                    .completed, .incomplete => {},
                },
                .@"error" => return error.ProviderFailed,
            }
        }

        if (text.items.len == 0) return;

        const content = try alloc.dupe(u8, text.items);
        errdefer alloc.free(content);
        try self.messages.append(alloc, .{ .assistant = .{ .content = content } });
    }

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        for (self.messages.items) |message| switch (message) {
            .user => |user| alloc.free(user.content),
            .assistant => |assistant| alloc.free(assistant.content),
        };
        self.messages.deinit(alloc);
    }
};
