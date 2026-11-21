const std = @import("std");
const elz = @import("elz");

pub const Error = std.mem.Allocator.Error || error{
    InitializationFailed,
    InvalidCString,
    OutputBufferTooSmall,
    SchemeError,
    WrongThread,
};

/// Configuration passed to the interpreter. `heap_bytes` is the managed heap
/// limit. A value of zero selects the default.
pub const InitOptions = struct {
    heap_bytes: usize = 0,
    use_default_bundles: bool = true,
};

const default_heap_bytes = 64 * 1024 * 1024;
const max_observation = 64 * 1024;

var load_mutex: std.Io.Mutex = .init;

pub const Foreign = *const fn (env: *elz.Environment, args: elz.core.ValueList) anyerror!elz.Value;

pub const Handler = *const fn (
    self: *Environment,
    args: []const elz.Value,
    gc: std.mem.Allocator,
) anyerror!elz.Value;

pub const Tool = struct {
    identifier: []const u8,
    description: []const u8 = "",
    usage: []const u8 = "",
    skill: ?[]const u8 = null,
    impl: Foreign,

    fn trampoline(comptime identifier: []const u8, comptime handler: Handler) Foreign {
        return &struct {
            fn call(elz_env: *elz.Environment, args: elz.core.ValueList) anyerror!elz.Value {
                const bound = elz_env.get("*env*") catch return error.MissingEnv;
                const ptr = switch (bound) {
                    .opaque_pointer => |p| p orelse return error.MissingEnv,
                    else => return error.MissingEnv,
                };
                const self: *Environment = @ptrCast(@alignCast(ptr));
                return handler(self, args.items, elz_env.allocator) catch |err| {
                    const interp = elz.ffi.active_interp orelse return err;
                    return interp.fail(elz.ElzError.ForeignFunctionError, "{s}: {t}", .{ identifier, err });
                };
            }
        }.call;
    }
};

fn helpHandler(self: *Environment, args: []const elz.Value, gc: std.mem.Allocator) anyerror!elz.Value {
    _ = self;
    _ = args;
    return elz.core.copyString(gc, "help");
}

pub const Help = Tool{
    .identifier = "help",
    .description = "Show help.",
    .usage = "(help)",
    .skill = null,
    .impl = Tool.trampoline("help", helpHandler),
};

pub const core_tools: []const Tool = &.{Help};

pub const core_bundle_name = "env";
pub const core_bundle_description = "Environment tools.";

