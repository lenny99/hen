const std = @import("std");
const socket = @import("socket");
const protocol = socket.protocol;

test "client frames round trip" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const frames = [_]protocol.ClientFrame{
        .{ .hello = protocol.version },
        .new,
        .ls,
        .{ .attach = "abc" },
        .detach,
        .snapshot,
        .{ .message = "hello" },
    };

    for (frames) |frame| {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try protocol.writeClientFrame(alloc, &writer, frame);

        var reader = std.Io.Reader.fixed(writer.buffered());
        const back = try protocol.readClientFrame(arena.allocator(), &reader);
        try std.testing.expectEqual(std.meta.activeTag(frame), std.meta.activeTag(back));
        switch (frame) {
            .hello => |value| try std.testing.expectEqual(value, back.hello),
            .attach => |value| try std.testing.expectEqualStrings(value, back.attach),
            .message => |value| try std.testing.expectEqualStrings(value, back.message),
            else => {},
        }
    }
}

test "server event and snapshot round trip" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try protocol.writeServerFrame(alloc, &writer, .{ .event = .{ .seq = 7, .kind = "message", .text = "hi" } });
        var reader = std.Io.Reader.fixed(writer.buffered());
        const back = try protocol.readServerFrame(arena.allocator(), &reader);
        try std.testing.expectEqual(@as(u64, 7), back.event.seq);
        try std.testing.expectEqualStrings("message", back.event.kind);
        try std.testing.expectEqualStrings("hi", back.event.text);
    }
    {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const messages = [_][]const u8{ "one", "two" };
        try protocol.writeServerFrame(alloc, &writer, .{ .snapshot = .{ .messages = &messages, .seq = 3 } });
        var reader = std.Io.Reader.fixed(writer.buffered());
        const back = try protocol.readServerFrame(arena.allocator(), &reader);
        try std.testing.expectEqual(@as(u64, 3), back.snapshot.seq);
        try std.testing.expectEqual(@as(usize, 2), back.snapshot.messages.len);
        try std.testing.expectEqualStrings("one", back.snapshot.messages[0]);
        try std.testing.expectEqualStrings("two", back.snapshot.messages[1]);
    }
}

test "sessions and failure round trip" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const ids = [_][]const u8{ "a", "b" };
        try protocol.writeServerFrame(alloc, &writer, .{ .sessions = &ids });
        var reader = std.Io.Reader.fixed(writer.buffered());
        const back = try protocol.readServerFrame(arena.allocator(), &reader);
        try std.testing.expectEqual(@as(usize, 2), back.sessions.len);
        try std.testing.expectEqualStrings("b", back.sessions[1]);
    }
    {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try protocol.writeServerFrame(alloc, &writer, .{ .failure = .{ .code = "busy", .message = "one client" } });
        var reader = std.Io.Reader.fixed(writer.buffered());
        const back = try protocol.readServerFrame(arena.allocator(), &reader);
        try std.testing.expectEqualStrings("busy", back.failure.code);
        try std.testing.expectEqualStrings("one client", back.failure.message);
    }
}

test "unknown frame type is rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const fake = socket.msgpack.Payload{ .str = socket.msgpack.Str.init("nope") };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try socket.codec.encodeValue(&out.writer, fake);
    try socket.codec.writeFrame(&writer, out.written());

    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(error.NotMap, protocol.readClientFrame(arena.allocator(), &reader));
}
