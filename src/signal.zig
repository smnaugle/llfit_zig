const std = @import("std");

const syts = @import("systematics.zig");
const fit = @import("root.zig");
const Parameter = @import("Parameter.zig");

// TODO: Implement interface for signals to support binned and KDE PDFs.
pub const Signal = struct {
    parameter: Parameter = .{},

    name: []const u8 = undefined,
    input_mc: std.StringHashMap([]f64) = undefined,
    systematics: std.ArrayList(*syts.Systematic) = .empty,
    needs_binning: bool = true,
    dimensions: []*fit.Dimension = &.{},
    dataset: *fit.Dataset = undefined,
    /// Bins to buffer in each dimension
    buffer_bins: []u32 = &.{},
    // Maybe just a slice of histogram contents now?
    probability: []f64 = &.{},
    histogram: fit.Histogram = undefined,
    buffered_histogram: fit.Histogram = undefined,

    _allocator: std.mem.Allocator = undefined,
    _scratch_points: [][]f64 = &.{},
    _last_systematics: std.ArrayList(f64) = .empty,

    first_iter: bool = true,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, points: []const fit.DataPoints, dataset: *fit.Dataset) !Signal {
        var sig = Signal{};
        sig._allocator = allocator;
        sig.dataset = dataset;
        sig.input_mc = .init(allocator);
        var dimensions: std.ArrayList(*fit.Dimension) = .empty;
        var num_bins: usize = 1;
        for (points) |p| {
            try sig.input_mc.putNoClobber(
                try sig._allocator.dupe(u8, p.dimension_name),
                try sig._allocator.dupe(f64, p.points),
            );
            try dimensions.append(sig._allocator, try dataset.getDimension(p.dimension_name));
            num_bins *= dimensions.items[dimensions.items.len - 1].bin_centers.len;
        }
        sig.dimensions = try dimensions.toOwnedSlice(allocator);
        sig.name = name;
        sig.parameter.name = name;
        sig.probability = try sig._allocator.alloc(f64, num_bins);
        sig._scratch_points = try sig._allocator.alloc([]f64, sig.dimensions.len);
        // TODO: Check if the points are all the same length and does not have zero length
        for (0..sig._scratch_points.len) |idx| {
            sig._scratch_points[idx] = try sig._allocator.alloc(f64, points[0].points.len);
        }
        for (sig.probability) |*c| {
            c.* = 0;
        }
        var bins = try allocator.alloc([]const f64, sig.dimensions.len);
        for (0..bins.len) |idx| bins[idx] = sig.dimensions[idx].bins;
        sig.histogram = try .init(allocator, bins, &.{}, .{});
        return sig;
    }

    pub fn deinit(self: *Signal) void {
        var mc_iter = self.input_mc.iterator();
        while (mc_iter.next()) |it| {
            self._allocator.free(it.key_ptr.*);
            self._allocator.free(it.value_ptr.*);
        }
        self.input_mc.deinit();
        for (self._scratch_points) |*sp| {
            self._allocator.free(sp.*);
        }
        self._allocator.free(self._scratch_points);
        self._allocator.free(self.dimensions);
        self.systematics.deinit(self._allocator);
        self._last_systematics.deinit(self._allocator);
        self._allocator.free(self.probability);
        self.histogram.deinit();
    }

    /// Add a systematic effect to the signal
    ///
    /// Systematics are applied in the order they are added to the signal.
    /// If a systematic bins the data, ie a resolution systematic, it must be
    /// added last and it __must__ bin the data and then set the `Signal.needs_binning`
    /// flag to false.
    pub fn addSystematic(self: *Signal, systematic: *syts.Systematic) !void {
        try self.systematics.append(self._allocator, systematic);
        // Here the value we are appending does not matter as long as it is different, we just need to trigger
        // applying systematics on the first iteration
        try self._last_systematics.append(self._allocator, systematic.parameter.value - 1);
    }

    pub fn getOwnedHistogram(self: Signal, points: ?[][]f64, options: fit.Histogram.Options) !fit.Histogram {
        var need_free = false;
        var hist_points: [][]f64 = undefined;
        if (points == null) {
            hist_points = try self._allocator.alloc([]f64, self.dimensions.len);
            for (0..self.dimensions.len) |dim_idx| {
                hist_points[dim_idx] = try self._allocator.dupe(f64, self.input_mc.get(self.dimensions[dim_idx].name).?);
            }
            need_free = true;
        } else {
            hist_points = points.?;
        }

        var bins: [][]f64 = try self._allocator.alloc([]f64, self.dimensions.len);
        defer self._allocator.free(bins);
        defer for (bins) |*b| {
            self._allocator.free(b.*);
        };
        for (self.dimensions, 0..) |dim, idx| {
            bins[idx] = try self._allocator.dupe(f64, dim.bins);
        }
        const hist: fit.Histogram = try .init(self._allocator, bins, hist_points, options);
        if (need_free) {
            for (hist_points) |hp| {
                self._allocator.free(hp);
            }
            self._allocator.free(hist_points);
        }
        return hist;
    }

    pub fn getProbability(self: *Signal) ![]f64 {
        var rerun: bool = false;
        for (self.systematics.items, 0..) |systematic, idx| {
            if (systematic.parameter.value != self._last_systematics.items[idx]) {
                self._last_systematics.items[idx] = systematic.parameter.value;
                rerun = true;
            }
        }
        if (self.first_iter) rerun = true;
        if (rerun) {
            self.needs_binning = true;
            std.log.debug("Rerunning systematics for {s}", .{self.name});
            for (0..self.dimensions.len) |dim_idx| {
                for (0..self._scratch_points[dim_idx].len) |p_idx| {
                    self._scratch_points[dim_idx][p_idx] = self.input_mc.get(self.dimensions[dim_idx].name).?[p_idx];
                }
            }
            for (self.systematics.items) |systematic| {
                systematic.applySystematic(self);
            }
        }
        // Need to check needs_binning here since certain systematics might
        // already rebin the points
        if (self.needs_binning) {
            self.histogram.loadNewPoints(self._scratch_points, .{ .density = true, .zero_pad = true, .points_limit = 50000 });
            for (self.histogram.contents, 0..) |content, idx| {
                self.probability[idx] = content;
            }
            self.needs_binning = false;
        }
        self.first_iter = false;
        return self.probability;
    }
};
