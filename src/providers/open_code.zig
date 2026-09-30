const std = @import("std");
const agent = @import("agent");
const http = @import("http");

const Stream = agent.Stream;

pub const Secret = struct {
    name: []const u8,
    value: []const u8,
};

fn bearerToken(gpa: std.mem.Allocator, token: *const Secret) ![]const u8 {
    return try std.mem.concat(gpa, u8, .{ "Bearer ", token.value });
}

const Generator = struct {
    scope: std.mem.Allocator,
    request: *http.Request,
    parser: http.SseParser = .empty,

    fn init(allocator: std.mem.Allocator, request: *http.Request) !*Generator {
        var gen = try allocator.create(Generator);
        gen.scope = allocator;
        gen.request = request;
        return gen;
    }

    fn next(self: *Generator, _: std.Io) agent.Stream(agent.Message).Error!?agent.Message {
        var buf: [4096]u8 = undefined;
        var body = self.request.body();
        while (true) {
            const readBytes = try body.read(&buf);
            if (readBytes == 0) break;
            try self.parser.feed(self.scope.allocator(), buf[0..readBytes]);
            while (self.parser.take()) |event| {
                switch (event.kind) {
                    .reply => return agent.Message{ .assistantMessage = event.data },
                    .error_reply => return error.ProviderError,
                    .done => break,
                }
            }
        }
        return null;
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
    const MODEL_ENDPOINT = "https://opencode.ai/zen/go/v1/models";
    const GO_ENDPOINT = "https://opencode.ai/zen/go/v1/chat/completions";

    token: *const Secret,
    transport: *const http.Transport,

    pub fn init(alloc: std.mem.Allocator, transport: *const http.Transport) !*OpencodeProvider {
        var self = try alloc.create(OpencodeProvider);
        self.transport = transport;
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
        const scope: std.heap.ArenaAllocator = .init(self.transport.allocator);

        var payload: std.Io.Writer.Allocating = .init(scope.allocator());
        {
            var openAiMessages = try scope.allocator().alloc(OpenAi.Message, messages.len);
            for (messages, 0..) |message, i| {
                switch (message) {
                    .user => openAiMessages[i] = .{ .role = OpenAi.Role.user, .content = message.user.content },
                    .assistant => openAiMessages[i] = .{ .role = OpenAi.Role.assistant, .content = message.assistant.content },
                }
            }
            const fmt = std.json.fmt(OpenAi.Create{
                .model = model,
                .stream = true,
                .messages = std.mem.concat(scope.allocator(), OpenAi.Message, .{
                    &.{&.{ .role = OpenAi.Role.system, .content = system }},
                    openAiMessages,
                }),
            }, .{});
            fmt.format(payload.writer);
        }
        defer payload.deinit();

        const request = try http.Request.open(self.transport, .{
            .url = GO_ENDPOINT,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = try bearerToken(self.transport.gpa, self.token) },
                .{ .name = "x-opencode-session", .value = session.toString(scope.allocator()) },
            },
            .payload = try payload.toOwnedSlice(),
        });

        if (request.status().class() != .sucess) return error.HttpStatus;

        const generator = try Generator.init(scope.allocator());
        return .{ .impl = generator, .next_fn = Generator.next };
    }

    pub fn asProvider(self: *const OpencodeProvider) agent.Provider {
        return .{ .impl = &self, .table = .{
            .stream = stream,
        } };
    }
};
