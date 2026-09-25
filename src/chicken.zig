//! A small, Zig-only interface to the vendored CHICKEN interpreter.
//!
//! `Interpreter` owns no resources. CHICKEN is a process-global runtime, so the
//! first value returned by `init` binds the runtime to the calling thread. All
//! operations must happen on that thread. CHICKEN has no matching shutdown
//! operation, so there is intentionally no `deinit` method.

const std = @import("std");
const c = @cImport({
    @cInclude("chicken/chicken.h");
});

const output_too_small_message = "Error: not enough room for result string";

var runtime_mutex: std.atomic.Mutex = .unlocked;
var runtime_owner: ?std.Thread.Id = null;
var default_toplevel_started = false;

/// Configuration passed to `CHICKEN_initialize`.
///
/// A value of zero asks CHICKEN to select its default. Sizes are in bytes,
/// except `symbol_table_size`, which is CHICKEN's symbol-table size argument.
pub const InitOptions = struct {
    heap_bytes: usize = 0,
    stack_bytes: usize = 0,
    symbol_table_size: usize = 0,
};

/// Errors returned by the safe wrapper around CHICKEN's C API.
pub const Error = std.mem.Allocator.Error || error{
    InitializationFailed,
    InvalidCString,
    OutputBufferTooSmall,
    SchemeError,
    StringTooLarge,
    WrongThread,
};

/// A handle to CHICKEN's process-global interpreter.
///
/// The handle is cheap to copy. Copies remain bound to the thread that first
/// initialized CHICKEN and refer to the same runtime.
pub const Interpreter = struct {
    owner_thread: std.Thread.Id,

    /// Initialize CHICKEN, or attach to an already initialized runtime.
    ///
    /// CHICKEN initialization and all later calls must remain on the same
    /// native thread. The default library toplevel is started once, making the
    /// runtime ready for `eval` and `load` calls.
    pub fn init(options: InitOptions) Error!Interpreter {
        const thread_id = std.Thread.getCurrentId();

        while (!runtime_mutex.tryLock()) std.atomic.spinLoopHint();
        defer runtime_mutex.unlock();

        if (runtime_owner) |owner| {
            if (owner != thread_id) return error.WrongThread;
        } else {
            const heap = try toCInt(options.heap_bytes);
            const stack = try toCInt(options.stack_bytes);
            const symbols = try toCInt(options.symbol_table_size);

            if (c.CHICKEN_initialize(heap, stack, symbols, c.CHICKEN_default_toplevel) == 0) {
                return error.InitializationFailed;
            }

            runtime_owner = thread_id;
        }

        if (!default_toplevel_started) {
            _ = c.CHICKEN_run(null);
            default_toplevel_started = true;
        }

        return .{ .owner_thread = thread_id };
    }

    /// Evaluate one Scheme expression and return its written representation.
    ///
    /// `output` is caller-owned storage. The returned slice points into it.
    /// CHICKEN evaluates the expression before discovering whether its written
    /// representation fits, so a successful call must never be retried merely
    /// to grow the buffer. `error.OutputBufferTooSmall` lets callers choose a
    /// larger buffer before evaluating the expression again.
    pub fn eval(
        self: Interpreter,
        allocator: std.mem.Allocator,
        source: []const u8,
        output: []u8,
    ) Error![]u8 {
        try self.checkThread();
        if (output.len == 0) return error.OutputBufferTooSmall;
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidCString;
        _ = try toCInt(source.len);

        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        const output_len = try toCInt(output.len);
        if (c.CHICKEN_eval_string_to_string(source_z.ptr, output.ptr, output_len) != 0) {
            return resultSlice(output);
        }

        return self.mapEvaluationError();
    }

    /// Load a Scheme source or compiled file.
    pub fn load(self: Interpreter, allocator: std.mem.Allocator, path: []const u8) Error!void {
        try self.checkThread();
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCString;
        _ = try toCInt(path.len);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        if (c.CHICKEN_load(path_z.ptr) != 0) return;
        return error.SchemeError;
    }

    /// Copy CHICKEN's most recent error message into caller-owned storage.
    pub fn lastError(self: Interpreter, output: []u8) Error![]u8 {
        try self.checkThread();
        if (output.len == 0) return error.OutputBufferTooSmall;

        const output_len = try toCInt(output.len);
        c.CHICKEN_get_error_message(output.ptr, output_len);
        return resultSlice(output);
    }

    /// Run one scheduled Scheme thread, if any.
    pub fn yield(self: Interpreter) Error!bool {
        self.checkThread();
        return c.CHICKEN_yield() != 0;
    }

    /// Return whether CHICKEN currently considers its runtime to be running.
    pub fn isRunning(self: Interpreter) Error!bool {
        try self.checkThread();
        return c.CHICKEN_is_running() != 0;
    }

    /// Interrupt the running Scheme program.
    pub fn interrupt(self: Interpreter) Error!void {
        try self.checkThread();
    }

    fn checkThread(self: Interpreter) Error!void {
        if (self.owner_thread != std.Thread.getCurrentId()) return error.WrongThread;
    }

    fn mapEvaluationError(self: Interpreter) Error {
        var error_buffer: [512]u8 = undefined;
        const message = self.lastError(&error_buffer) catch return error.SchemeError;
        if (std.mem.eql(u8, message, output_too_small_message)) {
            return error.OutputBufferTooSmall;
        }
        return error.SchemeError;
    }
};

