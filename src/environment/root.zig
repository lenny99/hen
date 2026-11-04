//! A small, Zig-only interface to the vendored Elz interpreter.
//!
//! Each `Interpreter` owns one Elz engine. The engine is not thread-safe, so
//! every call must stay on the thread that ran `init`.

const std = @import("std");
const elz = @import("elz");

/// Configuration passed to the interpreter.
///
/// `heap_bytes` is the managed heap limit. A value of zero selects Elz's
/// default. `stack_bytes` and `symbol_table_size` are kept for source
/// compatibility with the previous runtime and are ignored.
pub const InitOptions = struct {
    heap_bytes: usize = 0,
    stack_bytes: usize = 0,
    symbol_table_size: usize = 0,
};

/// Errors returned by the safe wrapper around the Elz API.
pub const Error = std.mem.Allocator.Error || error{
    InitializationFailed,
    InvalidCString,
    OutputBufferTooSmall,
    SchemeError,
    StringTooLarge,
    WrongThread,
};

const default_heap_bytes = 64 * 1024 * 1024;

/// A handle to one Elz interpreter.
///
/// The handle is cheap to copy and refers to the same engine. All copies stay
/// bound to the thread that first initialized the engine.
pub const Interpreter = struct {
    state: *elz.Interpreter,
    owner_thread: std.Thread.Id,

    /// Initialize an Elz engine.
    pub fn init(options: InitOptions) Error!Interpreter {
        const backing = std.heap.page_allocator;
        const state = try backing.create(elz.Interpreter);
        errdefer backing.destroy(state);

        state.* = elz.Interpreter.init(.{
            .heap_limit_bytes = if (options.heap_bytes == 0) default_heap_bytes else options.heap_bytes,
        }) catch return error.InitializationFailed;

        return .{ .state = state, .owner_thread = std.Thread.getCurrentId() };
    }

    /// Release the engine. Call this once, on the owning thread.
    pub fn deinit(self: *Interpreter) void {
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
    pub fn eval(
        self: Interpreter,
        allocator: std.mem.Allocator,
        source: []const u8,
        output: []u8,
    ) Error![]u8 {
        _ = allocator;
        try self.checkThread();
        if (output.len == 0) return error.OutputBufferTooSmall;
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidCString;

        var fuel: u64 = std.math.maxInt(u64);
        const value = self.state.evalString(source, &fuel) catch return error.SchemeError;

        var writer = std.Io.Writer.fixed(output);
        elz.write(value, &writer) catch return error.OutputBufferTooSmall;
        return output[0..writer.end];
    }

    /// Load a Scheme source file.
    pub fn load(self: Interpreter, allocator: std.mem.Allocator, path: []const u8) Error!void {
        try self.checkThread();
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCString;

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

    /// Copy the most recent error message into caller-owned storage.
    pub fn lastError(self: Interpreter, output: []u8) Error![]u8 {
        try self.checkThread();
        if (output.len == 0) return error.OutputBufferTooSmall;

        const message = self.state.last_error.message orelse return output[0..0];
        const length = @min(message.len, output.len);
        @memcpy(output[0..length], message[0..length]);
        return output[0..length];
    }

    /// Elz schedules no separate Scheme threads.
    pub fn yield(self: Interpreter) Error!bool {
        try self.checkThread();
        return false;
    }

    /// Elz has no process-global runtime state to inspect.
    pub fn isRunning(self: Interpreter) Error!bool {
        try self.checkThread();
        return true;
    }

    /// Elz exposes a fuel counter rather than an asynchronous interrupt.
    pub fn interrupt(self: Interpreter) Error!void {
        try self.checkThread();
    }

    fn checkThread(self: Interpreter) Error!void {
        if (self.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
    }
};

/// One synchronous call into an environment: Zig sends one action (the
/// adapter passes `arguments` as the model's Scheme source and ignores
/// `name`) and reads back one observation.
pub const Environment = @import("contract").Environment;

const env = @import("env.zig");

pub const Env = env.Env;
pub const ToolDesc = env.ToolDesc;
pub const ModuleEntry = env.ModuleEntry;
pub const ConfigValue = env.ConfigValue;
pub const ModuleName = env.ModuleName;
pub const ModulePath = env.ModulePath;
pub const ConfigSourceVar = env.ConfigSourceVar;
pub const ConfigLiteral = env.ConfigLiteral;
pub const bridge_api_version = env.bridge_api_version;
pub const Datum = env.Datum;
pub const parseDatum = env.parseDatum;
pub const freeDatum = env.freeDatum;
pub const writeSchemeString = env.writeSchemeString;

test {
    _ = env;
}
