const std = @import("std");
const environment = @import("environment");
const manifest = @import("manifest.zig");
const ledger = @import("ledger.zig");
const load = @import("load.zig");

const max_file_bytes = 4 * 1024 * 1024;
const listing_start = 4096;
const listing_max = 1024 * 1024;
const registry_file = "registry.sexp";
const hen_prefix = "hen-";
const report_not_enforced = "reported, not enforced";
const checkpoint_source = "(begin (hen:registrations/checkpoint!) #t)";
const undo_source = "(begin (hen:registrations/undo!) #t)";

pub const Result = enum { pass, fail };

pub const Check = struct {
    name: []const u8,
    result: Result,
    detail: []const u8,
};

pub const Diff = struct {
    added: []const []const u8 = &.{},
    removed: []const []const u8 = &.{},
    changed: []const []const u8 = &.{},
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    parent: []const u8,
    result: Result,
    checks: []const Check,
    capabilities: []const []const u8,
    diff: Diff,
    sexp: []const u8,
};

pub fn freeReport(allocator: std.mem.Allocator, report: Report) void {
    _ = allocator;
    var arena = report.arena;
    arena.deinit();
}

pub const RunError = std.mem.Allocator.Error ||
    ledger.FileIoError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.WriteFileError ||
    std.Io.Dir.Iterator.Error ||
    environment.Error;

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    candidate_id: []const u8,
    environ: *const std.process.Environ.Map,
) RunError!Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var checks: std.ArrayList(Check) = .empty;
    var capabilities: std.ArrayList([]const u8) = .empty;
    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;

    const gen_dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, candidate_id });
    const info: ?ManifestInfo = readManifestInfo(a, io, gen_dir_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (info) |read| {
        for (read.capabilities) |capability| {
            try capabilities.append(a, capability);
        }
    }

    const prepared: ?load.Prepared = blk: {
        const raw = load.prepare(io, allocator, root, candidate_id, environ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const detail = try std.fmt.allocPrint(a, "load failed: {s}", .{@errorName(err)});
                try addCheck(a, &checks, "prepare", .fail, detail);
                break :blk null;
            },
        };
        break :blk raw;
    };

    var listing: ?[]const Record = null;

    if (prepared) |p| {
        defer load.freePrepared(allocator, p);

        var env = try environment.Env.init(allocator, &.{"scheme/env.scm"});

        {
            var output: [64]u8 = undefined;
            _ = try env.interpreter.eval(a, checkpoint_source, &output);
        }

        var loaded = true;
        env.loadGeneration(a, p.entries, p.configs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const detail = try loadFailureDetail(a, &env, err, "module load failed");
                try addCheck(a, &checks, "module-load", .fail, detail);
                loaded = false;
            },
        };
        if (loaded) try addCheck(a, &checks, "module-load", .pass, "");

        if (loaded) {
            if (try listingCheck(a, &env, &checks)) |parsed| listing = parsed;
            if (listing) |parsed| {
                try lintCheck(a, &checks, parsed, info orelse empty_info);
            }

            const observed = try env.call(a, "(+ 1 2)");
            if (std.mem.eql(u8, observed, "3")) {
                try addCheck(a, &checks, "smoke", .pass, "");
            } else {
                const detail = try std.fmt.allocPrint(a, "smoke eval returned {s}", .{observed});
                try addCheck(a, &checks, "smoke", .fail, detail);
            }

            try loadTestFiles(io, a, &env, gen_dir_path, &checks);

            if (listing) |parsed| {
                const parent_records = try readParentRecords(a, io, root, parentText(info));
                const compared = try diffRecords(a, parsed, parent_records);
                for (compared.added) |name| try added.append(a, name);
                for (compared.removed) |name| try removed.append(a, name);
                for (compared.changed) |name| try changed.append(a, name);
            }
        }

        try undoCheck(a, &env, &checks);
    }

    try addCheck(a, &checks, "capabilities", .pass, report_not_enforced);

    const result = overall(checks.items);

    const added_names = try added.toOwnedSlice(a);
    const removed_names = try removed.toOwnedSlice(a);
    const changed_names = try changed.toOwnedSlice(a);

    const sexp_text = try emitReport(a, candidate_id, parentText(info), checks.items, capabilities.items, .{
        .added = added_names,
        .removed = removed_names,
        .changed = changed_names,
    }, result);

    try ledger.append(io, allocator, root, .{
        .id = candidate_id,
        .parent = parentText(info),
        .hash = hashText(info),
        .status = if (result == .pass) .candidate else .failed,
        .evidence = sexp_text,
    });

    if (result == .pass) {
        if (listing) |records| {
            const registry_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ gen_dir_path, registry_file });
            const bytes = try registryText(a, records);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = registry_path, .data = bytes });
        }
    }

    return .{
        .arena = arena,
        .id = try a.dupe(u8, candidate_id),
        .parent = try a.dupe(u8, parentText(info)),
        .result = result,
        .checks = try checks.toOwnedSlice(a),
        .capabilities = try capabilities.toOwnedSlice(a),
        .diff = .{
            .added = added_names,
            .removed = removed_names,
            .changed = changed_names,
        },
        .sexp = sexp_text,
    };
}

