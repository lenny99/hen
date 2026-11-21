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

    fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Collector) void {
        self.events.deinit(self.allocator);
    }

    fn listener(self: *Collector) instance.Listener {
        return .{ .ctx = self, .func = emit };
    }

    fn emit(ctx: *anyopaque, event: instance.Event) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.events.append(self.allocator, event) catch @panic("out of memory");
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
    try std.testing.expectEqual(instance.Origin.user, session.messages.items[0].origin);
    try expect(session.messages.items[0].payload.message).toEqual("Hello, Agent!");
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
    try expect(call.messages[0].payload.message).toEqual("first");
    try expect(call.messages[1].payload.message).toEqual("second");
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
    try expect(session.messages.items[1].payload.message).toEqual("Hi! How can I help?");
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

    try expect(session.messages.items[1].payload.message).toEqual("the complete answer");
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
        .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
        .{ .done = "let me check the weather." },
    });

    try session.appendMessage(alloc, "Hello, Agent!");
    try session.run(std.testing.io, alloc, null);

    try expect(session.messages.items).toHaveLength(3);
    try expect(session.messages.items[1].payload.message).toEqual("let me check the weather.");
    try expect(session.messages.items[2].payload.evaluation.output).toEqual("3");
    try std.testing.expectEqual(instance.Evaluation.Status.completed, session.messages.items[2].payload.evaluation.status);
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

test "the request loop runs each action round until a text-only answer" {
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

    try f.mock.mocks.stream.toHaveBeenCalledTimes(2);
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    try std.testing.expectEqual(instance.Origin.model, session.messages.items[1].origin);
    try std.testing.expectEqualStrings("call_1", session.messages.items[1].payload.evaluation.call.id);
    try std.testing.expectEqualStrings("3", session.messages.items[1].payload.evaluation.output);
    try std.testing.expectEqualStrings("All done.", session.messages.items[2].payload.message);
}

test "a failed evaluation becomes an observation" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "not scheme" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "Handled." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    try std.testing.expectEqual(instance.Evaluation.Status.failed, session.messages.items[1].payload.evaluation.status);
    try std.testing.expect(std.mem.startsWith(u8, session.messages.items[1].payload.evaluation.output, "Error: "));
}

test "the session asks for a final answer when the round budget is spent" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;
    session.max_rounds = 1;

    var collector = Collector.init(alloc);
    defer collector.deinit();

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "final answer" }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, collector.listener());

    try f.mock.mocks.stream.toHaveBeenCalledTimes(2);
    try expect(f.mock.call.?.tools).toBeEmpty();
    try std.testing.expectEqual(@as(usize, 4), session.messages.items.len);
    try std.testing.expectEqual(instance.Origin.user, session.messages.items[2].origin);
    try std.testing.expectEqualStrings(instance.Session.final_answer_prompt, session.messages.items[2].payload.message);
    try std.testing.expectEqualStrings("final answer", session.messages.items[3].payload.message);

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    switch (collector.events.items[0].payload) {
        .eval => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(instance.Origin.user, collector.events.items[1].origin);
    const user_done = switch (collector.events.items[1].payload) {
        .message => |part| part.done,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(instance.Session.final_answer_prompt, user_done);
    const model_done = switch (collector.events.items[2].payload) {
        .message => |part| part.done,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("final answer", model_done);
}

fn installHelpBundle(session: *instance.Session) !void {
    const tools = [_]instance.Bundle.Tool{
        .{ .name = "help", .description = "Show help.", .usage = "(env.help)" },
    };
    const bundles = [_]instance.Bundle{
        .{ .name = "env", .description = "Test bundle.", .tools = &tools },
    };
    try session.environment.setBundles(&bundles);
}

test "run hands the provider the eval tool with the catalog" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try installHelpBundle(session);

    try f.mock.returns(&.{.{ .delta = "done" }});

    try session.appendMessage(alloc, "Hello.");
    try session.run(std.testing.io, alloc, null);

    const call = f.mock.call.?;
    try expect(call.tools).toHaveLength(1);
    try expect(call.tools[0].name).toEqual("eval");
    try std.testing.expect(std.mem.indexOf(u8, call.tools[0].description, "Submit one Scheme form.") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.tools[0].description, "(env.help): Show help.") != null);
}

test "setBundles with no entries leaves the eval catalog empty" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try session.environment.setBundles(&.{});
    try expect(session.environment.bundles).toBeEmpty();

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
    try session.environment.setBundles(&bundles);

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
    try std.testing.expect(std.mem.indexOf(u8, session.environment.evalDescription(), "(alpha-pin): Returns the fixture value.") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.environment.evalDescription(), "(alpha.beta-probe): A probe.") != null);

    const replaced = [_]instance.Bundle{
        .{ .name = "gamma", .description = "A later bundle." },
    };
    try session.environment.setBundles(&replaced);

    try expect(session.environment.bundles).toHaveLength(1);
    try expect(session.environment.bundles[0].name).toEqual("gamma");
    try expect(session.environment.bundles[0].tools).toBeEmpty();
}

test "turn appends the user message and runs the request" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.returns(&.{.{ .delta = "Hi!" }});

    try session.turn(std.testing.io, alloc, "hello", null);

    try expect(session.messages.items).toHaveLength(2);
    try expect(session.messages.items[0].payload.message).toEqual("hello");
    try expect(session.messages.items[1].payload.message).toEqual("Hi!");
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
    try session.run(std.testing.io, alloc, collector.listener());

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    try std.testing.expectEqual(instance.Origin.model, collector.events.items[0].origin);
    const first = switch (collector.events.items[0].payload) {
        .message => |part| part.delta,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Hi!", first);
    const second = switch (collector.events.items[1].payload) {
        .message => |part| part.delta,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(" there", second);
    const done = switch (collector.events.items[2].payload) {
        .message => |part| part.done,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Hi! there", done);
}

test "run reports a finished eval with timing" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    var collector = Collector.init(alloc);
    defer collector.deinit();

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "{\"source\": \"(+ 1 2)\"}" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "All done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, collector.listener());

    try std.testing.expectEqual(@as(usize, 2), collector.events.items.len);
    try std.testing.expectEqual(instance.Origin.model, collector.events.items[0].origin);
    const evaluation = collector.events.items[0].payload.eval;
    try std.testing.expectEqualStrings("call_1", evaluation.call.id);
    try std.testing.expectEqualStrings("3", evaluation.output);
    try std.testing.expectEqual(instance.Evaluation.Status.completed, evaluation.status);
    try std.testing.expect(evaluation.duration != null);
    const done = switch (collector.events.items[1].payload) {
        .message => |part| part.done,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("All done.", done);

    try std.testing.expectEqual(session.messages.items[1].payload.evaluation.start, evaluation.start);
    try std.testing.expect(session.messages.items[1].payload.evaluation.duration != null);
}

test "a raw argument reaches the evaluator unchanged" {
    const alloc = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const session = &f.session;

    try f.mock.queue(alloc, &.{
        &.{
            .{ .tool_invocation = .{ .id = "call_1", .name = "eval", .arguments = "(+ 1 2)" } },
            .{ .lifecycle = .{ .id = "resp_1", .kind = .completed } },
        },
        &.{.{ .done = "Done." }},
    });

    try session.appendMessage(alloc, "How is the weather?");
    try session.run(std.testing.io, alloc, null);

    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
    try std.testing.expectEqualStrings("3", session.messages.items[1].payload.evaluation.output);
}
