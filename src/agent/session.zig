const std = @import("std");
const uuid = @import("uuid");
const Provider = @import("provider.zig").Provider;

pub const Session = struct {
    pub const Id = uuid.UUID;
    //
    allocator: std.heap.PageAllocator,
    //
    id: Id,
    provider: Provider,
    messages: std.DoublyLinkedList,
};
