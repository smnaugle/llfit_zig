const std = @import("std");

pub const Histogram = struct {
    // Bins can be ragged
    bins: []*[]f64 = &.{},
    // Points should be same length in every dimension
    counts: [][]f64 = &.{},

    _allocator: std.mem.Allocator = undefined,
    pub fn init(allocator: std.mem.Allocator, bins: []const *[]f64, points: []const []f64) !Histogram {
        var hist: Histogram = .{};
        hist._allocator = allocator;
        hist.bins = try hist._allocator.alloc(*[]f64, bins.len);
        // NOTE: We create dupe bins so we can have bins be a const
        for (bins, 0..) |b, di| {
            const nb_ptr = try hist._allocator.create([]f64);
            nb_ptr.* = try hist._allocator.alloc(f64, b.*.len);
            hist.bins[di] = nb_ptr;
        }
        for (points) |p| {
            _ = p;
        }
        return hist;
        //
    }

    pub fn deinit(self: *Histogram) void {
        for (self.bins) |b| {
            self._allocator.free(b.*);
            self._allocator.destroy(b);
        }
        self._allocator.free(self.bins);
    }
};
