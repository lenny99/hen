const std = @import("std");

const root = @import("root.zig");

const Interpreter = root.Interpreter;
pub const Error = root.Error;

/// One registered tool listed by `hen:tools/list`.
pub const ToolDesc = struct {
    name: []const u8,
    summary: []const u8,
    when: []const u8,
    description: []const u8,
};

/// The bridge version the registry implements. A generation whose manifest
/// declares a different api cannot load.
pub const bridge_api_version = "1";

pub const ModuleName = struct {
    text: []const u8,

    pub fn init(text: []const u8) ModuleName {
        return .{ .text = text };
    }
};

pub const ModulePath = struct {
    text: []const u8,

    pub fn init(text: []const u8) ModulePath {
        return .{ .text = text };
    }
};

pub const ConfigSourceVar = struct {
    text: []const u8,

    pub fn init(text: []const u8) ConfigSourceVar {
        return .{ .text = text };
    }
};

pub const ConfigLiteral = struct {
    text: []const u8,

    pub fn init(text: []const u8) ConfigLiteral {
        return .{ .text = text };
    }
};

/// One plugin module to load into the environment: its registry name and
/// the absolute path of its source file.
pub const ModuleEntry = struct {
    name: ModuleName,
    path: ModulePath,
};

/// One host-resolved configuration value, handed to the runtime before any
/// module loads: `hen:config/set!` pairs the source variable with the value.
pub const ConfigValue = struct {
    source_var: ConfigSourceVar,
    value: ConfigLiteral,
};

/// The module wrapper the interpreter evaluates per generation module:
/// imports first, `register-module!` inside the module body so the source
/// publishes under its own name, and `(and #t)` for a tiny written result.
fn formatWrapper(allocator: std.mem.Allocator, entry: ModuleEntry) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const head = try std.fmt.allocPrint(
        allocator,
        "(module {s} * (import scheme (chicken base) (chicken condition) (chicken port) hen-plugin) (register-module! '{s}) (include ",
        .{ entry.name.text, entry.name.text },
    );
    defer allocator.free(head);
    try out.appendSlice(allocator, head);
    try writeSchemeString(allocator, &out, entry.path.text);
    try out.appendSlice(allocator, ") (and #t))");
    return out.toOwnedSlice(allocator);
}

/// `(begin ... #t)` keeps the written result tiny: `hen:config/set!` itself
/// returns the whole new config table.
fn formatConfigSet(allocator: std.mem.Allocator, config: ConfigValue) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "(begin (hen:config/set! ");
    try writeSchemeString(allocator, &out, config.source_var.text);
    try out.appendSlice(allocator, " ");
    try writeSchemeString(allocator, &out, config.value.text);
    try out.appendSlice(allocator, ") #t)");
    return out.toOwnedSlice(allocator);
}

