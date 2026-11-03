const std = @import("std");

pub const Environment = struct {
    impl: *anyopaque,

    call_fn: *const fn (
        impl: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
    ) CallError![]u8,

    pub const CallError = std.mem.Allocator.Error || std.Io.Cancelable || error{Failed};

    pub fn call(
        self: Environment,
        io: std.Io,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
    ) CallError![]u8 {
        return self.call_fn(self.impl, io, allocator, name, arguments);
    }
};
