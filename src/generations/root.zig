const std = @import("std");
const environment = @import("environment");

pub const Generation = struct {
    environment: ?environment.Interpreter = null,
};

test "generations stub links the environment module" {
    const interpreter = try environment.Interpreter.init(.{});
    const generation = Generation{ .environment = interpreter };
    try std.testing.expectEqual(interpreter.owner_thread, generation.environment.?.owner_thread);
}
