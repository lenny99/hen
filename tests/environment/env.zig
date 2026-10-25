const environment = @import("environment");

const std = @import("std");

const allocator = std.testing.allocator;

const Interpreter = environment.Interpreter;

const registry_path = "scheme/env.scm";
const fixture_path = "tests/environment/testdata/tools.scm";

fn registry() environment.Error!Interpreter {
    const interpreter = try Interpreter.init(.{});
    try interpreter.load(allocator, registry_path);
    try interpreter.load(allocator, fixture_path);
    return interpreter;
}

test "list registered tools with names and descriptions" {
    const interpreter = try registry();
    var output: [2048]u8 = undefined;

    const listing = try interpreter.eval(allocator, "(hen:tools/list)", &output);
    try std.testing.expect(std.mem.indexOf(u8, listing, "hen-echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "Echoes its text argument back.") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "hen-boom") != null);
}

test "call moves the action in and fetch reads the observation out" {
    const interpreter = try registry();
    var output: [256]u8 = undefined;

    const length = try interpreter.eval(
        allocator,
        "(hen:tools/call! \"hen-echo\" '((text . \"hello bridge\")))",
        &output,
    );
    try std.testing.expectEqualStrings("12", length);

    const first = try interpreter.eval(allocator, "(hen:tools/fetch)", &output);
    try std.testing.expectEqualStrings("\"hello bridge\"", first);

    const second = try interpreter.eval(allocator, "(hen:tools/fetch)", &output);
    try std.testing.expectEqualStrings("\"hello bridge\"", second);
}

test "store tool errors as Error observations" {
    const interpreter = try registry();
    var output: [256]u8 = undefined;

    const length = try interpreter.eval(
        allocator,
        "(hen:tools/call! \"hen-boom\" '())",
        &output,
    );
    try std.testing.expectEqualStrings("11", length);

    const stored = try interpreter.eval(allocator, "(hen:tools/fetch)", &output);
    try std.testing.expectEqualStrings("\"Error: boom\"", stored);
}

test "store unknown tools as Error observations" {
    const interpreter = try registry();
    var output: [256]u8 = undefined;

    const length = try interpreter.eval(
        allocator,
        "(hen:tools/call! \"hen-ghost\" '())",
        &output,
    );
    try std.testing.expectEqualStrings("30", length);

    const stored = try interpreter.eval(allocator, "(hen:tools/fetch)", &output);
    try std.testing.expectEqualStrings("\"Error: unknown tool: hen-ghost\"", stored);
}

const registry_and_fixture = &.{ registry_path, fixture_path };

test "list tools as provider-ready descriptors" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), registry_and_fixture);
    const descs = try env.tools(arena.allocator());

    const names = [_][]const u8{ "hen-echo", "hen-boom", "hen-keys", "hen-tick" };
    const descriptions = [_][]const u8{ "Echoes its text argument back.", "Always raises.", "Joins its arg keys with spaces.", "Counts its calls." };
    try std.testing.expectEqual(names.len, descs.len);
    for (names, descriptions, descs) |name, description, desc| {
        try std.testing.expectEqualStrings(name, desc.name);
        try std.testing.expectEqualStrings(description, desc.description);
    }
}

test "render tool shapes as JSON schemas" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), registry_and_fixture);
    const descs = try env.tools(arena.allocator());

    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"text to echo\"}},\"required\":[\"text\"]}",
        try std.json.Stringify.valueAlloc(arena.allocator(), descs[0].parameters, .{}),
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\"}",
        try std.json.Stringify.valueAlloc(arena.allocator(), descs[1].parameters, .{}),
    );
}

test "reject a shape outside the subset" {
    var env = try environment.Env.init(allocator, registry_and_fixture);
    var output: [256]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'bad #:description \"Bad shape.\" #:shape '(type object (pattern x)) #:handler (lambda (args) \"nope\"))",
        &output,
    );

    try std.testing.expectError(error.SchemeError, env.tools(allocator));
}

test "list an empty registry" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), &.{registry_path});
    const descs = try env.tools(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), descs.len);
}

test "propagate module load failures as errors" {
    try std.testing.expectError(
        error.SchemeError,
        environment.Env.init(allocator, &.{ registry_path, "src/environment/testdata/absent.scm" }),
    );
}

