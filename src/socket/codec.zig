const std = @import("std");
const msgpack = @import("msgpack");

pub const max_frame_bytes: usize = 4 * 1024 * 1024;

pub fn writeFrame(writer: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len > max_frame_bytes) return error.FrameTooLarge;
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(payload.len), .big);
    try writer.writeAll(&prefix);
    try writer.writeAll(payload);
    try writer.flush();
}

pub fn readFrame(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var prefix: [4]u8 = undefined;
    reader.readSliceAll(&prefix) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedFrame,
        else => |rest| return rest,
    };
    const length: usize = std.mem.readInt(u32, &prefix, .big);
    if (length > max_frame_bytes) return error.FrameTooLarge;
    const payload = try alloc.alloc(u8, length);
    errdefer alloc.free(payload);
    reader.readSliceAll(payload) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedFrame,
        else => |rest| return rest,
    };
    return payload;
}

pub const parse_limits = msgpack.ParseLimits{
    .max_depth = 32,
    .max_array_length = 100_000,
    .max_map_size = 100_000,
};

pub fn encodeValue(writer: *std.Io.Writer, value: msgpack.Payload) !void {
    const encoder = msgpack.Encoder{ .writer = writer };
    try encoder.write(value);
}

pub fn decodeValue(alloc: std.mem.Allocator, reader: *std.Io.Reader) !msgpack.Payload {
    const decoder = msgpack.Decoder{ .reader = reader, .limits = parse_limits };
    return decoder.read(alloc);
}
