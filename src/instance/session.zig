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
    const Part = union(enum) {
        delta: []const u8,
        done: []const u8,
    };

    origin: Origin,
    payload: union(enum) {
        message: Part,
        eval: Evaluation,
    },

    fn fromEvaluation(evaluation: *Evaluation) Event {
        return .{ 
            .origin = evaluation.call.origin,
            .payload = .{ .eval = *evaluation }
        };
    }
};

pub const Session = struct {
    pub const Id = uuid.UUID;

    pub const Listener = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, seq: usize, message: Message) void,

        pub fn emit(self: Listener, seq: *usize, message: Event) void {
            seq = *seq + 1;
            self.func(self.ctx, *seq, message);
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

    pub fn run(self: *Session, io: std.Io, alloc: std.mem.Allocator, sink: ?Listener) !void {
        errdefer {
            const now = std.Io.Clock.real.now(io);
            for (self.evals.items) |*call| {
                self.messages.append(alloc, .{ .origin = call.origin, .payload = .{
                    .evaluation = Evaluation{
                        .call = *call,
                        .status = .canceled,
                        .output = "",
                        .start = now,
                        .duration = null,
                    },
                } });
            }
            self.evals.clearAndFree(alloc);
        }

        var round: usize = 0;
        while (round < self.max_rounds) : (round += 1) {
            const calls = try self.turn(io, alloc, sink);
            if (calls == 0) return;
            io.checkCancel();
        }
    }

    fn turn(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        sink: ?Listener,
    ) !void {
        const eval_tool = prov.ToolSpec{ .name = "eval", .description = "Evaluate scheme inside the session environment." };
        var stream = try self.provider.stream(.{
            .model = self.model.id(),
            .system = self.system,
            .messages = self.messages.items,
            .tools = &.{eval_tool},
            .session = self.id,
        });
        defer stream.deinit(io);

        var partial_message: std.ArrayList(u8) = .empty;
        defer partial_message.deinit(alloc);

        var seq: usize = 0;

        while (try stream.next(io)) |delta| {
            switch (delta) {
                .delta => |chunk| {
                    try partial_message.appendSlice(alloc, chunk);
                    sink.?.emit(self.seq, Event{});
                },
                // `done` is the provider's complete text for the item, so it
                // replaces whatever the deltas accumulated before it.
                .done => |complete| {
                    try partial_message.appendSlice(alloc, complete);
                    self.messages.append(Message{ .assistant = .{ .content = partial_message.toOwnedSlice(alloc) } });
                    partial_message.clearRetainingCapacity();
                },
                .tool_invocation => |invocation| {
                    // The invocation slices live in the stream arena, so copy
                    // everything the session keeps.
                    const source = decodeEvalSource(alloc, alloc.dupe([]const u8, invocation.arguments));
                    self.queueEval(try alloc.dupe(u8, invocation.id), source);
                },
                .tool_return => {},
                .lifecycle => |lifecycle| switch (lifecycle.kind) {
                    .failed => return error.ResponseFailed,
                    .completed, .incomplete => {},
                },
                .@"error" => return error.ProviderFailed,
            }
        }

        
        for (self.evals.popBack()) |evaluation| {
            const result = try self.eval(io, alloc, &evaluation);
            self.messages.append(alloc, Message{ 
                .origin = result.origin, 
                .payload = .{ .evaluation = result }
            });
            sink.?.emit(&seq, Event.fromEvaluation(&result));
        }
    }

    fn eval(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        call: *Evaluation.Call,
    ) !Evaluation {
        const clock = std.Io.Clock.real;
        const started_at: std.Io.Timestamp = clock.now(io);

        const result = self.environment.eval(call.source, &alloc) catch std.mem.Allocator.Error.OutOfMemory;

        const ended_at: std.Io.Timestamp = clock.now(io);

        return Evaluation{
            .call = *call,
            .start = started_at,
            .duration = started_at.durationTo(ended_at),
            .output = result,
            .status = .completed,
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

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        self.environment.deinit(alloc);
        self.messages.clearAndFree(alloc);
    }
};
