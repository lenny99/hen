const std = @import("std");
const uuid = @import("uuid");
const environment = @import("environment");
const provider_mod = @import("provider.zig");
const message_mod = @import("message.zig");

const Provider = provider_mod.Provider;
const SystemPrompt = provider_mod.SystemPrompt;
const Message = message_mod.Message;
const Tool = message_mod.Tool;
const ToolSpec = provider_mod.ToolSpec;

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

/// The action payload the environment carries back for one tool call.
///
/// One user request drives zero or more action rounds. Each round streams one
/// model turn, folds the text deltas, and collects the tool calls the model
/// made. When the turn carries calls, the session appends one assistant
/// message that carries them, runs every call in the environment, and appends
/// one observation message per call; the next round reads those observations.
/// When the turn carries no calls, the session appends the assistant text and
/// the request is done.
///
/// The round budget lives in `Session.max_rounds`. When it is spent, the
/// session stops sending the tool list and asks the model for a final answer.
/// That final turn gets no tool list, so the text answer is the last message.
pub const Session = struct {
    pub const Id = uuid.UUID;

    pub const action_tool_name = "hen-eval";

    pub const action_tool_description =
        "Run exactly one Scheme expression per call: pass one complete expression as source. " ++
        "Results and observations come back as text; errors start with Error:. " ++
        "Tools are called like (hen:tools/call! \"name\" '((k . \"v\"))).";

    /// One registered tool the record listing reports; the catalog lines in
    /// the action tool description are assembled from these.
    pub const CatalogEntry = struct {
        name: []const u8,
        summary: []const u8,
        when: []const u8,
    };

    /// The collected catalog entries with methods over them.
    pub const Catalog = struct {
        entries: []const CatalogEntry = &.{},

        pub fn init(entries: []const CatalogEntry) Catalog {
            return .{ .entries = entries };
        }

        pub fn adopt(alloc: std.mem.Allocator, entries: []const CatalogEntry) std.mem.Allocator.Error!Catalog {
            var owned = try alloc.alloc(CatalogEntry, entries.len);
            var filled: usize = 0;
            errdefer {
                for (owned[0..filled]) |copy| freeEntry(alloc, copy);
                alloc.free(owned);
            }
            for (entries, 0..) |entry, index| {
                owned[index] = try copyEntry(alloc, entry);
                filled += 1;
            }
            return .{ .entries = owned };
        }

        pub fn free(self: Catalog, alloc: std.mem.Allocator) void {
            for (self.entries) |entry| freeEntry(alloc, entry);
            if (self.entries.len > 0) alloc.free(self.entries);
        }

        pub fn render(self: Catalog, alloc: std.mem.Allocator, base: []const u8) std.mem.Allocator.Error![]u8 {
            var text: std.ArrayList(u8) = .empty;
            errdefer text.deinit(alloc);
            try text.appendSlice(alloc, base);
            for (self.entries) |entry| {
                try text.appendSlice(alloc, "\n");
                try text.appendSlice(alloc, entry.name);
                try text.appendSlice(alloc, ": ");
                try text.appendSlice(alloc, entry.summary);
                try text.appendSlice(alloc, " (");
                try text.appendSlice(alloc, entry.when);
                try text.appendSlice(alloc, ")");
            }
            return text.toOwnedSlice(alloc);
        }

        fn copyEntry(alloc: std.mem.Allocator, entry: CatalogEntry) std.mem.Allocator.Error!CatalogEntry {
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            const summary = try alloc.dupe(u8, entry.summary);
            errdefer alloc.free(summary);
            const when = try alloc.dupe(u8, entry.when);
            errdefer alloc.free(when);
            return .{ .name = name, .summary = summary, .when = when };
        }

        fn freeEntry(alloc: std.mem.Allocator, entry: CatalogEntry) void {
            alloc.free(entry.name);
            alloc.free(entry.summary);
            alloc.free(entry.when);
        }
    };

    id: Id,
    provider: *const Provider,
    model: *const Model,

    system: SystemPrompt,
    messages: std.ArrayList(Message),

    /// The registered tool records the session adopted with `setCatalog`.
    /// Empty until then; the action tool description stays the fixed text.
    catalog: Catalog = .{},

    /// The one function tool sent with every turn. Its description carries
    /// the fixed contract plus one `name: summary (when)` line per catalog
    /// entry.
    action_tool: ToolSpec = .{ .name = action_tool_name, .description = action_tool_description },

    /// Whether `catalog` and `action_tool.description` are session-owned.
    catalog_attached: bool = false,

    /// The environment that runs one action per call. `null` means no tools
    /// are executable; the session then never sends a tool list either.
    environment: ?*const environment.Environment = null,

    /// Action rounds per user request before the session asks for a final
    /// answer. Docs phase #4: default 8, set on the session.
    max_rounds: usize = 8,

    pub fn init(id: Id, provider: *const Provider) !Session {
        return .{
            .id = id,
            .provider = provider,
            .model = &glm51,
            .system = "",
            .messages = .empty,
            .environment = null,
        };
    }

    /// Adopt the assembled catalog: one `name: summary (when)` line per
    /// registered tool appended to the action tool description. The session
    /// owns copies of the entries and the new description, always built from
    /// the pristine fixed contract text. An empty registry keeps the fixed
    /// description untouched.
    pub fn setCatalog(self: *Session, alloc: std.mem.Allocator, entries: []const CatalogEntry) std.mem.Allocator.Error!void {
        if (entries.len == 0) return;

        const catalog = try Catalog.adopt(alloc, entries);
        errdefer catalog.free(alloc);
        const description = try catalog.render(alloc, action_tool_description);

        if (self.catalog_attached) {
            self.catalog.free(alloc);
            alloc.free(self.action_tool.description);
        }
        self.catalog_attached = true;
        self.catalog = catalog;
        self.action_tool.description = description;
    }

    /// Append one user message. The session owns a copy of `message`.
    pub fn appendMessage(self: *Session, alloc: std.mem.Allocator, message: []const u8) !void {
        const content = try alloc.dupe(u8, message);
        errdefer alloc.free(content);
        try self.messages.append(alloc, .{ .user = .{ .content = content } });
    }

    /// Run one user request to completion: zero or more action rounds, then
    /// either a text-only turn or the forced final answer once the round
    /// budget is spent.
    ///
    /// Cancellation happens at the points between rounds; within a round the
    /// stream and the environment see the cancellation the `io` layer gives
    /// them.
    pub fn run(self: *Session, io: std.Io, alloc: std.mem.Allocator) !void {
        var round: usize = 0;
        while (round < self.max_rounds) : (round += 1) {
            const calls = try self.runTurn(io, alloc, true);
            if (calls == 0) return;
        }

        // The round budget is spent. Stop sending the tool list and ask for
        // a final answer on the next turn.
        try io.checkCancel();
        try self.appendMessage(alloc, final_answer_prompt);
        _ = try self.runTurn(io, alloc, false);
    }

    pub const final_answer_prompt =
        "Please give your final answer now: wrap up and reply with text only.";

    /// Stream one model turn, fold the text deltas, and append exactly one of
    /// the two outcomes. Without tool calls the assistant text goes in and the
    /// returned count is 0. With tool calls the session appends the assistant
    /// message that carries them, runs each action in the environment, and
    /// appends one observation message per call; the returned count is the
    /// number of calls it ran.
    fn runTurn(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        with_tools: bool,
    ) !usize {
        var stream = try self.provider.stream(.{
            .model = self.model.id(),
            .system = self.system,
            .messages = self.messages.items,
            .tools = if (self.environment != null and with_tools) &.{self.action_tool} else &.{},
            .session = self.id,
        });
        defer stream.deinit(io);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);

        var calls: std.ArrayList(Tool.Invocation) = .empty;
        errdefer {
            for (calls.items) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments);
            }
            calls.deinit(alloc);
        }

        while (try stream.next(io)) |delta| {
            switch (delta) {
                .delta => |chunk| try text.appendSlice(alloc, chunk),
                // `done` is the provider's complete text for the item, so it
                // replaces whatever the deltas accumulated before it.
                .done => |complete| {
                    text.clearRetainingCapacity();
                    try text.appendSlice(alloc, complete);
                },
                .tool_invocation => |invocation| {
                    // The invocation slices live in the stream arena, so copy
                    // everything the session keeps.
                    try calls.append(alloc, .{
                        .id = try alloc.dupe(u8, invocation.id),
                        .name = try alloc.dupe(u8, invocation.name),
                        .arguments = try alloc.dupe(u8, invocation.arguments),
                    });
                },
                .tool_return => {},
                .lifecycle => |lifecycle| switch (lifecycle.kind) {
                    .failed => return error.ResponseFailed,
                    .completed, .incomplete => {},
                },
                .@"error" => return error.ProviderFailed,
            }
        }

        if (calls.items.len == 0) {
            if (text.items.len == 0) return 0;

            try self.appendOwnedAssistant(alloc, try alloc.dupe(u8, text.items), &.{});
            return 0;
        }

        // One assistant message carries every call of this round.
        const carried = try calls.toOwnedSlice(alloc);
        try self.appendOwnedAssistant(alloc, try alloc.dupe(u8, text.items), carried);

        // Run each action in the environment and append one observation per
        // call. A tool error is an observation, not a failed turn.
        for (carried) |call| {
            const output = try self.runAction(io, alloc, call);
            try self.messages.append(alloc, .{ .tool = output });
        }
        return carried.len;
    }

    fn appendOwnedAssistant(
        self: *Session,
        alloc: std.mem.Allocator,
        content: []u8,
        tool_calls: []const Tool.Invocation,
    ) !void {
        errdefer alloc.free(content);
        try self.messages.append(alloc, .{ .assistant = .{
            .content = content,
            .tool_calls = tool_calls,
        } });
    }

    /// Run one action in the environment. Errors come back as an observation
    /// that starts with `Error: `; `error.Canceled` propagates.
    fn runAction(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        call: Tool.Invocation,
    ) !Tool.Output {
        const call_id = try alloc.dupe(u8, call.id);
        errdefer alloc.free(call_id);

        const call_name = try alloc.dupe(u8, call.name);
        errdefer alloc.free(call_name);

        const decoded = try decodeActionSource(alloc, call.arguments);

        const observation = switch (decoded) {
            .observation => |text| text,
            .source => |source| blk: {
                defer alloc.free(source);
                if (self.environment) |env|
                    break :blk env.call(io, alloc, call.name, source) catch |err| switch (err) {
                        error.OutOfMemory, error.Canceled => return err,
                        else => try std.fmt.allocPrint(alloc, "Error: {t}", .{err}),
                    };
                break :blk try alloc.dupe(u8, "Error: no environment");
            },
        };

        // The environment returns caller-owned text, so the session keeps it.
        return .{ .id = call_id, .name = call_name, .content = observation };
    }

    const DecodedSource = union(enum) {
        source: []const u8,
        observation: []const u8,
    };

    fn decodeActionSource(alloc: std.mem.Allocator, arguments: []const u8) !DecodedSource {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .source = try alloc.dupe(u8, arguments) },
        };
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |object| object,
            else => return .{ .source = try alloc.dupe(u8, arguments) },
        };

        const member = object.get("source") orelse
            return .{ .observation = try alloc.dupe(u8, "Error: tool call arguments missing source") };

        const text = switch (member) {
            .string => |text| text,
            else => return .{ .observation = try alloc.dupe(u8, "Error: tool call arguments source is not a string") },
        };

        return .{ .source = try alloc.dupe(u8, text) };
    }

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        if (self.catalog_attached) {
            self.catalog.free(alloc);
            alloc.free(self.action_tool.description);
        }
        for (self.messages.items) |message| switch (message) {
            .user => |user| alloc.free(user.content),
            .assistant => |assistant| {
                alloc.free(assistant.content);
                for (assistant.tool_calls) |call| {
                    alloc.free(call.id);
                    alloc.free(call.name);
                    alloc.free(call.arguments);
                }
                alloc.free(assistant.tool_calls);
            },
            .tool => |tool| {
                alloc.free(tool.id);
                alloc.free(tool.name);
                alloc.free(tool.content);
            },
        };
        self.messages.deinit(alloc);
    }
};
