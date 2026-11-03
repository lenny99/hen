const std = @import("std");
const socket = @import("socket");
const protocol = socket.protocol;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const environ = init.environ_map;

    const base = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(gpa, "{s}/hen/hen.sock", .{base});
    defer gpa.free(path);

    var stream = connectOrStart(io, path) catch |err| {
        std.debug.print("hen: cannot reach hend at {s}: {t}\n", .{ path, err });
        return err;
    };
    defer stream.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    try protocol.writeClientFrame(gpa, &writer.interface, .{ .hello = protocol.version });
    switch (try protocol.readServerFrame(arena.allocator(), &reader.interface)) {
        .hello => |value| if (value.protocol != protocol.version) {
            std.debug.print("hen: protocol mismatch: server {d}, client {d}\n", .{ value.protocol, protocol.version });
            return error.ProtocolMismatch;
        },
        else => return error.UnexpectedFrame,
    }

    try protocol.writeClientFrame(gpa, &writer.interface, .new);
    switch (try protocol.readServerFrame(arena.allocator(), &reader.interface)) {
        .attached => |id| std.debug.print("hen: session {s}\n", .{id}),
        .failure => |failure| {
            std.debug.print("hen: {s}: {s}\n", .{ failure.code, failure.message });
            return error.StartFailed;
        },
        else => return error.UnexpectedFrame,
    }

    const stdin = std.Io.File.stdin();
    var in_buffer: [16 * 1024]u8 = undefined;
    var in = stdin.readerStreaming(io, &in_buffer);

    const stdout = std.Io.File.stdout();
    var out_buffer: [16 * 1024]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    const screen = &out.interface;

    while (true) {
        _ = arena.reset(.retain_capacity);
        try screen.writeAll("\n> ");
        try screen.flush();

        const line = (try in.interface.takeDelimiter('\n')) orelse break;
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "exit")) {
            try protocol.writeClientFrame(gpa, &writer.interface, .detach);
            break;
        }

        try protocol.writeClientFrame(gpa, &writer.interface, .{ .message = text });
        while (true) {
            const frame = try protocol.readServerFrame(arena.allocator(), &reader.interface);
            switch (frame) {
                .event => |event| {
                    if (event.text.len > 0) try screen.print("{s}\n", .{event.text});
                    if (std.mem.eql(u8, event.kind, "turn.finished")) break;
                },
                .failure => |failure| {
                    try screen.print("[error {s}] {s}\n", .{ failure.code, failure.message });
                    break;
                },
                else => {},
            }
        }
        try screen.flush();
    }
}

fn connectOrStart(io: std.Io, path: []const u8) !socket.Stream {
    if (socket.connect(io, path)) |stream| return stream else |_| {}

    var child = try std.process.spawn(io, .{ .argv = &.{"hend"} });
    _ = &child;

    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (socket.connect(io, path)) |stream| return stream else |_| {}
        std.Io.sleep(io, .{ .nanoseconds = 50_000_000 }, .awake) catch {};
    }
    return error.HendUnreachable;
}
