const std = @import("std");
const instance = @import("instance");
const socket = @import("socket");
const protocol = socket.protocol;
const uuid = @import("uuid");

const EventWriter = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    seq: *u64,
    failed: ?anyerror = null,

    fn emit(ctx: *anyopaque, event: instance.Event) void {
        const self: *EventWriter = @ptrCast(@alignCast(ctx));
        if (self.failed != null) return;
        self.forward(event) catch |err| {
            self.failed = err;
        };
    }

    fn forward(self: *EventWriter, event: instance.Event) !void {
        switch (event.payload) {
            .message => |part| switch (part) {
                .delta => |text| try self.write(.message_delta, text),
                .done => |text| try self.write(
                    if (event.origin == .user) .user else .assistant,
                    text,
                ),
            },
            .eval => |evaluation| try self.write(.tool, evaluation.output),
        }
    }

    fn write(self: *EventWriter, kind: protocol.EventKind, text: []const u8) !void {
        self.seq.* += 1;
        try protocol.writeServerFrame(self.gpa, self.writer, .{ .event = .{
            .seq = self.seq.*,
            .kind = kind,
            .text = text,
        } });
    }
};

pub fn serve(
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
                session = try instance.Session.init(gpa, id, backend);
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
                var event_writer = EventWriter{ .gpa = gpa, .writer = &writer.interface, .seq = &seq };
                const listener = instance.Listener{ .ctx = &event_writer, .func = EventWriter.emit };
                session.?.turn(io, gpa, text, listener) catch |err| {
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "turn", .message = @errorName(err) } });
                    continue;
                };
                if (event_writer.failed) |err| return err;
                seq += 1;
                try protocol.writeServerFrame(gpa, &writer.interface, .{ .event = .{ .seq = seq, .kind = .turn_finished, .text = "" } });
            },
        }
    }
}

fn collectMessages(arena: std.mem.Allocator, session: instance.Session) ![]const []const u8 {
    const texts = try arena.alloc([]const u8, session.messages.items.len);
    for (session.messages.items, 0..) |message, index| {
        texts[index] = try arena.dupe(u8, switch (message.payload) {
            .message => |text| text,
            .evaluation => |evaluation| evaluation.output,
        });
    }
    return texts;
}
