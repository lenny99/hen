const std = @import("std");
const agent = @import("agent");
const http = @import("http");
const openai = @import("apis/openai.zig");

const Stream = agent.Stream;
const Provider = agent.Provider;

fn bearerToken(gpa: std.mem.Allocator, token: *const agent.Secret) ![]const u8 {
    return try std.mem.concat(gpa, u8, &.{ "Bearer ", token.value });
}

pub const OpencodeProvider = struct {
    pub const Endpoints = struct { 
        models: []const u8 = "https://opencode.ai/zen/go/v1/models", 
        go: []const u8 = "https://opencode.ai/zen/go/v1/chat/completions" ,
    };

    token: *const agent.Secret,
    transport: *http.Transport,
    endpoints: Endpoints = .{},

    pub fn init(alloc: std.mem.Allocator, transport: *http.Transport, token: *const agent.Secret) !*OpencodeProvider {
        const self = try alloc.create(OpencodeProvider);
        self.* = .{ .token = token, .transport = transport };
        return self;
    }

    pub fn deinit(self: *OpencodeProvider, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn stream(
        self: OpencodeProvider,
        _: std.Io,
        model: agent.ModelId,
        system: agent.SystemPrompt,
        messages: []const agent.Message,
        _: []const agent.Tool,
        session: agent.Session.Id,
    ) Provider.Error!Provider.DeltaStream {
        var scope: std.heap.ArenaAllocator = .init(self.transport.gpa);
        defer scope.deinit();

        var payload: std.Io.Writer.Allocating = .init(scope.allocator());
        defer payload.deinit();
        {
            var conversation_messages = try scope.allocator().alloc(openai.Message, messages.len);
            for (messages, 0..) |message, i| {
                switch (message) {
                    .user => conversation_messages[i] = .{ .role = openai.Role.user, .content = message.user.content },
                    .assistant => conversation_messages[i] = .{ .role = openai.Role.assistant, .content = message.assistant.content },
                }
            }
            const fmt = std.json.fmt(openai.Create{
                .model = model,
                .stream = true,
                .messages = try std.mem.concat(scope.allocator(), openai.Message, &.{
                    &.{.{ .role = openai.Role.system, .content = system }},
                    conversation_messages,
                }),
            }, .{});
            fmt.format(&payload.writer) catch return error.ConnectionError;
        }

        const request = http.Request.open(self.transport, .{
            .url = self.endpoints.go,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = try bearerToken(self.transport.gpa, self.token) },
                .{ .name = "x-opencode-session", .value = try session.toString(scope.allocator()) },
            },
            .payload = try payload.toOwnedSlice(),
        }) catch return error.ConnectionError;

        if (request.status().class() != .success) return error.ConnectionError;

        const generator = try Generator.init(self.transport.gpa, request);
        return .{ .impl = generator, .next_fn = Generator.next };
    }

    const Generator = struct {
        scope: std.mem.Allocator,
        request: ?*http.Request,
        parser: http.SseParser = .init,

        fn init(allocator: std.mem.Allocator, request: *http.Request) !*Generator {
            const gen = try allocator.create(Generator);
            gen.* = .{ .scope = allocator, .request = request };
            return gen;
        }

        fn next(impl: *anyopaque, _: std.Io) Provider.DeltaStream.Error!?agent.Delta {
            const self: *Generator = @ptrCast(@alignCast(impl));
            const request = self.request orelse return null;
            var buf: [4096]u8 = undefined;
            var body = request.body();
            while (true) {
                const readBytes = body.read(&buf) catch {
                    self.finish();
                    return error.Failed;
                };
                if (readBytes == 0) {
                    self.finish();
                    return null;
                }
                self.parser.feed(self.scope, buf[0..readBytes]) catch |err| {
                    self.finish();
                    return err;
                };
                while (self.parser.take()) |event| {
                    switch (event.kind) {
                        .reply => {
                            // TODO: message ordering is currently ignored, messages come in out of order
                            const parsed = openai.parse(self.scope, event.data) catch return error.ResponseError;
                            const kind = parsed.value.kind();
                            switch (kind) {
                                .text_delta => |delta| return agent.Delta{ .delta = delta },
                                // The complete assistant text of an item
                                // (`response.output_text.done`).
                                .text_done => |done| return agent.Delta{ .done = done },
                                // A fragment of streamed function call arguments
                                // (`response.function_call_arguments.delta`).
                                .arguments_delta => |args| {
                                    _ = self.collectToolCall(args);
                                },
                                // The complete function call arguments of an item
                                // (`response.function_call_arguments.done`).
                                .arguments_done => return agent.Delta{ .tool_invocation = undefined }, // TODO:
                                // A finished output item (`response.output_item.done`).
                                .item => return agent.Delta{ .tool_return = undefined }, // TODO:
                                // The final response body (`response.completed`).
                                .completed, .incomplete, .failed => |response_body| return try toLifecycle(kind, response_body),
                                .error_message => |err| return agent.Delta{ .@"error" = err },
                                .other => {},
                            }
                        },
                        .error_reply => {
                            self.finish();
                            return error.Failed;
                        },
                        .done => {},
                    }
                }
            }
        }

        fn collectToolCall(_: *Generator, _: []const u8 ) agent.Tool.Invocation {
            return .{};
        }

        /// Release the response. The parser keeps the event payloads that the
        /// caller received as message content.
        fn finish(self: *Generator) void {
            if (self.request) |request| request.deinit();
            self.request = null;
        }
    };

    pub fn asProvider(self: *const OpencodeProvider) agent.Provider {
        return .{ .impl = &self, .table = .{
            .stream = stream,
        } };
    }
};

fn toToolReturn(_: openai.Response.OutputItem) !agent.Delta {
    return .{ .tool_return = .{} };
}

fn toLifecycle(kind: openai.Response.Kind, body: *const openai.Response.Body) !agent.Delta {
    const lifecycle_status: agent.Lifecycle.Status = switch (kind) {
        .completed => .completed,
        .incomplete => .incomplete,
        .failed => .failed,
        else => unreachable,
    };
    return .{ .lifecycle = .{ .id = body.id, .kind = lifecycle_status } };
}
