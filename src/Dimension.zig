const std = @import("std");
const mem = std.mem;

pub const Dimension = @This();

bins: []const f64 = undefined,
bin_centers: []const f64 = undefined,
name: []const u8 = "",

_allocator: mem.Allocator = undefined,

pub fn init(allocator: mem.Allocator, name: []const u8, bins: []const f64) !Dimension {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const owned_bins = try allocator.dupe(f64, bins);
    errdefer allocator.free(owned_bins);

    var owned_bin_centers = try allocator.alloc(f64, bins.len - 1);
    errdefer allocator.free(owned_bin_centers);
    for (0..(bins.len - 1)) |idx| {
        owned_bin_centers[idx] = (bins[idx] + bins[idx + 1]) / 2;
    }

    return .{
        ._allocator = allocator,
        .name = owned_name,
        .bins = owned_bins,
        .bin_centers = owned_bin_centers,
    };
}

pub fn deinit(self: Dimension) void {
    self._allocator.free(self.name);
    self._allocator.free(self.bins);
    self._allocator.free(self.bin_centers);
}
