const std = @import("std");
const worker = @import("worker_proto");
const socket = @import("socket");
const codec = socket.codec;
const msgpack = socket.msgpack;

test "request round trip" {
    const alloc = std.testing.allocator;
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const request = worker.Request{
        .alloc = alloc,
        .op = .call,
        .name = @constCast("echo"),
        .arguments = @constCast("(1 2)"),
    };
    try worker.writeRequest(alloc, &writer, request);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var back = try worker.readRequest(alloc, &reader);
    defer back.deinit();
    try std.testing.expectEqual(worker.Op.call, back.op);
    try std.testing.expectEqualStrings("echo", back.name);
    try std.testing.expectEqualStrings("(1 2)", back.arguments);
}

test "reply round trip" {
    const alloc = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try worker.writeReply(alloc, &writer, true, "42");

    var reader = std.Io.Reader.fixed(writer.buffered());
    var back = try worker.readReply(alloc, &reader);
    defer back.deinit();
    try std.testing.expect(back.ok);
    try std.testing.expectEqualStrings("42", back.text);
}

test "unknown op is rejected" {
    const alloc = std.testing.allocator;
    const map = msgpack.Map.init(alloc);
    var payload = msgpack.Payload{ .map = map };
    defer payload.free(alloc);
    try payload.map.put(.{ .str = msgpack.Str.init("op") }, try msgpack.Payload.strToPayload("bogus", alloc));

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try codec.encodeValue(&encoded.writer, payload);

    var frame: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&frame);
    try codec.writeFrame(&writer, encoded.written());

    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(error.UnknownOp, worker.readRequest(alloc, &reader));
}
