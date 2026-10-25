const std = @import("std");

const root = @import("root.zig");

const Interpreter = root.Interpreter;
const Error = root.Error;

/// One tool in the provider `tools` array.
pub const ToolDesc = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for the arguments, rendered from the shape the registry
    /// declares.
    parameters: std.json.Value,
};

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

    /// List the registered tools as provider-ready descriptors.
    ///
    /// The result, its strings, and the parameter values are owned by
    /// `allocator`; freeing the whole tree at once is easiest with an arena.
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
    /// `args` crosses as datum text rendered by `renderArgs`; the result
    /// comes back as the written literal `(hen:tools/fetch)` returns and
    /// decodes to the exact bytes the tool returned. A tool error is an
    /// observation, as is a failed bridge eval; the action always runs
    /// exactly once, so neither eval is ever retried. Allocation failures
    /// and `WrongThread`-class errors propagate.
    pub fn call(self: *Env, allocator: std.mem.Allocator, name: []const u8, args: std.json.Value) Error![]u8 {
        const datum = try renderArgs(allocator, args);
        defer allocator.free(datum);

        const source = try formatDispatch(allocator, name, datum);
        defer allocator.free(source);

        var length_buffer: [64]u8 = undefined;
        const length_written = self.interpreter.eval(allocator, source, &length_buffer) catch |err|
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
};

const shape_types = [_][]const u8{ "string", "number", "integer", "boolean", "array", "object", "enum" };
const shape_keywords = [_][]const u8{ "properties", "items", "enum", "description", "required" };
const variadic_keywords = [_][]const u8{ "properties", "required", "enum" };

fn clauseLengthOk(keyword: []const u8, len: usize) bool {
    if (memberIndex(&variadic_keywords, keyword) != null) return len >= 2;
    return len == 2;
}

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
    if (fields.len != 3) return error.SchemeError;
    const name = try textOf(allocator, fields[0]);
    errdefer allocator.free(name);
    const description = try textOf(allocator, fields[1]);
    errdefer allocator.free(description);
    const parameters = try renderShape(allocator, fields[2]);
    errdefer freeValue(allocator, parameters);
    return .{ .name = name, .description = description, .parameters = parameters };
}

fn textOf(allocator: std.mem.Allocator, datum: Datum) Error![]const u8 {
    return switch (datum) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.SchemeError,
    };
}

fn freeDesc(allocator: std.mem.Allocator, desc: ToolDesc) void {
    allocator.free(desc.name);
    allocator.free(desc.description);
    freeValue(allocator, desc.parameters);
}

/// Render one shape datum as a JSON Schema over the shape subset. A shape
/// outside the subset fails closed with `error.SchemeError`.
fn renderShape(allocator: std.mem.Allocator, datum: Datum) Error!std.json.Value {
    const clauses = switch (datum) {
        .list => |items| items,
        else => return error.SchemeError,
    };
    if (clauses.len < 2) return error.SchemeError;
    if (clauses[0] != .symbol or !std.mem.eql(u8, clauses[0].symbol, "type")) return error.SchemeError;
    if (clauses[1] != .symbol) return error.SchemeError;
    const type_name = clauses[1].symbol;
    if (memberIndex(&shape_types, type_name) == null) return error.SchemeError;
    return renderClauses(allocator, type_name, null, clauses[2..]);
}

/// Render one property spec: the property name followed by the same clause
/// lists a shape carries, with `(type ...)` in clause position. Exactly one
/// type clause is required, mirroring the top level.
fn renderProperty(allocator: std.mem.Allocator, spec: []const Datum) Error!std.json.Value {
    if (spec.len == 0 or spec[0] != .symbol) return error.SchemeError;
    var type_name: ?[]const u8 = null;
    var type_at: ?usize = null;
    for (spec[1..], 0..) |clause_datum, index| {
        const clause = switch (clause_datum) {
            .list => |items| items,
            else => return error.SchemeError,
        };
        if (clause.len == 0 or clause[0] != .symbol) return error.SchemeError;
        const keyword = clause[0].symbol;
        if (std.mem.eql(u8, keyword, "type")) {
            if (type_name != null) return error.SchemeError;
            if (!clauseLengthOk(keyword, clause.len)) return error.SchemeError;
            if (clause[1] != .symbol) return error.SchemeError;
            if (memberIndex(&shape_types, clause[1].symbol) == null) return error.SchemeError;
            type_name = clause[1].symbol;
            type_at = index;
        } else {
            if (memberIndex(&shape_keywords, keyword) == null) return error.SchemeError;
            if (!clauseLengthOk(keyword, clause.len)) return error.SchemeError;
        }
    }
    if (type_name == null) return error.SchemeError;
    return renderClauses(allocator, type_name, type_at, spec[1..]);
}