/// The synchronous bridge between Zig and the CHICKEN runtime.
///
/// One `Env` owns one interpreter handle. Every call must stay on the thread
/// that ran `init`; CHICKEN enforces that with `error.WrongThread`. There is
/// no shutdown: the runtime lives until the process exits.
pub const Env = struct {
    interpreter: Interpreter,

    /// Start the runtime and load `modules` in order. The registry
    /// `scheme/env.scm` is the caller's first entry. A failed load propagates
    /// as an error, it is not an observation.
    pub fn init(allocator: std.mem.Allocator, modules: []const []const u8) Error!Env {
        const interpreter = try Interpreter.init(.{});
        for (modules) |module| try interpreter.load(allocator, module);
        return .{ .interpreter = interpreter };
    }

    /// Start the runtime on a generation: the host registry loads first, then
    /// every configuration value is set, then each module entry loads through
    /// its module wrapper in the given order. Wrapper internals stay on the
    /// plugin side of the module wall; a failed load or config set propagates
    /// as an error.
    pub fn initGeneration(
        allocator: std.mem.Allocator,
        entries: []const ModuleEntry,
        configs: []const ConfigValue,
    ) Error!Env {
        var env = try Env.init(allocator, &.{"scheme/env.scm"});
        try env.loadGeneration(allocator, entries, configs);
        return env;
    }

    pub fn loadGeneration(
        self: *Env,
        allocator: std.mem.Allocator,
        entries: []const ModuleEntry,
        configs: []const ConfigValue,
    ) Error!void {
        const interpreter = self.interpreter;

        for (configs) |config| {
            const source = try formatConfigSet(allocator, config);
            defer allocator.free(source);
            var output: [64]u8 = undefined;
            _ = try interpreter.eval(allocator, source, &output);
        }

        for (entries) |entry| {
            const wrapper = try formatWrapper(allocator, entry);
            defer allocator.free(wrapper);
            var output: [64]u8 = undefined;
            _ = try interpreter.eval(allocator, wrapper, &output);
        }
    }

    /// List the registered tools as provider-ready descriptors.
    ///
    /// The result and its strings are owned by `allocator`; freeing the
    /// whole list at once is easiest with an arena.
    pub fn tools(self: *Env, allocator: std.mem.Allocator) Error![]ToolDesc {
        const listing = try evalRead(self.interpreter, allocator, "(hen:tools/list)");
        defer allocator.free(listing);

        const datum = try parseDatum(allocator, listing);
        defer freeDatum(allocator, datum);

        const entries = switch (datum) {
            .list => |items| items,
            else => return error.SchemeError,
        };

        var descs: std.ArrayList(ToolDesc) = .empty;
        errdefer {
            for (descs.items) |desc| freeDesc(allocator, desc);
            descs.deinit(allocator);
        }

        for (entries) |entry| {
            const desc = try descFromEntry(allocator, entry);
            errdefer freeDesc(allocator, desc);
            try descs.append(allocator, desc);
        }
        return descs.toOwnedSlice(allocator);
    }

    /// Run one action and return its observation as caller-owned text.
    ///
    /// `source` is the model's action as one string; `hen:eval!` reads
    /// exactly one expression from it and resolves the stored observation
    /// under its guard rails. The result comes back as the written literal
    /// `(hen:tools/fetch)` returns and decodes to the exact bytes stored.
    /// A tool error is an observation, as is a failed bridge eval; the
    /// action always runs exactly once, so neither eval is ever retried.
    /// Allocation failures and `WrongThread`-class errors propagate.
    pub fn call(self: *Env, allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
        const dispatch = try formatEval(allocator, source);
        defer allocator.free(dispatch);

        var length_buffer: [64]u8 = undefined;
        const length_written = self.interpreter.eval(allocator, dispatch, &length_buffer) catch |err|
            return errorObservation(self, allocator, err);
        const length = std.fmt.parseInt(usize, length_written, 10) catch
            return errorObservation(self, allocator, error.SchemeError);

        const byte_slack_per_char = 6;
        const byte_slack = 64;
        const written_width = std.math.mul(usize, length, byte_slack_per_char) catch
            return errorObservation(self, allocator, error.SchemeError);
        const scratch_len = std.math.add(usize, written_width, byte_slack) catch
            return errorObservation(self, allocator, error.SchemeError);

        const scratch = try allocator.alloc(u8, scratch_len);
        defer allocator.free(scratch);

        const written = self.interpreter.eval(allocator, "(hen:tools/fetch)", scratch) catch |err|
            return errorObservation(self, allocator, err);

        return decodeResult(allocator, written) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadEncoding => allocator.dupe(u8, "Error: bad result encoding"),
        };
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
                if (self.interpreter.lastError(&message_buffer)) |text| message = text else |_| {}

                const trimmed = std.mem.trim(u8, message, " \t\n\r\x0b\x0c");
                const body = if (std.mem.startsWith(u8, trimmed, "Error: ")) trimmed["Error: ".len..] else trimmed;
                if (body.len == 0) return allocator.dupe(u8, "Error: scheme error");
                return std.fmt.allocPrint(allocator, "Error: {s}", .{body});
            },
            error.OutputBufferTooSmall => return allocator.dupe(u8, "Error: result buffer too small"),
            else => return err,
        }
    }

    pub fn asEnvironment(self: *Env) root.Environment {
        return .{ .impl = self, .call_fn = call_fn };
    }

    fn call_fn(
        impl: *anyopaque,
        _: std.Io,
        allocator: std.mem.Allocator,
        _: []const u8,
        arguments: []const u8,
    ) root.Environment.CallError![]u8 {
        const self: *Env = @ptrCast(@alignCast(impl));
        return self.call(allocator, arguments) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
    }
};

