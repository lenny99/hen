const instance = @import("instance");

const std = @import("std");

const allocator = std.testing.allocator;

const Env = instance.Env;

test "evaluate Scheme through the Elz interpreter" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit(allocator);
    var output: [128]u8 = undefined;

    try std.testing.expectEqualStrings("6", try env.eval("(+ 1 2 3)", &output));
    try std.testing.expectEqualStrings("(1 2 3)", try env.eval("'(1 2 3)", &output));
}

test "report Elz errors through Zig" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit(allocator);
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        error.SchemeError,
        env.eval("(error \"boom\")", &output),
    );

    var message: [512]u8 = undefined;
    const detail = try env.lastError(&message);
    try std.testing.expect(std.mem.indexOf(u8, detail, "boom") != null);
}

test "reject empty output buffer before evaluating" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit(allocator);
    var output: [128]u8 = undefined;
    _ = try env.eval("(define zig-buffer-test 0)", &output);

    var no_output: [0]u8 = undefined;
    try std.testing.expectError(
        error.OutputBufferTooSmall,
        env.eval("(begin (set! zig-buffer-test 1) 42)", &no_output),
    );
    try std.testing.expectEqualStrings("0", try env.eval("zig-buffer-test", &output));
}

test "reject embedded NUL bytes" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit(allocator);
    var output: [16]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCString,
        env.eval("(+ 1 2)\x00ignored", &output),
    );
    try std.testing.expectError(
        error.InvalidCString,
        env.load(allocator, "src/instance/testdata/load.scm\x00ignored"),
    );
}

test "a registered tool reaches the Env through the trampoline" {
    var env: Env = undefined;
    try env.init(.{});
    defer env.deinit(allocator);

    try env.setGlobal(instance.EnvHelp.identifier, .{ .foreign_procedure = instance.EnvHelp.impl });
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"help\"", try env.eval("(help)", &output));
}
