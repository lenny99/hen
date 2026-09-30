//! SSE (text/event-stream) frame parser.
//!
//! Own implementation per the plan decision; no library dependency.
//!
//! Grammar: `name: value` lines; an empty line ends one event. Line
//! endings may be `"\n"`, `"\r\n"`, or a bare `"\r"` followed by
//! content. A chunk may split a line or an event; `feed` buffers
//! partial input until the line terminator arrives.
//!
//! Field dispatch: `data` collects the payload lines; `event` names the
//! frame and may decide the `Kind`; every other field is kept as a
//! compact `name value\n` record in `extra`. Comments (lines starting
//! with ':') are dropped. The optional single space after ':' in a
//! field value is dropped per the spec.

const std = @import("std");

pub const Kind = enum {
    /// A normal frame with data.
    reply,
    /// The provider signalled the end of the stream (`data: [DONE]` or
    /// an `event: done`/`event: end` frame).
    done,
    /// The frame carries an error object.
    error_reply,
};

pub const Event = struct {
    kind: Kind,
    /// The event's data payload with '\n' after each data line. Empty
    /// when the frame carries no data lines. Freed by the caller with
    /// the transport allocator.
    data: []u8,
    /// Extra frame fields as `name value\n` lines. Freed by the caller
    /// with the transport allocator.
    extra: []u8,
};

pub const SseParser = struct {
    /// Stream bytes waiting for their line terminator.
    line_buf: std.ArrayList(u8) = .empty,

    /// Current frame under construction.
    data: std.ArrayList(u8) = .empty,
    extra: std.ArrayList(u8) = .empty,
    kind: Kind = .reply,
    /// "error" occurrences in the current frame's data values.
    error_marker_count: usize = 0,

    /// Complete events not yet taken.
    events: std.ArrayList(Event) = .empty,

    pub const Error = error{OutOfMemory};

    const Self = @This();

    pub const init: Self = .{};

    pub fn deinit(self: *SseParser, alloc: std.mem.Allocator) void {
        for (self.events.items) |e| {
            alloc.free(e.data);
            alloc.free(e.extra);
        }
        self.events.deinit(alloc);
        self.line_buf.deinit(alloc);
        self.data.deinit(alloc);
        self.extra.deinit(alloc);
    }

    /// Accept stream bytes of any length; chunks may split lines and
    /// frames. Processed lines drop out of `line_buf` after the pass,
    /// so a long stream never grows it.
    pub fn feed(self: *SseParser, alloc: std.mem.Allocator, bytes: []const u8) Error!void {
        try self.line_buf.appendSlice(alloc, bytes);
        var idx: usize = 0;
        while (idx < self.line_buf.items.len) {
            // Line terminators: "\n", "\r\n", or a bare "\r".
            const term = std.mem.indexOfAnyPos(u8, self.line_buf.items, idx, "\r\n") orelse break;
            var skip: usize = 1;
            if (self.line_buf.items[term] == '\r' and
                term + 1 < self.line_buf.items.len and self.line_buf.items[term + 1] == '\n')
            {
                skip = 2;
            }
            try self.parseLine(alloc, self.line_buf.items[idx..term]);
            idx = term + skip;
        }
        const keep = self.line_buf.items.len - idx;
        if (idx > 0) {
            std.mem.copyForwards(u8, self.line_buf.items[0..keep], self.line_buf.items[idx..]);
            self.line_buf.shrinkRetainingCapacity(keep);
        }
    }

    fn parseLine(self: *SseParser, alloc: std.mem.Allocator, line: []const u8) Error!void {
        if (line.len == 0) return self.finishFrame(alloc);
        if (line[0] == ':') return; // comment per the SSE grammar

        const colon = std.mem.indexOfScalar(u8, line, ':');
        var name: []const u8 = line;
        var value: []const u8 = "";
        if (colon) |c| {
            name = line[0..c];
            value = line[c + 1 ..];
            // Drop the optional space after ':' per the spec.
            if (value.len > 0 and value[0] == ' ') value = value[1..];
        }

        if (std.mem.eql(u8, name, "data")) {
            if (std.mem.eql(u8, value, "[DONE]")) {
                self.kind = .done;
            } else if (std.mem.indexOf(u8, value, "\"error\"") != null) {
                self.error_marker_count += 1;
            }
            try self.data.appendSlice(alloc, value);
            try self.data.append(alloc, '\n');
        } else if (std.mem.eql(u8, name, "event")) {
            if (std.mem.eql(u8, value, "error") or std.mem.eql(u8, value, "exception")) {
                self.kind = .error_reply;
            } else if (std.mem.eql(u8, value, "done") or std.mem.eql(u8, value, "end") or
                std.mem.eql(u8, value, "stop"))
            {
                if (self.kind != .error_reply and self.kind != .done) self.kind = .done;
            } else {
                try self.noteField(alloc, name, value);
            }
        } else {
            try self.noteField(alloc, name, value);
        }
    }

    /// Record a field that is not part of the data/event dispatch.
    fn noteField(self: *SseParser, alloc: std.mem.Allocator, name: []const u8, value: []const u8) Error!void {
        try self.extra.appendSlice(alloc, name);
        try self.extra.append(alloc, ' ');
        try self.extra.appendSlice(alloc, value);
        try self.extra.append(alloc, '\n');
    }

    /// Flush the pending frame, if any, into the event queue.
    fn finishFrame(self: *SseParser, alloc: std.mem.Allocator) Error!void {
        defer self.resetFrame();
        // A blank line after a flushed frame emits nothing.
        const has_data = self.data.items.len > 0;
        const has_extra = self.extra.items.len > 0;
        if (!has_data and !has_extra) return;

        if (self.error_marker_count > 0 and has_data) {
            self.kind = .error_reply;
        }
        const data = try self.data.toOwnedSlice(alloc);
        const extra = try self.extra.toOwnedSlice(alloc);
        try self.events.append(alloc, .{
            .kind = self.kind,
            .data = data,
            .extra = extra,
        });
    }

    fn resetFrame(self: *SseParser) void {
        self.data.clearRetainingCapacity();
        self.extra.clearRetainingCapacity();
        self.kind = .reply;
        self.error_marker_count = 0;
    }

    /// Pop one complete event, or null when the parser needs more input.
    pub fn take(self: *SseParser) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }
};

