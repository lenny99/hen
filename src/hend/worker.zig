const std = @import("std");
const instance = @import("instance");
const worker_proto = @import("worker_proto");

pub const Worker = struct {
    child: std.process.Child = undefined,
    reader: std.Io.File.Reader = undefined,
    writer: std.Io.File.Writer = undefined,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [16 * 1024]u8 = undefined,

    pub fn init(self: *Worker, io: std.Io) !void {
        self.child = try std.process.spawn(io, .{
            .argv = &.{"hen-worker"},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.writer = self.child.stdin.?.writer(io, &self.write_buffer);
        self.reader = self.child.stdout.?.readerStreaming(io, &self.read_buffer);
    }

    pub fn call(self: *Worker, gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
        try worker_proto.writeRequest(gpa, &self.writer.interface, .{
            .alloc = gpa,
            .op = .call,
            .name = @constCast(name),
            .arguments = @constCast(arguments),
        });
        try self.writer.interface.flush();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const reply = try worker_proto.readReply(arena.allocator(), &self.reader.interface);
        if (!reply.ok) return error.WorkerFailed;
        return gpa.dupe(u8, reply.text);
    }

    pub fn tools(self: *Worker, gpa: std.mem.Allocator) ![]u8 {
        try worker_proto.writeRequest(gpa, &self.writer.interface, .{ .alloc = gpa, .op = .tools });
        try self.writer.interface.flush();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const reply = try worker_proto.readReply(arena.allocator(), &self.reader.interface);
        if (!reply.ok) return error.WorkerFailed;
        return gpa.dupe(u8, reply.text);
    }

    pub fn stop(self: *Worker, io: std.Io, gpa: std.mem.Allocator) void {
        worker_proto.writeRequest(gpa, &self.writer.interface, .{ .alloc = gpa, .op = .shutdown }) catch {};
        self.writer.interface.flush() catch {};
        _ = std.process.Child.wait(&self.child, io) catch {};
    }
};

pub const Bridge = struct {
    worker: *Worker,

    pub fn environment(self: *Bridge) instance.Environment {
        return .{ .impl = self, .call_fn = callFn };
    }

    fn callFn(
        impl: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
    ) instance.Environment.CallError![]u8 {
        const self: *Bridge = @ptrCast(@alignCast(impl));
        _ = io;
        return self.worker.call(allocator, name, arguments) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
    }
};