/// Render the clause lists of one schema level. `skip` is the index of a
/// type clause already accounted for by the caller. An `enum` type carries
/// its values in the `(enum ...)` clause: the schema is that array alone,
/// with no `type` field.
fn renderClauses(allocator: std.mem.Allocator, type_name: ?[]const u8, skip: ?usize, clauses: []const Datum) Error!std.json.Value {
    var positions = [_]?usize{null} ** shape_keywords.len;
    for (clauses, 0..) |clause_datum, index| {
        if (skip) |at| {
            if (at == index) continue;
        }
        const clause = switch (clause_datum) {
            .list => |items| items,
            else => return error.SchemeError,
        };
        if (clause.len == 0 or clause[0] != .symbol) return error.SchemeError;
        const keyword = clause[0].symbol;
        const at = memberIndex(&shape_keywords, keyword) orelse return error.SchemeError;
        if (positions[at] != null) return error.SchemeError;
        if (!clauseLengthOk(keyword, clause.len)) return error.SchemeError;
        positions[at] = index;
    }

    const is_object = type_name != null and std.mem.eql(u8, type_name.?, "object");
    const is_array = type_name != null and std.mem.eql(u8, type_name.?, "array");

    var object: std.json.ObjectMap = .{};
    errdefer freeObject(allocator, &object);
    if (type_name) |name| {
        if (!std.mem.eql(u8, name, "enum")) try putStringField(allocator, &object, "type", name);
    }

    for (shape_keywords, 0..) |keyword, at| {
        const position = positions[at] orelse continue;
        const clause = clauses[position].list;
        if (std.mem.eql(u8, keyword, "properties")) {
            if (!is_object) return error.SchemeError;
            const rendered = try renderProperties(allocator, clause[1..]);
            errdefer freeValue(allocator, rendered);
            try putField(allocator, &object, keyword, rendered);
        } else if (std.mem.eql(u8, keyword, "items")) {
            if (!is_array) return error.SchemeError;
            const rendered = try renderShape(allocator, clause[1]);
            errdefer freeValue(allocator, rendered);
            try putField(allocator, &object, keyword, rendered);
        } else if (std.mem.eql(u8, keyword, "enum")) {
            const rendered = try renderEnum(allocator, clause[1..]);
            errdefer freeValue(allocator, rendered);
            try putField(allocator, &object, keyword, rendered);
        } else if (std.mem.eql(u8, keyword, "description")) {
            const rendered = try renderDescription(allocator, clause[1]);
            errdefer freeValue(allocator, rendered);
            try putField(allocator, &object, keyword, rendered);
        } else {
            if (!is_object) return error.SchemeError;
            const rendered = try renderRequired(allocator, clause[1..]);
            errdefer freeValue(allocator, rendered);
            try putField(allocator, &object, keyword, rendered);
        }
    }

    if (type_name) |name| {
        if (std.mem.eql(u8, name, "enum")) {
            const enum_at = memberIndex(&shape_keywords, "enum") orelse return error.SchemeError;
            if (positions[enum_at] == null) return error.SchemeError;
        }
    }
    return .{ .object = object };
}

fn renderProperties(allocator: std.mem.Allocator, specs: []const Datum) Error!std.json.Value {
    var properties: std.json.ObjectMap = .{};
    errdefer freeObject(allocator, &properties);
    for (specs) |spec| {
        const fields = switch (spec) {
            .list => |items| items,
            else => return error.SchemeError,
        };
        if (fields.len == 0 or fields[0] != .symbol) return error.SchemeError;
        for (properties.keys()) |existing| {
            if (std.mem.eql(u8, existing, fields[0].symbol)) return error.SchemeError;
        }
        {
            const rendered = try renderProperty(allocator, fields);
            errdefer freeValue(allocator, rendered);
            try putField(allocator, &properties, fields[0].symbol, rendered);
        }
    }
    return .{ .object = properties };
}

