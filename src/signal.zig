const std = @import("std");

const syts = @import("systematics.zig");
const fit = @import("root.zig");
const Parameter = @import("Parameter.zig");
const utilities = @import("utilities.zig");

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
    buffer_bins: [][2]u32 = undefined,
    // Maybe just a slice of histogram contents now?
    probability: []f64 = &.{},

    options: Options = .{},

    output_histogram: fit.Histogram = undefined,
    original_histogram: fit.Histogram = undefined,
    histogram: fit.Histogram = undefined,

    _allocator: std.mem.Allocator = undefined,
    _scratch_points: [][]f64 = &.{},
    _last_systematics: std.ArrayList(f64) = .empty,

    first_iter: bool = true,

    pub const Options = struct {
        buffer_bins: ?[]const [2]u32 = null,
        histogram_options: fit.Histogram.Options = .{
            .zero_pad = 0.5,
            .density = true,
        },
    };

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        points: []const fit.DataPoints,
        dataset: *fit.Dataset,
        options: Options,
    ) !Signal {
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
        for (0..sig.dimensions.len) |dim_idx| {
            for (0..sig._scratch_points[dim_idx].len) |p_idx| {
                const input_points = sig.input_mc.get(sig.dimensions[dim_idx].name).?;
                sig._scratch_points[dim_idx][p_idx] = input_points[p_idx];
            }
        }

        var bins = try allocator.alloc([]const f64, sig.dimensions.len);
        defer allocator.free(bins);

        sig.options = options;
        sig.buffer_bins = try allocator.alloc([2]u32, sig.dimensions.len);
        if (sig.options.buffer_bins) |buf_bins| {
            if (buf_bins.len != sig.dimensions.len) {
                std.debug.panic("Must supply number of buffer bins for every dimension.", .{});
            }
            for (buf_bins, 0..) |bb, idx| {
                sig.buffer_bins[idx] = bb;
            }
        } else {
            for (sig.buffer_bins) |*b| {
                b.* = .{ 0, 0 };
            }
        }

        for (0..bins.len) |idx| bins[idx] = sig.dimensions[idx].bins;
        var backing_hist_bins = try allocator.alloc([]const f64, bins.len);
        defer {
            for (backing_hist_bins) |bhb| {
                allocator.free(bhb);
            }
            allocator.free(backing_hist_bins);
        }
        for (0..sig.dimensions.len) |idx| {
            const nbins = sig.dimensions[idx].bins.len;
            const low_width = sig.dimensions[idx].bins[1] - sig.dimensions[idx].bins[0];
            const high_width = sig.dimensions[idx].bins[nbins - 1] - sig.dimensions[idx].bins[nbins - 2];
            const low_bins = try utilities.linearSpacedBins(
                allocator,
                f64,
                sig.dimensions[idx].bins[0] - @as(f64, @floatFromInt(sig.buffer_bins[idx][0])) * low_width,
                sig.dimensions[idx].bins[0] - low_width,
                sig.buffer_bins[idx][0],
            );
            defer allocator.free(low_bins);
            const high_bins = try utilities.linearSpacedBins(
                allocator,
                f64,
                sig.dimensions[idx].bins[nbins - 1] + high_width,
                sig.dimensions[idx].bins[nbins - 1] + @as(f64, @floatFromInt(sig.buffer_bins[idx][1])) * high_width,
                sig.buffer_bins[idx][1],
            );
            defer allocator.free(high_bins);
            backing_hist_bins[idx] = try std.mem.concat(allocator, f64, &.{ low_bins, sig.dimensions[idx].bins, high_bins });
        }

        sig.original_histogram = try .init(allocator, backing_hist_bins, sig._scratch_points, sig.options.histogram_options);
        var backing_options = sig.options.histogram_options;
        backing_options.zero_pad = std.sort.min(f64, sig.original_histogram.contents, {}, std.sort.asc(f64)).?;
        sig.histogram = try .init(allocator, backing_hist_bins, sig._scratch_points, backing_options);
        sig.output_histogram = try .init(allocator, bins, sig._scratch_points, sig.options.histogram_options);
        sig.output_histogram.options.zero_pad = std.sort.min(f64, sig.original_histogram.contents, {}, std.sort.asc(f64)).?;
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
        self._allocator.free(self.buffer_bins);
        self.systematics.deinit(self._allocator);
        self._last_systematics.deinit(self._allocator);
        self._allocator.free(self.probability);
        self.output_histogram.deinit();
        self.original_histogram.deinit();
        self.histogram.deinit();
    }

    /// Add a systematic effect to the signal
    ///
    /// Systematics are applied in the order they are added to the signal.
    ///
    /// Currently systematics are expected to be applied to the binned signal,
    /// so they should act on the histogram member variable
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
        if (self.first_iter) {
            rerun = true;
        }
        if (rerun) {
            // Reset histogram when running systematics
            self.histogram.deinit();
            self.histogram = try self.original_histogram.clone(self._allocator);
            self.needs_binning = false;
            std.log.debug("Rerunning systematics for {s}", .{self.name});
            for (self.systematics.items) |systematic| {
                systematic.applySystematic(self);
            }
            const stride = self.histogram.bins[0].len - 1;
            const offset = @as(usize, @intCast(self.buffer_bins[0][0]));
            const keep = self.dimensions[0].bins.len - 1;

            var idx = offset;
            var kept: usize = 0;
            while (idx < self.histogram.contents.len) : (idx += stride) {
                const bin = try self.histogram.flatIndexToBin(idx);
                var in_dim = true;
                for (bin, 0..) |b, dim_idx| {
                    if (b < self.buffer_bins[dim_idx][0] or b >= (self.buffer_bins[dim_idx][0] + self.dimensions[dim_idx].bins.len - 1)) {
                        in_dim = false;
                    }
                }
                if (!in_dim) continue;
                @memcpy(self.output_histogram.contents[keep * kept .. keep * (kept + 1)], self.histogram.contents[idx..(idx + keep)]);
                kept += 1;
            }

            self.output_histogram.zeroPad(self.output_histogram.options.zero_pad.?);
            if (self.output_histogram.options.density) {
                self.output_histogram.normalize();
            }
            @memcpy(self.probability, self.output_histogram.contents);
        }

        self.first_iter = false;
        return self.probability;
    }

    pub fn format(self: @This(), writer: *std.io.Writer) !void {
        const temp_allocator = std.heap.page_allocator;
        var local_writer: std.io.Writer.Allocating = .init(temp_allocator);
        defer local_writer.deinit();
        _ = try local_writer.writer.print("{s}:\n", .{self.name});
        _ = try local_writer.writer.print("\tvalue: {d}\n", .{self.parameter.value});
        _ = try local_writer.writer.print("\tsigma: {d}\n", .{self.parameter.sigma});
        _ = try local_writer.writer.print("\texpectation: {d}\n", .{self.parameter.expectation});
        _ = try local_writer.writer.print("\tfree: {any}", .{self.parameter.free});
        _ = try writer.write(local_writer.toOwnedSlice() catch |err| {
            std.debug.panic("Could not print: {any}", .{err});
        });
    }
};
