const std = @import("std");
const instance = @import("instance");
const ztf = @import("zig_test_framework");

/// `ztf.expect` asks for an allocator, but it never uses it. The matchers only
/// call `std.debug.print`. Keep that argument out of the tests with this
/// helper. It still passes `std.testing.allocator`, so a leak inside the
/// framework still fails the test run.
inline fn expect(actual: anytype) @TypeOf(ztf.expect(std.testing.allocator, actual)) {
    return ztf.expect(std.testing.allocator, actual);
}

const MockProvider = struct {
    const Error = instance.Provider.Error;

    allocator: std.mem.Allocator,
    /// The framework mocks record every call to the provider functions, so the
    /// tests can count the calls.
    mocks: struct {
        stream: ztf.Mock(instance.Provider.DeltaStream),
    },
    /// The arguments of the last call. The framework mock stores call
    /// arguments as text, so the typed values go here.
    call: ?instance.Provider.SessionArgs = null,
    tool_specs: []instance.ToolSpec = &.{},
    /// How many times the session released the stream.
    deinits: usize = 0,
    /// The deltas the stream hands out, in order. After the last one the
    /// stream ends, and `next` returns null.
    replies: std.ArrayList(instance.Delta) = .empty,
    /// Multi-round mode: stream call n gets `rounds[n]`, the last one repeats.
    rounds: std.ArrayList(std.ArrayList(instance.Delta)) = .empty,
    queue_index: usize = 0,
    calls: usize = 0,
    active: ?*std.ArrayList(instance.Delta) = null,

    fn init(alloc: std.mem.Allocator) MockProvider {
        return .{
            .allocator = alloc,
            .mocks = .{
                .stream = ztf.Mock(instance.Provider.DeltaStream).init(alloc),
            },
        };
    }

    fn deinit(self: *MockProvider) void {
        self.freeToolSpecs();
        for (self.rounds.items) |*list| list.deinit(self.allocator);
        self.rounds.deinit(self.allocator);
        self.replies.deinit(self.allocator);
        self.mocks.stream.deinit();
    }

    fn copyToolSpecs(self: *MockProvider, specs: []const instance.ToolSpec) ![]instance.ToolSpec {
        self.freeToolSpecs();
        if (specs.len == 0) return &.{};
        const owned = try self.allocator.alloc(instance.ToolSpec, specs.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |spec| {
                self.allocator.free(spec.name);
                self.allocator.free(spec.description);
            }
            self.allocator.free(owned);
        }
        for (specs, 0..) |spec, index| {
            owned[index] = .{
                .name = try self.allocator.dupe(u8, spec.name),
                .description = try self.allocator.dupe(u8, spec.description),
            };
            filled += 1;
        }
        return owned;
    }

    fn freeToolSpecs(self: *MockProvider) void {
        for (self.tool_specs) |spec| {
            self.allocator.free(spec.name);
            self.allocator.free(spec.description);
        }
        if (self.tool_specs.len > 0) self.allocator.free(self.tool_specs);
        self.tool_specs = &.{};
    }

    /// Make the stream hand out these deltas, in order.
    fn returns(self: *MockProvider, replies: []const instance.Delta) !void {
        self.replies.clearRetainingCapacity();
        try self.replies.appendSlice(self.allocator, replies);
    }

    /// Queue the replies of each round: stream call n gets round n, the
    /// last round repeats.
    fn queue(self: *MockProvider, alloc: std.mem.Allocator, rounds: []const []const instance.Delta) !void {
        self.calls = rounds.len;
        for (rounds) |round| {
            var list: std.ArrayList(instance.Delta) = .empty;
            try list.appendSlice(self.allocator, round);
            try self.rounds.append(alloc, list);
        }
    }

    fn supplyNext(impl: *anyopaque, _: std.Io) instance.Provider.DeltaStream.Error!?instance.Delta {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        const list = self.active orelse &self.replies;
        if (list.items.len == 0) return null;
        return list.orderedRemove(0);
    }

    fn supplyDeinit(impl: *anyopaque, _: std.Io) void {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        self.deinits += 1;
    }

    fn stream(impl: *anyopaque, args: instance.Provider.SessionArgs) Error!instance.Provider.DeltaStream {
        const self: *MockProvider = @ptrCast(@alignCast(impl));
        const specs = try self.copyToolSpecs(args.tools);
        self.tool_specs = specs;
        var call = args;
        call.tools = specs;
        self.call = call;
        if (self.rounds.items.len > 0) {
            if (self.queue_index >= self.rounds.items.len) self.queue_index = self.rounds.items.len - 1;
            self.active = &self.rounds.items[self.queue_index];
            self.queue_index += 1;
        }
        self.mocks.stream.recordCall("stream") catch return error.Canceled;
        return .{ .impl = self, .next_fn = supplyNext, .deinit_fn = supplyDeinit };
    }

    fn asProvider(self: *MockProvider, alloc: std.mem.Allocator) !*const instance.Provider {
        const ref = try alloc.create(instance.Provider);
        ref.* = instance.Provider.init(self, stream);
        return ref;
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(instance.Event) = .empty,
    session: ?*instance.Session = null,
    active_at_start: usize = 0,
    started_id: []u8 = &.{},
    started_name: []u8 = &.{},
    started_source: []u8 = &.{},
    started_at_ms: i64 = 0,

    fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Collector) void {
        self.allocator.free(self.started_id);
        self.allocator.free(self.started_name);
        self.allocator.free(self.started_source);
        self.events.deinit(self.allocator);
    }

    fn sink(self: *Collector) instance.EventSink {
        return .{ .ctx = self, .emit = emit };
    }

    fn emit(ctx: *anyopaque, event: instance.Event) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.events.append(self.allocator, event) catch @panic("out of memory");
        switch (event) {
            .tool_started => |value| {
                self.replacedupe(&self.started_id, value.id);
                self.replacedupe(&self.started_name, value.name);
                self.replacedupe(&self.started_source, value.source);
                self.started_at_ms = value.started_at_ms;
                if (self.session) |session| self.active_at_start = session.active_calls.items.len;
            },
            else => {},
        }
    }

    fn replacedupe(self: *Collector, slot: *[]u8, text: []const u8) void {
        self.allocator.free(slot.*);
        slot.* = self.allocator.dupe(u8, text) catch @panic("out of memory");
    }
};