fn renderEnum(allocator: std.mem.Allocator, values: []const Datum) Error!std.json.Value {
    var items: std.json.Array = .init(allocator);
    errdefer freeArray(allocator, &items);
    for (values) |value| {
        const item: std.json.Value = switch (value) {
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .symbol => |text| .{ .string = try allocator.dupe(u8, text) },
            .integer => |n| .{ .integer = n },
            .float => |f| .{ .float = f },
            .boolean => |b| .{ .bool = b },
            else => return error.SchemeError,
        };
        {
            errdefer freeValue(allocator, item);
            try items.append(item);
        }
    }
    return .{ .array = items };
}

fn renderDescription(allocator: std.mem.Allocator, datum: Datum) Error!std.json.Value {
    return switch (datum) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        else => error.SchemeError,
    };
}

fn renderRequired(allocator: std.mem.Allocator, names: []const Datum) Error!std.json.Value {
    var required: std.json.Array = .init(allocator);
    errdefer freeArray(allocator, &required);
    for (names) |name| {
        const text = switch (name) {
            .symbol => |spec| try allocator.dupe(u8, spec),
            .string => |spec| try allocator.dupe(u8, spec),
            else => return error.SchemeError,
        };
        {
            errdefer allocator.free(text);
            try required.append(.{ .string = text });
        }
    }
    return .{ .array = required };
}

/// Put `key` with `value` into `object`. On success the object owns both; on
/// failure the key is freed and `value` stays with the caller.
fn putField(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) Error!void {
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    try object.put(allocator, key_copy, value);
}

fn putStringField(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, text: []const u8) Error!void {
    try putField(allocator, object, key, .{ .string = try allocator.dupe(u8, text) });
}

fn memberIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, at| {
        if (std.mem.eql(u8, candidate, name)) return at;
    }
    return null;
}

fn freeObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap) void {
    var it = object.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeValue(allocator, entry.value_ptr.*);
    }
    object.deinit(allocator);
}

fn freeArray(allocator: std.mem.Allocator, array: *std.json.Array) void {
    for (array.items) |item| freeValue(allocator, item);
    array.deinit();
}

fn freeValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    var tree = value;
    switch (tree) {
        .string => |text| allocator.free(text),
        .array => |*items| {
            for (items.items) |item| freeValue(allocator, item);
            items.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            object.deinit(allocator);
        },
        else => {},
    }
}

/// Render parsed JSON arguments as quoted datum source text: an object as
/// an alist `((key . value) ...)`, an array as a list, strings as escaped
/// literals, numbers as numerals, booleans as `#t`/`#f`, and `null` as the
/// symbol `null`, distinct from `()`. `error.SchemeError` marks an argument
/// not representable as source text this runtime reads back.
pub fn renderArgs(allocator: std.mem.Allocator, args: std.json.Value) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeDatum(allocator, &out, args);
    return out.toOwnedSlice(allocator);
}

/// Write one JSON value as datum source text.
fn writeDatum(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) Error!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "#t" else "#f"),
        .integer => |n| {
            var numeral: [24]u8 = undefined;
            const written = std.fmt.bufPrint(&numeral, "{d}", .{n}) catch unreachable;
            try out.appendSlice(allocator, written);
        },
        .float => |f| {
            if (!std.math.isFinite(f)) return error.SchemeError;
            var numeral: [512]u8 = undefined;
            const written = std.fmt.bufPrint(&numeral, "{d}", .{f}) catch return error.SchemeError;
            try out.appendSlice(allocator, written);
        },
        .number_string => |text| {
            if (!isRenderableNumber(text)) return error.SchemeError;
            try out.appendSlice(allocator, text);
        },
        .string => |text| try writeSchemeString(allocator, out, text),
        .array => |items| {
            try out.append(allocator, '(');
            var first = true;
            for (items.items) |item| {
                if (!first) try out.append(allocator, ' ');
                first = false;
                try writeDatum(allocator, out, item);
            }
            try out.append(allocator, ')');
        },
        .object => |object| {
            try out.append(allocator, '(');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ' ');
                first = false;
                try out.append(allocator, '(');
                try writeSymbolKey(allocator, out, entry.key_ptr.*);
                try out.appendSlice(allocator, " . ");
                try writeDatum(allocator, out, entry.value_ptr.*);
                try out.append(allocator, ')');
            }
            try out.append(allocator, ')');
        },
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