test "render nested object shapes with variadic clauses" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), registry_and_fixture);
    var output: [2048]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-nested #:description \"Nested.\" #:shape '(type object (properties (filters (type object) (properties (kind (type string)) (limit (type integer))) (required kind limit)) (name (type string))) (required filters name)) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    const descs = try env.tools(arena.allocator());
    var found = false;
    for (descs) |desc| {
        if (!std.mem.eql(u8, desc.name, "hen-nested")) continue;
        found = true;
        try std.testing.expectEqualStrings(
            "{\"type\":\"object\",\"properties\":{\"filters\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"kind\",\"limit\"]},\"name\":{\"type\":\"string\"}},\"required\":[\"filters\",\"name\"]}",
            try std.json.Stringify.valueAlloc(arena.allocator(), desc.parameters, .{}),
        );
    }
    try std.testing.expect(found);
}

test "read pipe-quoted property keys" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), registry_and_fixture);
    var output: [2048]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-pipe #:description \"Piped.\" #:shape '(type object (properties (|user id| (type string)) (|a\\|b| (type integer))) (required |user id|)) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    const descs = try env.tools(arena.allocator());
    var found = false;
    for (descs) |desc| {
        if (!std.mem.eql(u8, desc.name, "hen-pipe")) continue;
        found = true;
        try std.testing.expectEqualStrings(
            "{\"type\":\"object\",\"properties\":{\"user id\":{\"type\":\"string\"},\"a|b\":{\"type\":\"integer\"}},\"required\":[\"user id\"]}",
            try std.json.Stringify.valueAlloc(arena.allocator(), desc.parameters, .{}),
        );
    }
    try std.testing.expect(found);
}

test "render an enum shape as its enum array alone" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), registry_and_fixture);
    var output: [2048]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-enum #:description \"Enums.\" #:shape '(type enum (enum \"left\" right 3)) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    const descs = try env.tools(arena.allocator());
    var found = false;
    for (descs) |desc| {
        if (!std.mem.eql(u8, desc.name, "hen-enum")) continue;
        found = true;
        try std.testing.expectEqualStrings(
            "{\"enum\":[\"left\",\"right\",3]}",
            try std.json.Stringify.valueAlloc(arena.allocator(), desc.parameters, .{}),
        );
    }
    try std.testing.expect(found);
}

test "reject an enum shape without an enum clause" {
    var env = try environment.Env.init(allocator, registry_and_fixture);
    var output: [256]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-enumless #:description \"Enumless.\" #:shape '(type enum) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    try std.testing.expectError(error.SchemeError, env.tools(allocator));
}

test "reject an unknown shape type" {
    var env = try environment.Env.init(allocator, registry_and_fixture);
    var output: [256]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-dated #:description \"Dated.\" #:shape '(type date) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    try std.testing.expectError(error.SchemeError, env.tools(allocator));
}

test "read hex-escaped pipe keys from written forms" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = try environment.Env.init(arena.allocator(), registry_and_fixture);
    var output: [2048]u8 = undefined;
    _ = try env.interpreter.eval(
        arena.allocator(),
        "(register-tool! 'hen-hex #:description \"Hexes.\" #:shape '(type object (properties (|héllo wörld| (type string)))) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    const descs = try env.tools(arena.allocator());
    var found = false;
    for (descs) |desc| {
        if (!std.mem.eql(u8, desc.name, "hen-hex")) continue;
        found = true;
        try std.testing.expectEqualStrings(
            "{\"type\":\"object\",\"properties\":{\"héllo wörld\":{\"type\":\"string\"}}}",
            try std.json.Stringify.valueAlloc(arena.allocator(), desc.parameters, .{}),
        );
    }
    try std.testing.expect(found);
}

test "improper dots in written shapes fail closed" {
    var env = try environment.Env.init(allocator, registry_and_fixture);
    var output: [256]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-dot #:description \"Dot.\" #:shape (cons 'type 'x) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    try std.testing.expectError(error.SchemeError, env.tools(allocator));
}

test "hex escapes past the reader bound fail closed" {
    var env = try environment.Env.init(allocator, registry_and_fixture);
    var output: [2048]u8 = undefined;
    _ = try env.interpreter.eval(
        allocator,
        "(register-tool! 'hen-bounded #:description \"Bounded.\" #:shape '(type object (properties (|𠀀 x| (type string)))) #:handler (lambda (args) \"ok\"))",
        &output,
    );

    try std.testing.expectError(error.SchemeError, env.tools(allocator));
}