const Fixture = struct {
    /// One fixed id that every test uses.
    const id = instance.Session.Id.fromBytes(.{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10,
    });

    mock: MockProvider,
    provider: *const instance.Provider,
    session: instance.Session,

    /// Fill in the fields. Do not return a Fixture by value. The provider
    /// points at the mock, and a returned value leaves that pointer on a copy.
    fn init(self: *Fixture, alloc: std.mem.Allocator) !void {
        self.mock = MockProvider.init(alloc);
        errdefer self.mock.deinit();
        self.provider = try self.mock.asProvider(alloc);
        errdefer alloc.destroy(self.provider);
        self.session = try instance.Session.init(alloc, id, self.provider);
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        self.session.deinit(alloc);
        alloc.destroy(self.provider);
        self.mock.deinit();
    }
};

test "session initializes" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit(std.testing.allocator);
    const session = &f.session;

    try expect(session.messages.items).toBeEmpty();
    try expect(Fixture.id).toEqual(session.id);
}

test "message added to the session is present in the history" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.appendMessage(alloc, "Hello, Agent!");

    try expect(session.messages.items).toHaveLength(1);
    try expect(session.messages.items[0].user.content).toEqual("Hello, Agent!");
}

test "run calls the provider once per run" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try f.mock.mocks.stream.toHaveBeenCalledTimes(1);
    const call = f.mock.call.?;
    try expect(call.session).toEqual(Fixture.id);
    try expect(call.model).toEqual(session.model.id());
    try expect(call.system).toEqual(session.system);
}

test "run hands the provider the whole history in order" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.appendMessage(alloc, "first");
    try session.appendMessage(alloc, "second");
    try session.run(std.testing.io, alloc, null);

    try f.mock.mocks.stream.toHaveBeenCalledTimes(1);
    const call = f.mock.call.?;
    try expect(call.messages).toHaveLength(2);
    try expect(call.messages[0].user.content).toEqual("first");
    try expect(call.messages[1].user.content).toEqual("second");
    try expect(call.tools).toHaveLength(1);
    try expect(call.tools[0].name).toEqual("eval");
}

test "run folds the streamed deltas into one assistant message" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "Hi!" },
        .{ .delta = " How can" },
        .{ .delta = " I help?" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try expect(session.messages.items).toHaveLength(2);
    try expect(session.messages.items[1].assistant.content).toEqual("Hi! How can I help?");
}

