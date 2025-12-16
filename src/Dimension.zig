const std = @import("std");
const mem = std.mem;

pub const Dimension = @This();

bins: []f64 = undefined,
bin_centers: []f64 = undefined,
name: []const u8 = "",

_allocator: mem.Allocator = undefined,

pub fn init(allocator: mem.Allocator, name: []const u8, bins: []const f64) !Dimension {
    var dim: Dimension = .{};
    dim._allocator = allocator;
    dim.name = name;
    dim.bins = try allocator.alloc(f64, bins.len);
    @memcpy(dim.bins, bins);
    dim.bin_centers = try allocator.alloc(f64, bins.len - 1);
    for (0..(bins.len - 1)) |idx| {
        dim.bin_centers[idx] = (bins[idx] + bins[idx + 1]) / 2;
    }
    return dim;
}

pub fn deinit(self: *Dimension) void {
    self._allocator.free(self.bins);
    self._allocator.free(self.bin_centers);
}
