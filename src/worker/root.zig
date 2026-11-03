const std = @import("std");
const socket = @import("socket");
const codec = socket.codec;
const msgpack = socket.msgpack;

pub const Op = enum { call, tools, shutdown };

pub const SchemeCode = struct {
    source: []const u8,
};

pub const Tool = struct {
    name: []const u8,
    summary: []const u8,
    when: []const u8,
};

pub const Request = struct {
    alloc: std.mem.Allocator,
    op: Op,
    tool: []u8 = &.{},
    scheme: []u8 = &.{},

    pub fn deinit(self: *Request) void {
        self.alloc.free(self.tool);
        self.alloc.free(self.scheme);
        self.* = undefined;
    }
};

pub const Reply = struct {
    alloc: std.mem.Allocator,
    ok: bool,
    text: []u8,
    tools: []Tool = &.{},

    pub fn deinit(self: *Reply) void {
        self.alloc.free(self.text);
        for (self.tools) |tool| {
            self.alloc.free(tool.name);
            self.alloc.free(tool.summary);
            self.alloc.free(tool.when);
        }
        self.alloc.free(self.tools);
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
    if (request.tool.len > 0) try payload.map.put(strKey("tool"), try ownedStr(alloc, request.tool));
    if (request.scheme.len > 0) try payload.map.put(strKey("scheme"), try ownedStr(alloc, request.scheme));
    try writePayload(alloc, writer, &payload);
}

fn stringField(payload: msgpack.Payload, name: []const u8) !?[]const u8 {
    const value = (try payload.mapGet(name)) orelse return null;
    if (value != .str) return error.WrongType;
    return value.str.str;
}

fn dupeField(alloc: std.mem.Allocator, payload: msgpack.Payload, name: []const u8) ![]u8 {
    return alloc.dupe(u8, (try stringField(payload, name)) orelse "");
}

fn parseRequest(alloc: std.mem.Allocator, bytes: []const u8) !Request {
    var reader = std.Io.Reader.fixed(bytes);
    const payload = try codec.decodeValue(alloc, &reader);
    defer payload.free(alloc);
    const op_text = (try stringField(payload, "op")) orelse return error.MissingOp;
    const op = std.meta.stringToEnum(Op, op_text) orelse return error.UnknownOp;
    const tool = try dupeField(alloc, payload, "tool");
    errdefer alloc.free(tool);
    const scheme = try dupeField(alloc, payload, "scheme");
    return .{ .alloc = alloc, .op = op, .tool = tool, .scheme = scheme };
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

pub fn writeToolsReply(alloc: std.mem.Allocator, writer: *std.Io.Writer, tools: []const Tool) !void {
    const map = msgpack.Map.init(alloc);
    var payload = msgpack.Payload{ .map = map };
    defer payload.free(alloc);
    try payload.map.put(strKey("ok"), .{ .bool = true });
    try payload.map.put(strKey("text"), try ownedStr(alloc, ""));

    const items = try alloc.alloc(msgpack.Payload, tools.len);
    for (tools, 0..) |tool, index| {
        const item_map = msgpack.Map.init(alloc);
        items[index] = .{ .map = item_map };
        try items[index].map.put(strKey("name"), try ownedStr(alloc, tool.name));
        try items[index].map.put(strKey("summary"), try ownedStr(alloc, tool.summary));
        try items[index].map.put(strKey("when"), try ownedStr(alloc, tool.when));
    }
    try payload.map.put(strKey("tools"), .{ .arr = items });
    try writePayload(alloc, writer, &payload);
}

pub fn readReply(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Reply {
    const bytes = try codec.readFrame(alloc, reader);
    defer alloc.free(bytes);
    var fixed = std.Io.Reader.fixed(bytes);
    const payload = try codec.decodeValue(alloc, &fixed);
    defer payload.free(alloc);

    const ok_value = (try payload.mapGet("ok")) orelse return error.MissingOk;
    if (ok_value != .bool) return error.WrongType;
    const text = try dupeField(alloc, payload, "text");

    var tools: []Tool = &.{};
    if (try payload.mapGet("tools")) |tools_value| {
        if (tools_value != .arr) return error.WrongType;
        const items = try alloc.alloc(Tool, tools_value.arr.len);
        for (tools_value.arr, 0..) |item, index| {
            if (item != .map) return error.WrongType;
            items[index] = .{
                .name = try dupeField(alloc, item, "name"),
                .summary = try dupeField(alloc, item, "summary"),
                .when = try dupeField(alloc, item, "when"),
            };
        }
        tools = items;
    }
    return .{ .alloc = alloc, .ok = ok_value.bool, .text = text, .tools = tools };
}
