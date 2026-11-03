const std = @import("std");
const socket = @import("socket");
const instance = @import("instance");
const http = @import("http");
const provider = @import("provider");
const uuid = @import("uuid");
const worker_mod = @import("worker.zig");

const protocol = socket.protocol;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "gate")) return forwardWorker(io, gpa, "gate", &args);
        if (std.mem.eql(u8, command, "rollback")) return forwardWorker(io, gpa, "rollback", &args);
    }
    return serve(init);
}

fn forwardWorker(io: std.Io, gpa: std.mem.Allocator, command: []const u8, args: *std.process.Args.Iterator) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "hen-worker");
    try argv.append(gpa, command);
    while (args.next()) |argument| try argv.append(gpa, argument);

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try std.process.Child.wait(&child, io);
    if (!term.success()) return error.ChildFailed;
}

fn socketPaths(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !struct { dir: []u8, path: []u8 } {
    const base = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/hen", .{base});
    errdefer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/hen.sock", .{dir});
    return .{ .dir = dir, .path = path };
}

fn serve(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const environ = init.environ_map;

    const paths = try socketPaths(gpa, environ);
    defer gpa.free(paths.dir);
    defer gpa.free(paths.path);
    try std.Io.Dir.cwd().createDirPath(io, paths.dir);

    const base_url: ?[]const u8 = if (environ.get("OPENCODE_BASE_URL")) |value| if (value.len > 0) value else null else null;
    const token_value = environ.get("OPENCODE_API_KEY") orelse blk: {
        if (base_url != null) break :blk "dummy";
        std.debug.print("hend: set OPENCODE_API_KEY or OPENCODE_BASE_URL\n", .{});
        return error.MissingToken;
    };
    const token = instance.Secret{ .name = "█[PROVIDER CREDENTIAL REDACTED]█", .value = token_value };

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    const client = try provider.OpencodeProvider.init(gpa, &transport, &token);
    defer client.deinit(gpa);

    var endpoints: ?provider.OpenAIProvider.Endpoints = null;
    defer if (endpoints) |e| {
        gpa.free(e.go);
        gpa.free(e.models);
    };
    if (base_url) |base| {
        endpoints = try provider.OpenAIProvider.Endpoints.fromBase(gpa, base);
        client.impl.endpoints = endpoints.?;
    }

    var backend = client.asProvider();

    var model: ?instance.Model = null;
    if (environ.get("OPENCODE_MODEL")) |name| {
        if (name.len > 0) model = .{ .provider = "█[PROVIDER CREDENTIAL REDACTED]█", .name = name, .context = 300.000 };
    }

    if (socket.connect(io, paths.path)) |stream| {
        var existing = stream;
        existing.close(io);
        std.debug.print("hend: already running at {s}\n", .{paths.path});
        return;
    } else |_| {
        std.Io.Dir.deleteFileAbsolute(io, paths.path) catch {};
    }

    var listener = try socket.Listener.bind(io, paths.path);
    defer listener.close(io);

    while (true) {
        var stream = listener.accept(io) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        defer stream.close(io);
        serveConnection(io, gpa, &stream, &backend, model) catch |err| {
            std.debug.print("hend: connection ended: {t}\n", .{err});
        };
    }
}

fn serveConnection(
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
    var session_id: []u8 = &.{};

    var worker: worker_mod.Worker = undefined;
    var worker_started = false;
    var bridge: worker_mod.Bridge = undefined;
    var environment_iface: instance.Environment = undefined;
    defer if (worker_started) worker.stop(io, gpa);

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
                    .session = if (session != null) session_id else "",
                } });
                _ = version;
            },
            .new => {
                if (session != null) {
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "busy", .message = "session exists" } });
                    continue;
                }
                worker.init(io) catch |err| {
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .failure = .{ .code = "worker", .message = @errorName(err) } });
                    continue;
                };
                worker_started = true;
                bridge = .{ .worker = &worker };
                environment_iface = bridge.environment();
                const generator = uuid.Generator.init(gpa, io);
                const id = try generator.v4();
                session = try instance.Session.init(id, backend);
                session.?.environment = &environment_iface;
                if (worker.tools(gpa)) |listing| {
                    defer gpa.free(listing);
                    var entries: std.ArrayList(instance.Session.CatalogEntry) = .empty;
                    defer entries.deinit(gpa);
                    var lines = std.mem.splitScalar(u8, listing, '\n');
                    while (lines.next()) |line| {
                        if (line.len == 0) continue;
                        var fields = std.mem.splitScalar(u8, line, '\t');
                        const name = fields.next() orelse continue;
                        const summary = fields.next() orelse "";
                        const when = fields.next() orelse "";
                        try entries.append(gpa, .{ .name = name, .summary = summary, .when = when });
                    }
                    try session.?.setCatalog(gpa, entries.items);
                } else |_| {}
                if (model) |*value| session.?.model = value;
                session_id = try std.fmt.allocPrint(arena.allocator(), "{f}", .{id});
                try protocol.writeServerFrame(gpa, &writer.interface, .{ .attached = session_id });
            },
            .ls => {
                const ids = [_][]const u8{session_id};
                const list: []const []const u8 = if (session != null) &ids else &.{};
                try protocol.writeServerFrame(gpa, &writer.interface, .{ .sessions = list });
            },
            .attach => |id| {
                if (session == null or !std.mem.eql(u8, id, session_id)) {
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
                    try protocol.writeServerFrame(gpa, &writer.interface, .{ .event = .{
                        .seq = seq,
                        .kind = @tagName(message),
                        .text = messageText(message),
                    } });
                }
                seq += 1;
                try protocol.writeServerFrame(gpa, &writer.interface, .{ .event = .{ .seq = seq, .kind = "turn.finished", .text = "" } });
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