test "the reader reads raw control bytes inside string literals" {
    const interpreter = try registry();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [256]u8 = undefined;

    const raw = try allocator.dupe(u8, "(equal? \"A\x00B\" (apply string (map integer->char (list 65 0 66))))");
    defer allocator.free(raw);
    try std.testing.expectError(error.InvalidCString, interpreter.eval(a, raw, &output));

    for (1..32) |b| {
        const byte: u8 = @intCast(b);
        const source = try std.fmt.allocPrint(
            a,
            "(equal? \"A{s}B\" (apply string (map integer->char (list 65 {d} 66))))",
            .{ [_]u8{byte}, byte },
        );
        try std.testing.expectEqualStrings("#t", try interpreter.eval(a, source, &output));
    }
    try std.testing.expectEqualStrings(
        "#t",
        try interpreter.eval(a, "(equal? \"A\x7fB\" (apply string (map integer->char (list 65 127 66))))", &output),
    );
}

test "numbers the renderer emits read back as numbers" {
    const interpreter = try registry();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [64]u8 = undefined;

    for ([_][]const u8{ "1e5", "-0.5", "0.5", "1.5e-3", "99999999999999999999" }) |numeral| {
        const number_form = try std.fmt.allocPrint(a, "(number? {s})", .{numeral});
        try std.testing.expectEqualStrings("#t", try interpreter.eval(a, number_form, &output));
    }
}

test "call echoes the observation as decoded text" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"text\":\"hello via call\"}", .{});
    const observation = try env.call(a, "hen-echo", parsed.value);
    try std.testing.expectEqualStrings("hello via call", observation);
}

test "call returns a tool error as an Error observation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "hen-boom", .null);
    try std.testing.expectEqualStrings("Error: boom", observation);
}

test "call returns unknown tools as Error observations" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "hen-ghost", .null);
    try std.testing.expectEqualStrings("Error: unknown tool: hen-ghost", observation);
}

test "call runs the action exactly once across two dispatches" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    try std.testing.expectEqualStrings("1", try env.call(a, "hen-tick", .null));
    try std.testing.expectEqualStrings("2", try env.call(a, "hen-tick", .null));
}

test "call decodes a non-string result through its written form" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [2048]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(a, "(register-tool! 'hen-num #:handler (lambda (args) 42))", &output);

    const observation = try env.call(a, "hen-num", .null);
    try std.testing.expectEqualStrings("42", observation);
}

test "call round-trips mixed args byte for byte" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [2048]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(
        a,
        "(register-tool! 'hen-args #:handler (lambda (args) (with-output-to-string (lambda () (write args)))))",
        &output,
    );

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"s\":\"a\\\"b\\nd\",\"z\":\"a\\u0000b\",\"i\":3,\"x\":1.5,\"b\":true,\"f\":false,\"n\":null,\"arr\":[1,\"two\",false],\"o\":{\"in\":true}}",
        .{},
    );
    const observation = try env.call(a, "hen-args", parsed.value);
    try std.testing.expectEqualStrings(
        "((s . \"a\\\"b\\nd\") (z . \"a\\x00;b\") (i . 3) (x . 1.5) (b . #t) (f . #f) (n . null) (arr 1 \"two\" #f) (o (in . #t)))",
        observation,
    );
}

test "call decodes a NUL through the written form" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [256]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(
        a,
        "(register-tool! 'hen-nul #:handler (lambda (args) (apply string (map integer->char (list 97 0 98)))))",
        &output,
    );

    const observation = try env.call(a, "hen-nul", .null);
    try std.testing.expectEqual(@as(usize, 3), observation.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x61, 0x00, 0x62 }, observation);
}

test "call round-trips multi-byte characters byte for byte" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unit = "é€日";
    var payload: std.ArrayList(u8) = .empty;
    for (0..100) |_| try payload.appendSlice(a, unit);
    var object: std.json.ObjectMap = .{};
    try object.put(a, "text", .{ .string = payload.items });

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "hen-echo", .{ .object = object });
    try std.testing.expectEqualStrings(payload.items, observation);
}

