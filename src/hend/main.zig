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
        var worker: worker_mod.Worker = undefined;
        worker.init(io) catch |err| {
            std.debug.print("hend: worker start failed: {t}\n", .{err});
            continue;
        };
        defer worker.stop(io, gpa);

        worker.serve(io, gpa, &stream, &backend, model) catch |err| {
            std.debug.print("hend: connection ended: {t}\n", .{err});
        };
    }
}

