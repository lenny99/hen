const std = @import("std");
const codec = @import("codec.zig");
const msgpack = @import("msgpack");

pub const version: u32 = 0;

pub const ClientFrame = union(enum) {
    hello: u32,
    new,
    ls,
    attach: []const u8,
    detach,
    snapshot,
    message: []const u8,
};

pub const ServerFrame = union(enum) {
    hello: struct { protocol: u32, session: []const u8 },
    attached: []const u8,
    sessions: []const []const u8,
    snapshot: struct { messages: []const []const u8, seq: u64 },
    event: struct { seq: u64, kind: []const u8, text: []const u8 },
    failure: struct { code: []const u8, message: []const u8 },
};

fn strKey(name: []const u8) msgpack.Payload {
    return .{ .str = msgpack.Str.init(name) };
}

fn putStr(alloc: std.mem.Allocator, payload: *msgpack.Payload, key: []const u8, value: []const u8) !void {
    try payload.map.put(strKey(key), try msgpack.Payload.strToPayload(value, alloc));
}

fn putStrArray(alloc: std.mem.Allocator, payload: *msgpack.Payload, key: []const u8, values: []const []const u8) !void {
    const items = try alloc.alloc(msgpack.Payload, values.len);
    for (values, 0..) |value, index| {
        items[index] = try msgpack.Payload.strToPayload(value, alloc);
    }
    try payload.map.put(strKey(key), .{ .arr = items });
}

fn writePayload(alloc: std.mem.Allocator, writer: *std.Io.Writer, payload: *msgpack.Payload) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try codec.encodeValue(&out.writer, payload.*);
    try codec.writeFrame(writer, out.written());
}

fn stringField(payload: msgpack.Payload, name: []const u8) !?[]const u8 {
    const value = (try payload.mapGet(name)) orelse return null;
    if (value != .str) return error.WrongType;
    return value.str.str;
}

fn uintField(payload: msgpack.Payload, name: []const u8) !?u64 {
    const value = (try payload.mapGet(name)) orelse return null;
    return switch (value) {
        .uint => |number| number,
        .int => |number| if (number >= 0) @intCast(number) else return error.WrongType,
        else => error.WrongType,
    };
}

pub fn writeClientFrame(alloc: std.mem.Allocator, writer: *std.Io.Writer, frame: ClientFrame) !void {
    const map = msgpack.Map.init(alloc);
    var payload = msgpack.Payload{ .map = map };
    defer payload.free(alloc);
    switch (frame) {
        .hello => |protocol| {
            try putStr(alloc, &payload, "type", "hello");
            try payload.map.put(strKey("protocol"), .{ .uint = protocol });
        },
        .new => try putStr(alloc, &payload, "type", "new"),
        .ls => try putStr(alloc, &payload, "type", "ls"),
        .attach => |session| {
            try putStr(alloc, &payload, "type", "attach");
            try putStr(alloc, &payload, "session", session);
        },
        .detach => try putStr(alloc, &payload, "type", "detach"),
        .snapshot => try putStr(alloc, &payload, "type", "snapshot"),
        .message => |text| {
            try putStr(alloc, &payload, "type", "message");
            try putStr(alloc, &payload, "text", text);
        },
    }
    try writePayload(alloc, writer, &payload);
}

pub fn readClientFrame(arena: std.mem.Allocator, reader: *std.Io.Reader) !ClientFrame {
    const bytes = try codec.readFrame(arena, reader);
    var fixed = std.Io.Reader.fixed(bytes);
    const payload = try codec.decodeValue(arena, &fixed);
    const kind = (try stringField(payload, "type")) orelse return error.MissingType;
    if (std.mem.eql(u8, kind, "hello")) {
        return .{ .hello = @intCast((try uintField(payload, "protocol")) orelse return error.MissingField) };
    }
    if (std.mem.eql(u8, kind, "new")) return .new;
    if (std.mem.eql(u8, kind, "ls")) return .ls;
    if (std.mem.eql(u8, kind, "attach")) {
        return .{ .attach = (try stringField(payload, "session")) orelse return error.MissingField };
    }
    if (std.mem.eql(u8, kind, "detach")) return .detach;
    if (std.mem.eql(u8, kind, "snapshot")) return .snapshot;
    if (std.mem.eql(u8, kind, "message")) {
        return .{ .message = (try stringField(payload, "text")) orelse return error.MissingField };
    }
    return error.UnknownType;
}

