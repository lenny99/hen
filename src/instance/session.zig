const std = @import("std");
const uuid = @import("uuid");

const prov = @import("provider.zig");
const Provider = prov.Provider;
const SystemPrompt = prov.SystemPrompt;
const ToolSpec = prov.ToolSpec;

const Environment = @import("environment.zig").Environment;

pub const Model = struct {
    provider: []const u8,
    name: []const u8,
    context: i32,

    /// The name that a provider expects in a request.
    pub fn id(self: *const Model) []const u8 {
        return self.name;
    }
};

const glm51 = Model{ .provider = "opencode", .name = "glm-5.3-flash", .context = 1_000_000 };

pub const Origin = enum { user, model };

pub const Evaluation = struct {
    call: Call,
    output: []const u8,
    status: Status,
    start: std.Io.Timestamp,
    duration: ?std.Io.Duration,

    pub const Call = struct {
        id: []const u8,
        source: []const u8,
        origin: Origin,
    };

    pub const Status = enum { running, completed, failed, canceled };
};

pub const Message = struct {
    origin: Origin,
    payload: union(enum) {
        message: []const u8,
        evaluation: Evaluation,
    },
};

pub const Event = struct {
    pub const Part = union(enum) {
        delta: []const u8,
        done: []const u8,
    };

    origin: Origin,
    payload: union(enum) {
        message: Part,
        eval: Evaluation,
    },

    fn fromEvaluation(evaluation: Evaluation) Event {
        return .{
            .origin = evaluation.call.origin,
            .payload = .{ .eval = evaluation },
        };
    }
};


