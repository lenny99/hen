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