pub const Bundle = struct {
    pub const Skill = struct {
        name: []const u8,
        description: []const u8 = "",
        content: []const u8,
    };

    pub const Tool = struct {
        name: []const u8,
        description: []const u8,
        usage: []const u8 = "",
        skill: ?[]const u8 = null,
    };

    name: []const u8,
    description: []const u8 = "",
    skills: []const Skill = &.{},
    tools: []const Bundle.Tool = &.{},

    pub fn adopt(alloc: std.mem.Allocator, bundles: []const Bundle) std.mem.Allocator.Error![]Bundle {
        const owned = try alloc.alloc(Bundle, bundles.len);
        var filled: usize = 0;
        errdefer {
            freeSlice(alloc, owned[0..filled]);
            alloc.free(owned);
        }
        for (bundles, 0..) |bundle, index| {
            owned[index] = try copy(alloc, bundle);
            filled += 1;
        }
        return owned;
    }

    pub fn freeSlice(alloc: std.mem.Allocator, bundles: []Bundle) void {
        for (bundles) |bundle| freeBundle(alloc, bundle);
        if (bundles.len > 0) alloc.free(bundles);
    }

    fn copy(alloc: std.mem.Allocator, bundle: Bundle) std.mem.Allocator.Error!Bundle {
        const name = try alloc.dupe(u8, bundle.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, bundle.description);
        errdefer alloc.free(description);
        const skills = try copySkills(alloc, bundle.skills);
        errdefer freeSkills(alloc, skills);
        const tools = try copyTools(alloc, bundle.tools);
        errdefer freeTools(alloc, tools);
        return .{
            .name = name,
            .description = description,
            .skills = skills,
            .tools = tools,
        };
    }

    fn freeBundle(alloc: std.mem.Allocator, bundle: Bundle) void {
        alloc.free(bundle.name);
        alloc.free(bundle.description);
        freeSkills(alloc, bundle.skills);
        freeTools(alloc, bundle.tools);
    }

    fn copySkills(alloc: std.mem.Allocator, skills: []const Skill) std.mem.Allocator.Error![]Skill {
        const owned = try alloc.alloc(Skill, skills.len);
        var filled: usize = 0;
        errdefer {
            freeSkills(alloc, owned[0..filled]);
            alloc.free(owned);
        }
        for (skills, 0..) |skill, index| {
            owned[index] = try copySkill(alloc, skill);
            filled += 1;
        }
        return owned;
    }

    fn copySkill(alloc: std.mem.Allocator, skill: Skill) std.mem.Allocator.Error!Skill {
        const name = try alloc.dupe(u8, skill.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, skill.description);
        errdefer alloc.free(description);
        const content = try alloc.dupe(u8, skill.content);
        errdefer alloc.free(content);
        return .{ .name = name, .description = description, .content = content };
    }

    fn freeSkills(alloc: std.mem.Allocator, skills: []const Skill) void {
        for (skills) |skill| {
            alloc.free(skill.name);
            alloc.free(skill.description);
            alloc.free(skill.content);
        }
        if (skills.len > 0) alloc.free(skills);
    }

    fn copyTools(alloc: std.mem.Allocator, tools: []const Bundle.Tool) std.mem.Allocator.Error![]Bundle.Tool {
        const owned = try alloc.alloc(Bundle.Tool, tools.len);
        var filled: usize = 0;
        errdefer {
            freeTools(alloc, owned[0..filled]);
            alloc.free(owned);
        }
        for (tools, 0..) |tool, index| {
            owned[index] = try copyTool(alloc, tool);
            filled += 1;
        }
        return owned;
    }

    fn copyTool(alloc: std.mem.Allocator, tool: Bundle.Tool) std.mem.Allocator.Error!Bundle.Tool {
        const name = try alloc.dupe(u8, tool.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, tool.description);
        errdefer alloc.free(description);
        const usage = try alloc.dupe(u8, tool.usage);
        errdefer alloc.free(usage);
        const skill = if (tool.skill) |value| try alloc.dupe(u8, value) else null;
        errdefer if (skill) |value| alloc.free(value);
        return .{
            .name = name,
            .description = description,
            .usage = usage,
            .skill = skill,
        };
    }

    fn freeTools(alloc: std.mem.Allocator, tools: []const Bundle.Tool) void {
        for (tools) |tool| {
            alloc.free(tool.name);
            alloc.free(tool.description);
            alloc.free(tool.usage);
            if (tool.skill) |skill| alloc.free(skill);
        }
        if (tools.len > 0) alloc.free(tools);
    }
};

pub fn coreBundles(alloc: std.mem.Allocator) std.mem.Allocator.Error![]Bundle {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const temp = arena.allocator();

    const tools = try temp.alloc(Bundle.Tool, core_tools.len);
    for (core_tools, 0..) |tool, index| {
        tools[index] = .{
            .name = tool.identifier,
            .description = if (tool.description.len > 0)
                tool.description
            else if (tool.usage.len > 0)
                tool.usage
            else
                tool.identifier,
            .usage = try std.fmt.allocPrint(temp, "({s}.{s})", .{ core_bundle_name, tool.identifier }),
            .skill = tool.skill,
        };
    }

    const source = [_]Bundle{
        .{ .name = core_bundle_name, .description = core_bundle_description, .tools = tools },
    };
    return Bundle.adopt(alloc, &source);
}

fn buildEvalDescription(alloc: std.mem.Allocator, bundles: []const Bundle) std.mem.Allocator.Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try text.appendSlice(alloc, "Submit one Scheme form. Available tools:");
    for (bundles) |bundle| {
        for (bundle.tools) |tool| {
            try text.appendSlice(alloc, "\n  ");
            if (tool.usage.len > 0) {
                try text.appendSlice(alloc, tool.usage);
            } else {
                try text.appendSlice(alloc, "(");
                try text.appendSlice(alloc, bundle.name);
                try text.appendSlice(alloc, ".");
                try text.appendSlice(alloc, tool.name);
                try text.appendSlice(alloc, ")");
            }
            try text.appendSlice(alloc, ": ");
            try text.appendSlice(alloc, tool.description);
        }
    }
    return text.toOwnedSlice(alloc);
}

