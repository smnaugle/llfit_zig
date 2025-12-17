const std = @import("std");

const fit = @import("root.zig");

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
};

pub const Dataset = struct {
    name: []const u8 = "",
    dimensions: std.ArrayList(*fit.Dimension) = .empty,
    signals: std.ArrayList(*fit.Signal) = .empty,
    // "energy": [e1, e2, ...]
    data: std.AutoHashMap([]const u8, []f64) = undefined,

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
        self.data.deinit();
        self.* = undefined;
    }

    pub fn addDimension(self: *Dataset, name: []const u8, bins: []const f64) !*fit.Dimension {
        const dim_ptr = try self._allocator.create(fit.Dimension);
        dim_ptr.* = try .init(self._allocator, name, bins);
        try self.dimensions.append(self._allocator, dim_ptr);
        return dim_ptr;
    }

    pub fn addSignal(self: *Dataset, name: []const u8, points: []const fit.Signal.DimensionPoints) !*fit.Signal {
        const signal_ptr = try self._allocator.create(fit.Signal);
        signal_ptr.* = try .init(self._allocator, name, points);
        try self.signals.append(self._allocator, signal_ptr);
        return signal_ptr;
    }
};