fn toCInt(value: usize) Error!c_int {
    if (value > std.math.maxInt(c_int)) return error.StringTooLarge;
    return @intCast(value);
}

fn resultSlice(output: []u8) Error![]u8 {
    const end = std.mem.indexOfScalar(u8, output, 0) orelse return error.SchemeError;
    return output[0..end];
}

test "evaluate Scheme through the Zig API" {
    const allocator = std.testing.allocator;
    const interpreter = try Interpreter.init(.{});
    var output: [128]u8 = undefined;

    try std.testing.expectEqualStrings("6", try interpreter.eval(allocator, "(+ 1 2 3)", &output));
    try std.testing.expectEqualStrings("(1 2 3)", try interpreter.eval(allocator, "'(1 2 3)", &output));
}

test "report CHICKEN errors through Zig" {
    const allocator = std.testing.allocator;
    const interpreter = try Interpreter.init(.{});
    var output: [64]u8 = undefined;

    try std.testing.expectError(
        error.SchemeError,
        interpreter.eval(allocator, "(error \"boom\")", &output),
    );

    var message: [512]u8 = undefined;
    const detail = try interpreter.lastError(&message);
    try std.testing.expect(std.mem.indexOf(u8, detail, "boom") != null);
}

test "reject an empty output buffer before evaluating" {
    const allocator = std.testing.allocator;
    const interpreter = try Interpreter.init(.{});
    var output: [128]u8 = undefined;
    _ = try interpreter.eval(allocator, "(define zig-buffer-test 0)", &output);

    var no_output: [0]u8 = undefined;
    try std.testing.expectError(
        error.OutputBufferTooSmall,
        interpreter.eval(allocator, "(begin (set! zig-buffer-test 1) 42)", &no_output),
    );
    try std.testing.expectEqualStrings("0", try interpreter.eval(allocator, "zig-buffer-test", &output));
}

test "reject embedded NUL bytes" {
    const allocator = std.testing.allocator;
    const interpreter = try Interpreter.init(.{});
    var output: [16]u8 = undefined;

    try std.testing.expectError(
        error.InvalidCString,
        interpreter.eval(allocator, "(+ 1 2)\x00ignored", &output),
    );
    try std.testing.expectError(
        error.InvalidCString,
        interpreter.load(allocator, "src/testdata/load.scm\x00ignored"),
    );
}

test "load a Scheme file through the Zig API" {
    const allocator = std.testing.allocator;
    const interpreter = try Interpreter.init(.{});
    var output: [64]u8 = undefined;

    try interpreter.load(allocator, "src/testdata/load.scm");
    try std.testing.expectEqualStrings("99", try interpreter.eval(allocator, "loaded-through-zig", &output));
}