test "a done delta replaces the deltas before it" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "partial" },
        .{ .done = "the complete answer" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try expect(session.messages.items[1].assistant.content).toEqual("the complete answer");
}

test "a completed lifecycle still commits the message" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "done." },
        .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try expect(session.messages.items).toHaveLength(2);
}

test "a tool call does not become part of the assistant text" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "let me check " },
        .{ .tool_invocation = .{ .id = "call_1", .name = "weather", .arguments = "{}" } },
        .{ .done = "let me check the weather." },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try expect(session.messages.items[1].assistant.content).toEqual("let me check the weather.");
}

test "an error delta leaves the history unchanged and releases the stream" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "partial" },
        .{ .@"error" = "boom" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try std.testing.expectError(error.ProviderFailed, session.run(std.testing.io, alloc, null));

    try expect(session.messages.items).toHaveLength(1);
    try std.testing.expectEqual(@as(usize, 1), f.mock.deinits);
}

test "a failed lifecycle leaves the history unchanged" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .lifecycle = .{ .id = "resp_1", .kind = .failed } },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try std.testing.expectError(error.ResponseFailed, session.run(std.testing.io, alloc, null));

    try expect(session.messages.items).toHaveLength(1);
}

test "the stream is released after a completed turn" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{
        .{ .delta = "hi" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 1), f.mock.deinits);
}

const MockEvaluator = struct {
    calls: usize = 0,
    last_source: ?[]u8 = null,
    fail: bool = false,

    fn eval(ctx: *anyopaque, _: std.Io, alloc: std.mem.Allocator, source: []const u8) instance.Evaluator.Error![]u8 {
        const self: *MockEvaluator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.last_source) |old| alloc.free(old);
        self.last_source = try alloc.dupe(u8, source);
        if (self.fail) return error.Failed;
        return try alloc.dupe(u8, "observation text");
    }

    fn deinit(self: *MockEvaluator, alloc: std.mem.Allocator) void {
        if (self.last_source) |old| alloc.free(old);
    }

    fn evaluator(self: *MockEvaluator) instance.Evaluator {
        return .{ .ctx = self, .eval = eval };
    }
};

fn installBundle(
    session: *instance.Session,
    alloc: std.mem.Allocator,
    bundle_name: []const u8,
    tool_name: []const u8,
    description: []const u8,
    usage: []const u8,
) !void {
    const tools = try alloc.alloc(instance.Bundle.Tool, 1);
    defer alloc.free(tools);
    tools[0] = .{ .name = tool_name, .description = description, .usage = usage };

    const bundles = try alloc.alloc(instance.Bundle, 1);
    defer alloc.free(bundles);
    bundles[0] = .{ .name = bundle_name, .description = "Test bundle.", .tools = tools };
    try session.environment.setBundles(alloc, bundles);
}

test "the request loop runs each action round until a text-only answer" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 1), evaluator.calls);
    try std.testing.expectEqualStrings("(+ 1 2)", evaluator.last_source.?);
    try std.testing.expectEqual(@as(usize, 4), session.messages.items.len);
    const carried = session.messages.items[1].assistant;
    try std.testing.expectEqual(@as(usize, 1), carried.tool_calls.len);
    try std.testing.expectEqualStrings("eval", carried.tool_calls[0].name);
    const observation = session.messages.items[2].tool;
    try std.testing.expectEqualStrings("call_1", observation.id);
    try std.testing.expectEqualStrings("eval", observation.name);
    try std.testing.expectEqualStrings("observation text", observation.content);
    try std.testing.expectEqual(instance.Tool.Status.completed, observation.status);
    try std.testing.expect(observation.timing.started_at_ms > 0);
    try std.testing.expectEqualStrings("All done.", session.messages.items[3].assistant.content);
}

test "a failed evaluation becomes an observation" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{ .fail = true };
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "Handled." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqualStrings("Error: Failed", session.messages.items[2].tool.content);
    try std.testing.expectEqual(instance.Tool.Status.failed, session.messages.items[2].tool.status);
}

test "the session asks for a final answer when the round budget is spent" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;
    session.max_rounds = 1;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "final answer" }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 2), f.mock.calls);
    try expect(f.mock.call.?.tools).toBeEmpty();
    try expect(session.messages.items[3].user.content).toEqual(instance.Session.final_answer_prompt);
    try expect(session.messages.items[4].assistant.content).toEqual("final answer");
}