test "frames" {
    const alloc = std.testing.allocator;
    var parser: SseParser = .{};
    defer parser.deinit(alloc);

    try parser.feed(alloc, "event: reply\ndata: {\"");
    try parser.feed(alloc, "chunk\": 1}\n\n");
    try parser.feed(alloc, "data: [DONE]\n\n");

    {
        const event = parser.take() orelse return error.TestUnexpectedResult;
        defer alloc.free(event.data);
        defer alloc.free(event.extra);
        try std.testing.expectEqual(Kind.reply, event.kind);
        try std.testing.expectEqualStrings("{\"chunk\": 1}\n", event.data);
        try std.testing.expectEqualStrings("event reply\n", event.extra);
    }
    {
        const event = parser.take() orelse return error.TestUnexpectedResult;
        defer alloc.free(event.data);
        defer alloc.free(event.extra);
        try std.testing.expectEqual(Kind.done, event.kind);
        try std.testing.expectEqualStrings("[DONE]\n", event.data);
    }

    try std.testing.expectEqual(@as(?Event, null), parser.take());
    try std.testing.expectEqual(@as(usize, 0), parser.line_buf.items.len);
}

test "carriage returns" {
    const alloc = std.testing.allocator;
    var parser: SseParser = .{};
    defer parser.deinit(alloc);

    try parser.feed(alloc, "data: a\r\ndata: b\r\n\r\n");
    const event = parser.take() orelse return error.TestUnexpectedResult;
    defer alloc.free(event.data);
    defer alloc.free(event.extra);
    try std.testing.expectEqual(Kind.reply, event.kind);
    try std.testing.expectEqualStrings("a\nb\n", event.data);
    try std.testing.expectEqual(@as(usize, 0), event.extra.len);
}

test "naked carriage returns" {
    const alloc = std.testing.allocator;
    var parser: SseParser = .{};
    defer parser.deinit(alloc);

    try parser.feed(alloc, "data: a\rdata: b\r\r");
    const event = parser.take() orelse return error.TestUnexpectedResult;
    defer alloc.free(event.data);
    defer alloc.free(event.extra);
    try std.testing.expectEqual(Kind.reply, event.kind);
    try std.testing.expectEqualStrings("a\nb\n", event.data);
    try std.testing.expectEqual(@as(usize, 0), parser.line_buf.items.len);
}

test "error event" {
    const alloc = std.testing.allocator;
    var parser: SseParser = .{};
    defer parser.deinit(alloc);

    try parser.feed(alloc, "event: error\ndata: {\"message\": \"x\"}\n\n");
    const event = parser.take() orelse return error.TestUnexpectedResult;
    defer alloc.free(event.data);
    defer alloc.free(event.extra);
    try std.testing.expectEqual(Kind.error_reply, event.kind);
    try std.testing.expectEqualStrings("{\"message\": \"x\"}\n", event.data);
    try std.testing.expectEqual(@as(usize, 0), event.extra.len);
}
