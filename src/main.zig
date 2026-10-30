//! A minimal terminal chat loop for exercising the instance core end to end.
//!
//! One line per turn; the assistant reply is printed after each turn. The loop
//! ends at EOF or on the line `exit`. The provider token comes from
//! OPENCODE_API_KEY (optional when OPENCODE_BASE_URL is set);
//! OPENCODE_BASE_URL and OPENCODE_MODEL override the endpoints and model.
//! Subcommands run without a provider: `hen gate <root> <id>` gates a
//! candidate in a fresh process, `hen rollback <id>` repoints the active
//! generation under `generations/`.

const std = @import("std");
const uuid = @import("uuid");

const instance = @import("instance");
const http = @import("http");
const provider = @import("provider");
const environment = @import("environment");
const generations = @import("generations");

const generations_root = "generations";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next();
    if (command) |name| {
        if (std.mem.eql(u8, name, "gate")) return gateCommand(init, io, gpa, &args);
        if (std.mem.eql(u8, name, "rollback")) return rollbackCommand(io, gpa, &args);
    }
    return repl(init, io, gpa);
}

fn gateCommand(
    init: std.process.Init,
    io: std.Io,
    gpa: std.mem.Allocator,
    args: *std.process.Args.Iterator,
) !void {
    const root = args.next() orelse {
        std.debug.print("hen: usage: gate <root> <id>\n", .{});
        return error.Usage;
    };
    const id = args.next() orelse {
        std.debug.print("hen: usage: gate <root> <id>\n", .{});
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
        std.debug.print("hen: usage: rollback <id>\n", .{});
        return error.Usage;
    };

    const events = generations.ledger.read(io, gpa, generations_root) catch |err| {
        std.debug.print("hen: cannot read " ++ generations_root ++ "/ledger.sexp: {t}\n", .{err});
        return err;
    };
    defer generations.ledger.freeEvents(gpa, events);

    var latest: ?generations.LedgerEvent = null;
    for (events) |event| {
        if (std.mem.eql(u8, event.id, id)) latest = event;
    }
    const target = latest orelse {
        std.debug.print("hen: generation {s} is not in " ++ generations_root ++ "/ledger.sexp\n", .{id});
        return error.GenerationMissing;
    };
    if (target.status != .promoted) {
        std.debug.print("hen: generation {s} is {s}, not promoted; refusing rollback\n", .{ id, @tagName(target.status) });
        return error.NotPromoted;
    }

    try generations.ledger.setActive(io, gpa, generations_root, id);

    const stdout = std.Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    try out.interface.print("hen: active generation is now {s}, effective on the next start\n", .{id});
    try out.interface.flush();
}

