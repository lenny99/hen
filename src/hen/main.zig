const std = @import("std");
const socket = @import("socket");
const protocol = socket.protocol;
const client = @import("client");

const Command = union(enum) {
    start,
    list,
    attach: protocol.SessionId,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const environ = init.environ_map;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const command = parseCommand(&args) catch {
        printUsage();
        std.process.exit(2);
    };

    const base = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(gpa, "{s}/hen/hen.sock", .{base});
    defer gpa.free(path);

    switch (command) {
        .start => try runSession(io, gpa, environ, path, null),
        .attach => |id| try runSession(io, gpa, environ, path, id),
        .list => try runList(io, gpa, path),
    }
}

fn parseCommand(args: *std.process.Args.Iterator) !Command {
    const first = args.next();
    const second = args.next();
    const third = args.next();
    const command = try parseCommandArgs(first, second);
    if (third != null) return error.UnexpectedArgument;
    return command;
}

fn parseCommandArgs(first: ?[]const u8, second: ?[]const u8) !Command {
    const head = first orelse return .start;
    if (std.mem.eql(u8, head, "ls")) {
        if (second != null) return error.UnexpectedArgument;
        return .list;
    }
    if (std.mem.eql(u8, head, "attach")) {
        const text = second orelse return error.MissingSession;
        const id = protocol.sessionIdFromText(text) catch return error.InvalidSession;
        return .{ .attach = id };
    }
    return error.UnknownCommand;
}

fn printUsage() void {
    std.debug.print(
        \\usage: hen
        \\       hen ls
        \\       hen attach <id>
        \\
    , .{});
}

fn fail(code: []const u8, message: []const u8) noreturn {
    std.debug.print("hen: {s}: {s}\n", .{ code, message });
    std.process.exit(1);
}

fn runSession(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    path: []const u8,
    attach: ?protocol.SessionId,
) !void {
    const stream = connectOrStart(io, path) catch |err| {
        std.debug.print("hen: cannot reach hend at {s}: {t}\n", .{ path, err });
        std.process.exit(1);
    };
    var connection = try client.Connection.init(io, gpa, stream);
    defer connection.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    _ = try hello(arena.allocator(), &connection);

    if (attach) |id| {
        try connection.write(.{ .attach = id });
    } else {
        try connection.write(.new);
    }

    const session_id = switch (try connection.read(arena.allocator())) {
        .attached => |id| id,
        .failure => |failure| fail(failure.code, failure.message),
        else => return error.UnexpectedFrame,
    };

    _ = arena.reset(.retain_capacity);
    try connection.write(.snapshot);
    const snapshot = switch (try connection.read(arena.allocator())) {
        .snapshot => |value| value,
        .failure => |failure| fail(failure.code, failure.message),
        else => return error.UnexpectedFrame,
    };

    try client.run(io, gpa, environ, &connection, session_id, snapshot.messages);
}

fn runList(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const stream = connectOrStart(io, path) catch |err| {
        std.debug.print("hen: cannot reach hend at {s}: {t}\n", .{ path, err });
        std.process.exit(1);
    };
    var connection = try client.Connection.init(io, gpa, stream);
    defer connection.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    _ = try hello(arena.allocator(), &connection);
    try connection.write(.ls);

    const ids = switch (try connection.read(arena.allocator())) {
        .sessions => |value| value,
        .failure => |failure| fail(failure.code, failure.message),
        else => return error.UnexpectedFrame,
    };

    if (ids.len == 0) {
        std.debug.print("hen: no sessions\n", .{});
    } else {
        for (ids) |id| std.debug.print("{s}\n", .{id[0..]});
    }

    try connection.write(.detach);
}

fn hello(arena: std.mem.Allocator, connection: *client.Connection) !?protocol.SessionId {
    try connection.write(.{ .hello = protocol.version });
    return switch (try connection.read(arena)) {
        .hello => |value| blk: {
            if (value.protocol != protocol.version) {
                std.debug.print("hen: protocol mismatch: server {d}, client {d}\n", .{ value.protocol, protocol.version });
                std.process.exit(1);
            }
            break :blk value.session;
        },
        else => return error.UnexpectedFrame,
    };
}

fn connectOrStart(io: std.Io, path: []const u8) !socket.Stream {
    if (socket.connect(io, path)) |stream| return stream else |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {},
        else => return err,
    }

    var child = try std.process.spawn(io, .{ .argv = &.{"hend"} });
    _ = &child;

    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (socket.connect(io, path)) |stream| return stream else |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused, error.WouldBlock => {},
            else => return err,
        }
        std.Io.sleep(io, .{ .nanoseconds = 50_000_000 }, .awake) catch {};
    }
    return error.HendUnreachable;
}

const testing = std.testing;
const valid_session = "01234567-89ab-cdef-0123-456789abcdef";

test "parse command without arguments" {
    try testing.expect(std.meta.eql(Command.start, try parseCommandArgs(null, null)));
}

test "parse list command" {
    try testing.expect(std.meta.eql(Command.list, try parseCommandArgs("ls", null)));
}

test "parse attach command" {
    switch (try parseCommandArgs("attach", valid_session)) {
        .attach => |id| try testing.expectEqualStrings(valid_session, id[0..]),
        else => return error.ExpectedAttach,
    }
}

test "reject invalid command arguments" {
    try testing.expectError(error.MissingSession, parseCommandArgs("attach", null));
    try testing.expectError(error.InvalidSession, parseCommandArgs("attach", "nope"));
    try testing.expectError(error.UnexpectedArgument, parseCommandArgs("ls", "extra"));
    try testing.expectError(error.UnknownCommand, parseCommandArgs("wat", null));
}
