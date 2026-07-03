const std = @import("std");

pub fn zeroArray(array: []f64) void {
    for (array) |*elem| {
        elem.* = 0;
    }
}

pub fn linearSpacedBins(allocator: std.mem.Allocator, comptime T: type, start: T, stop: T, nbins: usize) ![]T {
    switch (@typeInfo(T)) {
        .float => {},
        inline else => @compileError("Cannot create bins from non-float inputs"),
    }
    if (nbins == 0) return &.{};
    if (nbins == 1) {
        const bins = try allocator.alloc(T, 1);
        bins[0] = start;
        return bins;
    }
    var bins = try allocator.alloc(T, nbins);
    const step = (stop - start) / @as(T, @floatFromInt(nbins - 1));
    for (0..nbins) |idx| {
        bins[idx] = start + @as(f64, @floatFromInt(idx)) * step;
    }
    return bins;
}
