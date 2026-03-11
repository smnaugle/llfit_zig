const std = @import("std");

const fit = @import("root.zig");
const utilities = @import("utilities.zig");
const min = @import("minimization.zig");
const Parameter = @import("Parameter.zig");

/// Returns the __negative__ log-likelihood value of a Gaussian penalty term
fn penalty(value: f64, mean: f64, sigma: f64) f64 {
    return 0.5 * std.math.pow(f64, (value - mean) / sigma, 2);
}

pub const Fit = struct {
    name: []const u8 = "",
    datasets: std.ArrayList(*Dataset) = .empty,
    // name_dataset: std.StringHashMap(*Dataset) = .{},
    systematics: std.ArrayList(*fit.Systematic) = .empty,

    _allocator: std.mem.Allocator = undefined,
    _free: std.ArrayList(*Parameter) = .empty,
    _fixed: std.ArrayList(*Parameter) = .empty,
    _parameters: std.ArrayList(*Parameter) = .empty,
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Fit {
        var init_fit = Fit{};
        init_fit.name = try allocator.dupe(u8, name);
        init_fit._allocator = allocator;
        // init_fit.name_dataset = .init(allocator);
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
        try self._free.append(self._allocator, &self.systematics.items[self.systematics.items.len - 1].parameter);
        return systematic_ptr;
    }

    pub fn deinit(self: *Fit) void {
        self._allocator.free(self.name);
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
        self._free.deinit(self._allocator);
        self._fixed.deinit(self._allocator);
        self._parameters.deinit(self._allocator);
        self.* = undefined;
    }

    fn classifyAndAppendParameter(self: *Fit, param: *Parameter) !void {
        if (param.free) {
            try self._free.append(self._allocator, param);
        } else {
            try self._fixed.append(self._allocator, param);
        }
        try self._parameters.append(self._allocator, param);
    }

    pub fn updateParameters(self: *Fit) !void {
        self._free.clearRetainingCapacity();
        self._fixed.clearRetainingCapacity();
        self._parameters.clearRetainingCapacity();
        for (self.systematics.items) |sys| {
            try classifyAndAppendParameter(self, &sys.parameter);
        }
        for (self.datasets.items) |dataset| {
            for (dataset.signals.items) |sig| {
                try classifyAndAppendParameter(self, &sig.parameter);
            }
        }
    }

    pub fn getNLL(self: Fit) f64 {
        var results: f64 = 0;
        for (self.systematics.items) |systematic| {
            results += penalty(systematic.parameter.value, systematic.parameter.expectation, systematic.parameter.sigma);
            std.log.debug("After systematics penalty: {d}", .{results});
        }
        for (self.datasets.items) |dataset| {
            results += dataset.getNLL();
            std.log.debug("After datasets calculation: {d}", .{results});
        }
        return results;
    }

    pub fn minimize(self: *Fit, optimizer: ?min.Optimizer) min.FitResult {
        if (optimizer) |opt| {
            return opt.minimize(self._allocator);
        } else {
            var simple_opt: min.SimpleOptimizer = .{ .fit = self, .optimizer_name = "LN_SBPLX" };
            const opt = simple_opt.optimizer();
            return opt.minimize(self._allocator);
        }
    }

    /// Returns "appropriately" spaced step sizes based on the fit state
    /// Caller owns the resulting slice
    pub fn getStepSizes(self: Fit, allocator: std.mem.Allocator) ![]f64 {
        var dxs = try std.ArrayList(f64).initCapacity(allocator, self._free.items.len);
        for (self._free.items) |p| {
            if (std.math.isFinite(p.sigma)) {
                dxs.appendAssumeCapacity(p.sigma);
            } else {
                if (std.math.isFinite(p.bounds[0]) and std.math.isFinite(p.bounds[1])) {
                    dxs.appendAssumeCapacity((p.bounds[1] - p.bounds[0]) / 10);
                } else {
                    var step: f64 = 1;
                    if (p.value > 3) {
                        step = std.math.sqrt(@abs(p.value));
                    } else {
                        step = 1;
                    }
                    if (p.value - step < p.bounds[0]) {
                        step = (p.value - p.bounds[0]) / 10;
                    }
                    if (p.value - step > p.bounds[1]) {
                        step = (p.bounds[1] - p.value) / 10;
                    }
                    dxs.appendAssumeCapacity(step);
                }
            }
        }
        std.debug.assert(dxs.items.len == self._free.items.len);
        return dxs.toOwnedSlice(allocator);
    }

    fn getParameterScanBound(self: *Fit, param: *Parameter, optimizer: ?min.Optimizer, fitresult: min.FitResult, positve: bool) !f64 {
        const step_sizes = try self.getStepSizes(self._allocator);
        defer self._allocator.free(step_sizes);

        var step_size = param.value;
        for (self._free.items, 0..) |p, pidx| {
            if (p == param) {
                step_size = step_sizes[pidx];
            }
        }

        var state = try self.cacheParameterStates(self._allocator);
        defer {
            for (self._parameters.items) |p| {
                const param_state = state.get(p.name).?;
                p.value = param_state.value;
                p.free = param_state.free;
            }
            self.updateParameters() catch unreachable;
            state.deinit();
        }

        const original_value = param.value;
        if (param.value > 3) {
            step_size = std.math.sqrt(param.value);
        } else {
            step_size = param.value * 0.10;
        }

        var nll = fitresult.value;
        var num_iter: u16 = 0;
        while (nll - fitresult.value < 2) {
            if (num_iter > 16) {
                std.log.err("Could not find parameter scan range", .{});
                break;
            }
            step_size *= 2;
            if (positve) {
                param.value = original_value + step_size;
            } else {
                param.value = original_value - step_size;
            }
            if (param.value < param.bounds[0] or param.value > param.bounds[1]) {
                if (num_iter == 0) {
                    if (positve) {
                        step_size = (param.bounds[1] - original_value) / 10;
                        param.value = original_value + step_size;
                    } else {
                        step_size = (original_value - param.bounds[0]) / 10;
                        param.value = original_value - step_size;
                    }
                } else {
                    if (positve) {
                        param.value = param.bounds[1];
                    } else {
                        param.value = param.bounds[0];
                    }
                    std.log.err("Reached bound for {s} with {d}\n", .{ param.name, param.value });
                    break;
                }
            }
            const new_min = self.minimize(optimizer);
            nll = new_min.value;
            std.debug.print("On bound step: {d}, {d}\n", .{ param.value, nll });
            num_iter += 1;
        }
        num_iter = 0;
        while (nll - fitresult.value > 4) {
            if (num_iter > 16) {
                std.log.err("Could not find parameter scan range", .{});
                break;
            }
            step_size /= 2;
            if (positve) {
                param.value = original_value + step_size;
            } else {
                param.value = original_value - step_size;
            }
            if (param.value < param.bounds[0] or param.value > param.bounds[1]) {
                std.log.err("Reached bound for {s} with {d}\n", .{ param.name, param.value });
                break;
            }
            const new_min = self.minimize(optimizer);
            nll = new_min.value;
            num_iter += 1;
            std.debug.print("On bound step: {d}, {d}\n", .{ param.value, nll });
        }
        const return_val = param.value;
        param.value = original_value;
        return return_val;
    }

    const ParameterState = struct {
        value: f64,
        free: bool,
    };
    pub fn cacheParameterStates(self: *Fit, allocator: std.mem.Allocator) !std.StringHashMap(ParameterState) {
        var state: std.StringHashMap(ParameterState) = .init(allocator);
        for (self._parameters.items) |p| {
            try state.put(p.name, .{ .value = p.value, .free = p.free });
        }
        return state;
    }

    const ScanOptions = struct {
        steps: u16 = 20,
        range: ?[2]f64 = null,
    };
    pub fn posteriorScan(self: *Fit, optimize: ?min.Optimizer, param: *Parameter, fitresult: min.FitResult, options: ScanOptions) ![2][]f64 {
        const xs = try self._allocator.alloc(f64, options.steps);
        const dnlls = try self._allocator.alloc(f64, options.steps);

        var state = try self.cacheParameterStates(self._allocator);
        param.free = false;
        try self.updateParameters();
        defer {
            for (self._parameters.items) |p| {
                const param_state = state.get(p.name).?;
                p.value = param_state.value;
                p.free = param_state.free;
            }
            self.updateParameters() catch unreachable;
            state.deinit();
        }

        var bounds: [2]f64 = undefined;
        if (options.range == null) {
            bounds[0] = try self.getParameterScanBound(param, optimize, fitresult, false);
            bounds[1] = try self.getParameterScanBound(param, optimize, fitresult, true);
        } else {
            bounds[0] = options.range.?[0];
            bounds[1] = options.range.?[1];
        }

        std.debug.print("bounds: {d}, {d}\n", .{ bounds[0], bounds[1] });
        for (0..options.steps) |idx| {
            std.debug.print("on step {d} out of {d}\n", .{ idx, options.steps });
            const x = bounds[0] + @as(f64, @floatFromInt(idx)) * (bounds[1] - bounds[0]) / @as(f64, @floatFromInt(options.steps));
            xs[idx] = x;
            param.value = x;
            std.debug.print("{s} is {d}\n", .{ param.name, param.value });
            const scan_result = self.minimize(optimize);
            for (self._free.items) |p| {
                std.debug.print("{s}: {d}\n", .{ p.name, p.value });
                p.value = state.get(p.name).?.value;
            }
            dnlls[idx] = scan_result.value - fitresult.value;
        }
        return .{ xs, dnlls };
    }
};