fn addCheck(
    a: std.mem.Allocator,
    checks: *std.ArrayList(Check),
    name: []const u8,
    result: Result,
    detail: []const u8,
) std.mem.Allocator.Error!void {
    const owned_name = try a.dupe(u8, name);
    try checks.append(a, .{ .name = owned_name, .result = result, .detail = detail });
}

fn loadFailureDetail(
    a: std.mem.Allocator,
    env: *environment.Env,
    err: environment.Error,
    kind: []const u8,
) environment.Error![]const u8 {
    const observed = env.errorObservation(a, err) catch |oom| return oom;
    if (kind.len == 0) return observed;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ kind, observed });
}

fn listingCheck(
    a: std.mem.Allocator,
    env: *environment.Env,
    checks: *std.ArrayList(Check),
) environment.Error!?[]const Record {
    const written = evalListing(env.*, a, "(hen:tools/list)") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const detail = try loadFailureDetail(a, env, err, "tools listing failed");
            try addCheck(a, checks, "tools-list", .fail, detail);
            return null;
        },
    };
    const parsed = recordsFromListing(a, written) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const detail = try a.dupe(u8, "tools listing is not a 5-field record list");
            try addCheck(a, checks, "tools-list", .fail, detail);
            return null;
        },
    };
    try addCheck(a, checks, "tools-list", .pass, "");
    return parsed;
}

fn lintCheck(
    a: std.mem.Allocator,
    checks: *std.ArrayList(Check),
    listing: []const Record,
    info: ManifestInfo,
) std.mem.Allocator.Error!void {
    var problems: std.ArrayList([]const u8) = .empty;
    for (listing) |record| {
        if (std.mem.eql(u8, record.summary, "")) {
            try problems.append(a, try std.fmt.allocPrint(a, "empty summary: {s}", .{record.name}));
        }
        if (std.mem.eql(u8, record.description, "")) {
            try problems.append(a, try std.fmt.allocPrint(a, "empty description: {s}", .{record.name}));
        }
        var prefixed = false;
        for (info.modules) |module_name| {
            const prefix = try std.fmt.allocPrint(a, "{s}-", .{module_name});
            if (std.mem.startsWith(u8, record.name, prefix)) prefixed = true;
        }
        if (!prefixed) {
            try problems.append(a, try std.fmt.allocPrint(a, "module-less: {s}", .{record.name}));
        }
    }
    if (problems.items.len == 0) {
        try addCheck(a, checks, "lint", .pass, "");
        return;
    }
    var text: std.ArrayList(u8) = .empty;
    for (problems.items, 0..) |problem, index| {
        if (index > 0) try text.appendSlice(a, "; ");
        try text.appendSlice(a, problem);
    }
    try addCheck(a, checks, "lint", .fail, text.items);
}

fn undoCheck(a: std.mem.Allocator, env: *environment.Env, checks: *std.ArrayList(Check)) environment.Error!void {
    var undo_ok = true;
    var detail: []const u8 = "";
    {
        var output: [64]u8 = undefined;
        const undo_written = env.interpreter.eval(a, undo_source, &output) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                undo_ok = false;
                detail = try loadFailureDetail(a, env, err, "undo failed");
                break :blk "";
            },
        };
        _ = undo_written;
    }
    var count: usize = 0;
    if (undo_ok) blk: {
        const written = evalListing(env.*, a, "(hen:tools/list)") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                undo_ok = false;
                detail = try a.dupe(u8, "undo listing unavailable");
                break :blk;
            },
        };
        const after = recordsFromListing(a, written) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                undo_ok = false;
                detail = try a.dupe(u8, "undo listing unavailable");
                break :blk;
            },
        };
        count = after.len;
    }
    if (count > 0) undo_ok = false;
    if (detail.len == 0) {
        detail = try std.fmt.allocPrint(a, "{d} tools after undo", .{count});
    }
    try addCheck(a, checks, "undo", if (undo_ok) Result.pass else Result.fail, detail);
}