pub const Session = struct {
    pub const Id = uuid.UUID;

    pub const eval_tool_name = "eval";

    pub const final_answer_prompt =
        "Please give your final answer now: wrap up and reply with text only.";

    pub const Listener = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, event: Event) void,

        pub fn send(self: Listener, event: Event) void {
            self.func(self.ctx, event);
        }
    };

    id: Id,
    provider: *const Provider,
    model: *const Model,
    system: SystemPrompt,
    max_rounds: usize = 8,

    messages: std.ArrayList(Message),
    evals: std.Deque(Evaluation.Call),

    environment: *Environment,

    pub fn init(alloc: std.mem.Allocator, id: Id, provider: *const Provider) !Session {
        const environment = try Environment.initAlloc(alloc, .{});

        return .{
            .id = id,
            .provider = provider,
            .model = &glm51,
            .system = "",
            .messages = .empty,
            .evals = .empty,
            .environment = environment,
        };
    }

    pub fn appendMessage(self: *Session, alloc: std.mem.Allocator, message: []const u8) !void {
        const content = try alloc.dupe(u8, message);
        errdefer alloc.free(content);
        try self.messages.append(alloc, .{ .origin = .user, .payload = .{ .message = content } });
    }

    pub fn turn(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        message: []const u8,
        sink: ?Listener,
    ) !void {
        try self.appendMessage(alloc, message);
        try self.run(io, alloc, sink);
    }

    pub fn run(self: *Session, io: std.Io, alloc: std.mem.Allocator, sink: ?Listener) !void {
        var round: usize = 0;
        while (round < self.max_rounds) : (round += 1) {
            const calls = try self.runTurn(io, alloc, true, sink);
            if (calls == 0) return;
            try io.checkCancel();
        }

        try io.checkCancel();
        try self.appendMessage(alloc, final_answer_prompt);
        emit(sink, .{ .origin = .user, .payload = .{ .message = .{ .done = final_answer_prompt } } });
        _ = try self.runTurn(io, alloc, false, sink);
    }

    fn runTurn(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        with_tools: bool,
        sink: ?Listener,
    ) !usize {
        var spec_buffer: [1]ToolSpec = undefined;
        if (with_tools) spec_buffer[0] = .{
            .name = eval_tool_name,
            .description = self.environment.evalDescription(),
        };
        const specs: []const ToolSpec = if (with_tools) &spec_buffer else &.{};

        var stream = try self.provider.stream(.{
            .model = self.model.id(),
            .system = self.system,
            .messages = self.messages.items,
            .tools = specs,
            .session = self.id,
        });
        defer stream.deinit(io);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);

        errdefer self.releaseEvals(alloc);

        while (try stream.next(io)) |delta| {
            switch (delta) {
                .delta => |chunk| {
                    try text.appendSlice(alloc, chunk);
                    emit(sink, .{ .origin = .model, .payload = .{ .message = .{ .delta = chunk } } });
                },
                // `done` is the provider's complete text for the item, so it
                // replaces whatever the deltas accumulated before it.
                .done => |complete| {
                    text.clearRetainingCapacity();
                    try text.appendSlice(alloc, complete);
                    try self.commitAssistant(alloc, text.items, sink);
                    text.clearRetainingCapacity();
                },
                .tool_invocation => |invocation| {
                    // The invocation slices live in the stream arena, so copy
                    // everything the session keeps.
                    try self.queueEval(alloc, invocation);
                },
                .tool_return => {},
                .lifecycle => |lifecycle| switch (lifecycle.kind) {
                    .failed => return error.ResponseFailed,
                    .completed, .incomplete => {},
                },
                .@"error" => return error.ProviderFailed,
            }
        }

        if (text.items.len > 0) {
            try self.commitAssistant(alloc, text.items, sink);
        }

        var calls: usize = 0;
        while (self.evals.popFront()) |call| {
            const evaluation = try self.eval(io, alloc, call);
            try self.messages.append(alloc, .{
                .origin = evaluation.call.origin,
                .payload = .{ .evaluation = evaluation },
            });
            emit(sink, Event.fromEvaluation(evaluation));
            calls += 1;
        }
        return calls;
    }

    fn commitAssistant(
        self: *Session,
        alloc: std.mem.Allocator,
        content: []const u8,
        sink: ?Listener,
    ) !void {
        const owned = try alloc.dupe(u8, content);
        errdefer alloc.free(owned);
        try self.messages.append(alloc, .{ .origin = .model, .payload = .{ .message = owned } });
        emit(sink, .{ .origin = .model, .payload = .{ .message = .{ .done = owned } } });
    }

    fn queueEval(self: *Session, alloc: std.mem.Allocator, invocation: prov.Tool.Invocation) !void {
        const id = try alloc.dupe(u8, invocation.id);
        errdefer alloc.free(id);
        const source = try decodeEvalSource(alloc, invocation.arguments);
        errdefer alloc.free(source);
        try self.evals.pushBack(alloc, .{ .id = id, .source = source, .origin = .model });
    }

    fn releaseEvals(self: *Session, alloc: std.mem.Allocator) void {
        while (self.evals.popFront()) |call| {
            alloc.free(call.id);
            alloc.free(call.source);
        }
    }

    fn eval(self: *Session, io: std.Io, alloc: std.mem.Allocator, call: Evaluation.Call) !Evaluation {
        const started = std.Io.Clock.real.now(io);

        const output: []const u8 = self.environment.call(alloc, call.source) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk try std.fmt.allocPrint(alloc, "Error: {t}", .{err});
        };
        const status: Evaluation.Status = if (std.mem.startsWith(u8, output, "Error: "))
            .failed
        else
            .completed;

        const ended = std.Io.Clock.real.now(io);

        return .{
            .call = call,
            .output = output,
            .status = status,
            .start = started,
            .duration = started.durationTo(ended),
        };
    }

    fn decodeEvalSource(alloc: std.mem.Allocator, arguments: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return alloc.dupe(u8, arguments),
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |object| {
                if (object.get("source")) |member| {
                    switch (member) {
                        .string => |text| return alloc.dupe(u8, text),
                        else => {},
                    }
                }
            },
            else => {},
        }
        return alloc.dupe(u8, arguments);
    }

    fn emit(sink: ?Listener, event: Event) void {
        if (sink) |value| value.send(event);
    }

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        self.releaseEvals(alloc);
        self.evals.deinit(alloc);
        for (self.messages.items) |message| switch (message.payload) {
            .message => |content| alloc.free(content),
            .evaluation => |evaluation| {
                alloc.free(evaluation.call.id);
                alloc.free(evaluation.call.source);
                alloc.free(evaluation.output);
            },
        };
        self.messages.deinit(alloc);
        self.environment.deinit();
        alloc.destroy(self.environment);
    }
};