const eval_read_start = 4096;
const eval_read_max = 1024 * 1024;

/// Evaluate a pure read, growing the buffer and re-evaluating until the
/// written representation fits, starting at 4 KiB and failing beyond 1 MiB.
fn evalRead(interpreter: Interpreter, allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
    var capacity: usize = eval_read_start;
    while (true) {
        const buffer = try allocator.alloc(u8, capacity);
        const result = interpreter.eval(allocator, source, buffer) catch |err| switch (err) {
            error.OutputBufferTooSmall => {
                allocator.free(buffer);
                if (capacity * 2 > eval_read_max) return error.OutputBufferTooSmall;
                capacity *= 2;
                continue;
            },
            else => {
                allocator.free(buffer);
                return err;
            },
        };
        defer allocator.free(buffer);
        return allocator.dupe(u8, result);
    }
}

fn descFromEntry(allocator: std.mem.Allocator, entry: Datum) Error!ToolDesc {
    const fields = switch (entry) {
        .list => |items| items,
        else => return error.SchemeError,
    };
    if (fields.len != 5) return error.SchemeError;
    const name = try textOf(allocator, fields[0]);
    errdefer allocator.free(name);
    const summary = try textOf(allocator, fields[1]);
    errdefer allocator.free(summary);
    const when = try textOf(allocator, fields[2]);
    errdefer allocator.free(when);
    const description = try textOf(allocator, fields[3]);
    errdefer allocator.free(description);
    return .{ .name = name, .summary = summary, .when = when, .description = description };
}

fn textOf(allocator: std.mem.Allocator, datum: Datum) Error![]const u8 {
    return switch (datum) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.SchemeError,
    };
}

fn freeDesc(allocator: std.mem.Allocator, desc: ToolDesc) void {
    allocator.free(desc.name);
    allocator.free(desc.summary);
    allocator.free(desc.when);
    allocator.free(desc.description);
}

const max_depth = 64;

/// One parsed element of a written representation.
pub const Datum = union(enum) {
    symbol: []const u8,
    string: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
    list: []const Datum,
};

pub fn parseDatum(allocator: std.mem.Allocator, text: []const u8) Error!Datum {
    var parser = Parser{ .allocator = allocator, .text = text };
    const datum = try parser.parseValue(0);
    parser.skipSpace();
    if (parser.pos != parser.text.len) return error.SchemeError;
    return datum;
}

