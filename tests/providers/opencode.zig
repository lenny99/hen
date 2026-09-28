const std = @import("std");
const agent = @import("agent");
const provider = @import("provider");

const OpencodeProvider = provider.OpencodeProvider;

// The provider root must re-export the provider, or callers of the module
// cannot reach it.
test "the provider root exports the provider" {
    try std.testing.expect(@hasDecl(provider, "OpencodeProvider"));
}

// The session stores a `*agent.Provider`, so the constructor must return that
// exact type. The body returns `undefined` until the HTTP client lands, so the
// signature is all this can check today.
test "asProvider returns a pointer to an agent provider" {
    const info = @typeInfo(@TypeOf(OpencodeProvider.asProvider)).@"fn";
    try std.testing.expect(info.return_type == *agent.Provider);
}
