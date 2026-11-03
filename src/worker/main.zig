const std = @import("std");
const environment = @import("environment");
const generations = @import("generations");
const worker = @import("worker_proto");

const generations_root = "generations";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "gate")) return gateCommand(init, io, gpa, &args);
        if (std.mem.eql(u8, command, "rollback")) return rollbackCommand(io, gpa, &args);
    }
    return serve(io, gpa);
}

fn serve(io: std.Io, gpa: std.mem.Allocator) !void {
    var env = try environment.Env.init(gpa, &.{"scheme/env.scm"});

    const stdin = std.Io.File.stdin();
    var in_buffer: [16 * 1024]u8 = undefined;
    var in = stdin.readerStreaming(io, &in_buffer);

    const stdout = std.Io.File.stdout();
    var out_buffer: [16 * 1024]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);

    while (true) {
        var request = worker.readRequest(gpa, &in.interface) catch |err| switch (err) {
            error.TruncatedFrame => return,
            else => return err,
        };
        defer request.deinit();

        switch (request.op) {
            .call => try handleCall(gpa, &env, &out.interface, request.arguments),
            .tools => try handleTools(gpa, &env, &out.interface),
            .shutdown => {
                try worker.writeReply(gpa, &out.interface, true, "");
                try out.interface.flush();
                return;
            },
        }
    }
}

fn handleCall(gpa: std.mem.Allocator, env: *environment.Env, writer: *std.Io.Writer, arguments: []const u8) !void {
    var message_buffer: [1024]u8 = undefined;
    const value = env.call(gpa, arguments) catch |err| {
        const text: []const u8 = env.interpreter.lastError(&message_buffer) catch @errorName(err);
        try worker.writeReply(gpa, writer, false, text);
        try writer.flush();
        return;
    };
    defer gpa.free(value);
    try worker.writeReply(gpa, writer, true, value);
    try writer.flush();
}

fn handleTools(gpa: std.mem.Allocator, env: *environment.Env, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const descs = env.tools(arena.allocator()) catch |err| {
        try worker.writeReply(gpa, writer, false, @errorName(err));
        try writer.flush();
        return;
    };

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (descs, 0..) |desc, index| {
        if (index > 0) try text.writer.writeAll("\n");
        try text.writer.print("{s}\t{s}\t{s}", .{ desc.name, desc.summary, desc.when });
    }

    try worker.writeReply(gpa, writer, true, text.written());
    try writer.flush();
}

fn gateCommand(
    init: std.process.Init,
    io: std.Io,
    gpa: std.mem.Allocator,
    args: *std.process.Args.Iterator,
) !void {
    const root = args.next() orelse {
        std.debug.print("hen-worker: usage: gate <root> <id>\n", .{});
        return error.Usage;
    };
    const id = args.next() orelse {
        std.debug.print("hen-worker: usage: gate <root> <id>\n", .{});
        return error.Usage;
    };

    const report = try generations.runGate(io, gpa, root, id, init.environ_map);
    defer generations.freeGateReport(gpa, report);

    const stdout = std.Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    try out.interface.print("{s}\n", .{report.sexp});
    try out.interface.flush();

    if (report.result == .fail) return error.GateFailed;
}

fn rollbackCommand(io: std.Io, gpa: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const id = args.next() orelse {
        std.debug.print("hen-worker: usage: rollback <id>\n", .{});
        return error.Usage;
    };

    const events = generations.ledger.read(io, gpa, generations_root) catch |err| {
        std.debug.print("hen-worker: cannot read " ++ generations_root ++ "/ledger.sexp: {t}\n", .{err});
        return err;
    };
    defer generations.ledger.freeEvents(gpa, events);

    var latest: ?generations.LedgerEvent = null;
    for (events) |event| {
        if (std.mem.eql(u8, event.id, id)) latest = event;
    }
    const target = latest orelse {
        std.debug.print("hen-worker: generation {s} is not in " ++ generations_root ++ "/ledger.sexp\n", .{id});
        return error.GenerationMissing;
    };
    if (target.status != .promoted) {
        std.debug.print("hen-worker: generation {s} is {s}, not promoted; refusing rollback\n", .{ id, @tagName(target.status) });
        return error.NotPromoted;
    }

    try generations.ledger.setActive(io, gpa, generations_root, id);

    const stdout = std.Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    try out.interface.print("hen-worker: active generation is now {s}, effective on the next start\n", .{id});
    try out.interface.flush();
}