pub const Dataset = struct {
    name: []const u8 = "",
    dimensions: std.ArrayList(*fit.Dimension) = .empty,
    signals: std.ArrayList(*fit.Signal) = .empty,
    // "energy": [e1, e2, ...]
    data: std.StringHashMap([]f64) = undefined,
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
        var iter = self.data.iterator();
        while (iter.next()) |val| {
            self._allocator.free(val.key_ptr.*);
            self._allocator.free(val.value_ptr.*);
        }
        self.data.deinit();
        self._allocator.free(self.data_counts);
        self._allocator.free(self._total_pdf_scratch);
        self.* = undefined;
    }

    pub fn addData(self: *Dataset, data: []const fit.DataPoints) !void {
        var bins = try self._allocator.alloc([]const f64, data.len);
        defer self._allocator.free(bins);
        var points = try self._allocator.alloc([]const f64, data.len);
        defer self._allocator.free(points);
        for (data, 0..) |p, idx| {
            try self.data.putNoClobber(
                try self._allocator.dupe(u8, p.dimension_name),
                try self._allocator.dupe(f64, p.points),
            );
            const dimension = try self.getDimension(p.dimension_name);
            bins[idx] = dimension.bins;
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

    /// Get the names of the dimensions in the dataset. Returns array of
    /// slices pointing to the names used internally by the struct, so the
    /// names themselves do not need to be freed, only the retured array. So
    /// caller must call `allocator.free(returned_array)`;
    pub fn getDimensionNames(self: Dataset, allocator: std.mem.Allocator) ![]const []const u8 {
        var names = try allocator.alloc([]const u8, self.dimensions.items.len);
        for (self.dimensions.items, 0..) |dim, idx| {
            names[idx] = dim.name;
        }
        return names;
    }

    pub fn getDimension(self: Dataset, name: []const u8) !*fit.Dimension {
        for (self.dimensions.items) |dim| {
            if (std.mem.eql(u8, dim.name, name)) return dim;
        }
        return error.DimensionNotFound;
    }

    pub fn addSignal(self: *Dataset, name: []const u8, points: []const fit.DataPoints) !*fit.Signal {
        const signal_ptr = try self._allocator.create(fit.Signal);
        signal_ptr.* = try .init(self._allocator, name, points, self);
        try self.signals.append(self._allocator, signal_ptr);
        return signal_ptr;
    }

    fn getNLL(self: Dataset) f64 {
        utilities.zeroArray(self._total_pdf_scratch);
        var expected_events: f64 = 0;
        var penalty_total: f64 = 0;
        for (self.signals.items) |signal| {
            const param = signal.parameter;
            expected_events += param.value;
            const probabilities = signal.getProbability() catch |err| {
                std.debug.panic("Cannot calculate probabilities for {}, recieved {}", .{ signal, err });
            };
            for (probabilities, 0..) |prob, idx| {
                self._total_pdf_scratch[idx] += param.value * prob;
            }
            penalty_total += penalty(param.value, param.expectation, param.sigma);
        }
        var total: f64 = 0;
        for (self._total_pdf_scratch, 0..) |val, idx| {
            if (self.data_counts[idx] == 0) {
                continue;
            }
            total += self.data_counts[idx] * std.math.log(f64, std.math.e, val);
        }
        const nll = expected_events - total + penalty_total;
        return nll;
    }
};
