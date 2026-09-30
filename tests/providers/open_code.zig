const std = @import("std");
const agent = @import("agent");
const provider = @import("provider");
const http = @import("http");
const ztf = @import("zig_test_framework");

const OpencodeProvider = provider.OpencodeProvider;

test "opencode provider initializes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var transport = try http.Transport.init(io, gpa);
    defer transport.deinit();

    var opencode = try OpencodeProvider.init(gpa, &transport);
    defer opencode.deinit(gpa);
}