fn loadTestFiles(
    io: std.Io,
    a: std.mem.Allocator,
    env: *environment.Env,
    gen_dir_path: []const u8,
    checks: *std.ArrayList(Check),
) RunError!void {
    const tests_path = try std.fmt.allocPrint(a, "{s}/tests", .{gen_dir_path});
    var names: std.ArrayList([]u8) = .empty;
    var tests_dir: ?std.Io.Dir = null;
    if (std.Io.Dir.cwd().openDir(io, tests_path, .{ .iterate = true })) |dir| {
        tests_dir = dir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (tests_dir) |dir| {
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const owned = try a.dupe(u8, entry.name);
            try names.append(a, owned);
        }
    }
    std.mem.sort([]u8, names.items, {}, nameLessThan);
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".scm")) continue;
        const check_name = try std.fmt.allocPrint(a, "test:tests/{s}", .{name});
        const file_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ tests_path, name });
        if (env.interpreter.load(a, file_path)) |_| {
            try addCheck(a, checks, check_name, .pass, "");
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const detail = try loadFailureDetail(a, env, err, "");
                try addCheck(a, checks, check_name, .fail, detail);
            },
        }
    }
}

fn emitReport(
    a: std.mem.Allocator,
    id: []const u8,
    parent: []const u8,
    checks: []const Check,
    capabilities: []const []const u8,
    diff: Diff,
    result: Result,
) environment.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "(gate");
    try appendField(a, &out, "generation", id);
    try appendField(a, &out, "parent", parent);
    try out.appendSlice(a, " (checks");
    for (checks) |check| {
        try out.appendSlice(a, " (check ");
        try environment.writeSchemeString(a, &out, check.name);
        try out.appendSlice(a, " ");
        try out.appendSlice(a, @tagName(check.result));
        try out.appendSlice(a, " ");
        try environment.writeSchemeString(a, &out, check.detail);
        try out.appendSlice(a, ")");
    }
    try out.appendSlice(a, ")");
    try out.appendSlice(a, " (capabilities");
    for (capabilities) |capability| {
        try out.appendSlice(a, " ");
        try environment.writeSchemeString(a, &out, capability);
    }
    try out.appendSlice(a, ")");
    try out.appendSlice(a, " (diff");
    try appendNames(a, &out, "added", diff.added);
    try appendNames(a, &out, "removed", diff.removed);
    try appendNames(a, &out, "changed", diff.changed);
    try out.appendSlice(a, ")");
    try out.appendSlice(a, " (result ");
    try out.appendSlice(a, @tagName(result));
    try out.appendSlice(a, "))");
    return out.toOwnedSlice(a);
}

fn appendField(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, value: []const u8) environment.Error!void {
    try out.appendSlice(a, " (");
    try out.appendSlice(a, label);
    try out.appendSlice(a, " ");
    try environment.writeSchemeString(a, out, value);
    try out.appendSlice(a, ")");
}

fn appendNames(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, names: []const []const u8) environment.Error!void {
    try out.appendSlice(a, " (");
    try out.appendSlice(a, label);
    for (names) |name| {
        try out.appendSlice(a, " ");
        try environment.writeSchemeString(a, out, name);
    }
    try out.appendSlice(a, ")");
}

const ManifestInfo = struct {
    parent: []const u8,
    hash: []const u8,
    capabilities: []const []const u8,
    modules: []const []const u8,
};

const empty_info = ManifestInfo{ .parent = "", .hash = "", .capabilities = &.{}, .modules = &.{} };

fn parentText(info: ?ManifestInfo) []const u8 {
    return if (info) |read| read.parent else "";
}

fn hashText(info: ?ManifestInfo) []const u8 {
    return if (info) |read| read.hash else "";
}

fn readManifestInfo(
    a: std.mem.Allocator,
    io: std.Io,
    gen_dir_path: []const u8,
) (std.mem.Allocator.Error || manifest.ReadError || std.Io.Dir.OpenError)!ManifestInfo {
    var dir = try std.Io.Dir.cwd().openDir(io, gen_dir_path, .{});
    defer dir.close(io);
    const read = try manifest.read(io, a, dir, "manifest.sexp");
    defer manifest.freeManifest(a, read);

    var capabilities: std.ArrayList([]const u8) = .empty;
    for (read.capabilities) |capability| {
        const owned = try a.dupe(u8, capability);
        try capabilities.append(a, owned);
    }
    var modules: std.ArrayList([]const u8) = .empty;
    for (read.modules) |module| {
        const owned = try a.dupe(u8, module.name.text);
        try modules.append(a, owned);
    }
    return .{
        .parent = try a.dupe(u8, read.parent orelse ""),
        .hash = try a.dupe(u8, read.hash),
        .capabilities = try capabilities.toOwnedSlice(a),
        .modules = try modules.toOwnedSlice(a),
    };
}

