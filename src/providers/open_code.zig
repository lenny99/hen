const std = @import("std");
const agent = @import("agent");
const http = @import("http");

const Stream = agent.Stream;

pub const Secret = struct {
    name: []const u8,
    value: []const u8,
};

fn bearerToken(gpa: std.mem.Allocator, token: *const Secret) ![]const u8 {
    return try std.mem.concat(gpa, u8, &.{ "Bearer ", token.value });
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

    fn next(impl: *anyopaque, _: std.Io) agent.Stream(agent.Message).Error!?agent.Message {
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
                    .reply => return agent.Message{ .assistant = .{ .content = event.data } },
                    .error_reply => {
                        self.finish();
                        return error.Failed;
                    },
                    .done => {},
                }
            }
        }
    }

    /// Release the response. The parser keeps the event payloads that the
    /// caller received as message content.
    fn finish(self: *Generator) void {
        if (self.request) |request| request.deinit();
        self.request = null;
    }
};

const OpenAi = struct {
    pub const Role = enum { system, user, assistant, tool, developer };

    pub const Message = struct { role: Role, content: []const u8 };

    pub const Create = struct {
        model: []const u8,
        stream: bool,
        messages: []Message,
    };
};

pub const OpencodeProvider = struct {
    pub const Endpoints = struct { models: []const u8 = "https://opencode.ai/zen/go/v1/models", go: []const u8 = "https://opencode.ai/zen/go/v1/chat/completions" };

    token: *const Secret,
    transport: *http.Transport,
    endpoints: Endpoints = .{},

    pub fn init(alloc: std.mem.Allocator, transport: *http.Transport, token: *const Secret) !*OpencodeProvider {
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
    ) agent.Provider.Error!Stream(agent.Message) {
        var scope: std.heap.ArenaAllocator = .init(self.transport.gpa);
        defer scope.deinit();

        var payload: std.Io.Writer.Allocating = .init(scope.allocator());
        defer payload.deinit();
        {
            var conversation_messages = try scope.allocator().alloc(OpenAi.Message, messages.len);
            for (messages, 0..) |message, i| {
                switch (message) {
                    .user => conversation_messages[i] = .{ .role = OpenAi.Role.user, .content = message.user.content },
                    .assistant => conversation_messages[i] = .{ .role = OpenAi.Role.assistant, .content = message.assistant.content },
                }
            }
            const fmt = std.json.fmt(OpenAi.Create{
                .model = model,
                .stream = true,
                .messages = try std.mem.concat(scope.allocator(), OpenAi.Message, &.{
                    &.{.{ .role = OpenAi.Role.system, .content = system }},
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

    pub fn asProvider(self: *const OpencodeProvider) agent.Provider {
        return .{ .impl = &self, .table = .{
            .stream = stream,
        } };
    }
};
