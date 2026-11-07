const std = @import("std");
const vaxis = @import("vaxis");
const socket = @import("socket");
const protocol = socket.protocol;

pub const Connection = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: socket.Stream,
    read_buffer: []u8,
    write_buffer: []u8,
    reader: socket.Stream.Reader,
    writer: socket.Stream.Writer,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, stream: socket.Stream) !Connection {
        errdefer stream.close(io);
        const read_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(read_buffer);
        const write_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(write_buffer);

        return .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .reader = stream.reader(io, read_buffer),
            .writer = stream.writer(io, write_buffer),
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.gpa.free(self.read_buffer);
        self.gpa.free(self.write_buffer);
        self.* = undefined;
    }

    pub fn write(self: *Connection, frame: protocol.ClientFrame) !void {
        try protocol.writeClientFrame(self.gpa, &self.writer.interface, frame);
    }

    pub fn read(self: *Connection, arena: std.mem.Allocator) !protocol.ServerFrame {
        return protocol.readServerFrame(arena, &self.reader.interface);
    }
};

const MessageKind = enum {
    snapshot,
    user,
    assistant,
    tool,
    system,
    failure,
};

const Message = struct {
    kind: MessageKind,
    text: []u8,
};

const ServerKind = enum {
    assistant,
    tool,
    user,
    turn_finished,
    failure,
};

