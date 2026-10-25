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

test "call echoes the observation as decoded text" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "(hen:tools/call! \"hen-echo\" '((text . \"hello via call\")))");
    try std.testing.expectEqualStrings("hello via call", observation);
}

test "call returns a tool error as an Error observation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "(hen:tools/call! \"hen-boom\" '())");
    try std.testing.expectEqualStrings("Error: boom", observation);
}

test "call returns unknown tools as Error observations" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "(hen:tools/call! \"hen-ghost\" '())");
    try std.testing.expectEqualStrings("Error: unknown tool: hen-ghost", observation);
}

test "call runs the action exactly once across two dispatches" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    try std.testing.expectEqualStrings("1", try env.call(a, "(hen:tools/call! \"hen-tick\" '())"));
    try std.testing.expectEqualStrings("2", try env.call(a, "(hen:tools/call! \"hen-tick\" '())"));
}

test "call evals a non-call expression and stores its written result" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    try std.testing.expectEqualStrings("3", try env.call(a, "(+ 1 2)"));
}

test "call turns a raised model error into an Error observation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "(error \"model boom\")");
    try std.testing.expectEqualStrings("Error: model boom", observation);
}

test "call rejects trailing text after the expression" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "(+ 1 2) junk");
    try std.testing.expectEqualStrings("Error: trailing input after the expression", observation);
}

test "call rejects a source with no expression" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "");
    try std.testing.expectEqualStrings("Error: no expression", observation);
}

test "call leaves a call! observation in place and fetches its length" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(a, "(hen:tools/call! \"hen-echo\" '((text . \"left in place\")))");
    try std.testing.expectEqualStrings("left in place", observation);
}

test "call decodes a non-string result through its written form" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: [2048]u8 = undefined;

    var env = try environment.Env.init(a, registry_and_fixture);
    _ = try env.interpreter.eval(a, "(register-tool! 'hen-num #:handler (lambda (args) 42))", &output);

    const observation = try env.call(a, "(hen:tools/call! \"hen-num\" '())");
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

    const observation = try env.call(
        a,
        "(hen:tools/call! \"hen-args\" '((s . \"a\\\"b\\nd\") (z . \"a\\x00;b\") (i . 3) (x . 1.5) (b . #t) (f . #f) (n . null) (arr 1 \"two\" #f) (o (in . #t))))",
    );
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

    const observation = try env.call(a, "(hen:tools/call! \"hen-nul\" '())");
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

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(
        a,
        try std.fmt.allocPrint(a, "(hen:tools/call! \"hen-echo\" '((text . \"{s}\")))", .{payload.items}),
    );
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

    const observation = try env.call(a, "(hen:tools/call! \"hen-dense\" '())");
    try std.testing.expectEqualSlices(u8, &.{ '"', '\\', 7, 8, 9, 10, 11, 12, 13 }, observation);
}

test "call round-trips a large observation through the sized scratch" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unit = "aé€日";
    var payload: std.ArrayList(u8) = .empty;
    for (0..12_000) |_| try payload.appendSlice(a, unit);

    var env = try environment.Env.init(a, registry_and_fixture);
    const observation = try env.call(
        a,
        try std.fmt.allocPrint(a, "(hen:tools/call! \"hen-echo\" '((text . \"{s}\")))", .{payload.items}),
    );
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

    const observation = try env.call(a, "(hen:tools/call! \"hen-empty\" '())");
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
    if (probe.env.call(allocator, "(hen:tools/call! \"hen-tick\" '())")) |_| {} else |err| probe.call_err = err;
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

    const observation = try env.call(a, "(hen:tools/call! \"hen-fat\" '((n . 31)))");
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

    const observation = try env.call(a, "(hen:tools/call! \"hen-fat\" '((n . 30)))");
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

test "asEnvironment runs the arguments as the source" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const bridge = env.asEnvironment();
    try std.testing.expectEqualStrings("3", try bridge.call(std.testing.io, a, "hen-eval", "(+ 1 2)"));
}

test "asEnvironment returns a bad source as an Error observation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const bridge = env.asEnvironment();
    const observation = try bridge.call(std.testing.io, a, "hen-eval", "(+ 1 2) junk");
    try std.testing.expectEqualStrings("Error: trailing input after the expression", observation);
}

test "asEnvironment ignores the tool name" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try environment.Env.init(a, registry_and_fixture);
    const bridge = env.asEnvironment();
    try std.testing.expectEqualStrings("3", try bridge.call(std.testing.io, a, "not-a-wire-name", "(+ 1 2)"));
}
