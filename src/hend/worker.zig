const std = @import("std");
const environment = @import("environment");
const instance = @import("instance");
const socket = @import("socket");
const protocol = socket.protocol;
const uuid = @import("uuid");

/// One session worker. It owns its interpreter, so every call must run on the
/// thread that created the worker.
pub const Worker = struct {
    env: environment.Env,

    pub fn init(self: *Worker) !void {
        self.env = try environment.Env.init();
    }

    pub fn deinit(self: *Worker) void {
        self.env.deinit();
    }

    pub fn asEnvironment(self: *Worker) instance.Environment {
        return .{ .impl = self, .call_fn = callFn };
    }

    fn callFn(
        impl: *anyopaque,
        _: std.Io,
        allocator: std.mem.Allocator,
        _: []const u8,
        arguments: []const u8,
    ) instance.Environment.CallError![]u8 {
        const self: *Worker = @ptrCast(@alignCast(impl));
        return self.env.call(allocator, arguments) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
    }

    pub fn serve(
        self: *Worker,
        io: std.Io,
        gpa: std.mem.Allocator,
        stream: *socket.Stream,
        backend: *instance.Provider,
        model: ?instance.Model,
    ) !void {
        var read_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var write_buffer: [64 * 1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        var session: ?instance.Session = null;
        defer if (session) |*value| value.deinit(gpa);
        var session_id: protocol.SessionId = undefined;

        var environment_iface: instance.Environment = self.asEnvironment();

        var seq: u64 = 0;

        while (true) {
            _ = arena.reset(.retain_capacity);
            const frame = protocol.readClientFrame(arena.allocator(), &reader.interface) catch |err| switch (err) {
                error.TruncatedFrame => return,
                else => return err,
            };

            switch (frame) {
                .hello => |version| {
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .hello = .{
                        .protocol = protocol.version,
                        .session = if (session != null) session_id else null,
                    } });
                    _ = version;
                },
                .new => {
                    if (session != null) {
                        try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "busy", .message = "session exists" } });
                        continue;
                    }
                    const generator = uuid.Generator.init(gpa, io);
                    const id = try generator.v4();
                    session = try instance.Session.init(id, backend);
                    session.?.environment = &environment_iface;
                    if (model) |*value| session.?.model = value;
                    _ = id.encode(&session_id);
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .attached = session_id });
                },
                .ls => {
                    const ids = [_]protocol.SessionId{session_id};
                    const list: []const protocol.SessionId = if (session != null) &ids else &.{};
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .sessions = list });
                },
                .attach => |id| {
                    if (session == null or !std.mem.eql(u8, &id, &session_id)) {
                        try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "unknown_session", .message = "no such session" } });
                        continue;
                    }
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .attached = session_id });
                },
                .detach => return,
                .snapshot => {
                    if (session == null) {
                        try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "no_session", .message = "start a session first" } });
                        continue;
                    }
                    const texts = try collectMessages(arena.allocator(), session.?);
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .snapshot = .{ .messages = texts, .seq = seq } });
                },
                .message => |text| {
                    if (session == null) {
                        try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "no_session", .message = "start a session first" } });
                        continue;
                    }
                    const added = session.?.turn(io, gpa, text) catch |err| {
                        try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "turn", .message = @errorName(err) } });
                        continue;
                    };
                    for (added) |message| {
                        seq += 1;
                        const kind: protocol.EventKind = switch (message) {
                            .assistant => .assistant,
                            .tool => .tool,
                            .user => .user,
                        };
                        try protocol.writeServerFrame(gpa, &writer.interface, .{ .event = .{ .seq = seq, .kind = kind, .text = messageText(message) } });
                    }
                    seq += 1;
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .event = .{ .seq = seq, .kind = .turn_finished, .text = "" } });
                },
            }
        }
    }

    fn messageText(message: instance.Message) []const u8 {
        return switch (message) {
            .assistant => |value| value.content,
            .tool => |value| value.content,
            .user => |value| value.content,
        };
    }

    fn collectMessages(arena: std.mem.Allocator, session: instance.Session) ![]const []const u8 {
        const texts = try arena.alloc([]const u8, session.messages.items.len);
        for (session.messages.items, 0..) |message, index| {
            texts[index] = try arena.dupe(u8, messageText(message));
        }
        return texts;
    }
};
