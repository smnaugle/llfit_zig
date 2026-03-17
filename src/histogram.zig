const std = @import("std");

// ND is hard, lets just do everything flat under the hood
pub const Histogram = struct {
    bins: [][]f64 = &.{},
    bin_volumes: []f64 = &.{},
    nentries: u64 = 0,
    contents: []f64 = &.{},
    scratch_coord: []u64 = &.{},
    scratch_point: []f64 = &.{},
    options: Options = .{},

    // FIXME: Think about how to handle zeropad
    _allocator: std.mem.Allocator = undefined,

    pub const Options = struct {
        density: bool = false,
        zero_pad: ?f64 = null,
        points_limit: usize = std.math.maxInt(usize),
    };

    pub fn init(allocator: std.mem.Allocator, bins: []const []const f64, points: []const []const f64, options: Histogram.Options) !Histogram {
        var hist: Histogram = .{};
        hist._allocator = allocator;
        hist.bins = try hist._allocator.alloc([]f64, bins.len);
        var total_bins: usize = 1;
        for (bins, 0..) |b, di| {
            // const nb_ptr = try hist._allocator.create([]f64);
            // nb_ptr.* = try hist._allocator.dupe(f64, b.*);
            hist.bins[di] = try hist._allocator.dupe(f64, b);
            total_bins *= (b.len - 1);
        }
        hist.contents = try hist._allocator.alloc(f64, total_bins);
        for (hist.contents) |*bin| {
            bin.* = 0;
        }
        hist.scratch_coord = try hist._allocator.alloc(u64, bins.len);
        hist.scratch_point = try hist._allocator.alloc(f64, bins.len);
        try hist.createBinVolumes();
        if (points.len != 0) {
            for (0..points[0].len) |idx| {
                for (0..points.len) |dim_idx| {
                    hist.scratch_point[dim_idx] = points[dim_idx][idx];
                }
                hist.addPoint(hist.scratch_point);
                if (hist.nentries > options.points_limit) break;
            }
        }
        hist.options = options;
        if (options.zero_pad) |pad| {
            hist.zeroPad(pad);
        }
        if (options.density) {
            hist.normalize();
        }
        return hist;
    }

    pub fn clone(self: Histogram, allocator: std.mem.Allocator) !Histogram {
        var copy: Histogram = try .init(allocator, self.bins, &.{}, self.options);
        @memcpy(copy.bin_volumes, self.bin_volumes);
        @memcpy(copy.contents, self.contents);
        copy.nentries = self.nentries;
        copy.options = self.options;
        const og_int = self.integral();
        if (!std.math.approxEqAbs(f64, og_int, copy.integral(), std.math.floatEpsAt(f64, og_int))) {
            std.log.err("Copy with different integral: {d} vs {d}", .{ og_int, copy.integral() });
        }
        return copy;
    }

    pub fn loadNewPoints(self: *Histogram, points: []const []const f64, options: Histogram.Options) void {
        self.nentries = 0;
        if (points.len != self.bins.len) {
            std.debug.panic("Cannot load histogram with points" ++
                " of different dimension than bins: {d}, {d}", .{ points.len, self.bins.len });
        }
        for (0..self.contents.len) |ci| self.contents[ci] = 0;
        for (0..points[0].len) |idx| {
            for (0..points.len) |dim_idx| {
                self.scratch_point[dim_idx] = points[dim_idx][idx];
            }
            self.addPoint(self.scratch_point);
            if (self.nentries > options.points_limit) break;
        }
        if (options.zero_pad) |pad| {
            self.zeroPad(pad);
        }
        if (options.density) {
            self.normalize();
        }
    }

    pub fn zeroPad(self: *Histogram, pad: f64) void {
        for (self.contents) |*b| {
            if (b.* == 0) {
                b.* = pad;
            }
        }
    }

    fn createBinVolumes(self: *Histogram) !void {
        self.bin_volumes = try self._allocator.alloc(f64, self.contents.len);
        for (0..self.contents.len) |idx| {
            self.bin_volumes[idx] = 1;
            const coord = try self.flatIndexToBin(idx);
            for (0..self.bins.len) |dim_idx| {
                const bin_low = (self.bins[dim_idx])[coord[dim_idx]];
                const bin_high = (self.bins[dim_idx])[coord[dim_idx] + 1];
                self.bin_volumes[idx] *= (bin_high - bin_low);
            }
        }
    }

    pub fn normalize(self: *Histogram) void {
        const tot: f64 = self.integral();
        for (0..self.contents.len) |idx| {
            self.contents[idx] = (self.contents[idx]) / tot;
        }
    }

    pub fn integral(self: Histogram) f64 {
        const bin_vols = self.bin_volumes;
        var sum: f64 = 0;
        for (0..bin_vols.len) |idx| {
            sum += self.contents[idx] * bin_vols[idx];
        }
        return sum;
    }

    pub fn flatIndexToBin(self: Histogram, idx: usize) ![]usize {
        if (idx > self.contents.len) {
            std.log.warn("Trying to access a bin out of the range of _flat_counts: {} and {}", .{ idx, self.contents.len });
            return error.BinOutOfRange;
        }
        for (self.bins, 0..) |b, dim_idx| {
            if (dim_idx == 0) {
                self.scratch_coord[dim_idx] = idx % (b.len - 1);
            } else {
                var bins_to_cover: usize = 1;
                for (0..dim_idx) |remaining_dim_idx| {
                    bins_to_cover *= (self.bins[remaining_dim_idx].len - 1);
                }
                self.scratch_coord[dim_idx] = @divFloor(idx, bins_to_cover) % (b.len - 1);
            }
        }
        return self.scratch_coord;
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

    fn addPoint(self: *Histogram, value: []const f64) void {
        // var bin_coordinate = try self._allocator.alloc(usize, self.bins.len);
        // defer self._allocator.free(bin_coordinate);
        var coord_counts: u64 = 0;
        for (self.bins, 0..) |b, dim_idx| {
            const bin_spacing = b[1] - b[0];
            const float_coord = (value[dim_idx] - b[0]) / bin_spacing;
            if (float_coord < 0 or float_coord >= @as(f64, @floatFromInt(b.len - 1))) {
                return;
            }
            self.scratch_coord[dim_idx] = @intFromFloat(@trunc(float_coord));
            coord_counts += 1;

            // if (dim_idx == 0) {}
            // for (0..(b.len - 1)) |bin_idx| {
            //     if (value[dim_idx] >= b[bin_idx] and value[dim_idx] < b[bin_idx + 1]) {
            //         bin_coordinate[dim_idx] = bin_idx;
            //         coord_counts += 1;
            //     }
            // }
        }
        // if (coord_counts != self.bins.len) {
        //     return;
        // }
        const index = self.coordinateToIndex(self.scratch_coord) catch |err| {
            std.log.err("{}\n", .{err});
            std.debug.panic("Cannot convert coordinate to index {any}\n", .{self.scratch_coord});
        };
        self.nentries += 1;
        self.contents[index] += 1;
    }

    pub fn deinit(self: *Histogram) void {
        for (self.bins) |*b| {
            self._allocator.free(b.*);
        }
        self._allocator.free(self.bins);
        self._allocator.free(self.bin_volumes);
        self._allocator.free(self.contents);
        self._allocator.free(self.scratch_coord);
        self._allocator.free(self.scratch_point);
    }
};