/// Start the runtime on the active generation, or on the bare registry when
/// no pointer exists. A present-but-broken pointer exits loudly; it never
/// downgrades to the fallback.
fn repl(init: std.process.Init, io: std.Io, gpa: std.mem.Allocator) !void {
    const environ = init.environ_map;
    const a = init.arena.allocator();

    var env: environment.Env = undefined;
    var provider_base: ?[]const u8 = null;
    var provider_model: ?[]const u8 = null;

    const active = blk: {
        const pointer = generations.ledger.getActive(io, gpa, generations_root) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            error.ActiveMissing => {
                std.debug.print("hen: " ++ generations_root ++ "/active exists but is empty\n", .{});
                return error.ActiveMissing;
            },
            else => |rest| return rest,
        };
        break :blk pointer;
    };
    defer if (active) |id| gpa.free(id);

    if (active) |id| {
        if (generationManifest(io, a, generations_root, id)) |read| {
            if (read.provider) |p| {
                if (p.endpoints.len > 0) provider_base = p.endpoints[0];
                if (p.models.len > 0) provider_model = p.models[0];
            }
        }

        env = blk: {
            const prepared = generations.load.prepare(io, gpa, generations_root, id, environ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    generationStartupFailure(a, io, id, environ, err);
                    return err;
                },
            };
            defer generations.load.freePrepared(gpa, prepared);
            break :blk try generations.load.initEnv(gpa, prepared);
        };
    } else {
        env = try environment.Env.init(gpa, &.{"scheme/env.scm"});
    }

    const fallback_base: ?[]const u8 = if (provider_base) |base| if (base.len > 0) base else null else null;
    const env_base: ?[]const u8 = if (environ.get("OPENCODE_BASE_URL")) |base| if (base.len > 0) base else null else null;
    const base_url = env_base orelse fallback_base;

    const token_value = environ.get("OPENCODE_API_KEY") orelse blk: {
        if (base_url) |base| {
            if (base.len > 0) break :blk "dummy";
        }
        std.debug.print("hen: set OPENCODE_API_KEY to an opencode token, or point OPENCODE_BASE_URL at an OpenAI-compatible server\n", .{});
        return error.MissingToken;
    };
    const token = instance.Secret{ .name = "opencode", .value = token_value };

    var model: ?instance.Model = null;
    const env_model: ?[]const u8 = if (environ.get("OPENCODE_MODEL")) |name| if (name.len > 0) name else null else null;
    const model_name = env_model orelse provider_model;
    if (model_name) |name| {
        model = .{ .provider = "opencode", .name = name, .context = 300.000 };
    }

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    const client = try provider.OpencodeProvider.init(gpa, &transport, &token);
    defer client.deinit(gpa);

    var endpoint_urls: ?provider.OpenAIProvider.Endpoints = null;
    defer {
        if (endpoint_urls) |e| {
            gpa.free(e.go);
            gpa.free(e.models);
        }
    }
    if (base_url) |base| {
        if (base.len > 0) {
            endpoint_urls = try provider.OpenAIProvider.Endpoints.fromBase(gpa, base);
            client.impl.endpoints = endpoint_urls.?;
        }
    }

    var backend = client.asProvider();

    const generator = uuid.Generator.init(gpa, io);
    const id = try generator.v4();
    var session = try instance.Session.init(id, &backend);
    if (model) |*m| session.model = m;
    defer session.deinit(gpa);

    var listing = std.heap.ArenaAllocator.init(gpa);
    defer listing.deinit();
    const descs = try env.tools(listing.allocator());
    var catalog: std.ArrayList(instance.Session.CatalogEntry) = .empty;
    defer catalog.deinit(listing.allocator());
    for (descs) |desc| {
        try catalog.append(listing.allocator(), .{
            .name = desc.name,
            .summary = desc.summary,
            .when = desc.when,
        });
    }
    try session.setCatalog(gpa, catalog.items);

    const bridge = env.asEnvironment();
    session.environment = &bridge;

    const stdout = std.Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    const writer = &out.interface;

    const stdin = std.Io.File.stdin();
    var in_buffer: [16 * 1024]u8 = undefined;
    var in = stdin.readerStreaming(io, &in_buffer);

    const id_text = try generator.toString(id);
    defer gpa.free(id_text);
    try writer.print("hen: session {s}; type a message, `exit` to stop\n", .{id_text});
    try writer.flush();

    while (true) {
        try writer.print("\n> ", .{});
        try writer.flush();

        // End-of-stream counts as the end of the line, and `null` means the
        // input is done.
        const line = (try in.interface.takeDelimiter('\n')) orelse break;
        const message = std.mem.trim(u8, line, " \t\r");
        if (message.len == 0) continue;
        if (std.mem.eql(u8, message, "exit")) break;

        try session.appendMessage(gpa, message);

        const before = session.messages.items.len;
        session.run(io, gpa) catch |err| {
            try writer.print("[provider error: {t}]\n", .{err});
            try writer.flush();
            continue;
        };

        for (session.messages.items[before..]) |msg| {
            switch (msg) {
                .assistant => |assistant| try writer.print("{s}\n", .{assistant.content}),
                .tool => |output| try writer.print("{s}\n", .{output.content}),
                .user => {},
            }
        }
        try writer.flush();
    }
}

fn generationManifest(
    io: std.Io,
    a: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
) ?generations.manifest.Manifest {
    const gen_path = std.fmt.allocPrint(a, "{s}/{s}", .{ root, id }) catch return null;
    var dir = std.Io.Dir.cwd().openDir(io, gen_path, .{}) catch return null;
    defer dir.close(io);
    return generations.manifest.read(io, a, dir, "manifest.sexp") catch null;
}

fn generationStartupFailure(
    a: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    environ: *const std.process.Environ.Map,
    err: anyerror,
) void {
    if (err == error.ConfigUnresolved) {
        if (generationManifest(io, a, generations_root, id)) |read| {
            for (read.config) |decl| {
                if (decl.literal != null) continue;
                const source = decl.env_source orelse {
                    std.debug.print("hen: generation {s} config {s} has no source, unresolved\n", .{ id, decl.name });
                    return;
                };
                if (environ.get(source.text) == null) {
                    std.debug.print("hen: generation {s} config {s} needs {s} in the environment\n", .{ id, decl.name, source.text });
                    return;
                }
            }
        }
    }
    std.debug.print("hen: generation {s} failed to load: {t}\n", .{ id, err });
}
