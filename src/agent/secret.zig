/// A named credential that a provider sends with each request.
pub const Secret = struct {
    name: []const u8,
    value: []const u8,
};