pub fn writeServerFrame(alloc: std.mem.Allocator, writer: *std.Io.Writer, frame: ServerFrame) !void {
    const map = msgpack.Map.init(alloc);
    var payload = msgpack.Payload{ .map = map };
    defer payload.free(alloc);
    switch (frame) {
        .hello => |hello| {
            try putStr(alloc, &payload, "type", "hello");
            try payload.map.put(strKey("protocol"), .{ .uint = hello.protocol });
            try putStr(alloc, &payload, "session", hello.session);
        },
        .attached => |session| {
            try putStr(alloc, &payload, "type", "attached");
            try putStr(alloc, &payload, "session", session);
        },
        .sessions => |ids| {
            try putStr(alloc, &payload, "type", "sessions");
            try putStrArray(alloc, &payload, "ids", ids);
        },
        .snapshot => |snapshot| {
            try putStr(alloc, &payload, "type", "snapshot");
            try putStrArray(alloc, &payload, "messages", snapshot.messages);
            try payload.map.put(strKey("seq"), .{ .uint = snapshot.seq });
        },
        .event => |event| {
            try putStr(alloc, &payload, "type", "event");
            try payload.map.put(strKey("seq"), .{ .uint = event.seq });
            try putStr(alloc, &payload, "kind", event.kind);
            try putStr(alloc, &payload, "text", event.text);
        },
        .failure => |failure| {
            try putStr(alloc, &payload, "type", "error");
            try putStr(alloc, &payload, "code", failure.code);
            try putStr(alloc, &payload, "message", failure.message);
        },
    }
    try writePayload(alloc, writer, &payload);
}

pub fn readServerFrame(arena: std.mem.Allocator, reader: *std.Io.Reader) !ServerFrame {
    const bytes = try codec.readFrame(arena, reader);
    var fixed = std.Io.Reader.fixed(bytes);
    const payload = try codec.decodeValue(arena, &fixed);
    const kind = (try stringField(payload, "type")) orelse return error.MissingType;
    if (std.mem.eql(u8, kind, "hello")) {
        return .{ .hello = .{
            .protocol = @intCast((try uintField(payload, "protocol")) orelse return error.MissingField),
            .session = (try stringField(payload, "session")) orelse "",
        } };
    }
    if (std.mem.eql(u8, kind, "attached")) {
        return .{ .attached = (try stringField(payload, "session")) orelse return error.MissingField };
    }
    if (std.mem.eql(u8, kind, "sessions")) {
        const value = (try payload.mapGet("ids")) orelse return error.MissingField;
        if (value != .arr) return error.WrongType;
        const ids = try arena.alloc([]const u8, value.arr.len);
        for (value.arr, 0..) |item, index| {
            if (item != .str) return error.WrongType;
            ids[index] = item.str.str;
        }
        return .{ .sessions = ids };
    }
    if (std.mem.eql(u8, kind, "snapshot")) {
        const value = (try payload.mapGet("messages")) orelse return error.MissingField;
        if (value != .arr) return error.WrongType;
        const messages = try arena.alloc([]const u8, value.arr.len);
        for (value.arr, 0..) |item, index| {
            if (item != .str) return error.WrongType;
            messages[index] = item.str.str;
        }
        return .{ .snapshot = .{
            .messages = messages,
            .seq = (try uintField(payload, "seq")) orelse 0,
        } };
    }
    if (std.mem.eql(u8, kind, "event")) {
        return .{ .event = .{
            .seq = (try uintField(payload, "seq")) orelse 0,
            .kind = (try stringField(payload, "kind")) orelse "",
            .text = (try stringField(payload, "text")) orelse "",
        } };
    }
    if (std.mem.eql(u8, kind, "error")) {
        return .{ .failure = .{
            .code = (try stringField(payload, "code")) orelse "",
            .message = (try stringField(payload, "message")) orelse "",
        } };
    }
    return error.UnknownType;
}