test "run hands the provider the eval tool with the catalog" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());
    try installBundle(session, alloc, "env", "help", "Show help.", "(env.help)");

    try f.mock.returns(&.{.{ .delta = "done" }});

    try session.appendMessage(alloc, "Hello.");
    try session.run(std.testing.io, alloc, null);

    const call = f.mock.call.?;
    try expect(call.tools).toHaveLength(1);
    try expect(call.tools[0].name).toEqual("eval");
    try std.testing.expect(std.mem.indexOf(u8, call.tools[0].description, "Submit one Scheme form.") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.tools[0].description, "(env.help): Show help.") != null);
}

test "the evaluator receives the decoded source" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 1), evaluator.calls);
    try std.testing.expectEqualStrings("(+ 1 2)", evaluator.last_source.?);
    try std.testing.expectEqualStrings("observation text", session.messages.items[2].tool.content);
}

test "a raw argument reaches the evaluator unchanged" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "(+ 1 2)" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 1), evaluator.calls);
    try std.testing.expectEqualStrings("(+ 1 2)", evaluator.last_source.?);
    try std.testing.expectEqualStrings("observation text", session.messages.items[2].tool.content);
}

test "the assistant message keeps the raw arguments the model sent" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    const carried = session.messages.items[1].assistant;
    try std.testing.expectEqual(@as(usize, 1), carried.tool_calls.len);
    try std.testing.expectEqualStrings("{\"source\": \"(+ 1 2)\"}", carried.tool_calls[0].arguments);
}

test "setBundles with no entries leaves the eval catalog empty" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.environment.setBundles(alloc, &.{});
    try expect(session.environment.bundles).toBeEmpty();

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try f.mock.returns(&.{.{ .delta = "done" }});
    try session.appendMessage(alloc, "Hello.");
    try session.run(std.testing.io, alloc, null);

    const call = f.mock.call.?;
    try expect(call.tools).toHaveLength(1);
    try std.testing.expectEqualStrings("Submit one Scheme form. Available tools:", call.tools[0].description);
}

test "setBundles adopts bundles, skills, and tools" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    const skills = [_]instance.Bundle.Skill{
        .{ .name = "alpha-skill", .description = "A skill.", .content = "Skill body." },
    };
    const tools = [_]instance.Bundle.Tool{
        .{
            .name = "alpha-pin",
            .description = "Returns the fixture value.",
            .usage = "(alpha-pin)",
            .skill = "alpha-skill",
        },
        .{
            .name = "beta-probe",
            .description = "A probe.",
        },
    };
    const bundles = [_]instance.Bundle{
        .{ .name = "alpha", .description = "Alpha bundle.", .skills = &skills, .tools = &tools },
    };
    try session.environment.setBundles(alloc, &bundles);

    try expect(session.environment.bundles).toHaveLength(1);
    try expect(session.environment.bundles[0].name).toEqual("alpha");
    try expect(session.environment.bundles[0].description).toEqual("Alpha bundle.");
    try expect(session.environment.bundles[0].skills).toHaveLength(1);
    try expect(session.environment.bundles[0].skills[0].name).toEqual("alpha-skill");
    try expect(session.environment.bundles[0].skills[0].description).toEqual("A skill.");
    try expect(session.environment.bundles[0].skills[0].content).toEqual("Skill body.");
    try expect(session.environment.bundles[0].tools).toHaveLength(2);
    try expect(session.environment.bundles[0].tools[0].name).toEqual("alpha-pin");
    try expect(session.environment.bundles[0].tools[0].description).toEqual("Returns the fixture value.");
    try expect(session.environment.bundles[0].tools[0].usage).toEqual("(alpha-pin)");
    try expect(session.environment.bundles[0].tools[0].skill.?).toEqual("alpha-skill");
    try std.testing.expect(std.mem.indexOf(u8, session.environment.eval_description, "(alpha-pin): Returns the fixture value.") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.environment.eval_description, "(alpha.beta-probe): A probe.") != null);

    const replaced = [_]instance.Bundle{
        .{ .name = "gamma", .description = "A later bundle." },
    };
    try session.environment.setBundles(alloc, &replaced);

    try expect(session.environment.bundles).toHaveLength(1);
    try expect(session.environment.bundles[0].name).toEqual("gamma");
    try expect(session.environment.bundles[0].tools).toBeEmpty();
}

