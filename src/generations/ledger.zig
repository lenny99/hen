const std = @import("std");
const environment = @import("environment");

const ledger_file = "ledger.sexp";
const active_file = "active";
const active_tmp_file = ".active.tmp";
const max_file_bytes = 4 * 1024 * 1024;

pub const Status = enum { candidate, promoted, failed, discarded };

pub const Event = struct {
    id: []const u8,
    parent: []const u8,
    hash: []const u8,
    status: Status,
    evidence: []const u8,
};

pub const FileIoError = environment.Error ||
    std.Io.File.OpenError ||
    std.Io.File.StatError ||
    std.Io.File.WritePositionalError ||
    std.Io.File.Reader.Error ||
    std.Io.File.Writer.Error ||
    std.Io.Cancelable ||
    std.Io.UnexpectedError;

pub const AppendError = FileIoError;

pub const ReadError = std.mem.Allocator.Error ||
    std.Io.Dir.ReadFileAllocError ||
    error{LedgerMalformed};

pub const ActiveError = std.mem.Allocator.Error ||
    std.Io.Dir.ReadFileAllocError ||
    error{ActiveMissing};

pub const SetActiveError = std.mem.Allocator.Error ||
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.WriteFileError ||
    std.Io.Dir.RenameError ||
    AppendError ||
    error{ LedgerMalformed, GenerationMissing };

pub fn append(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    event: Event,
) AppendError!void {
    const path = try std.fmt.allocPrint(allocator, "{s}/" ++ ledger_file, .{root});
    defer allocator.free(path);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, "(");
    try appendField(allocator, &line, "generation", event.id);
    try line.appendSlice(allocator, " ");
    try appendField(allocator, &line, "parent", event.parent);
    try line.appendSlice(allocator, " ");
    try appendField(allocator, &line, "hash", event.hash);
    try line.appendSlice(allocator, " (status ");
    try line.appendSlice(allocator, @tagName(event.status));
    try line.appendSlice(allocator, ") ");
    try appendField(allocator, &line, "evidence", event.evidence);
    try line.appendSlice(allocator, ")\n");

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    try file.writePositionalAll(io, line.items, size);
}

pub fn read(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) ReadError![]Event {
    const path = try std.fmt.allocPrint(allocator, "{s}/" ++ ledger_file, .{root});
    defer allocator.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
    defer allocator.free(text);

    var events: std.ArrayList(Event) = .empty;
    errdefer freeEvents(allocator, events.items);
    var rest: []const u8 = text;
    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..line_end], " \t\r");
        rest = rest[if (line_end == rest.len) rest.len else line_end + 1..];
        if (line.len == 0) continue;
        const event = try parseEvent(allocator, line);
        try events.append(allocator, event);
    }
    return events.toOwnedSlice(allocator);
}

pub fn setActive(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
) SetActiveError!void {
    const events = try read(io, allocator, root);
    defer freeEvents(allocator, events);
    var found: ?Event = null;
    for (events) |event| {
        if (std.mem.eql(u8, event.id, id)) found = event;
    }
    const generation = found orelse return error.GenerationMissing;

    const bytes = try std.fmt.allocPrint(allocator, "{s}\n", .{id});
    defer allocator.free(bytes);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/" ++ active_tmp_file, .{root});
    defer allocator.free(tmp_path);
    const active_path = try std.fmt.allocPrint(allocator, "{s}/" ++ active_file, .{root});
    defer allocator.free(active_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = bytes });
    try cwd.rename(tmp_path, cwd, active_path, io);

    try append(io, allocator, root, .{
        .id = id,
        .parent = generation.parent,
        .hash = generation.hash,
        .status = .promoted,
        .evidence = "",
    });
}

pub fn getActive(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) ActiveError![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/" ++ active_file, .{root});
    defer allocator.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
    defer allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.ActiveMissing;
    return allocator.dupe(u8, trimmed);
}

pub fn freeEvents(allocator: std.mem.Allocator, events: []const Event) void {
    for (events) |event| freeEvent(allocator, event);
    allocator.free(events);
}

pub fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.id);
    allocator.free(event.parent);
    allocator.free(event.hash);
    allocator.free(event.evidence);
}