const Record = struct {
    name: []const u8,
    summary: []const u8,
    when: []const u8,
    description: []const u8,
    shape_text: []const u8,
};

fn textFrom(a: std.mem.Allocator, datum: environment.Datum) environment.Error![]const u8 {
    return switch (datum) {
        .string => |text| try a.dupe(u8, text),
        else => error.SchemeError,
    };
}

fn recordFromEntry(a: std.mem.Allocator, entry: environment.Datum) environment.Error!Record {
    const fields = switch (entry) {
        .list => |items| items,
        else => return error.SchemeError,
    };
    if (fields.len != 5) return error.SchemeError;
    const name = try textFrom(a, fields[0]);
    const summary = try textFrom(a, fields[1]);
    const when = try textFrom(a, fields[2]);
    const description = try textFrom(a, fields[3]);
    var shape_out: std.ArrayList(u8) = .empty;
    try emitDatum(a, &shape_out, fields[4]);
    return .{
        .name = name,
        .summary = summary,
        .when = when,
        .description = description,
        .shape_text = shape_out.items,
    };
}

fn recordsFromListing(a: std.mem.Allocator, text: []const u8) environment.Error![]const Record {
    const datum = try environment.parseDatum(a, text);
    defer environment.freeDatum(a, datum);
    const rows = switch (datum) {
        .list => |items| items,
        else => return error.SchemeError,
    };
    var records: std.ArrayList(Record) = .empty;
    for (rows) |row| {
        const record = try recordFromEntry(a, row);
        if (std.mem.startsWith(u8, record.name, hen_prefix)) continue;
        try records.append(a, record);
    }
    return records.toOwnedSlice(a);
}

fn evalListing(env: environment.Env, a: std.mem.Allocator, source: []const u8) environment.Error![]u8 {
    var capacity: usize = listing_start;
    while (true) {
        const buffer = try a.alloc(u8, capacity);
        const written = env.interpreter.eval(a, source, buffer) catch |err| switch (err) {
            error.OutputBufferTooSmall => {
                if (capacity * 2 > listing_max) return error.OutputBufferTooSmall;
                capacity *= 2;
                continue;
            },
            else => return err,
        };
        return a.dupe(u8, written);
    }
}

fn readParentRecords(
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    parent_id: []const u8,
) std.mem.Allocator.Error![]const Record {
    if (parent_id.len == 0) return &.{};
    const path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ root, parent_id, registry_file });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var records: std.ArrayList(Record) = .empty;
    var rest: []const u8 = bytes;
    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..line_end], " \t\r");
        rest = rest[if (line_end == rest.len) rest.len else line_end + 1..];
        if (line.len == 0) continue;
        const datum = environment.parseDatum(a, line) catch continue;
        const record = recordFromEntry(a, datum) catch {
            environment.freeDatum(a, datum);
            continue;
        };
        environment.freeDatum(a, datum);
        try records.append(a, record);
    }
    return records.toOwnedSlice(a);
}

fn diffRecords(
    a: std.mem.Allocator,
    candidate: []const Record,
    parent: []const Record,
) std.mem.Allocator.Error!Diff {
    var added_names: std.ArrayList([]const u8) = .empty;
    var removed_names: std.ArrayList([]const u8) = .empty;
    var changed_names: std.ArrayList([]const u8) = .empty;
    for (candidate) |record| {
        if (findRecord(parent, record.name)) |parent_record| {
            if (recordEql(record, parent_record)) continue;
            try changed_names.append(a, record.name);
        } else {
            try added_names.append(a, record.name);
        }
    }
    for (parent) |record| {
        if (findRecord(candidate, record.name) == null) {
            try removed_names.append(a, record.name);
        }
    }
    return .{
        .added = try added_names.toOwnedSlice(a),
        .removed = try removed_names.toOwnedSlice(a),
        .changed = try changed_names.toOwnedSlice(a),
    };
}

fn findRecord(records: []const Record, name: []const u8) ?Record {
    for (records) |record| {
        if (std.mem.eql(u8, record.name, name)) return record;
    }
    return null;
}

