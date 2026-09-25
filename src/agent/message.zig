const std = @import("std");

pub const Message = struct {
    node: std.DoublyLinkedList.Node = .{},
    content: []const u8,
};
