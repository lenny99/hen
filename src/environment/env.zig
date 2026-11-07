const std = @import("std");
const elz = @import("elz");
const contract = @import("contract");

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
};

const default_heap_bytes = 64 * 1024 * 1024;
const max_observation = 64 * 1024;

var load_mutex: std.Io.Mutex = .init;

pub const Skill = struct {
    name: []const u8,
    content: []const u8,
};

pub const Foreign = *const fn (env: *elz.Environment, args: elz.core.ValueList) anyerror!elz.Value;

pub const Handler = *const fn (
    self: *Env,
    args: []const elz.Value,
    gc: std.mem.Allocator,
) anyerror!elz.Value;

pub const Tool = struct {
    identifier: []const u8,
    description: []const u8 = "",
    usage: []const u8 = "",
    skill: ?*const Skill = null,
    impl: Foreign,

    fn trampoline(comptime identifier: []const u8, comptime handler: Handler) Foreign {
        return &struct {
            fn call(elz_env: *elz.Environment, args: elz.core.ValueList) anyerror!elz.Value {
                const bound = elz_env.get("*env*") catch return error.MissingEnv;
                const ptr = switch (bound) {
                    .opaque_pointer => |p| p orelse return error.MissingEnv,
                    else => return error.MissingEnv,
                };
                const self: *Env = @ptrCast(@alignCast(ptr));
                return handler(self, args.items, elz_env.allocator) catch |err| {
                    const interp = elz.ffi.active_interp orelse return err;
                    return interp.fail(elz.ElzError.ForeignFunctionError, "{s}: {t}", .{ identifier, err });
                };
            }
        }.call;
    }
};

fn helpHandler(self: *Env, args: []const elz.Value, gc: std.mem.Allocator) anyerror!elz.Value {
    _ = self;
    _ = args;
    return elz.core.copyString(gc, "help");
}

pub const Help = Tool{
    .identifier = "help",
    .description = "",
    .usage = "(help)",
    .skill = null,
    .impl = Tool.trampoline("help", helpHandler),
};

const DEFAULT_TOOLS: []const Tool = &.{
    Help
};

/// One Elz engine and its host-side bridge. The engine is not thread-safe, so
/// every call must stay on the thread that ran `init`.
pub const Env = struct {
    state: *elz.Interpreter,
    registry: std.ArrayList(Tool),
    owner_thread: std.Thread.Id,

    /// Initialize the engine in place. The address is stable for the whole
    /// lifetime, which is what the `*env*` host binding requires.
    pub fn init(self: *Env, options: InitOptions) Error!void {
        const backing = std.heap.page_allocator;
        const state = try backing.create(elz.Interpreter);
        state.* = elz.Interpreter.init(.{
            .heap_limit_bytes = if (options.heap_bytes == 0) default_heap_bytes else options.heap_bytes,
        }) catch {
            backing.destroy(state);
            return error.InitializationFailed;
        };

        var registry = std.ArrayList(Tool).initCapacity(backing, DEFAULT_TOOLS.len) catch {
            return error.InitializationFailed;
        };
        registry.appendSliceAssumeCapacity(DEFAULT_TOOLS);

        self.* = .{ 
            .state = state, 
            .owner_thread = std.Thread.getCurrentId(), 
            .registry = registry 
        };
        self.setGlobal("*env*", .{ .opaque_pointer = self }) catch {
            self.state.deinit();
            backing.destroy(self.state);
            return error.InitializationFailed;
        };
    }

    /// Release the engine. Call this once, on the owning thread.
    pub fn deinit(self: *Env) void {
        self.checkThread() catch return;
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
    pub fn eval(self: *Env, source: []const u8, output: []u8) Error![]u8 {
        if (output.len == 0) return error.OutputBufferTooSmall;
        const value = try self.evalValue(source);

        var writer = std.Io.Writer.fixed(output);
        elz.write(value, &writer) catch return error.OutputBufferTooSmall;
        return output[0..writer.end];
    }

    fn evalValue(self: *Env, source: []const u8) Error!elz.Value {
        try self.checkThread();
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidCString;

        var fuel: u64 = std.math.maxInt(u64);
        return self.state.evalString(source, &fuel) catch return error.SchemeError;
    }

    /// Load a Scheme source file.
    pub fn load(self: *Env, allocator: std.mem.Allocator, path: []const u8) Error!void {
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
    pub fn setGlobal(self: *Env, name: []const u8, value: elz.Value) Error!void {
        try self.checkThread();
        self.state.root_env.set(name, value) catch return error.SchemeError;
    }

    /// Copy the most recent error message into caller-owned storage.
    pub fn lastError(self: *Env, output: []u8) Error![]u8 {
        try self.checkThread();
        if (output.len == 0) return error.OutputBufferTooSmall;

        const message = self.state.last_error.message orelse return output[0..0];
        const length = @min(message.len, output.len);
        @memcpy(output[0..length], message[0..length]);
        return output[0..length];
    }

    /// Elz schedules no separate Scheme threads.
    pub fn yield(self: *Env) Error!bool {
        try self.checkThread();
        return false;
    }

    /// Elz has no process-global runtime state to inspect.
    pub fn isRunning(self: *Env) Error!bool {
        try self.checkThread();
        return true;
    }

    /// Elz exposes a fuel counter rather than an asynchronous interrupt.
    pub fn interrupt(self: *Env) Error!void {
        try self.checkThread();
    }

    fn checkThread(self: *Env) Error!void {
        if (self.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
    }

    /// Run one action and return its observation as caller-owned text.
    ///
    /// A string result crosses as its raw bytes; every other value crosses as
    /// its written representation, capped at `max_observation`. A Scheme
    /// error is an observation that starts with `Error: `. Allocation
    /// failures and `WrongThread`-class errors propagate.
    pub fn call(self: *Env, allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
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
    pub fn errorObservation(self: *Env, allocator: std.mem.Allocator, err: Error) Error![]u8 {
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

    pub fn asEnvironment(self: *Env) contract.Environment {
        return .{ .impl = self, .call_fn = call_fn };
    }

    fn call_fn(
        impl: *anyopaque,
        _: std.Io,
        allocator: std.mem.Allocator,
        _: []const u8,
        arguments: []const u8,
    ) contract.Environment.CallError![]u8 {
        const self: *Env = @ptrCast(@alignCast(impl));
        return self.call(allocator, arguments) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
    }
};


test "call crosses a string result as raw text" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit();

    const result = try env.call(std.testing.allocator, "\"hello\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "call crosses other results as written text" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit();

    const result = try env.call(std.testing.allocator, "(+ 1 2)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "call turns a scheme error into an observation" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit();

    const result = try env.call(std.testing.allocator, "(error \"boom\")");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "Error: "));
}
