const std = @import("std");

const fit = @import("root.zig");
const utilities = @import("utilities.zig");
const min = @import("minimization.zig");
const Parameter = @import("Parameter.zig");
const c_imports = @import("c_imports");

const fitlog = std.log.scoped(.llfit);
const hesslog = std.log.scoped(.llfit);

/// Returns the __negative__ log-likelihood value of a Gaussian penalty term
fn penalty(value: f64, mean: f64, sigma: f64) f64 {
    return 0.5 * std.math.pow(f64, (value - mean) / sigma, 2);
}

pub const Fit = struct {
    name: []const u8,
    datasets: std.ArrayList(*Dataset) = .empty,
    // name_dataset: std.StringHashMap(*Dataset) = .{},
    systematics: std.ArrayList(*fit.Systematic) = .empty,
    llfn: *const fn (self: Fit) f64 = defNLL,

    _allocator: std.mem.Allocator,
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

    pub fn addSystematic(self: *Fit, options: fit.Systematic.SystematicOptions) !*fit.Systematic {
        const systematic_ptr = try self._allocator.create(fit.Systematic);
        systematic_ptr.* = .init(options);
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

    pub fn defNLL(self: Fit) f64 {
        var results: f64 = 0;
        for (self.systematics.items) |systematic| {
            results += penalty(systematic.parameter.value, systematic.parameter.expectation, systematic.parameter.sigma);
            fitlog.debug("Penalty for {s}: {d}", .{ systematic.name, results });
        }
        for (self.datasets.items) |dataset| {
            results += dataset.getNLL();
            fitlog.debug("After datasets calculation: {d}", .{results});
        }
        return results;
    }

    pub fn getNLL(self: Fit) f64 {
        return self.llfn(self);
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

        param.free = false;
        try self.updateParameters();
        const original_value = param.value;
        if (param.value > 3) {
            step_size = std.math.sqrt(param.value);
        } else {
            step_size = param.value * 0.10;
        }

        var nll = fitresult.value;
        var num_iter: u16 = 0;
        while (nll - fitresult.value < 2) {
            if (num_iter > 1024) {
                fitlog.warn("Could not find parameter scan range", .{});
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
                    fitlog.warn("Reached bound for {s} with {d}", .{ param.name, param.value });
                    break;
                }
            }
            const new_min = self.minimize(optimizer);
            nll = new_min.value;
            num_iter += 1;
            for (self._free.items) |p| {
                const param_state = state.get(p.name).?;
                p.value = param_state.value;
            }
        }
        num_iter = 0;
        while (nll - fitresult.value > 4) {
            if (num_iter > 1024) {
                fitlog.warn("Could not find parameter scan range", .{});
                break;
            }
            step_size /= 2;
            if (positve) {
                param.value = original_value + step_size;
            } else {
                param.value = original_value - step_size;
            }
            if (param.value < param.bounds[0] or param.value > param.bounds[1]) {
                fitlog.warn("Reached bound for {s} with {d}", .{ param.name, param.value });
                break;
            }
            const new_min = self.minimize(optimizer);
            nll = new_min.value;
            num_iter += 1;
            for (self._free.items) |p| {
                const param_state = state.get(p.name).?;
                p.value = param_state.value;
            }
        }
        const return_val = param.value;
        param.value = original_value;
        return return_val;
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
            fitlog.info("Bounds from scan: {d}, {d}", .{ bounds[0], bounds[1] });
        } else {
            bounds[0] = options.range.?[0];
            bounds[1] = options.range.?[1];
        }

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

    pub fn calculateNegativeHessian(self: Fit, allocator: std.mem.Allocator, step: ?f64) ![][]f64 {
        const Func = struct {
            pub fn getParameterRange(p: *Parameter, p_in: f64, s: f64) ![2]f64 {
                var p_high = p_in + s;
                var p_low = p_in - s;
                if (p_high > p.bounds[1]) {
                    p_high = p.bounds[1];
                    p_low = p_high - 2 * s;
                    if (p_low < p.bounds[0]) {
                        hesslog.err("On paramter {s}, cannot find adequate low bound.", .{p.name});
                        hesslog.err("Bounds are {any}.", .{p.bounds});
                        hesslog.err("Last tried hessian bounds are {d}, {d}.", .{ p_low, p_high });
                        return error.OverConstrained;
                    }
                } else if (p_low < p.bounds[0]) {
                    p_low = p.bounds[0];
                    p_high = p_low + 2 * s;
                    if (p_high > p.bounds[1]) {
                        hesslog.err("On paramter {s}, cannot find adequate high bound.", .{p.name});
                        hesslog.err("Bounds are {any}.", .{p.bounds});
                        hesslog.err("Last tried hessian bounds are {d}, {d}.", .{ p_low, p_high });
                        return error.OverConstrained;
                    }
                }
                return .{ p_low, p_high };
            }
            pub fn calculateNLL(pfit: *const Fit, pi: *Parameter, pj: *Parameter, pi_values: [2]f64, pj_values: [2]f64) [4]f64 {
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
                if (step == null) {
                    si = @abs(pi.value * std.math.pow(f64, std.math.floatEpsAt(f64, pi.value), 0.25));
                    sj = @abs(pj.value * std.math.pow(f64, std.math.floatEpsAt(f64, pj.value), 0.25));
                    // It seems like if parameter is too small the step size is not big enough,
                    // this cut off size was just chosen at random
                    if (si < 1e-1) si = std.math.pow(f64, std.math.floatEpsAt(f64, 1e-1), 0.25);
                    if (sj < 1e-1) sj = std.math.pow(f64, std.math.floatEpsAt(f64, 1e-1), 0.25);
                } else {
                    si = step.?;
                    sj = step.?;
                }
                const pi_in = pi.value;
                const pj_in = pj.value;

                var pj_range = try Func.getParameterRange(pj, pj_in, sj);

                var pi_range = try Func.getParameterRange(pi, pi_in, si);

                var nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);

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
                        nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
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
                                hesslog.err("{any}", .{err});
                                break :blk pj.bounds;
                            };
                            break :blk rv;
                        };
                        hesslog.warn("pi: {s}\n", .{pi.name});
                        hesslog.warn("pj: {s}\n", .{pj.name});
                        hesslog.warn("sj: {any}\n", .{sj});
                        hesslog.warn("Retrying with range {any}\n", .{pj_range});
                        nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
                        // If changing pj does not affect calculation, and we are at the bounds,
                        // then just bump the LL slightly so we can move on.
                        if (std.mem.eql(f64, &pj_range, &pj.bounds)) {
                            hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pj.name});
                            break;
                        }
                    }
                    while (nll_values[0] < input_min_nll or nll_values[1] < input_min_nll) {
                        sj *= 10;
                        pj_range = blk: {
                            const rv = Func.getParameterRange(pj, pj_in, sj) catch |err| {
                                hesslog.err("{any}", .{err});
                                break :blk pj.bounds;
                            };
                            break :blk rv;
                        };
                        hesslog.warn("nll_values lt min  nll: {d}, {any}\n", .{ input_min_nll, nll_values });
                        hesslog.warn("Params are {s} and {s}", .{ pi.name, pj.name });
                        hesslog.warn("Ranges are are {any} and {any}", .{ pi_range, pj_range });
                        nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
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
                                hesslog.err("{any}", .{err});
                                break :blk pi.bounds;
                            };
                            break :blk rv;
                        };
                        nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
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
                        nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
                        // If changing pj does not affect calculation, and we are at the bounds,
                        // then just bump the LL slightly so we can move on.
                        if (std.mem.eql(f64, &pj_range, &pj.bounds)) {
                            hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pj.name});
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
                        nll_values = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
                        if (std.mem.eql(f64, &pi_range, &pi.bounds) and std.mem.eql(f64, &pj_range, &pj.bounds)) {
                            hesslog.warn("Could not find adequate range for {s}, at bounds.", .{pj.name});
                            break;
                        }
                    }
                }

                hesslog.debug("Done with {s}, {s}", .{ pj.name, pi.name });
                const final_vals = Func.calculateNLL(&self, pi, pj, pi_range, pj_range);
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

    pub fn calculateCovarianceMatrix(self: Fit, allocator: std.mem.Allocator, step: ?f64) ![][]f64 {
        const neg_hess = try calculateNegativeHessian(self, allocator, step);
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

    fn getNLL(self: Dataset) f64 {
        utilities.zeroArray(self._total_pdf_scratch);
        var expected_events: f64 = 0;
        var penalty_total: f64 = 0;
        for (self.signals.items) |signal| {
            const param = signal.parameter;
            expected_events += param.value;
            const probabilities = signal.getProbability() catch |err| {
                std.debug.panic("Cannot calculate probabilities for {f}, recieved {any}", .{ signal, err });
            };
            for (probabilities, 0..) |prob, idx| {
                self._total_pdf_scratch[idx] += param.value * prob;
            }
            fitlog.debug("Param info: {any}\n", .{param});
            const pen = penalty(param.value, param.expectation, param.sigma);
            penalty_total += pen;
            fitlog.debug("Param penalty: {d}\n", .{pen});
        }
        fitlog.debug("Total from penalties: {any}\n", .{penalty_total});
        fitlog.debug("Total pdf: {any}\n", .{self._total_pdf_scratch});
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