const ServerEvent = struct {
    kind: ServerKind,
    text: []u8,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    server: ServerEvent,
    disconnected: []const u8,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    connection: *Connection,
    session_id: protocol.SessionId,
    messages: std.ArrayList(Message) = .empty,
    input: vaxis.widgets.TextInput,
    scroll: usize = 0,
    busy: bool = false,
    connected: bool = true,
    quit: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        connection: *Connection,
        session_id: protocol.SessionId,
        snapshot: []const []const u8,
    ) !App {
        var app = App{
            .gpa = gpa,
            .connection = connection,
            .session_id = session_id,
            .input = vaxis.widgets.TextInput.init(gpa),
        };
        errdefer app.deinit();
        for (snapshot) |text| try app.appendMessage(.snapshot, text);
        return app;
    }

    pub fn deinit(self: *App) void {
        for (self.messages.items) |message| self.gpa.free(message.text);
        self.messages.deinit(self.gpa);
        self.input.deinit();
    }

    fn appendMessage(self: *App, kind: MessageKind, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        try self.messages.append(self.gpa, .{ .kind = kind, .text = copy });
        self.scroll = scrollAfterAppend(self.scroll);
    }

    fn appendFailure(self: *App, code: []const u8, message: []const u8) !void {
        const text = try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ code, message });
        defer self.gpa.free(text);
        try self.appendMessage(.failure, text);
    }

    fn submit(self: *App) !void {
        if (!self.connected or self.busy) return;
        const owned = try self.input.toOwnedSlice();
        defer self.gpa.free(owned);
        const text = std.mem.trim(u8, owned, " \t\r\n");
        if (text.len == 0) return;
        try self.appendMessage(.user, text);
        self.scroll = 0;
        try self.connection.write(.{ .message = text });
        self.busy = true;
    }

    fn handleServer(self: *App, event: ServerEvent) !void {
        defer self.gpa.free(event.text);
        switch (event.kind) {
            .turn_finished => self.busy = false,
            .failure => {
                try self.appendMessage(.failure, event.text);
                self.busy = false;
            },
            else => if (event.text.len > 0) try self.appendMessage(messageKind(event.kind), event.text),
        }
    }

    fn handleDisconnected(self: *App, name: []const u8) !void {
        try self.appendFailure("connection", name);
        self.busy = false;
        self.connected = false;
    }

    fn draw(self: *App, win: vaxis.Window) void {
        win.clear();
        self.drawHeader(win.child(.{ .height = 1 }));
        self.drawTranscript(win.child(.{
            .y_off = 1,
            .height = win.height -| 3,
        }));
        self.drawInput(win);
        self.drawStatus(win.child(.{
            .y_off = win.height -| 1,
            .height = 1,
        }));
    }

    fn drawHeader(self: *App, win: vaxis.Window) void {
        _ = win.print(&.{
            .{ .text = " hen ", .style = .{ .bold = true, .reverse = true } },
            .{ .text = " " },
            .{ .text = self.session_id[0..], .style = .{ .dim = true } },
        }, .{ .wrap = .none });
    }

    fn drawTranscript(self: *App, win: vaxis.Window) void {
        if (self.messages.items.len == 0) {
            _ = win.print(&.{
                .{ .text = "No messages yet.", .style = .{ .dim = true } },
            }, .{ .wrap = .none });
            return;
        }

        const end = self.messages.items.len -| self.scroll;
        if (end == 0) return;

        var start = end;
        var used: u16 = 0;
        while (start > 0) {
            const rows = messageRows(win, self.messages.items[start - 1]);
            if (used +| rows > win.height) break;
            used +|= rows;
            start -= 1;
        }
        if (start == end) start = end - 1;

        var row: u16 = 0;
        for (self.messages.items[start..end]) |message| {
            if (row >= win.height) break;
            row = drawMessage(win, message, row).row;
        }
    }

    fn drawInput(self: *App, win: vaxis.Window) void {
        const row = win.height -| 2;
        const prompt = win.child(.{ .y_off = row, .height = 1 });
        _ = prompt.print(&.{
            .{ .text = "> ", .style = .{ .fg = .{ .index = 6 }, .bold = true } },
        }, .{ .wrap = .none });
        self.input.draw(win.child(.{
            .x_off = 2,
            .y_off = row,
            .width = win.width -| 2,
            .height = 1,
        }));
    }

    fn drawStatus(self: *App, win: vaxis.Window) void {
        const text = if (!self.connected)
            "disconnected | ctrl+c quit"
        else if (self.busy)
            "working..."
        else
            "enter send | pgup/pgdn scroll | ctrl+c quit";
        _ = win.print(&.{
            .{ .text = text, .style = .{ .dim = true } },
        }, .{ .wrap = .none });
    }
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    connection: *Connection,
    session_id: protocol.SessionId,
    snapshot: []const []const u8,
) !void {
    var app = try App.init(gpa, connection, session_id, snapshot);
    defer app.deinit();

    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    errdefer loop.stop();

    try vx.enterAltScreen(writer);
    defer vx.exitAltScreen(writer) catch {};

    try writer.flush();
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    const reader_thread = try std.Thread.spawn(.{}, readerMain, .{ connection, &loop, gpa });
    defer {
        connection.write(.detach) catch {};
        connection.stream.shutdown(io, .both) catch {};
        loop.stop();
        reader_thread.join();
    }

    while (!app.quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) {
                    app.quit = true;
                    continue;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    app.submit() catch |err| try app.appendFailure("send", @errorName(err));
                } else if (key.matches(vaxis.Key.page_up, .{})) {
                    app.scroll = @min(app.scroll +| 5, app.messages.items.len -| 1);
                } else if (key.matches(vaxis.Key.page_down, .{})) {
                    app.scroll -|= 5;
                } else if (key.matches(vaxis.Key.up, .{})) {
                    app.scroll = @min(app.scroll +| 1, app.messages.items.len -| 1);
                } else if (key.matches(vaxis.Key.down, .{})) {
                    app.scroll -|= 1;
                } else {
                    try app.input.update(.{ .key_press = key });
                }
            },
            .winsize => |winsize| try vx.resize(gpa, tty.writer(), winsize),
            .server => |server| app.handleServer(server) catch |err| try app.appendFailure("event", @errorName(err)),
            .disconnected => |name| app.handleDisconnected(name) catch |err| try app.appendFailure("event", @errorName(err)),
        }

        app.draw(vx.window());
        try vx.render(writer);
        try writer.flush();
    }
}

