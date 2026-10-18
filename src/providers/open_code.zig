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

    /// Open one streamed response. A single arena holds everything the stream
    /// needs: the payload, the headers, the request, the body buffer, the SSE
    /// parser, and every item handed out. `Stream.deinit` drops it in one step,
    /// so no piece of the request is freed on its own.
    pub fn stream(self: *const OpencodeProvider, args: Provider.SessionArgs) Provider.Error!Provider.DeltaStream {
        const gpa = self.transport.gpa;

        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }

        const alloc = arena.allocator();

        const body = buildPayload(alloc, args) catch return error.ConnectionError;
        const authorization = bearerToken(alloc, self.token) catch return error.ConnectionError;
        const session_id = args.session.toString(alloc) catch return error.ConnectionError;

        const request = http.Request.open(self.transport, alloc, .{
            .url = self.endpoints.go,
            .headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = authorization },
                .{ .name = "x-opencode-session", .value = session_id },
            },
            .payload = body,
        }) catch return error.ConnectionError;
        errdefer request.deinit();

        if (request.status().class() != .success) return error.ConnectionError;

        const generator = try alloc.create(Generator);
        generator.* = .{ .arena = arena, .request = request };

        return .{ .impl = generator, .next_fn = Generator.next, .deinit_fn = Generator.deinit };
    }

    /// The system prompt first, then the conversation, as one JSON body. The
    /// body lives in the stream arena, which keeps it valid through the send.
    fn buildPayload(alloc: std.mem.Allocator, args: Provider.SessionArgs) ![]const u8 {
        var conversation = try alloc.alloc(openai.Message, args.messages.len);
        for (args.messages, 0..) |message, i| {
            conversation[i] = switch (message) {
                .user => |user| .{ .role = openai.Role.user, .content = user.content },
                .assistant => |assistant| .{ .role = openai.Role.assistant, .content = assistant.content },
            };
        }

        const messages = try std.mem.concat(alloc, openai.Message, &.{
            &.{.{ .role = openai.Role.system, .content = args.system }},
            conversation,
        });

        var payload: std.Io.Writer.Allocating = .init(alloc);
        std.json.fmt(openai.Create{
            .model = args.model,
            .stream = true,
            .messages = messages,
        }, .{}).format(&payload.writer) catch return error.OutOfMemory;

        return payload.toOwnedSlice();
    }

    const Generator = struct {
        /// Owns the request, the body buffer, the parser, and every item handed
        /// out; `deinit` drops all of it at once.
        arena: *std.heap.ArenaAllocator,
        request: *http.Request,
        parser: http.SseParser = .init,
        buf: std.ArrayList(u8) = .empty,

        /// Close the stream: release the connection, then drop the arena.
        fn deinit(impl: *anyopaque, _: std.Io) void {
            const self: *Generator = @ptrCast(@alignCast(impl));
            const arena = self.arena;
            const gpa = arena.child_allocator;
            self.request.deinit();
            arena.deinit();
            gpa.destroy(arena);
        }

        fn next(impl: *anyopaque, _: std.Io) Provider.DeltaStream.Error!?agent.Delta {
            const self: *Generator = @ptrCast(@alignCast(impl));
            const alloc = self.arena.allocator();

            var body = self.request.body();
            while (true) {
                while (self.parser.take()) |event| {
                    switch (event.kind) {
                        .reply => {
                            const chunk = openai.parseChunkLeaky(alloc, event.data) catch |err| {
                                // TODO: temporary debug. Dump the raw reply when it
                                // does not parse, to see what opencode really sends.
                                std.debug.print("[hen] opencode reply parse failed ({t}): {s}\n", .{ err, event.data });
                                return error.ResponseError;
                            };

                            if (chunk.@"error") |failure| {
                                return agent.Delta{ .@"error" = failure.message orelse "provider error" };
                            }
                            if (chunk.text()) |text| return agent.Delta{ .delta = text };
                            // TODO: assemble the streamed `tool_calls` fragments
                            // once the agent runs tools.
                            if (chunk.finishReason()) |reason| {
                                return agent.Delta{ .lifecycle = .{
                                    .id = chunk.id orelse "chatcmpl",
                                    .kind = finishKind(reason),
                                } };
                            }
                        },
                        .error_reply => return error.Failed,
                        .done => {},
                    }
                }

                const start = self.buf.items.len;
                try self.buf.resize(alloc, start + 4096);
                const read_bytes = body.read(self.buf.items[start..]) catch return error.Failed;
                self.buf.shrinkRetainingCapacity(start + read_bytes);
                if (read_bytes == 0) return null;

                const consumed = self.parser.feed(alloc, self.buf.items) catch return error.Failed;
                const keep = self.buf.items.len - consumed;
                if (consumed > 0) {
                    std.mem.copyForwards(u8, self.buf.items[0..keep], self.buf.items[consumed..]);
                    self.buf.shrinkRetainingCapacity(keep);
                }
            }
        }
    };

    fn streamVia(impl: *anyopaque, args: Provider.SessionArgs) Provider.Error!Provider.DeltaStream {
        const self: *const OpencodeProvider = @ptrCast(@alignCast(impl));
        return self.stream(args);
    }

    pub fn asProvider(self: *const OpencodeProvider) Provider {
        return Provider.init(@constCast(self), streamVia);
    }
};

/// Map a Chat Completions `finish_reason` onto the agent's lifecycle status.
fn finishKind(reason: []const u8) agent.Lifecycle.Status {
    if (std.mem.eql(u8, reason, "length")) return .incomplete;
    if (std.mem.eql(u8, reason, "content_filter")) return .failed;
    return .completed;
}
