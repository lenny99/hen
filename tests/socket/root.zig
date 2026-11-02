const std = @import("std");
const socket = @import("socket");

test "listen accepts one connection and moves bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);
    const path = try std.fmt.allocPrint(alloc, "{s}/hen.sock", .{dir_path});
    defer alloc.free(path);

    var listener = try socket.Listener.bind(std.testing.io, path);
    defer listener.close(std.testing.io);

    var client = try socket.connect(std.testing.io, path);
    defer client.close(std.testing.io);

    var accepted = try listener.accept(std.testing.io);
    defer accepted.close(std.testing.io);

    var write_buffer: [64]u8 = undefined;
    var writer = client.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("ping");
    try writer.interface.flush();

    var read_buffer: [64]u8 = undefined;
    var reader = accepted.reader(std.testing.io, &read_buffer);
    var got: [4]u8 = undefined;
    try reader.interface.readSliceAll(&got);
    try std.testing.expectEqualStrings("ping", &got);
}
