const std = @import("std");

const fit = @import("root.zig");
const utilities = @import("utilities.zig");
const min = @import("minimization.zig");
const Parameter = @import("Parameter.zig");
const c_imports = @import("c_imports");

const fitlog = std.log.scoped(.llfit);
const hesslog = std.log.scoped(.llfit);

pub const Fit = struct {
    name: []const u8,
    _allocator: std.mem.Allocator,

    datasets: std.ArrayList(*Dataset) = .empty,
    // name_dataset: std.StringHashMap(*Dataset) = .{},
    systematics: std.ArrayList(*fit.Systematic) = .empty,

    llfn: *const fn (self: *Fit, ?*anyopaque) f64 = defNLL,
    llfn_params: ?*anyopaque = null,

    _free: std.ArrayList(*Parameter) = .empty,
    _fixed: std.ArrayList(*Parameter) = .empty,
    _parameters: std.ArrayList(*Parameter) = .empty,
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Fit {
        return .{
            .name = try allocator.dupe(u8, name),
            ._allocator = allocator,
        };
    }

    pub fn addDataset(self: *Fit, name: []const u8) !*Dataset {
        const dataset_ptr = try self._allocator.create(Dataset);
        dataset_ptr.* = try Dataset.init(self._allocator, name);
        // const dataset: Dataset = try .init(self._allocator, name);
        try self.datasets.append(self._allocator, dataset_ptr);
        return self.datasets.items[self.datasets.items.len - 1];
    }

    pub fn addSystematic(self: *Fit, name: []const u8, options: fit.Systematic.SystematicOptions) !*fit.Systematic {
        const systematic_ptr = try self._allocator.create(fit.Systematic);
        systematic_ptr.* = .init(name, options);
        try self.systematics.append(self._allocator, systematic_ptr);
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

    pub fn defDatasetNLL(dataset: *Dataset, io: std.Io) f64 {
        utilities.zeroArray(dataset._total_pdf_scratch);

        var prob_futures = dataset._allocator.alloc(std.Io.Future([]f64), dataset.signals.items.len) catch @panic("OOM");
        defer dataset._allocator.free(prob_futures);
        for (dataset.signals.items, 0..) |signal, idx| {
            prob_futures[idx] = io.async(fit.Signal.getProbability, .{signal});
        }

        var expected_events: f64 = 0;
        for (dataset.signals.items, 0..) |signal, i| {
            // var fut = prob_futures.get(signal.name);
            // const probabilities = fut.?.await(io);
            const probabilities = prob_futures[i].await(io);
            const param = signal.parameter;
            expected_events += param.value;
            // const probabilities = signal.getProbability() catch |err| {
            //     std.debug.panic("Cannot calculate probabilities for {f}, recieved {any}", .{ signal, err });
            // };
            for (probabilities, 0..) |prob, idx| {
                dataset._total_pdf_scratch[idx] += param.value * prob;
            }
            fitlog.debug("Param info: {any}\n", .{param});
        }
        fitlog.debug("Total pdf: {any}\n", .{dataset._total_pdf_scratch});
        var total: f64 = 0;
        for (dataset._total_pdf_scratch, 0..) |val, idx| {
            if (dataset.data_counts[idx] == 0) {
                continue;
            }
            total += dataset.data_counts[idx] * std.math.log(f64, std.math.e, val);
        }
        const nll = expected_events - total;
        return nll;
    }

    pub fn defNLL(self: *const Fit, func_params: ?*anyopaque) f64 {
        _ = func_params;
        var io = std.Io.Threaded.init_single_threaded;
        defer io.deinit();
        var results: f64 = 0;
        for (self._parameters.items) |param| {
            const pen = param.getPriorNLL();
            fitlog.debug("Penalty for {s}: {d}", .{ param.name, pen });
            results += pen;
        }
        for (self.datasets.items) |dataset| {
            results += defDatasetNLL(dataset, io.io());
            fitlog.debug("After datasets calculation: {d}", .{results});
        }
        return results;
    }

    pub const MulthreadOptions = struct {
        io: std.Io,
    };
    pub fn multithreadedNLL(self: *const Fit, func_params: ?*anyopaque) f64 {
        const options: *MulthreadOptions = @ptrCast(@alignCast(func_params));
        var results: f64 = 0;
        for (self._parameters.items) |param| {
            const pen = param.getPriorNLL();
            fitlog.debug("Penalty for {s}: {d}", .{ param.name, pen });
            results += pen;
        }
        for (self.datasets.items) |dataset| {
            results += defDatasetNLL(dataset, options.io);
            fitlog.debug("After datasets calculation: {d}", .{results});
        }
        return results;
    }

    pub fn getNLL(self: *Fit) f64 {
        return self.llfn(self, self.llfn_params);
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

    fn getParameterScanBound(self: *Fit, param: *Parameter, init_step: f64) ![2]f64 {
        const max_steps = 1e5;
        var state = try self.cacheParameterStates(self._allocator);
        defer self.applyAndFreeParameterStates(&state);

        const init_nll = self.getNLL();
        const init_value = param.value;

        var low_x = param.clampValue(init_value - init_step);
        param.value = low_x;
        var low = self.getNLL() - init_nll;
        var si: f64 = 0;
        while (low > 5 and param.value > init_value and si < max_steps) : (si += 1) {
            param.value = param.clampValue(init_value - (init_value - low_x) / 2);
            low_x = param.value;
            low = self.getNLL() - init_nll;
        }
        si = 0;
        while (low < 5 and param.value > param.bounds[0] and si < max_steps) : (si += 1) {
            param.value = param.clampValue(init_value - (init_value - low_x) * 2);
            low_x = param.value;
            low = self.getNLL() - init_nll;
        }

        var high_x = param.clampValue(init_value + init_step);
        param.value = high_x;
        var high = self.getNLL() - init_nll;
        si = 0;
        while (high > 5 and high_x > init_value and si < max_steps) : (si += 1) {
            param.value = param.clampValue(init_value + (high_x - init_value) / 2);
            high_x = param.value;
            high = self.getNLL() - init_nll;
        }
        si = 0;
        while (high < 5 and high_x < param.bounds[1] and si < max_steps) : (si += 1) {
            param.value = param.clampValue(init_value + (high_x - init_value) * 2);
            high_x = param.value;
            high = self.getNLL() - init_nll;
        }

        return .{ low_x, high_x };
    }

    pub fn cacheParameterStates(self: *Fit, allocator: std.mem.Allocator) !std.StringHashMap(Parameter) {
        var state: std.StringHashMap(Parameter) = .init(allocator);
        for (self._parameters.items) |p| {
            try state.put(p.name, p.copyShallow());
        }
        return state;
    }
    pub fn applyAndFreeParameterStates(self: *Fit, state: *std.StringHashMap(Parameter)) void {
        for (self._parameters.items) |p| {
            const param_state = state.get(p.name) orelse continue;
            p.setFrom(param_state);
        }
        self.updateParameters() catch unreachable;
        state.deinit();
    }

    const ScanOptions = struct {
        steps: u16 = 20,
        range: ?[2]f64 = null,
    };
    pub fn posteriorScan(self: *Fit, optimize: ?min.Optimizer, param: *Parameter, fitresult: min.FitResult, options: ScanOptions) ![2][]f64 {
        const xs = try self._allocator.alloc(f64, options.steps);
        const dnlls = try self._allocator.alloc(f64, options.steps);
        const param_idx = blk: {
            for (self._free.items, 0..) |p, idx| {
                if (p == param) {
                    break :blk idx;
                }
            }
            fitlog.err("Cannot computer posterior scan for a fixed parameters {s}", .{param.name});
            return error.FixedParam;
        };

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

        var bounds: [2]f64 = undefined;
        if (options.range == null) {
            const covariance = try self.calculateCovarianceMatrix(self._allocator, .{});
            defer {
                for (covariance) |row| self._allocator.free(row);
                self._allocator.free(covariance);
            }
            var cov_var = covariance[param_idx][param_idx];
            if (cov_var < 0) {
                hesslog.warn("Got a negative variance {d} for {s}", .{ cov_var, param.name });
                hesslog.warn("\tUsing 10% as first step size instead", .{});
                cov_var = std.math.pow(f64, param.value * 0.1, 2);
            }
            bounds = try self.getParameterScanBound(param, @sqrt(cov_var));
        } else {
            bounds[0] = options.range.?[0];
            bounds[1] = options.range.?[1];
        }

        param.free = false;
        try self.updateParameters();

        for (0..options.steps) |idx| {
            fitlog.info("On step {d} out of {d}", .{ idx, options.steps });
            const x = bounds[0] + @as(f64, @floatFromInt(idx)) * (bounds[1] - bounds[0]) / @as(f64, @floatFromInt(options.steps));
            xs[idx] = x;
            param.value = x;
            const scan_result = self.minimize(optimize);
            for (self._free.items) |p| {
                p.value = state.get(p.name).?.value;
            }
            dnlls[idx] = scan_result.value - fitresult.value;
            fitlog.info("delta_nll is {d}", .{dnlls[idx]});
        }
        return .{ xs, dnlls };
    }

    pub const HessianOptions = struct {
        step: ?f64 = null,
        check_minimum: bool = true,
    };
    pub fn calculateNegativeHessian(self: *Fit, allocator: std.mem.Allocator, options: HessianOptions) ![][]f64 {
        const Func = struct {
            pub fn getParameterRange(p: *Parameter, p_in: f64, s: f64) ![2]f64 {
                var p_high = p_in + s;
                var p_low = p_in - s;
                if (p_high > p.bounds[1]) {
                    p_high = p.bounds[1];
                    p_low = p_high - 2 * s;
                    if (p_low < p.bounds[0]) {
                        return error.OverConstrained;
                    }
                } else if (p_low < p.bounds[0]) {
                    p_low = p.bounds[0];
                    p_high = p_low + 2 * s;
                    if (p_high > p.bounds[1]) {
                        return error.OverConstrained;
                    }
                }
                return .{ p_low, p_high };
            }
            pub fn calculateNLL(pfit: *Fit, pi: *Parameter, pj: *Parameter, pi_values: [2]f64, pj_values: [2]f64) [4]f64 {
                const pi_in = pi.value;
                const pj_in = pj.value;

                const pj_low = pj_values[0];
                const pj_high = pj_values[1];
                const pi_low = pi_values[0];
                const pi_high = pi_values[1];

                if (pi == pj) {
                    // Special case for i==j since that will always be zero with this approach
                    pi.value = pi_high;
                    const fp = pfit.getNLL();
                    // pi.value = (pi_high + pi_low) / 2;
                    pi.value = pi_in;
                    const f0 = pfit.getNLL();
                    pi.value = pi_low;
                    const fm = pfit.getNLL();

                    pi.value = pi_in;
                    pj.value = pj_in;

                    return .{ fp, f0, fm, std.math.nan(f64) };
                }

                pj.value = pj_high;
                pi.value = pi_high;
                const pp = pfit.getNLL();

                pj.value = pj_high;
                pi.value = pi_low;
                const pm = pfit.getNLL();

                pj.value = pj_low;
                pi.value = pi_high;
                const mp = pfit.getNLL();

                pj.value = pj_low;
                pi.value = pi_low;
                const mm = pfit.getNLL();

                pi.value = pi_in;
                pj.value = pj_in;

                return .{ pp, pm, mp, mm };
            }

            pub fn nllToHess(nlls: [4]f64, si: f64, sj: f64, i: usize, j: usize) f64 {
                const pp = nlls[0];
                const pm = nlls[1];
                const mp = nlls[2];
                const mm = nlls[3];

                hesslog.debug("sj, si: {d}, {d}", .{ sj, si });
                hesslog.debug("pp: {d}, pm: {d}, mp: {d}, mm: {d}", .{ pp, pm, mp, mm });

                if (i == j) {
                    std.debug.assert(std.math.isNan(mm));
                    hesslog.debug("(pp - 2 *pm + mp): {d}", .{(pp - 2 * pm + mp)});
                    return (pp - 2 * pm + mp) / (si * si);
                } else {
                    hesslog.debug("(pp - pm - mp + mm): {d}", .{(pp - pm - mp + mm)});
                    return (pp - pm - mp + mm) / (4 * sj * si);
                }
            }
        };

        const input_min_nll = self.getNLL();

        const hess = try allocator.alloc([]f64, self._free.items.len);
        for (hess) |*h| {
            h.* = try allocator.alloc(f64, self._free.items.len);
        }

        for (self._free.items, 0..) |pi, i| {
            for (self._free.items, 0..) |pj, j| {
                var si: f64 = 0;
                var sj: f64 = 0;
                if (options.step == null) {
                    si = @abs(pi.value * std.math.pow(f64, std.math.floatEpsAt(f64, pi.value), 0.25));
                    sj = @abs(pj.value * std.math.pow(f64, std.math.floatEpsAt(f64, pj.value), 0.25));
                    // It seems like if parameter is too small the step size is not big enough,
                    // this cut off size was just chosen at random
                    if (si < 1e-1) si = std.math.pow(f64, std.math.floatEpsAt(f64, 1e-1), 0.25);
                    if (sj < 1e-1) sj = std.math.pow(f64, std.math.floatEpsAt(f64, 1e-1), 0.25);
                } else {
                    si = options.step.?;
                    sj = options.step.?;
                }
                const pi_in = pi.value;
                const pj_in = pj.value;

                var pj_range = try Func.getParameterRange(pj, pj_in, sj);

                var pi_range = try Func.getParameterRange(pi, pi_in, si);

                var nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);

                if (i != j) {
                    while (nll_values[0] == nll_values[1]) {
                        if (si == 0) {
                            hesslog.warn("zero step for pi: {s}\n", .{pi.name});
                        }
                        si *= 10;
                        pi_range = blk: {
                            const rv = Func.getParameterRange(pi, pi_in, si) catch |err| {
                                hesslog.err("{any}", .{err});
                                break :blk pi.bounds;
                            };
                            break :blk rv;
                        };
                        hesslog.warn("pi: {s}\n", .{pi.name});
                        hesslog.warn("pj: {s}\n", .{pj.name});
                        hesslog.warn("si: {any}\n", .{si});
                        hesslog.warn("Retrying with range {any}\n", .{pi_range});
                        nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                        hesslog.warn("Got vals {any}\n", .{nll_values});
                        if (std.mem.eql(f64, &pi_range, &pi.bounds)) {
                            hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pi.name});
                            break;
                        }
                    }
                    // This is checking if changing pj actually changes the LL calculation at all
                    while (nll_values[0] == nll_values[2]) {
                        sj *= 10;
                        pj_range = blk: {
                            const rv = Func.getParameterRange(pj, pj_in, sj) catch |err| {
                                hesslog.err("On line: {any}", .{@src().line});
                                hesslog.err("{any}", .{err});
                                break :blk pj.bounds;
                            };
                            break :blk rv;
                        };
                        hesslog.warn("pi: {s}\n", .{pi.name});
                        hesslog.warn("pj: {s}\n", .{pj.name});
                        hesslog.warn("sj: {any}\n", .{sj});
                        hesslog.warn("Retrying with range {any}\n", .{pj_range});
                        nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                        // If changing pj does not affect calculation, and we are at the bounds,
                        // then just bump the LL slightly so we can move on.
                        if (std.mem.eql(f64, &pj_range, &pj.bounds)) {
                            hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pj.name});
                            break;
                        }
                    }
                    if (options.check_minimum) {
                        while (nll_values[0] < input_min_nll or nll_values[1] < input_min_nll) {
                            sj *= 10;
                            pj_range = blk: {
                                const rv = Func.getParameterRange(pj, pj_in, sj) catch |err| {
                                    hesslog.err("On line: {any}", .{@src().line});
                                    hesslog.err("{any}", .{err});
                                    break :blk pj.bounds;
                                };
                                break :blk rv;
                            };
                            hesslog.warn("nll_values lt min  nll: {d}, {any}\n", .{ input_min_nll, nll_values });
                            hesslog.warn("Params are {s} and {s}", .{ pi.name, pj.name });
                            hesslog.warn("Ranges are are {any} and {any}", .{ pi_range, pj_range });
                            nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                            // If changing pj does not affect calculation, and we are at the bounds,
                            // then just bump the LL slightly so we can move on.
                            if (std.mem.eql(f64, &pj_range, &pj.bounds)) {
                                hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pj.name});
                                break;
                            }
                        }
                        while (nll_values[0] < input_min_nll or nll_values[2] < input_min_nll) {
                            si *= 10;
                            pi_range = blk: {
                                const rv = Func.getParameterRange(pi, pi_in, si) catch |err| {
                                    hesslog.err("On line: {any}", .{@src().line});
                                    hesslog.err("{any}", .{err});
                                    break :blk pi.bounds;
                                };
                                break :blk rv;
                            };
                            nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                            // If changing pj does not affect calculation, and we are at the bounds,
                            // then just bump the LL slightly so we can move on.
                            if (std.mem.eql(f64, &pi_range, &pi.bounds)) {
                                hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pi.name});
                                break;
                            }
                        }
                        while (nll_values[3] < input_min_nll) {
                            si *= 10;
                            pi_range = blk: {
                                if (pi_range[0] == pi.bounds[0]) {
                                    si /= 10;
                                    break :blk pi_range;
                                }
                                const rv = Func.getParameterRange(pi, pi_in, si) catch {
                                    break :blk pi.bounds;
                                };
                                break :blk rv;
                            };
                            sj *= 10;
                            pj_range = blk: {
                                if (pj_range[0] == pj.bounds[0]) {
                                    sj /= 10;
                                    break :blk pj_range;
                                }
                                const rv = Func.getParameterRange(pj, pj_in, sj) catch {
                                    break :blk pj.bounds;
                                };
                                break :blk rv;
                            };
                            hesslog.warn("Trying for {s}: {d} - {d},\n\t{s}: {d} - {d}", .{
                                pi.name,
                                pi_range[0],
                                pi_range[1],
                                pj.name,
                                pj_range[0],
                                pj_range[1],
                            });
                            nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                            hesslog.warn("LL values are {any}", .{nll_values});
                            // If changing pj does not affect calculation, and we are at the bounds,
                            // then just bump the LL slightly so we can move on.
                            if (pi_range[0] == pi.bounds[0] and pj_range[0] == pj.bounds[0]) {
                                hesslog.warn("Could not find adequate range for {s} and {s}, at bounds.", .{ pi.name, pj.name });
                                break;
                            }
                        }
                    } else {
                        while (nll_values[0] < nll_values[1] or nll_values[2] < nll_values[1]) {
                            si *= 10;
                            pi_range = blk: {
                                const rv = Func.getParameterRange(pi, pi_in, si) catch |err| {
                                    hesslog.err("{any}", .{err});
                                    break :blk pi.bounds;
                                };
                                break :blk rv;
                            };
                            sj *= 10;
                            pj_range = blk: {
                                const rv = Func.getParameterRange(pj, pj_in, sj) catch |err| {
                                    hesslog.err("{any}", .{err});
                                    break :blk pj.bounds;
                                };
                                break :blk rv;
                            };
                            nll_values = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                            if (std.mem.eql(f64, &pi_range, &pi.bounds) and std.mem.eql(f64, &pj_range, &pj.bounds)) {
                                hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pj.name});
                                break;
                            }
                        }
                    }
                }

                hesslog.debug("Done with {s}, {s}", .{ pj.name, pi.name });
                const final_vals = Func.calculateNLL(self, pi, pj, pi_range, pj_range);
                hesslog.debug("resut is {d:2}, {d:2}, {d:2}, {d:2}", .{ final_vals[0], final_vals[1], final_vals[2], final_vals[3] });
                hesslog.debug("sj {d}, si {d}", .{ pj_range[1] - pj_range[0], pi_range[1] - pi_range[0] });
                const res = Func.nllToHess(final_vals, pi_range[1] - pi_range[0], pj_range[1] - pj_range[0], i, j);
                hesslog.debug("{d}", .{res});
                hess[i][j] = res;

                pi.value = pi_in;
                pj.value = pj_in;
            }
        }
        return hess;
    }

    pub fn calculateCovarianceMatrix(self: *Fit, allocator: std.mem.Allocator, hessian_options: HessianOptions) ![][]f64 {
        const neg_hess = try calculateNegativeHessian(self, allocator, hessian_options);
        defer {
            for (neg_hess) |row| {
                allocator.free(row);
            }
            allocator.free(neg_hess);
        }
        const cov = try allocator.alloc([]f64, neg_hess.len);
        for (cov) |*row| {
            row.* = try allocator.alloc(f64, neg_hess[0].len);
        }
        const gsl_mat = c_imports.gsl_matrix_alloc(neg_hess.len, neg_hess[0].len);
        defer c_imports.gsl_matrix_free(gsl_mat);
        const gsl_inv = c_imports.gsl_matrix_alloc(neg_hess.len, neg_hess[0].len);
        defer c_imports.gsl_matrix_free(gsl_inv);
        const perm = c_imports.gsl_permutation_alloc(neg_hess.len);
        defer c_imports.gsl_permutation_free(perm);

        for (neg_hess, 0..) |row, i| {
            for (row, 0..) |el, j| {
                c_imports.gsl_matrix_set(gsl_mat, i, j, el);
            }
        }

        var signum: c_int = 0;
        _ = c_imports.gsl_linalg_LU_decomp(gsl_mat, perm, &signum);
        _ = c_imports.gsl_linalg_LU_invert(gsl_mat, perm, gsl_inv);

        for (cov, 0..) |row, i| {
            for (row, 0..) |*el, j| {
                el.* = c_imports.gsl_matrix_get(gsl_inv, i, j);
            }
        }

        return cov;
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

    pub fn addPrebinnedData(self: *Dataset, data: []const f64) !void {
        var tot_len: usize = 1;
        for (self.dimensions.items) |dim| {
            tot_len = dim.bin_centers.len * tot_len;
        }
        if (tot_len != data.len) {
            fitlog.err("Cannot load data of length {d} when binning implies length of {d}\n", .{ data.len, tot_len });
            return error.IllFormedData;
        }
        self.data_counts = try self._allocator.dupe(f64, data);
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

    pub fn addSignal(
        self: *Dataset,
        name: []const u8,
        points: []const fit.DataPoints,
        options: fit.Signal.Options,
    ) !*fit.Signal {
        const signal_ptr = try self._allocator.create(fit.Signal);
        signal_ptr.* = try .init(self._allocator, name, points, self, options);
        try self.signals.append(self._allocator, signal_ptr);
        return signal_ptr;
    }
};