test "turn returns the messages it added" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{.{ .delta = "Hi!" }});

    const added = try session.turn(std.testing.io, alloc, "hello", null);

    try expect(added).toHaveLength(1);
    try expect(added[0].assistant.content).toEqual("Hi!");
    try expect(session.messages.items).toHaveLength(2);
}

test "run streams message deltas and a done event" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var collector = Collector.init(alloc);
    defer collector.deinit();

    try f.mock.returns(&.{
        .{ .delta = "Hi!" },
        .{ .delta = " there" },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, collector.sink());

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    const first = switch (collector.events.items[0]) {
        .message_delta => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Hi!", first);
    const second = switch (collector.events.items[1]) {
        .message_delta => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(" there", second);
    const done = switch (collector.events.items[2]) {
        .message_done => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Hi! there", done);
}

test "run reports an eval start and finish with timing" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    var collector = Collector.init(alloc);
    defer collector.deinit();
    collector.session = session;

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, collector.sink());

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    switch (collector.events.items[0]) {
        .tool_started => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("call_1", collector.started_id);
    try std.testing.expectEqualStrings("eval", collector.started_name);
    try std.testing.expectEqualStrings("(+ 1 2)", collector.started_source);
    try std.testing.expect(collector.started_at_ms > 0);
    try std.testing.expectEqual(@as(usize, 1), collector.active_at_start);

    const finished = switch (collector.events.items[1]) {
        .tool_finished => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("call_1", finished.id);
    try std.testing.expectEqualStrings("observation text", finished.output);
    try std.testing.expectEqual(instance.Tool.Status.completed, finished.status);
    try std.testing.expect(finished.duration_ms >= 0);

    const done = switch (collector.events.items[2]) {
        .message_done => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("All done.", done);

    try std.testing.expectEqual(@as(usize, 0), session.active_calls.items.len);

    const observation = session.messages.items[2].tool;
    try std.testing.expectEqual(collector.started_at_ms, observation.timing.started_at_ms);
    try std.testing.expectEqual(finished.duration_ms, observation.timing.duration_ms);
}

test "an unknown tool reports a start and a failed finish" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    var collector = Collector.init(alloc);
    defer collector.deinit();

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "missing", .arguments = "{}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, collector.sink());

    try std.testing.expectEqual(@as(usize, 0), evaluator.calls);
    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);

    switch (collector.events.items[0]) {
        .tool_started => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("{}", collector.started_source);

    const finished = switch (collector.events.items[1]) {
        .tool_finished => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(instance.Tool.Status.failed, finished.status);
    try std.testing.expectEqualStrings("Error: unknown tool missing", finished.output);
}

test "a user evaluation is recorded without a provider turn" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{};
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try session.evaluate(std.testing.io, alloc, "(env.help)", null);

    try std.testing.expectEqual(@as(usize, 1), evaluator.calls);
    try std.testing.expectEqualStrings("(env.help)", evaluator.last_source.?);
    try f.mock.mocks.stream.toHaveBeenCalledTimes(0);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);

    const evaluation = session.messages.items[0].evaluation;
    try std.testing.expectEqualStrings("eval-0", evaluation.id);
    try std.testing.expectEqualStrings("(env.help)", evaluation.source);
    try std.testing.expectEqual(instance.Origin.user, evaluation.origin);
    try std.testing.expectEqualStrings("observation text", evaluation.output);
    try std.testing.expectEqual(instance.Tool.Status.completed, evaluation.status);
    try std.testing.expect(evaluation.timing.started_at_ms > 0);
    try std.testing.expectEqual(@as(usize, 0), session.active_calls.items.len);
}

test "a session runs an evaluation in its own environment" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.evaluate(std.testing.io, alloc, "(env.help)", null);

    const evaluation = session.messages.items[0].evaluation;
    try std.testing.expectEqualStrings("help", evaluation.output);
    try std.testing.expectEqual(instance.Tool.Status.completed, evaluation.status);
    try std.testing.expectEqual(@as(usize, 0), session.active_calls.items.len);
}

test "a failed user evaluation is recorded as failed" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var evaluator = MockEvaluator{ .fail = true };
    defer evaluator.deinit(alloc);
    session.setEvaluator(evaluator.evaluator());

    try session.evaluate(std.testing.io, alloc, "(env.help)", null);

    const evaluation = session.messages.items[0].evaluation;
    try std.testing.expectEqual(instance.Tool.Status.failed, evaluation.status);
    try std.testing.expectEqualStrings("Error: Failed", evaluation.output);
}
