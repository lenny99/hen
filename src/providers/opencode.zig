const std = @import("std");
const instance = @import("instance");
const http = @import("http");
const openai_impl = @import("openai.zig");

const OpenAIProvider = openai_impl.OpenAIProvider;
const Provider = instance.Provider;

const zen_endpoints: OpenAIProvider.Endpoints = .{
    .models = "https://opencode.ai/zen/go/v1/models",
    .go = "https://opencode.ai/zen/go/v1/chat/completions",
};

fn sessionHeader(alloc: std.mem.Allocator, args: Provider.SessionArgs) anyerror![]const std.http.Header {
    const session_id = try args.session.toString(alloc);
    const headers = try alloc.alloc(std.http.Header, 1);
    headers[0] = .{ .name = "x-opencode-session", .value = session_id };
    return headers;
}

pub const OpencodeProvider = struct {
    impl: *OpenAIProvider,

    pub fn init(alloc: std.mem.Allocator, transport: *http.Transport, token: *const instance.Secret) !*OpencodeProvider {
        const impl = try OpenAIProvider.init(alloc, transport, token);
        errdefer impl.deinit(alloc);
        impl.endpoints = zen_endpoints;
        impl.extra_headers = sessionHeader;
        const self = try alloc.create(OpencodeProvider);
        self.* = .{ .impl = impl };
        return self;
    }

    pub fn deinit(self: *OpencodeProvider, allocator: std.mem.Allocator) void {
        self.impl.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn stream(self: *const OpencodeProvider, args: Provider.SessionArgs) Provider.Error!Provider.DeltaStream {
        return self.impl.stream(args);
    }

    fn streamVia(impl: *anyopaque, args: Provider.SessionArgs) Provider.Error!Provider.DeltaStream {
        const self: *const OpencodeProvider = @ptrCast(@alignCast(impl));
        return self.stream(args);
    }

    pub fn asProvider(self: *const OpencodeProvider) Provider {
        return Provider.init(@constCast(self), streamVia);
    }
};