/// Render one object key as a Scheme symbol. Keys whose every byte is in
/// `[A-Za-z0-9_-]` and whose first byte is a letter or `_` write bare;
/// everything else — empty, `.`, number-like, `-`-led, spaces, unicode,
/// `|`, `\` — is `|...|`-quoted so it reads back as the intended symbol.
pub fn writeSymbolKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8) Error!void {
    if (isPlainSymbol(key)) return out.appendSlice(allocator, key);
    try out.append(allocator, '|');
    try writePipeBody(allocator, out, key);
    try out.append(allocator, '|');
}

/// Whether a symbol name may be written bare. Marginal cases pipe (a
/// leading `-` or `.` or `#`); under-piping, never, is the safe direction.
fn isPlainSymbol(key: []const u8) bool {
    if (key.len == 0) return false;
    switch (key[0]) {
        'a'...'z', 'A'...'Z', '_' => {},
        else => return false,
    }
    for (key) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// The inside of a `|...|`-quoted symbol, matching the vendored writer: one
/// codepoint at a time, `\|` for a pipe, `\\` for a backslash, and hex
/// `\x…;` (unpadded) for codepoints below `#\space` or above `#\~`. Past
/// U+1FFFF the reader cannot read the hex form back, so the raw UTF-8
/// bytes stand in there (pinned in tests/environment/env.zig).
fn writePipeBody(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8) Error!void {
    var at: usize = 0;
    while (at < key.len) {
        const length = std.unicode.utf8ByteSequenceLength(key[at]) catch return error.SchemeError;
        if (at + length > key.len) return error.SchemeError;
        const cp = std.unicode.utf8Decode(key[at .. at + length]) catch return error.SchemeError;
        switch (cp) {
            '|' => try out.appendSlice(allocator, "\\|"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => {
                if (cp >= 0x20 and cp <= 0x7e) {
                    try out.appendSlice(allocator, key[at .. at + length]);
                } else if (cp <= 0x1ffff) {
                    var digits: [8]u8 = undefined;
                    const hex = std.fmt.bufPrint(&digits, "{x}", .{cp}) catch unreachable;
                    try out.appendSlice(allocator, "\\x");
                    try out.appendSlice(allocator, hex);
                    try out.append(allocator, ';');
                } else {
                    try out.appendSlice(allocator, key[at .. at + length]);
                }
            },
        }
        at += length;
    }
}

/// Whether a number the JSON parse kept as its literal text renders as a
/// numeral the runtime reads: an optional sign then a digit. JSON's own
/// grammar guarantees this for parsed values (`0.5`, never `.5`);
/// hand-built values fail closed.
fn isRenderableNumber(text: []const u8) bool {
    const at: usize = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) 1 else 0;
    if (at >= text.len) return false;
    return switch (text[at]) {
        '0'...'9' => true,
        else => false,
    };
}

const max_depth = 64;

/// One parsed element of a written representation.
const Datum = union(enum) {
    symbol: []const u8,
    string: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
    list: []const Datum,
};

fn parseDatum(allocator: std.mem.Allocator, text: []const u8) Error!Datum {
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

fn freeDatum(allocator: std.mem.Allocator, datum: Datum) void {
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

fn formatDispatch(allocator: std.mem.Allocator, name: []const u8, args: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "(hen:tools/call! ");
    try writeSchemeString(allocator, &out, name);
    try out.appendSlice(allocator, " '");
    try out.appendSlice(allocator, args);
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

test "writeSymbolKey pipes only outside the plain class" {
    const cases = [_]struct { key: []const u8, rendered: []const u8 }{
        .{ .key = "_ok", .rendered = "_ok" },
        .{ .key = "ok2", .rendered = "ok2" },
        .{ .key = "a-b", .rendered = "a-b" },
        .{ .key = "a.b", .rendered = "|a.b|" },
        .{ .key = "42", .rendered = "|42|" },
        .{ .key = ".", .rendered = "|.|" },
        .{ .key = "", .rendered = "||" },
        .{ .key = "a b", .rendered = "|a b|" },
        .{ .key = "-1", .rendered = "|-1|" },
        .{ .key = "a|b", .rendered = "|a\\|b|" },
        .{ .key = "a\\b", .rendered = "|a\\\\b|" },
        .{ .key = "héllo", .rendered = "|h\\xe9;llo|" },
    };
    for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try writeSymbolKey(std.testing.allocator, &out, case.key);
        try std.testing.expectEqualStrings(case.rendered, out.items);
    }
}

test "renderArgs pins the JSON to datum text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { json: []const u8, datum: []const u8 }{
        .{ .json = "{}", .datum = "()" },
        .{ .json = "{\"hi\": \"x\", \"n\": null, \"b\": true, \"f\": false, \"i\": -3, \"f2\": 0.5}", .datum = "((hi . \"x\") (n . null) (b . #t) (f . #f) (i . -3) (f2 . 0.5))" },
        .{ .json = "{\"o\": {\"b\": true}}", .datum = "((o . ((b . #t))))" },
        .{ .json = "[]", .datum = "()" },
        .{ .json = "[1, null, \"s\"]", .datum = "(1 null \"s\")" },
        .{ .json = "99999999999999999999", .datum = "99999999999999999999" },
    };
    for (cases) |case| {
        const from_text = try std.json.parseFromSlice(std.json.Value, a, case.json, .{});
        const datum = try renderArgs(a, from_text.value);
        try std.testing.expectEqualStrings(case.datum, datum);
    }
}