fn recordEql(a: Record, b: Record) bool {
    return std.mem.eql(u8, a.summary, b.summary) and
        std.mem.eql(u8, a.when, b.when) and
        std.mem.eql(u8, a.description, b.description) and
        std.mem.eql(u8, a.shape_text, b.shape_text);
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn registryText(a: std.mem.Allocator, records: []const Record) environment.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (records) |record| {
        try out.append(a, '(');
        try environment.writeSchemeString(a, &out, record.name);
        try out.appendSlice(a, " ");
        try environment.writeSchemeString(a, &out, record.summary);
        try out.appendSlice(a, " ");
        try environment.writeSchemeString(a, &out, record.when);
        try out.appendSlice(a, " ");
        try environment.writeSchemeString(a, &out, record.description);
        try out.appendSlice(a, " ");
        try out.appendSlice(a, record.shape_text);
        try out.appendSlice(a, ")\n");
    }
    return out.toOwnedSlice(a);
}

fn symbolBare(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '#') return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '*', '+', '-', '.', '/', ':', '<', '=', '>', '?', '_' => {},
        else => return false,
    };
    return true;
}

fn emitSymbol(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) environment.Error!void {
    if (symbolBare(text)) {
        try out.appendSlice(a, text);
        return;
    }
    try out.append(a, '|');
    for (text) |byte| switch (byte) {
        '|', '\\' => {
            try out.append(a, '\\');
            try out.append(a, byte);
        },
        else => try out.append(a, byte),
    };
    try out.append(a, '|');
}

fn emitDatum(a: std.mem.Allocator, out: *std.ArrayList(u8), datum: environment.Datum) environment.Error!void {
    switch (datum) {
        .symbol => |text| try emitSymbol(a, out, text),
        .string => |text| try environment.writeSchemeString(a, out, text),
        .integer => |value| {
            const text = try std.fmt.allocPrint(a, "{d}", .{value});
            try out.appendSlice(a, text);
        },
        .float => |value| {
            const text = try std.fmt.allocPrint(a, "{d}", .{value});
            try out.appendSlice(a, text);
        },
        .boolean => |value| try out.appendSlice(a, if (value) "#t" else "#f"),
        .list => |items| {
            try out.append(a, '(');
            for (items, 0..) |item, index| {
                if (index > 0) try out.append(a, ' ');
                try emitDatum(a, out, item);
            }
            try out.append(a, ')');
        },
    }
}

fn overall(checks: []const Check) Result {
    for (checks) |check| {
        if (check.result == .fail) return .fail;
    }
    return .pass;
}

test "emitReport writes the fixed field layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const checks = [_]Check{
        .{ .name = "smoke", .result = .pass, .detail = "" },
        .{ .name = "nice \"name\"", .result = .fail, .detail = "bad\nline" },
    };
    const text = try emitReport(a, "id-1", "parent-1", &checks, &.{"spawn"}, .{
        .added = &.{"alpha-pin"},
        .removed = &.{},
        .changed = &.{"beta-probe"},
    }, .pass);
    try std.testing.expectEqualStrings(
        "(gate (generation \"id-1\") (parent \"parent-1\") (checks (check \"smoke\" pass \"\") (check \"nice \\\"name\\\"\" fail \"bad\\nline\")) (capabilities \"spawn\") (diff (added \"alpha-pin\") (removed) (changed \"beta-probe\")) (result pass))",
        text,
    );

    const parsed = try environment.parseDatum(a, text);
    defer environment.freeDatum(a, parsed);
    try std.testing.expect(parsed == .list);
}

test "diffRecords classifies added, removed, and changed tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent = [_]Record{
        .{ .name = "alpha-pin", .summary = "s", .when = "w", .description = "d", .shape_text = "(text)" },
        .{ .name = "old-tool", .summary = "s", .when = "w", .description = "d", .shape_text = "(text)" },
    };
    const candidate = [_]Record{
        .{ .name = "alpha-pin", .summary = "new", .when = "w", .description = "d", .shape_text = "(text)" },
        .{ .name = "beta-probe", .summary = "s", .when = "w", .description = "d", .shape_text = "(shape)" },
    };
    const diff = try diffRecords(a, &candidate, &parent);
    try std.testing.expectEqual(@as(usize, 1), diff.added.len);
    try std.testing.expectEqualStrings("beta-probe", diff.added[0]);
    try std.testing.expectEqual(@as(usize, 1), diff.removed.len);
    try std.testing.expectEqualStrings("old-tool", diff.removed[0]);
    try std.testing.expectEqual(@as(usize, 1), diff.changed.len);
    try std.testing.expectEqualStrings("alpha-pin", diff.changed[0]);
}