/// One Elz engine and its host-side bridge. The engine is not thread-safe, so
/// every call must stay on the thread that ran `init`.
pub const Environment = struct {
    state: *elz.Interpreter,
    owner_thread: std.Thread.Id,
    allocator: std.mem.Allocator,
    bundles: []Bundle = &.{},
    eval_description: []u8 = &.{},

    pub fn initAlloc(alloc: std.mem.Allocator, options: InitOptions) Error!*Environment {
        const environment = try alloc.create(Environment);
        try environment.init(alloc, options);
        return environment;
    }

    /// Initialize the engine in place. The address is stable for the whole
    /// lifetime, which is what the `*env*` host binding requires.
    pub fn init(self: *Environment, alloc: std.mem.Allocator, options: InitOptions) Error!void {
        const backing = std.heap.page_allocator;
        const state = try backing.create(elz.Interpreter);
        state.* = elz.Interpreter.init(.{
            .heap_limit_bytes = if (options.heap_bytes == 0) default_heap_bytes else options.heap_bytes,
        }) catch {
            backing.destroy(state);
            return error.InitializationFailed;
        };
        self.* = .{ .state = state, .owner_thread = std.Thread.getCurrentId(), .allocator = alloc };
        // bind itself to the runtime
        self.setGlobal("*env*", .{ .opaque_pointer = self }) catch {
            self.state.deinit();
            backing.destroy(self.state);
            return error.InitializationFailed;
        };
        // initialize standard library
        if (options.use_default_bundles) {
            try self.bindCoreTools();
        }
    }

    /// Release the engine. Call this once, on the owning thread.
    pub fn deinit(self: *Environment) void {
        self.checkThread() catch return;
        Bundle.freeSlice(self.allocator, self.bundles);
        if (self.eval_description.len > 0) self.allocator.free(self.eval_description);
        self.state.deinit();
        std.heap.page_allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Evaluate one or more expressions and write the last value into
    /// caller-owned storage.
    ///
    /// `output` must not be empty: the side effects of the evaluation happen
    /// before the result is written, so callers get a chance to provide a
    /// larger buffer instead of silently losing the result.
    pub fn eval(self: *Environment, source: []const u8, writer: *std.Io.Writer) Error![]u8 {
        const value = try self.evalValue(source);

        try elz.write(value, &writer);
        return writer.toOwnedSlice();
    }

    fn evalValue(self: *Environment, source: []const u8) Error!elz.Value {
        try self.checkThread();
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidCString;

        var fuel: u64 = std.math.maxInt(u64);
        return self.state.evalString(source, &fuel) catch return error.SchemeError;
    }

    /// Load a Scheme source file.
    pub fn load(self: *Environment, allocator: std.mem.Allocator, path: []const u8) Error!void {
        try self.checkThread();
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCString;

        load_mutex.lockUncancelable(self.state.io);
        defer load_mutex.unlock(self.state.io);

        const source = std.Io.Dir.cwd().readFileAlloc(
            self.state.io,
            path,
            allocator,
            .limited(64 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SchemeError,
        };
        defer allocator.free(source);

        var fuel: u64 = std.math.maxInt(u64);
        _ = self.state.evalString(source, &fuel) catch return error.SchemeError;
    }

    /// Bind a value into the interpreter's root environment.
    pub fn setGlobal(self: *Environment, name: []const u8, value: elz.Value) Error!void {
        try self.checkThread();
        self.state.root_env.set(name, value) catch return error.SchemeError;
    }

    /// Copy the most recent error message into caller-owned storage.
    pub fn lastError(self: *Environment, output: []u8) Error![]u8 {
        try self.checkThread();
        if (output.len == 0) return error.OutputBufferTooSmall;

        const message = self.state.last_error.message orelse return output[0..0];
        const length = @min(message.len, output.len);
        @memcpy(output[0..length], message[0..length]);
        return output[0..length];
    }

    /// Elz schedules no separate Scheme threads.
    pub fn yield(self: *Environment) Error!bool {
        try self.checkThread();
        return false;
    }

    /// Elz has no process-global runtime state to inspect.
    pub fn isRunning(self: *Environment) Error!bool {
        try self.checkThread();
        return true;
    }

    /// Elz exposes a fuel counter rather than an asynchronous interrupt.
    pub fn interrupt(self: *Environment) Error!void {
        try self.checkThread();
    }

    fn checkThread(self: *Environment) Error!void {
        if (self.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
    }

    /// Run one action and return its observation as caller-owned text.
    ///
    /// A string result crosses as its raw bytes; every other value crosses as
    /// its written representation, capped at `max_observation`. A Scheme
    /// error is an observation that starts with `Error: `. Allocation
    /// failures and `WrongThread`-class errors propagate.
    pub fn call(self: *Environment, allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
        const value = self.evalValue(source) catch |err|
            return errorObservation(self, allocator, err);

        switch (value) {
            .string => |text| return allocator.dupe(u8, text.bytes),
            else => {},
        }

        const buffer = try allocator.alloc(u8, max_observation);
        defer allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        elz.write(value, &writer) catch
            return allocator.dupe(u8, "Error: result too large");
        return allocator.dupe(u8, buffer[0..writer.end]);
    }

    /// The observation form of a failed bridge eval: `Error: ` with the
    /// runtime's recorded message, which never doubles a leading `Error: `,
    /// a stable `Error: scheme error` when nothing was recorded, and
    /// `Error: result buffer too small` for an eval without room to write
    /// its result. Every other error propagates; it is not an observation.
    pub fn errorObservation(self: *Environment, allocator: std.mem.Allocator, err: Error) Error![]u8 {
        switch (err) {
            error.SchemeError => {
                var message_buffer: [512]u8 = undefined;
                var message: []const u8 = "";
                if (self.lastError(&message_buffer)) |text| message = text else |_| {}

                const trimmed = std.mem.trim(u8, message, " \t\n\r\x0b\x0c");
                const body = if (std.mem.startsWith(u8, trimmed, "Error: ")) trimmed["Error: ".len..] else trimmed;
                if (body.len == 0) return allocator.dupe(u8, "Error: scheme error");
                return std.fmt.allocPrint(allocator, "Error: {s}", .{body});
            },
            error.OutputBufferTooSmall => return allocator.dupe(u8, "Error: result buffer too small"),
            else => return err,
        }
    }

    pub fn setBundles(self: *Environment, bundles: []const Bundle) std.mem.Allocator.Error!void {
        const owned = try Bundle.adopt(self.allocator, bundles);
        errdefer Bundle.freeSlice(self.allocator, owned);
        const description = try buildEvalDescription(self.allocator, owned);
        const previous = self.bundles;
        const previous_description = self.eval_description;
        self.bundles = owned;
        self.eval_description = description;
        Bundle.freeSlice(self.allocator, previous);
        if (previous_description.len > 0) self.allocator.free(previous_description);
    }

    pub fn evalDescription(self: *const Environment) []const u8 {
        return self.eval_description;
    }

    pub fn bindToolAs(self: *Environment, name: []const u8, tool: Tool) Error!void {
        try self.setGlobal(name, .{ .foreign_procedure = tool.impl });
    }

    pub fn bindCoreTools(self: *Environment) Error!void {
        var name_buffer: [256]u8 = undefined;
        for (core_tools) |tool| {
            try self.bindToolAs(tool.identifier, tool);
            const dotted = std.fmt.bufPrint(&name_buffer, "{s}.{s}", .{ core_bundle_name, tool.identifier }) catch
                return error.InitializationFailed;
            try self.bindToolAs(dotted, tool);
        }

        const bundles = try coreBundles(self.allocator);
        defer Bundle.freeSlice(self.allocator, bundles);
        try self.setBundles(bundles);
    }
};

test "call crosses a string result as raw text" {
    var env: Environment = undefined;
    try env.init(std.testing.allocator, .{});
    defer env.deinit();

    const result = try env.call(std.testing.allocator, "\"hello\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "call crosses other results as written text" {
    var env: Environment = undefined;
    try env.init(std.testing.allocator, .{});
    defer env.deinit();

    const result = try env.call(std.testing.allocator, "(+ 1 2)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "call turns a scheme error into an observation" {
    var env: Environment = undefined;
    try env.init(std.testing.allocator, .{});
    defer env.deinit();

    const result = try env.call(std.testing.allocator, "(error \"boom\")");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "Error: "));
}

test "bindToolAs exposes a namespaced tool" {
    var env: Environment = undefined;
    try env.init(std.testing.allocator, .{});
    defer env.deinit();

    try env.bindToolAs("env.help", Help);
    const result = try env.call(std.testing.allocator, "(env.help)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("help", result);
}
