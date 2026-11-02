const std = @import("std");

pub const Address = std.Io.net.UnixAddress;
pub const Server = std.Io.net.Server;
pub const Stream = std.Io.net.Stream;

pub const default_kernel_backlog: u31 = 16;

pub const Listener = struct {
    path: []const u8,
    server: Server,

    pub fn bind(io: std.Io, path: []const u8) !Listener {
        const address = try Address.init(path);
        const server = try address.listen(io, .{ .kernel_backlog = default_kernel_backlog });
        return .{ .path = path, .server = server };
    }

    pub fn accept(self: *Listener, io: std.Io) !Stream {
        return self.server.accept(io);
    }

    pub fn close(self: *Listener, io: std.Io) void {
        self.server.deinit(io);
        self.* = undefined;
    }
};

pub fn connect(io: std.Io, path: []const u8) !Stream {
    const address = try Address.init(path);
    return address.connect(io);
}
