const std = @import("std");
const socket = @import("socket");
const codec = socket.codec;

test "envelope round trip" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try codec.writeFrame(&writer, "abc");

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 3, 'a', 'b', 'c' }, buffer[0..7]);

    var reader = std.Io.Reader.fixed(buffer[0..7]);
    const payload = try codec.readFrame(std.testing.allocator, &reader);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings("abc", payload);
}

test "oversized frame is rejected" {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(codec.max_frame_bytes + 1), .big);
    var reader = std.Io.Reader.fixed(&prefix);
    try std.testing.expectError(error.FrameTooLarge, codec.readFrame(std.testing.allocator, &reader));
}

test "truncated prefix is rejected" {
    var reader = std.Io.Reader.fixed(&.{ 0, 0, 0 });
    try std.testing.expectError(error.TruncatedFrame, codec.readFrame(std.testing.allocator, &reader));
}

test "truncated payload is rejected" {
    var reader = std.Io.Reader.fixed(&.{ 0, 0, 0, 3, 'a' });
    try std.testing.expectError(error.TruncatedFrame, codec.readFrame(std.testing.allocator, &reader));
}

const msgpack = socket.msgpack;

fn roundTrip(alloc: std.mem.Allocator, value: msgpack.Payload) !msgpack.Payload {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try codec.encodeValue(&out.writer, value);
    var reader = std.Io.Reader.fixed(out.written());
    return codec.decodeValue(alloc, &reader);
}

test "value round trip: nil, bool, int, uint, float" {
    const alloc = std.testing.allocator;

    {
        var back = try roundTrip(alloc, .nil);
        defer back.free(alloc);
        try std.testing.expect(back == .nil);
    }
    {
        var back = try roundTrip(alloc, .{ .bool = true });
        defer back.free(alloc);
        try std.testing.expect(back.bool);
    }
    {
        var back = try roundTrip(alloc, .{ .int = -7 });
        defer back.free(alloc);
        try std.testing.expectEqual(@as(i64, -7), back.int);
    }
    {
        var back = try roundTrip(alloc, .{ .uint = 300 });
        defer back.free(alloc);
        try std.testing.expectEqual(@as(u64, 300), back.uint);
    }
    {
        var back = try roundTrip(alloc, .{ .float = 1.5 });
        defer back.free(alloc);
        try std.testing.expectEqual(@as(f64, 1.5), back.float);
    }
}

test "value round trip: str and bin" {
    const alloc = std.testing.allocator;

    {
        var back = try roundTrip(alloc, .{ .str = msgpack.Str.init("text") });
        defer back.free(alloc);
        try std.testing.expectEqualStrings("text", back.str.str);
    }
    {
        var bytes = [_]u8{ 1, 2, 3 };
        var back = try roundTrip(alloc, .{ .bin = msgpack.Bin.init(&bytes) });
        defer back.free(alloc);
        try std.testing.expectEqualSlices(u8, &bytes, back.bin.bin);
    }
}

test "value round trip: array and map" {
    const alloc = std.testing.allocator;

    {
        var items = [_]msgpack.Payload{ .{ .uint = 1 }, .{ .str = msgpack.Str.init("two") } };
        var back = try roundTrip(alloc, .{ .arr = &items });
        defer back.free(alloc);
        try std.testing.expectEqual(@as(usize, 2), back.arr.len);
        try std.testing.expectEqual(@as(u64, 1), back.arr[0].uint);
        try std.testing.expectEqualStrings("two", back.arr[1].str.str);
    }
    {
        var source = msgpack.Map.init(alloc);
        try source.put(.{ .str = msgpack.Str.init("k") }, .{ .uint = 1 });
        const value = msgpack.Payload{ .map = source };
        defer value.free(alloc);
        var back = try roundTrip(alloc, value);
        defer back.free(alloc);
        const got = try back.mapGet("k");
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u64, 1), got.?.uint);
    }
}

fn decodeAndReencode(alloc: std.mem.Allocator, golden: []const u8) !msgpack.Payload {
    var reader = std.Io.Reader.fixed(golden);
    const decoded = try codec.decodeValue(alloc, &reader);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try codec.encodeValue(&out.writer, decoded);
    try std.testing.expectEqualSlices(u8, golden, out.written());
    return decoded;
}

test "golden: nil" {
    const alloc = std.testing.allocator;
    var back = try decodeAndReencode(alloc, &.{0xc0});
    defer back.free(alloc);
    try std.testing.expect(back == .nil);
}

test "golden: bool" {
    const alloc = std.testing.allocator;
    {
        var back = try decodeAndReencode(alloc, &.{0xc3});
        defer back.free(alloc);
        try std.testing.expect(back.bool);
    }
    {
        var back = try decodeAndReencode(alloc, &.{0xc2});
        defer back.free(alloc);
        try std.testing.expect(!back.bool);
    }
}

test "golden: int and uint" {
    const alloc = std.testing.allocator;
    {
        var back = try decodeAndReencode(alloc, &.{0xf9});
        defer back.free(alloc);
        try std.testing.expectEqual(@as(i64, -7), back.int);
    }
    {
        var back = try decodeAndReencode(alloc, &.{ 0xcd, 0x01, 0x2c });
        defer back.free(alloc);
        try std.testing.expectEqual(@as(u64, 300), back.uint);
    }
}

test "golden: float" {
    const alloc = std.testing.allocator;
    var back = try decodeAndReencode(alloc, &.{ 0xca, 0x3f, 0xc0, 0, 0 });
    defer back.free(alloc);
    try std.testing.expectEqual(@as(f64, 1.5), back.float);
}

test "golden: str and bin" {
    const alloc = std.testing.allocator;
    {
        var back = try decodeAndReencode(alloc, &.{ 0xa4, 't', 'e', 'x', 't' });
        defer back.free(alloc);
        try std.testing.expectEqualStrings("text", back.str.str);
    }
    {
        var back = try decodeAndReencode(alloc, &.{ 0xc4, 0x03, 1, 2, 3 });
        defer back.free(alloc);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, back.bin.bin);
    }
}

test "golden: array" {
    const alloc = std.testing.allocator;
    var back = try decodeAndReencode(alloc, &.{ 0x92, 0x01, 0xa3, 't', 'w', 'o' });
    defer back.free(alloc);
    try std.testing.expectEqual(@as(usize, 2), back.arr.len);
    try std.testing.expectEqual(@as(u64, 1), back.arr[0].uint);
    try std.testing.expectEqualStrings("two", back.arr[1].str.str);
}

test "golden: map" {
    const alloc = std.testing.allocator;
    var back = try decodeAndReencode(alloc, &.{ 0x81, 0xa1, 'k', 0x01 });
    defer back.free(alloc);
    const got = try back.mapGet("k");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 1), got.?.uint);
}
