const std = @import("std");

const fit = @import("root.zig");
const utilities = @import("utilities.zig");

/// Returns the __negative__ log-likelihood value of a Gaussian penalty term
fn penalty(value: f64, mean: f64, sigma: f64) f64 {
    return 0.5 * std.math.pow(f64, (value - mean) / sigma, 2);
}

pub const Fit = struct {
    name: []const u8 = "",
    datasets: std.ArrayList(*Dataset) = .empty,
    systematics: std.ArrayList(*fit.Systematic) = .empty,

    _allocator: std.mem.Allocator = undefined,
    pub fn init(allocator: std.mem.Allocator, name: []const u8) Fit {
        var init_fit = Fit{};
        init_fit.name = name;
        init_fit._allocator = allocator;
        return init_fit;
    }

    pub fn addDataset(self: *Fit, name: []const u8) !*Dataset {
        const dataset_ptr = try self._allocator.create(Dataset);
        dataset_ptr.* = try Dataset.init(self._allocator, name);
        // const dataset: Dataset = try .init(self._allocator, name);
        try self.datasets.append(self._allocator, dataset_ptr);
        return self.datasets.items[self.datasets.items.len - 1];
    }

    pub fn addSystematic(self: *Fit, options: fit.Systematic.SystematicOptions) !*fit.Systematic {
        const systematic_ptr = try self._allocator.create(fit.Systematic);
        systematic_ptr.* = .init(options);
        try self.systematics.append(self._allocator, systematic_ptr);
        return systematic_ptr;
    }

    pub fn deinit(self: *Fit) void {
        for (self.datasets.items) |dataset| {
            dataset.*.deinit();
            self._allocator.destroy(dataset);
        }
        self.datasets.deinit(self._allocator);
        for (self.systematics.items) |systematic| {
            systematic.deinit();
            self._allocator.destroy(systematic);
        }
        self.systematics.deinit(self._allocator);
        self.* = undefined;
    }

    pub fn getNLL(self: Fit) f64 {
        var results: f64 = 0;
        for (self.systematics.items) |systematic| {
            results += penalty(systematic.value, systematic.expectation, systematic.sigma);
        }
        for (self.datasets.items) |dataset| {
            results += dataset.getNLL();
        }
        return results;
    }
};

pub const Dataset = struct {
    name: []const u8 = "",
    dimensions: std.ArrayList(*fit.Dimension) = .empty,
    signals: std.ArrayList(*fit.Signal) = .empty,
    // "energy": [e1, e2, ...]
    data: fit.DataPoints = undefined,
    data_counts: []f64 = &.{},
    binned_data: []f64 = &.{},
    _total_pdf_scratch: []f64 = &.{},

    _allocator: std.mem.Allocator = undefined,
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Dataset {
        var dataset = Dataset{};
        dataset.name = name;
        dataset._allocator = allocator;
        dataset.data = .init(allocator);
        return dataset;
    }

    pub fn deinit(self: *Dataset) void {
        for (self.dimensions.items) |dimension| {
            dimension.*.deinit();
            self._allocator.destroy(dimension);
        }
        self.dimensions.deinit(self._allocator);
        for (self.signals.items) |signal| {
            signal.deinit();
            self._allocator.destroy(signal);
        }
        self.signals.deinit(self._allocator);
        var iter = self.data.valueIterator();
        while (iter.next()) |val| {
            self._allocator.free(val.*);
        }
        self._allocator.free(self.data_counts);
        self._allocator.free(self._total_pdf_scratch);
        self.data.deinit();
        self.* = undefined;
    }

    pub fn addData(self: *Dataset, data: []const fit.DimensionPoints) !void {
        var bins = try self._allocator.alloc([]const f64, data.len);
        defer self._allocator.free(bins);
        var points = try self._allocator.alloc([]const f64, data.len);
        defer self._allocator.free(points);
        for (data, 0..) |p, idx| {
            try self.data.putNoClobber(p.dimension.name, try self._allocator.dupe(f64, p.points));
            bins[idx] = p.dimension.bins;
            points[idx] = p.points;
        }
        var hist = try fit.Histogram.init(self._allocator, bins, points, .{ .density = false });
        defer hist.deinit();
        self.data_counts = try self._allocator.dupe(f64, hist.contents);
        self._total_pdf_scratch = try self._allocator.alloc(f64, self.data_counts.len);
    }

    pub fn addDimension(self: *Dataset, name: []const u8, bins: []const f64) !*fit.Dimension {
        const dim_ptr = try self._allocator.create(fit.Dimension);
        dim_ptr.* = try .init(self._allocator, name, bins);
        try self.dimensions.append(self._allocator, dim_ptr);
        return dim_ptr;
    }

    pub fn addSignal(self: *Dataset, name: []const u8, points: []const fit.DimensionPoints) !*fit.Signal {
        const signal_ptr = try self._allocator.create(fit.Signal);
        signal_ptr.* = try .init(self._allocator, name, points);
        try self.signals.append(self._allocator, signal_ptr);
        return signal_ptr;
    }

    fn getNLL(self: Dataset) f64 {
        utilities.zero_array(self._total_pdf_scratch);
        var expected_events: f64 = 0;
        var penalty_total: f64 = 0;
        for (self.signals.items) |signal| {
            expected_events += signal.value;
            const probabilities = signal.getProbability() catch |err| {
                std.debug.panic("Cannot calculate probabilities for {}, recieved {}", .{ signal, err });
            };
            for (probabilities, 0..) |prob, idx| {
                self._total_pdf_scratch[idx] += signal.value * prob;
            }
            penalty_total += penalty(signal.value, signal.expectation, signal.sigma);
        }
        var total: f64 = 0;
        for (self._total_pdf_scratch, 0..) |val, idx| {
            if (self.data_counts[idx] == 0) {
                continue;
            }
            total += self.data_counts[idx] * std.math.log(f64, std.math.e, val);
        }
        const nll = -expected_events + total + penalty_total;
        return nll;
    }
};