test "renderArgs keeps number_string literals as-is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "1e5", "-0.5", "1.5e-3", "999999999999999999999999" }) |text| {
        const datum = try renderArgs(a, .{ .number_string = text });
        try std.testing.expectEqualStrings(text, datum);
    }

    try std.testing.expectError(
        error.SchemeError,
        renderArgs(a, .{ .number_string = ".5" }),
    );
    try std.testing.expectError(
        error.SchemeError,
        renderArgs(a, .{ .float = std.math.nan(f64) }),
    );
}

test "renderArgs crosses adversarial arg keys through the runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var object: std.json.ObjectMap = .{};
    for ([_][]const u8{ "a.b", "42", "a b", "a|b", "a\\b", "héllo", "", ".", "_ok", "ok2", "🦄", "𠀀" }) |key| {
        try object.put(a, key, .null);
    }

    const datum = try renderArgs(a, .{ .object = object });
    try std.testing.expectEqualStrings(
        "((|a.b| . null) (|42| . null) (|a b| . null) (|a\\|b| . null) (|a\\\\b| . null) (|h\\xe9;llo| . null) (|| . null) (|.| . null) (_ok . null) (ok2 . null) (|\\x1f984;| . null) (|𠀀| . null))",
        datum,
    );

    var env = try Env.init(a, &.{ "scheme/env.scm", "tests/environment/testdata/tools.scm" });
    var output: [4096]u8 = undefined;
    _ = try env.interpreter.eval(a, try formatDispatch(a, "hen-keys", datum), &output);

    const observation = try env.interpreter.eval(a, "(hen:tools/fetch)", &output);
    try std.testing.expectEqualStrings(
        "\"a.b 42 a b a|b a\\\\b héllo  . _ok ok2 🦄 𠀀\"",
        observation,
    );
}

test "renderArgs crosses an adversarial string value through the runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payload = "a\"b\\c\nd\r\te\x00g héllo";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "((text . ");
    try writeSchemeString(a, &out, payload);
    try out.appendSlice(a, "))");

    var env = try Env.init(a, &.{ "scheme/env.scm", "tests/environment/testdata/tools.scm" });
    var output: [4096]u8 = undefined;
    const length = try env.interpreter.eval(a, try formatDispatch(a, "hen-echo", out.items), &output);
    try std.testing.expectEqualStrings("18", length);

    const observation = try env.interpreter.eval(a, "(hen:tools/fetch)", &output);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\r\\te\\x00;g héllo\"", observation);
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
