const std = @import("std");
const mem = std.mem;

pub const Dimension = @This();

bins: []const f64 = undefined,
bin_centers: []const f64 = undefined,
name: []const u8 = "",

_allocator: mem.Allocator = undefined,

pub fn init(allocator: mem.Allocator, name: []const u8, bins: []const f64) !Dimension {
    var dim: Dimension = .{};
    dim._allocator = allocator;
    dim.name = name;
    var temp_bins = try allocator.alloc(f64, bins.len);
    for (0..bins.len) |idx| {
        temp_bins[idx] = bins[idx];
    }
    dim.bins = temp_bins;
    var temp_bin_centers = try allocator.alloc(f64, bins.len - 1);
    for (0..(bins.len - 1)) |idx| {
        temp_bin_centers[idx] = (bins[idx] + bins[idx + 1]) / 2;
    }
    dim.bin_centers = temp_bin_centers;
    return dim;
}

pub fn deinit(self: *Dimension) void {
    self._allocator.free(self.bins);
    self._allocator.free(self.bin_centers);
}