test "call round-trips the writer's whole escape set" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [256]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(
        a,
        "(register-tool! 'hen-dense #:handler (lambda (args) (apply string (map integer->char (list 34 92 7 8 9 10 11 12 13)))))",
        &output,
    );

    const observation = try env.call(a, "hen-dense", .null);
    try std.testing.expectEqualSlices(u8, &.{ '"', '\\', 7, 8, 9, 10, 11, 12, 13 }, observation);
}

test "call round-trips a large observation through the sized scratch" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unit = "aé€日";
    var payload: std.ArrayList(u8) = .empty;
    for (0..12_000) |_| try payload.appendSlice(a, unit);
    var object: std.json.ObjectMap = .{};
    try object.put(a, "text", .{ .string = payload.items });

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "hen-echo", .{ .object = object });
    try std.testing.expectEqual(@as(usize, 108_000), observation.len);
    try std.testing.expectEqualStrings(payload.items, observation);
}

test "call returns an empty observation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [256]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(
        a,
        "(register-tool! 'hen-empty #:handler (lambda (args) \"\"))",
        &output,
    );

    const observation = try env.call(a, "hen-empty", .null);
    try std.testing.expectEqual(@as(usize, 0), observation.len);
}

const WrongThreadProbe = struct {
    env: *environment.Env,
    call_err: ?anyerror = null,
    tools_err: ?anyerror = null,
    empty_fallback: ?[]const u8 = null,
    empty_fallback_err: ?anyerror = null,
};

fn probeForeignThread(probe: *WrongThreadProbe) void {
    if (probe.env.call(allocator, "hen-tick", .null)) |_| {} else |err| probe.call_err = err;
    if (probe.env.tools(allocator)) |_| {} else |err| probe.tools_err = err;
    if (probe.env.errorObservation(allocator, error.SchemeError)) |observation| {
        probe.empty_fallback = observation;
    } else |err| {
        probe.empty_fallback_err = err;
    }
}

test "call and tools reject a thread other than the runtime owner" {
    var env = try environment.Env.init(allocator, registry_and_fixture);

    var probe = WrongThreadProbe{ .env = &env };
    const thread = try std.Thread.spawn(.{}, probeForeignThread, .{&probe});
    thread.join();

    try std.testing.expect(probe.call_err.? == error.WrongThread);
    try std.testing.expect(probe.tools_err.? == error.WrongThread);
    try std.testing.expectEqualStrings("Error: scheme error", probe.empty_fallback.?);
    try std.testing.expectEqual(@as(?anyerror, null), probe.empty_fallback_err);
    allocator.free(probe.empty_fallback.?);
}

test "call turns a result over the scratch slack into a buffer-too-small observation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [256]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(
        a,
        "(register-tool! 'hen-fat #:handler (lambda (args) (make-string (arg args 'n 0) (integer->char #x1ffff))))",
        &output,
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"n\":31}", .{});
    const observation = try env.call(a, "hen-fat", parsed.value);
    try std.testing.expectEqualStrings("Error: result buffer too small", observation);
}

test "call round-trips a result within the scratch slack" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [256]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(
        a,
        "(register-tool! 'hen-fat #:handler (lambda (args) (make-string (arg args 'n 0) (integer->char #x1ffff))))",
        &output,
    );

    var expected: std.ArrayList(u8) = .empty;
    for (0..30) |_| try expected.appendSlice(a, "\xf0\x9f\xbf\xbf");

    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"n\":30}", .{});
    const observation = try env.call(a, "hen-fat", parsed.value);
    try std.testing.expectEqualStrings(expected.items, observation);
}

test "errorObservation turns bridge failures into Error observations" {
    var env = try environment.Env.init(allocator, registry_and_fixture);
    var output: [64]u8 = undefined;

    try std.testing.expectError(
        error.SchemeError,
        env.interpreter.eval(allocator, "(error \"boom boom\")", &output),
    );
    const observation = try env.errorObservation(allocator, error.SchemeError);
    defer allocator.free(observation);
    try std.testing.expect(std.mem.startsWith(u8, observation, "Error: "));
    try std.testing.expect(std.mem.indexOf(u8, observation, "boom boom") != null);

    const too_small = try env.errorObservation(allocator, error.OutputBufferTooSmall);
    defer allocator.free(too_small);
    try std.testing.expectEqualStrings("Error: result buffer too small", too_small);
}