fn ownedString(
    allocator: std.mem.Allocator,
    owned: *std.ArrayList([]const u8),
    datum: environment.Datum,
) ReadError![]const u8 {
    const text = switch (datum) {
        .string => |text| text,
        else => return error.LedgerMalformed,
    };
    const copy = try allocator.dupe(u8, text);
    try owned.append(allocator, copy);
    return copy;
}

fn parseEvent(allocator: std.mem.Allocator, line: []const u8) ReadError!Event {
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |text| allocator.free(text);
        owned.deinit(allocator);
    }
    const datum = environment.parseDatum(allocator, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LedgerMalformed,
    };
    defer environment.freeDatum(allocator, datum);

    const fields = switch (datum) {
        .list => |items| items,
        else => return error.LedgerMalformed,
    };
    if (fields.len != 5) return error.LedgerMalformed;

    var event = Event{ .id = "", .parent = "", .hash = "", .status = .candidate, .evidence = "" };
    for (fields, 1..) |field, index| {
        const field_items = switch (field) {
            .list => |items| items,
            else => return error.LedgerMalformed,
        };
        if (field_items.len != 2) return error.LedgerMalformed;
        const field_label = switch (field_items[0]) {
            .symbol => |field_text| field_text,
            else => return error.LedgerMalformed,
        };
        switch (index) {
            1 => {
                if (!std.mem.eql(u8, field_label, "generation")) return error.LedgerMalformed;
                event.id = try ownedString(allocator, &owned, field_items[1]);
            },
            2 => {
                if (!std.mem.eql(u8, field_label, "parent")) return error.LedgerMalformed;
                event.parent = try ownedString(allocator, &owned, field_items[1]);
            },
            3 => {
                if (!std.mem.eql(u8, field_label, "hash")) return error.LedgerMalformed;
                event.hash = try ownedString(allocator, &owned, field_items[1]);
            },
            4 => {
                if (!std.mem.eql(u8, field_label, "status")) return error.LedgerMalformed;
                const status_text = switch (field_items[1]) {
                    .symbol => |status_text| status_text,
                    else => return error.LedgerMalformed,
                };
                event.status = std.meta.stringToEnum(Status, status_text) orelse return error.LedgerMalformed;
            },
            5 => {
                if (!std.mem.eql(u8, field_label, "evidence")) return error.LedgerMalformed;
                event.evidence = try ownedString(allocator, &owned, field_items[1]);
            },
            else => return error.LedgerMalformed,
        }
    }
    owned.deinit(allocator);
    return event;
}

fn appendField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
    value: []const u8,
) AppendError!void {
    try out.appendSlice(allocator, "(");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, " ");
    try environment.writeSchemeString(allocator, out, value);
    try out.appendSlice(allocator, ")");
}

test "ledger keeps events and repoints active atomically" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_path = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd_path);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    defer a.free(root);

    try append(io, a, root, .{ .id = "id-1", .parent = "", .hash = "h1", .status = .candidate, .evidence = "" });
    try append(io, a, root, .{ .id = "id-2", .parent = "id-1", .hash = "h2", .status = .promoted, .evidence = "smoke ok" });

    const events = try read(io, a, root);
    defer freeEvents(a, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("id-1", events[0].id);
    try std.testing.expectEqual(Status.candidate, events[0].status);
    try std.testing.expectEqualStrings("id-2", events[1].id);
    try std.testing.expectEqualStrings("id-1", events[1].parent);
    try std.testing.expectEqualStrings("h2", events[1].hash);
    try std.testing.expectEqual(Status.promoted, events[1].status);
    try std.testing.expectEqualStrings("smoke ok", events[1].evidence);

    try setActive(io, a, root, "id-2");
    const active = try getActive(io, a, root);
    defer a.free(active);
    try std.testing.expectEqualStrings("id-2", active);

    const after = try read(io, a, root);
    defer freeEvents(a, after);
    try std.testing.expectEqual(@as(usize, 3), after.len);
    try std.testing.expectEqual(Status.promoted, after[2].status);
    try std.testing.expectEqualStrings("id-2", after[2].id);

    try std.testing.expectError(error.GenerationMissing, setActive(io, a, root, "id-9"));
}
