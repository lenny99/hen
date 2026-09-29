//! Streaming HTTP transport for provider requests.
//!
//! `Transport` owns one `std.http.Client` plus the environment and proxy
//! memory that the client borrows. `Request.open` sends one POST request and
//! reads the response head. `Request.body` exposes the response body as a
//! byte stream that the SSE parser can consume.

const std = @import("std");

pub const sse = @import("sse.zig");
pub const SseParser = sse.SseParser;
pub const Event = sse.Event;
pub const Kind = sse.Kind;

/// Transfer buffer size for one response body. Holds several SSE frames.
pub const transfer_buffer_len = 16 * 1024;

/// Owns the HTTP client and every allocation the client points at.
pub const Transport = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Process environment, used for the proxy variables.
    env: std.process.Environ.Map,
    /// Backing memory for the proxy records that `client` points at.
    proxies: std.heap.ArenaAllocator,
    client: std.http.Client,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) !Transport {
        var env = try environment(gpa);
        errdefer env.deinit();

        var proxies: std.heap.ArenaAllocator = .init(gpa);
        errdefer proxies.deinit();

        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        try client.initDefaultProxies(proxies.allocator(), &env);

        return .{
            .io = io,
            .gpa = gpa,
            .env = env,
            .proxies = proxies,
            .client = client,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.client.deinit();
        self.proxies.deinit();
        self.env.deinit();
    }
};

/// Copy the process environment into an owned map.
fn environment(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    const environ: [*:null]const ?[*:0]const u8 = std.c.environ;
    const slice: []const [*:0]const u8 = @ptrCast(std.mem.span(environ));
    try map.putPosixBlock(.{ .slice = slice });
    return map;
}

/// One in-flight request. Owns the connection and the body buffer.
///
/// `open` returns a pointer so that the response head and the body reader
/// keep pointing at a stable address.
pub const Request = struct {
    gpa: std.mem.Allocator,
    inner: std.http.Client.Request,
    response: std.http.Client.Response,
    /// The response body reader, borrowed from `response`.
    reader: *std.Io.Reader,
    transfer_buffer: []u8,

    pub const Options = struct {
        url: []const u8,
        headers: []const std.http.Header = &.{},
        /// Request body. Borrowed until `open` returns.
        payload: []const u8,
    };

    /// Send one POST request and read the response head.
    /// The caller owns the result and must call `deinit`.
    pub fn open(transport: *Transport, options: Options) !*Request {
        const gpa = transport.gpa;
        const uri = try std.Uri.parse(options.url);

        const self = try gpa.create(Request);
        errdefer gpa.destroy(self);

        self.inner = try transport.client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = options.headers,
        });
        errdefer self.inner.deinit();

        try self.inner.sendBodyComplete(@constCast(options.payload));
        self.response = try self.inner.receiveHead(&.{});

        self.transfer_buffer = try gpa.alloc(u8, transfer_buffer_len);
        errdefer gpa.free(self.transfer_buffer);
        self.reader = self.response.reader(self.transfer_buffer);
        self.gpa = gpa;
        return self;
    }

    pub fn status(self: *const Request) std.http.Status {
        return self.response.head.status;
    }

    /// The response body as a byte stream.
    pub fn body(self: *Request) BodyStream {
        return .{ .reader = self.reader };
    }

    pub fn deinit(self: *Request) void {
        self.inner.deinit();
        self.gpa.free(self.transfer_buffer);
        self.gpa.destroy(self);
    }
};

/// Read-only byte stream over an open response body.
pub const BodyStream = struct {
    reader: *std.Io.Reader,

    /// Fill up to `out.len` bytes. A short count means the body ended.
    pub fn read(self: *BodyStream, out: []u8) !usize {
        return self.reader.readSliceShort(out);
    }
};
