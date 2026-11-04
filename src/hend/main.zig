const std = @import("std");
const socket = @import("socket");
const instance = @import("instance");
const http = @import("http");
const provider = @import("provider");
const worker_mod = @import("worker.zig");

const Config = struct {
    token: instance.Secret,
    base_url: ?[]const u8,
    model: ?instance.Model,
};

const Connection = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: socket.Stream,
    config: Config,
};

pub fn main(init: std.process.Init) !void {
    return serve(init);
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

    var model: ?instance.Model = null;
    if (environ.get("OPENCODE_MODEL")) |name| {
        if (name.len > 0) model = .{ .provider = "█[PROVIDER CREDENTIAL REDACTED]█", .name = name, .context = 300.000 };
    }

    const config = Config{ .token = token, .base_url = base_url, .model = model };

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
        const stream = listener.accept(io) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };

        const connection = gpa.create(Connection) catch {
            var closed = stream;
            closed.close(io);
            continue;
        };
        connection.* = .{ .io = io, .gpa = gpa, .stream = stream, .config = config };

        const thread = std.Thread.spawn(.{}, serveConnection, .{connection}) catch |err| {
            std.debug.print("hend: session thread failed: {t}\n", .{err});
            var closed = connection.stream;
            closed.close(io);
            gpa.destroy(connection);
            continue;
        };
        thread.detach();
    }
}

fn serveConnection(connection: *Connection) void {
    const io = connection.io;
    const gpa = connection.gpa;
    defer gpa.destroy(connection);
    defer connection.stream.close(io);

    var transport = http.Transport.init(io, gpa) catch |err| {
        std.debug.print("hend: transport start failed: {t}\n", .{err});
        return;
    };
    defer transport.deinit();

    const client = provider.OpencodeProvider.init(gpa, &transport, &connection.config.token) catch |err| {
        std.debug.print("hend: provider start failed: {t}\n", .{err});
        return;
    };
    defer client.deinit(gpa);

    var endpoints: ?provider.OpenAIProvider.Endpoints = null;
    defer if (endpoints) |value| {
        gpa.free(value.go);
        gpa.free(value.models);
    };
    if (connection.config.base_url) |base| {
        endpoints = provider.OpenAIProvider.Endpoints.fromBase(gpa, base) catch |err| {
            std.debug.print("hend: endpoint setup failed: {t}\n", .{err});
            return;
        };
        client.impl.endpoints = endpoints.?;
    }

    var backend = client.asProvider();

    var worker: worker_mod.Worker = undefined;
    worker.init() catch |err| {
        std.debug.print("hend: interpreter start failed: {t}\n", .{err});
        return;
    };
    defer worker.deinit();

    worker.serve(io, gpa, &connection.stream, &backend, connection.config.model) catch |err| {
        std.debug.print("hend: connection ended: {t}\n", .{err});
    };
}