/// Reads the written representation CHICKEN produces: lists, strings with the
/// writer's escape set, symbols plain or `|...|`-quoted, numbers, and
/// `#t`/`#f`. Anything else fails closed with `error.SchemeError`.
const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser, depth: usize) Error!Datum {
        if (depth >= max_depth) return error.SchemeError;
        self.skipSpace();
        if (self.pos >= self.text.len) return error.SchemeError;
        switch (self.text[self.pos]) {
            '(' => return self.parseList(depth),
            '"' => return .{ .string = try self.parseString() },
            '|' => return .{ .symbol = try self.parsePipeSymbol() },
            ')', '\'', '\\' => return error.SchemeError,
            else => return self.parseAtom(),
        }
    }

    fn parseList(self: *Parser, depth: usize) Error!Datum {
        self.pos += 1;
        var items: std.ArrayList(Datum) = .empty;
        errdefer {
            for (items.items) |item| freeDatum(self.allocator, item);
            items.deinit(self.allocator);
        }
        while (true) {
            self.skipSpace();
            if (self.pos >= self.text.len) return error.SchemeError;
            if (self.text[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            const item = try self.parseValue(depth + 1);
            errdefer freeDatum(self.allocator, item);
            try items.append(self.allocator, item);
        }
        return .{ .list = try items.toOwnedSlice(self.allocator) };
    }

    fn parseString(self: *Parser) Error![]u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            if (self.pos >= self.text.len) return error.SchemeError;
            const ch = self.text[self.pos];
            self.pos += 1;
            if (ch == '"') break;
            if (ch == '\\') {
                try self.parseEscape(&out);
            } else {
                try out.append(self.allocator, ch);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn parsePipeSymbol(self: *Parser) Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            if (self.pos >= self.text.len) return error.SchemeError;
            const ch = self.text[self.pos];
            self.pos += 1;
            if (ch == '|') break;
            if (ch == '\\') {
                if (self.pos >= self.text.len) return error.SchemeError;
                const escaped = self.text[self.pos];
                self.pos += 1;
                switch (escaped) {
                    '|', '\\' => try out.append(self.allocator, escaped),
                    'x' => try self.parseHexEscape(&out),
                    else => return error.SchemeError,
                }
            } else {
                if (ch == 0) return error.SchemeError;
                try out.append(self.allocator, ch);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn parseEscape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        if (self.pos >= self.text.len) return error.SchemeError;
        const ch = self.text[self.pos];
        self.pos += 1;
        switch (ch) {
            '"' => try out.append(self.allocator, '"'),
            '\\' => try out.append(self.allocator, '\\'),
            'a' => try out.append(self.allocator, 0x07),
            'b' => try out.append(self.allocator, 0x08),
            't' => try out.append(self.allocator, '\t'),
            'n' => try out.append(self.allocator, '\n'),
            'v' => try out.append(self.allocator, 0x0b),
            'f' => try out.append(self.allocator, 0x0c),
            'r' => try out.append(self.allocator, '\r'),
            'x' => try self.parseHexEscape(out),
            else => return error.SchemeError,
        }
    }

    /// Hex escape `\x…;`: one to six digits, the closing `;`, and a
    /// codepoint the runtime reader accepts. Values above 0x7f encode as
    /// UTF-8, matching what the runtime reader turns them into.
    fn parseHexEscape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        var value: u32 = 0;
        var digits: usize = 0;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const digit = std.fmt.charToDigit(self.text[self.pos], 16) catch break;
            value = value * 16 + digit;
            digits += 1;
            if (digits > 6) return error.SchemeError;
        }
        if (digits == 0) return error.SchemeError;
        if (self.pos >= self.text.len or self.text[self.pos] != ';') return error.SchemeError;
        self.pos += 1;
        if (value > 0x1ffff) return error.SchemeError;
        if (value < 0x80) {
            try out.append(self.allocator, @intCast(value));
            return;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(value), &encoded) catch return error.SchemeError;
        try out.appendSlice(self.allocator, encoded[0..length]);
    }

    fn parseAtom(self: *Parser) Error!Datum {
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', '\r', '(', ')', '"', '\\', '\'', '|' => break,
                else => {},
            }
        }
        const atom = self.text[start..self.pos];
        if (atom.len == 0) return error.SchemeError;
        if (std.mem.eql(u8, atom, ".")) return error.SchemeError;
        if (std.mem.eql(u8, atom, "#t")) return .{ .boolean = true };
        if (std.mem.eql(u8, atom, "#f")) return .{ .boolean = false };
        if (atom[0] == '#') return error.SchemeError;
        switch (atom[0]) {
            '0'...'9', '+', '-', '.' => {
                if (std.fmt.parseInt(i64, atom, 10)) |n| return .{ .integer = n } else |_| {}
                if (std.fmt.parseFloat(f64, atom)) |f| return .{ .float = f } else |_| {}
            },
            else => {},
        }
        return .{ .symbol = try self.allocator.dupe(u8, atom) };
    }
};