fn readerMain(connection: *Connection, loop: *vaxis.Loop(Event), gpa: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const frame = connection.read(arena.allocator()) catch |err| {
            loop.postEvent(.{ .disconnected = @errorName(err) }) catch {};
            return;
        };

        switch (frame) {
            .event => |event| {
                const text = gpa.dupe(u8, event.text) catch {
                    loop.postEvent(.{ .disconnected = "OutOfMemory" }) catch {};
                    return;
                };
                loop.postEvent(.{ .server = .{
                    .kind = serverKind(event.kind),
                    .text = text,
                } }) catch {
                    gpa.free(text);
                    return;
                };
            },
            .failure => |failure| {
                const text = std.fmt.allocPrint(gpa, "{s}: {s}", .{ failure.code, failure.message }) catch {
                    loop.postEvent(.{ .disconnected = "OutOfMemory" }) catch {};
                    return;
                };
                loop.postEvent(.{ .server = .{
                    .kind = .failure,
                    .text = text,
                } }) catch {
                    gpa.free(text);
                    return;
                };
            },
            else => {},
        }
    }
}

fn serverKind(kind: protocol.EventKind) ServerKind {
    return switch (kind) {
        .assistant => .assistant,
        .tool => .tool,
        .user => .user,
        .turn_finished => .turn_finished,
    };
}

fn messageKind(kind: ServerKind) MessageKind {
    return switch (kind) {
        .assistant => .assistant,
        .tool => .tool,
        .user => .user,
        .turn_finished => .system,
        .failure => .failure,
    };
}

fn messageSegments(message: Message) [3]vaxis.Cell.Segment {
    return .{
        .{ .text = prefixFor(message.kind), .style = prefixStyleFor(message.kind) },
        .{ .text = message.text, .style = styleFor(message.kind) },
        .{ .text = "\n", .style = styleFor(message.kind) },
    };
}

fn messageRows(win: vaxis.Window, message: Message) u16 {
    const segments = messageSegments(message);
    const result = win.print(&segments, .{
        .wrap = .word,
        .commit = false,
    });
    return @max(result.row, 1);
}

fn drawMessage(win: vaxis.Window, message: Message, row: u16) vaxis.Window.PrintResult {
    const segments = messageSegments(message);
    return win.print(&segments, .{
        .row_offset = row,
        .wrap = .word,
    });
}

fn prefixFor(kind: MessageKind) []const u8 {
    return switch (kind) {
        .snapshot => "",
        .user => "you  ",
        .assistant => "hen  ",
        .tool => "tool  ",
        .system => "system  ",
        .failure => "error  ",
    };
}

fn styleFor(kind: MessageKind) vaxis.Style {
    return switch (kind) {
        .snapshot => .{ .dim = true },
        .user => .{ .fg = .{ .index = 6 } },
        .assistant => .{},
        .tool => .{ .fg = .{ .index = 3 }, .dim = true },
        .system => .{ .dim = true },
        .failure => .{ .fg = .{ .index = 1 }, .bold = true },
    };
}

fn prefixStyleFor(kind: MessageKind) vaxis.Style {
    return switch (kind) {
        .snapshot => .{ .dim = true },
        .user => .{ .fg = .{ .index = 6 }, .bold = true },
        .assistant => .{ .bold = true },
        .tool => .{ .fg = .{ .index = 3 }, .bold = true },
        .system => .{ .dim = true },
        .failure => .{ .fg = .{ .index = 1 }, .bold = true },
    };
}

fn scrollAfterAppend(scroll: usize) usize {
    return if (scroll > 0) scroll + 1 else 0;
}

const testing = std.testing;

test "server events map to message kinds" {
    try testing.expectEqual(MessageKind.assistant, messageKind(.assistant));
    try testing.expectEqual(MessageKind.tool, messageKind(.tool));
    try testing.expectEqual(MessageKind.user, messageKind(.user));
    try testing.expectEqual(MessageKind.system, messageKind(.turn_finished));
    try testing.expectEqual(MessageKind.failure, messageKind(.failure));
}

test "protocol events map to server kinds" {
    try testing.expectEqual(ServerKind.assistant, serverKind(.assistant));
    try testing.expectEqual(ServerKind.tool, serverKind(.tool));
    try testing.expectEqual(ServerKind.user, serverKind(.user));
    try testing.expectEqual(ServerKind.turn_finished, serverKind(.turn_finished));
}

test "scroll follows only when already at the bottom" {
    try testing.expectEqual(@as(usize, 0), scrollAfterAppend(0));
    try testing.expectEqual(@as(usize, 4), scrollAfterAppend(3));
}
