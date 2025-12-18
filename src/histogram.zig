const std = @import("std");

// ND is hard, lets just do everything flat under the hood
pub const Histogram = struct {
    // Bins can be ragged
    bins: []*[]f64 = &.{},
    nentries: u64 = 0,
    contents: []f64 = &.{},

    _allocator: std.mem.Allocator = undefined,
    pub const Options = struct {
        density: bool = false,
    };
    pub fn init(allocator: std.mem.Allocator, bins: []const *[]f64, points: []const []f64, options: Histogram.Options) !Histogram {
        var hist: Histogram = .{};
        hist._allocator = allocator;
        hist.bins = try hist._allocator.alloc(*[]f64, bins.len);
        var total_bins: usize = 1;
        for (bins, 0..) |b, di| {
            const nb_ptr = try hist._allocator.create([]f64);
            nb_ptr.* = try hist._allocator.dupe(f64, b.*);
            hist.bins[di] = nb_ptr;
            total_bins *= (b.*.len - 1);
        }
        hist.contents = try hist._allocator.alloc(f64, total_bins);
        for (hist.contents) |*bin| {
            bin.* = 0;
        }
        hist.nentries = @intCast(points[0].len);
        var point = try hist._allocator.alloc(f64, points.len);
        defer hist._allocator.free(point);
        for (0..points[0].len) |idx| {
            for (0..points.len) |dim_idx| {
                point[dim_idx] = points[dim_idx][idx];
            }
            try hist.addPoint(point);
        }
        if (options.density) {
            try hist.normalize();
        }
        return hist;
    }

    pub fn getBinVolumesOwned(self: Histogram) ![]f64 {
        var bin_vols = try self._allocator.alloc(f64, self.contents.len);
        for (0..self.contents.len) |idx| {
            bin_vols[idx] = 1;
            const coord = try self.flatIndexToOwnedBin(idx);
            defer self._allocator.free(coord);
            for (0..self.bins.len) |dim_idx| {
                const bin_low = (self.bins[dim_idx]).*[coord[dim_idx]];
                const bin_high = (self.bins[dim_idx]).*[coord[dim_idx] + 1];
                bin_vols[idx] *= (bin_high - bin_low);
            }
        }
        return bin_vols;
    }

    pub fn normalize(self: *Histogram) !void {
        const bin_vols = try self.getBinVolumesOwned();
        defer self._allocator.free(bin_vols);
        for (0..bin_vols.len) |idx| {
            self.contents[idx] = (self.contents[idx] / bin_vols[idx]) / @as(f64, @floatFromInt(self.nentries));
        }
    }

    pub fn integral(self: Histogram) !f64 {
        const bin_vols = try self.getBinVolumesOwned();
        defer self._allocator.free(bin_vols);
        var sum: f64 = 0;
        for (0..bin_vols.len) |idx| {
            sum += self.contents[idx] * bin_vols[idx];
        }
        return sum;
    }

    pub fn flatIndexToOwnedBin(self: Histogram, idx: usize) ![]usize {
        if (idx > self.contents.len) {
            std.log.warn("Trying to access a bin out of the range of _flat_counts: {} and {}", .{ idx, self.contents.len });
            return error.BinOutOfRange;
        }
        var coordinate = try self._allocator.alloc(usize, self.bins.len);
        for (self.bins, 0..) |b, dim_idx| {
            if (dim_idx == 0) {
                coordinate[dim_idx] = idx % (b.len - 1);
            } else {
                var bins_to_cover: usize = 1;
                for (0..dim_idx) |remaining_dim_idx| {
                    bins_to_cover *= (self.bins[remaining_dim_idx].len - 1);
                }
                coordinate[dim_idx] = @divFloor(idx, bins_to_cover) % (b.len - 1);
            }
        }
        return coordinate;
    }

    pub fn coordinateToIndex(self: Histogram, coordinate: []const usize) !usize {
        if (coordinate.len != self.bins.len) {
            return error.MismatchedDimensions;
        }
        var idx: usize = 0;
        var preceding_bins: usize = 1;
        for (coordinate, 0..) |c, dim_idx| {
            // -2 because 0 indexing and bin edges to bins
            if (c > (self.bins[dim_idx].len - 1 - 1)) {
                return error.MismatchedDimensions;
            }
            idx += c * preceding_bins;
            preceding_bins *= (self.bins[dim_idx].len - 1);
        }
        return idx;
    }

    fn addPoint(self: *Histogram, value: []const f64) !void {
        var bin_coordinate = try self._allocator.alloc(usize, self.bins.len);
        defer self._allocator.free(bin_coordinate);
        var coord_counts: u64 = 0;
        for (self.bins, 0..) |b, dim_idx| {
            if (dim_idx == 0) {}
            for (0..(b.*.len - 1)) |bin_idx| {
                if (value[dim_idx] >= b.*[bin_idx] and value[dim_idx] < b.*[bin_idx + 1]) {
                    bin_coordinate[dim_idx] = bin_idx;
                    coord_counts += 1;
                }
            }
        }
        if (coord_counts != self.bins.len) {
            return;
        }
        const index = try self.coordinateToIndex(bin_coordinate);
        self.contents[index] += 1;
    }

    pub fn deinit(self: *Histogram) void {
        for (self.bins) |b| {
            self._allocator.free(b.*);
            self._allocator.destroy(b);
        }
        self._allocator.free(self.bins);
        self._allocator.free(self.contents);
    }
};
