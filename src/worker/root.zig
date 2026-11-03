const std = @import("std");
const socket = @import("socket");
const codec = socket.codec;
const msgpack = socket.msgpack;

pub const Op = enum { call, tools, shutdown };

pub const Request = struct {
    alloc: std.mem.Allocator,
    op: Op,
    name: []u8 = &.{},
    arguments: []u8 = &.{},

    pub fn deinit(self: *Request) void {
        self.alloc.free(self.name);
        self.alloc.free(self.arguments);
        self.* = undefined;
    }
};

pub const Reply = struct {
    alloc: std.mem.Allocator,
    ok: bool,
    text: []u8,

    pub fn deinit(self: *Reply) void {
        self.alloc.free(self.text);
        self.* = undefined;
    }
};

fn strKey(name: []const u8) msgpack.Payload {
    return .{ .str = msgpack.Str.init(name) };
}

fn ownedStr(alloc: std.mem.Allocator, text: []const u8) !msgpack.Payload {
    return msgpack.Payload.strToPayload(text, alloc);
}

fn writePayload(alloc: std.mem.Allocator, writer: *std.Io.Writer, payload: *msgpack.Payload) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try codec.encodeValue(&out.writer, payload.*);
    try codec.writeFrame(writer, out.written());
}

pub fn writeRequest(alloc: std.mem.Allocator, writer: *std.Io.Writer, request: Request) !void {
    const map = msgpack.Map.init(alloc);
    var payload = msgpack.Payload{ .map = map };
    defer payload.free(alloc);
    try payload.map.put(strKey("op"), try ownedStr(alloc, @tagName(request.op)));
    if (request.name.len > 0) try payload.map.put(strKey("name"), try ownedStr(alloc, request.name));
    if (request.arguments.len > 0) try payload.map.put(strKey("arguments"), try ownedStr(alloc, request.arguments));
    try writePayload(alloc, writer, &payload);
}

fn stringField(payload: msgpack.Payload, name: []const u8) !?[]const u8 {
    const value = (try payload.mapGet(name)) orelse return null;
    if (value != .str) return error.WrongType;
    return value.str.str;
}

fn parseRequest(alloc: std.mem.Allocator, bytes: []const u8) !Request {
    var reader = std.Io.Reader.fixed(bytes);
    var payload = try codec.decodeValue(alloc, &reader);
    defer payload.free(alloc);
    const op_text = (try stringField(payload, "op")) orelse return error.MissingOp;
    const op = std.meta.stringToEnum(Op, op_text) orelse return error.UnknownOp;
    const name = try alloc.dupe(u8, (try stringField(payload, "name")) orelse "");
    errdefer alloc.free(name);
    const arguments = try alloc.dupe(u8, (try stringField(payload, "arguments")) orelse "");
    return .{ .alloc = alloc, .op = op, .name = name, .arguments = arguments };
}

pub fn readRequest(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Request {
    const bytes = try codec.readFrame(alloc, reader);
    defer alloc.free(bytes);
    return parseRequest(alloc, bytes);
}

pub fn writeReply(alloc: std.mem.Allocator, writer: *std.Io.Writer, ok: bool, text: []const u8) !void {
    const map = msgpack.Map.init(alloc);
    var payload = msgpack.Payload{ .map = map };
    defer payload.free(alloc);
    try payload.map.put(strKey("ok"), .{ .bool = ok });
    try payload.map.put(strKey("text"), try ownedStr(alloc, text));
    try writePayload(alloc, writer, &payload);
}

pub fn readReply(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Reply {
    const bytes = try codec.readFrame(alloc, reader);
    defer alloc.free(bytes);
    var fixed = std.Io.Reader.fixed(bytes);
    var payload = try codec.decodeValue(alloc, &fixed);
    defer payload.free(alloc);
    const ok_value = (try payload.mapGet("ok")) orelse return error.MissingOk;
    if (ok_value != .bool) return error.WrongType;
    const text = try alloc.dupe(u8, (try stringField(payload, "text")) orelse "");
    return .{ .alloc = alloc, .ok = ok_value.bool, .text = text };
}
