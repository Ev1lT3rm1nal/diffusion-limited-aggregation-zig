const std = @import("std");
const root = @import("root.zig");
const Gif = root.GifDLA;
const DLA = root.DLA;

pub fn main() !void {
    try Gif.create(std.heap.c_allocator, @ptrCast("test.gif"), 200, 200, 1000);
}
