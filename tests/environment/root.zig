const environment = @import("environment");

const std = @import("std");

const allocator = std.testing.allocator;

const Interpreter = environment.Interpreter;

test "evaluate Scheme through the Chicken interpreter" {
    const interpreter = try Interpreter.init(.{});
    var output: [128]u8 = undefined;

    try std.testing.expectEqualStrings("6", try interpreter.eval(allocator, "(+ 1 2 3)", &output));
    try std.testing.expectEqualStrings("(1 2 3)", try interpreter.eval(allocator, "'(1 2 3)", &output));
}

test "report CHICKEN errors through Zig" {
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

test "reject empty output buffer before evaluating" {
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
    const interpreter = try Interpreter.init(.{});
    var output: [16]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCString,
        interpreter.eval(allocator, "(+ 1 2)\x00ignored", &output),
    );
    try std.testing.expectError(
        error.InvalidCString,
        interpreter.load(allocator, "src/environment/testdata/load.scm\x00ignored"),
    );
}

test "load a Scheme file through the Zig API" {
    const interpreter = try Interpreter.init(.{});
    var output: [64]u8 = undefined;

    try interpreter.load(allocator, "src/environment/testdata/load.scm");
    try std.testing.expectEqualStrings("99", try interpreter.eval(allocator, "loaded-through-zig", &output));
}