pub fn freeDatum(allocator: std.mem.Allocator, datum: Datum) void {
    switch (datum) {
        .symbol => |text| allocator.free(text),
        .string => |text| allocator.free(text),
        .list => |items| {
            for (items) |item| freeDatum(allocator, item);
            allocator.free(items);
        },
        else => {},
    }
}

/// Render one string as a quoted Scheme literal: backslash, double quote,
/// newline, tab, and return are one-character escapes, NUL is `\x0;`, and
/// every other byte passes through; the vendored reader reads raw bytes
/// inside string literals (pinned in tests/environment/env.zig).
pub fn writeSchemeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) Error!void {
    try out.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            0 => try out.appendSlice(allocator, "\\x0;"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

fn formatEval(allocator: std.mem.Allocator, source: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "(hen:eval! ");
    try writeSchemeString(allocator, &out, source);
    try out.appendSlice(allocator, ")");
    return out.toOwnedSlice(allocator);
}

const DecodeError = std.mem.Allocator.Error || error{BadEncoding};

/// Decode the top-level written string literal into the exact bytes it
/// represents, through the same escape set the reader accepts for strings:
/// one-character escapes, `\x…;` with one to six hex digits for a codepoint
/// within the runtime's bound, and raw passthrough bytes. Text the reader
/// cannot take as one full string literal is `error.BadEncoding`, which is
/// an observation, not a Zig error.
fn decodeResult(allocator: std.mem.Allocator, written: []const u8) DecodeError![]u8 {
    if (written.len == 0 or written[0] != '"') return error.BadEncoding;

    var parser = Parser{ .allocator = allocator, .text = written };
    const datum = parser.parseValue(0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SchemeError => return error.BadEncoding,
        else => return error.BadEncoding,
    };
    parser.skipSpace();
    if (parser.pos != parser.text.len) {
        freeDatum(allocator, datum);
        return error.BadEncoding;
    }

    const decoded: []u8 = switch (datum) {
        .string => |text| text,
        else => {
            freeDatum(allocator, datum);
            return error.BadEncoding;
        },
    };
    return decoded;
}

test "writeSchemeString escapes the escape set and lets other bytes through" {
    const cases = [_]struct { text: []const u8, rendered: []const u8 }{
        .{ .text = "", .rendered = "\"\"" },
        .{ .text = "a\"b\\c\nd\r\te\tf", .rendered = "\"a\\\"b\\\\c\\nd\\r\\te\\tf\"" },
        .{ .text = "f\x00g", .rendered = "\"f\\x0;g\"" },
        .{ .text = "a\x01b\x0bc\x0cd\x0efg\x7fhéllo", .rendered = "\"a\x01b\x0bc\x0cd\x0efg\x7fhéllo\"" },
    };
    for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try writeSchemeString(std.testing.allocator, &out, case.text);
        try std.testing.expectEqualStrings(case.rendered, out.items);
    }
}

test "decodeResult unescapes the written literal exactly" {
    const decoded = try decodeResult(
        std.testing.allocator,
        "\"a\\\"b\\\\c\\nd\\r\\te\\tf\\x00; g\\x00;h\"",
    );
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a\"b\\c\nd\r\te\tf\x00 g\x00h", decoded);
}

test "decodeResult rejects malformed literals" {
    const a = std.testing.allocator;

    try std.testing.expectError(error.BadEncoding, decodeResult(a, "\"abc\\x\""));
    try std.testing.expectError(error.BadEncoding, decodeResult(a, "\"abc"));
    try std.testing.expectError(error.BadEncoding, decodeResult(a, "\"a\\xZZ;\""));
    try std.testing.expectError(error.BadEncoding, decodeResult(a, "\"a\\x20000;\""));
    try std.testing.expectError(error.BadEncoding, decodeResult(a, "42"));
    try std.testing.expectError(error.BadEncoding, decodeResult(a, "\"a\" 42"));
    try std.testing.expectError(error.BadEncoding, decodeResult(a, ""));
}
