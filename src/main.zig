//! A minimal terminal chat loop for exercising the instance core end to end.
//!
//! One line per turn; the assistant reply is printed after each turn. The loop
//! ends at EOF or on the line `exit`. The provider token comes from
//! OPENCODE_API_KEY.

const std = @import("std");
const uuid = @import("uuid");

const instance = @import("instance");
const http = @import("http");
const provider = @import("provider");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const token_value = init.environ_map.get("OPENCODE_API_KEY") orelse {
        std.debug.print("hen: set OPENCODE_API_KEY to an opencode token\n", .{});
        return error.MissingToken;
    };
    const token = instance.Secret{ .name = "opencode", .value = token_value };

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    const client = try provider.OpencodeProvider.init(gpa, &transport, &token);
    defer client.deinit(gpa);

    var backend = client.asProvider();

    const generator = uuid.Generator.init(gpa, io);
    const id = try generator.v4();
    var session = try instance.Session.init(id, &backend);
    defer session.deinit(gpa);

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

        if (session.messages.items.len > before) {
            switch (session.messages.items[session.messages.items.len - 1]) {
                .assistant => |assistant| try writer.print("{s}\n", .{assistant.content}),
                .tool => {},
                .user => {},
            }
            try writer.flush();
        }
    }
}
