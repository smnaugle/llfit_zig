const std = @import("std");
const c_imports = @import("c_imports");
const llfit = @import("fit.zig");
// TODO: Include Hessian calculations here

const inflog = std.log.scoped(.llfit);

pub const MCIntegrator = struct {
    pub const MCIntegratorType = enum {
        miser,
        vegas,
    };
    pub const MCIntegratorOptions = struct {
        n_calls: u64 = 1e6,
        int_type: MCIntegratorType = .vegas,
    };
    pub const MCIntegratorResult = struct {
        integral: f64 = 0,
        err: f64 = 0,
        chisqr: ?f64 = null,
    };

    params: usize,
    lows: []f64,
    highs: []f64,
    fit: *llfit.Fit,
    options: MCIntegratorOptions = .{},
    nll_min: f64 = 0,
    evals: usize = 0,

    fn gslInterfaceFn(xs: [*c]f64, dim: usize, params: ?*anyopaque) callconv(.c) f64 {
        const self: *MCIntegrator = @ptrCast(@alignCast(params));
        for (0..dim) |idx| {
            self.fit._free.items[idx].value = xs[idx];
        }
        const nll = self.fit.getNLL();
        const prob = @exp(self.nll_min - nll);
        self.evals += 1;
        if (self.evals % 1000 == 0) std.debug.print("On step {d} out of {d}\n", .{ self.evals, self.options.n_calls });
        return prob;
    }

    pub fn integrate(self: *MCIntegrator, allocator: std.mem.Allocator) !MCIntegratorResult {
        var state = try self.fit.cacheParameterStates(allocator);
        defer self.fit.applyAndFreeParameterStates(&state);
        self.nll_min = self.fit.getNLL();

        _ = c_imports.gsl_rng_env_setup();
        const rng_type = c_imports.gsl_rng_default;
        const rng = c_imports.gsl_rng_alloc(rng_type);
        var buf: [8]u8 = @splat(0);
        var io = std.Io.Threaded.init_single_threaded;
        defer io.deinit();
        io.io().random(&buf);
        c_imports.gsl_rng_set(rng, std.mem.readInt(u64, &buf, .big));
        defer c_imports.gsl_rng_free(rng);

        var func: c_imports.gsl_monte_function = .{ .f = gslInterfaceFn, .dim = self.params, .params = @ptrCast(self) };

        switch (self.options.int_type) {
            .vegas => {
                const mstate = c_imports.gsl_monte_vegas_alloc(self.params);
                defer c_imports.gsl_monte_vegas_free(mstate);
                var res: f64 = 0;
                var err: f64 = 0;
                _ = c_imports.gsl_monte_vegas_integrate(
                    @ptrCast(&func),
                    self.lows.ptr,
                    self.highs.ptr,
                    self.params,
                    self.options.n_calls / 10,
                    rng,
                    mstate,
                    &res,
                    &err,
                );
                _ = c_imports.gsl_monte_vegas_integrate(
                    @ptrCast(&func),
                    self.lows.ptr,
                    self.highs.ptr,
                    self.params,
                    self.options.n_calls,
                    rng,
                    mstate,
                    &res,
                    &err,
                );
                const chisqr = c_imports.gsl_monte_vegas_chisq(mstate);
                return .{ .integral = res, .err = err, .chisqr = chisqr };
            },
            .miser => {
                const mstate = c_imports.gsl_monte_miser_alloc(self.params);
                defer c_imports.gsl_monte_miser_free(mstate);
                var res: f64 = 0;
                var err: f64 = 0;
                _ = c_imports.gsl_monte_miser_integrate(
                    @ptrCast(&func),
                    self.lows.ptr,
                    self.highs.ptr,
                    self.params,
                    self.options.n_calls,
                    rng,
                    mstate,
                    &res,
                    &err,
                );
                return .{ .integral = res, .err = err };
            },
        }
    }

    pub fn init(allocator: std.mem.Allocator, fit: *llfit.Fit, lows: []f64, highs: []f64, options: MCIntegratorOptions) !MCIntegrator {
        const ls = try allocator.dupe(f64, lows);
        const hs = try allocator.dupe(f64, highs);

        return .{
            .params = fit._free.items.len,
            .lows = ls,
            .highs = hs,
            .fit = fit,
            .options = options,
        };
    }

    pub fn deinit(self: MCIntegrator, allocator: std.mem.Allocator) void {
        allocator.free(self.lows);
        allocator.free(self.highs);
    }
};

pub const TransformedMCIntegrator = struct {
    pub const TMCIOptions = struct {
        sigmas: f64 = 3,
        warmup_calls: usize = 1e5,
        cons_warmup_steps: usize = 3,
        eval_calls: usize = 2e5,
        cons_eval_steps: usize = 3,
    };
    pub const TMCIResult = MCIntegrator.MCIntegratorResult;
    cholesky_l: *c_imports.gsl_matrix,
    cholesky_l_det: f64,
    fit: *llfit.Fit,
    nll_min: f64 = 0,
    theta_hat: []f64 = &.{},
    lows: []f64,
    highs: []f64,
    options: TMCIOptions = .{},

    zeros: usize = 0,
    evals: usize = 0,

    fn evalFn(xs: [*c]f64, dims: usize, params: ?*anyopaque) callconv(.c) f64 {
        _ = dims;
        const self: *TransformedMCIntegrator = @ptrCast(@alignCast(params));
        self.evals += 1;
        // return getNLL(theta_hat + cholesky_l*xs) * abs(det(cholesky_l))
        for (0..self.cholesky_l.size1) |i| {
            var z: f64 = 0;
            // cholesky_l is lower triangular so we only need to go up to i
            for (0..(i + 1)) |j| {
                z += xs[j] * c_imports.gsl_matrix_get(self.cholesky_l, i, j);
            }
            self.fit._free.items[i].value = z + self.theta_hat[i];
            if (self.fit._free.items[i].bounds[0] > self.fit._free.items[i].value or self.fit._free.items[i].bounds[1] < self.fit._free.items[i].value) {
                self.zeros += 1;
                return 0;
            }
        }
        const nll = self.fit.getNLL();
        return @exp(self.nll_min - nll) * @abs(self.cholesky_l_det);
    }

    pub fn integrate(self: *TransformedMCIntegrator, allocator: std.mem.Allocator) !TMCIResult {
        var state = try self.fit.cacheParameterStates(allocator);
        defer self.fit.applyAndFreeParameterStates(&state);
        self.nll_min = self.fit.getNLL();
        self.theta_hat = try allocator.alloc(f64, self.fit._free.items.len);
        defer allocator.free(self.theta_hat);
        for (self.fit._free.items, 0..) |p, idx| {
            self.theta_hat[idx] = p.value;
        }

        _ = c_imports.gsl_rng_env_setup();
        const rng_type = c_imports.gsl_rng_default;
        const rng = c_imports.gsl_rng_alloc(rng_type);
        var buf: [8]u8 = @splat(0);
        var io = std.Io.Threaded.init_single_threaded;
        defer io.deinit();
        io.io().random(&buf);
        c_imports.gsl_rng_set(rng, std.mem.readInt(u64, &buf, .big));
        defer c_imports.gsl_rng_free(rng);

        var func: c_imports.gsl_monte_function = .{ .f = evalFn, .dim = self.lows.len, .params = @ptrCast(self) };

        const mstate = c_imports.gsl_monte_vegas_alloc(self.lows.len);
        defer c_imports.gsl_monte_vegas_free(mstate);
        var res: f64 = 0;
        var err: f64 = 0;
        // Warmup
        var wi: usize = 1;
        var good: usize = 0;
        while (good < self.options.cons_warmup_steps) : (wi += 1) {
            inflog.info("Running warmup step {d}", .{wi});
            _ = c_imports.gsl_monte_vegas_integrate(
                @ptrCast(&func),
                self.lows.ptr,
                self.highs.ptr,
                self.lows.len,
                self.options.warmup_calls,
                rng,
                mstate,
                &res,
                &err,
            );
            const chisqr = @abs(c_imports.gsl_monte_vegas_chisq(mstate));
            if (@abs(chisqr) - 1 < 0.5) {
                good += 1;
            } else {
                good = 0;
            }
            inflog.info("chisqr {d}", .{chisqr});
        }
        var ei: usize = 0;
        good = 0;
        while (good < self.options.cons_eval_steps) : (ei += 1) {
            inflog.info("Running evaluation step {d}", .{ei});
            _ = c_imports.gsl_monte_vegas_integrate(
                @ptrCast(&func),
                self.lows.ptr,
                self.highs.ptr,
                self.lows.len,
                self.options.eval_calls,
                rng,
                mstate,
                &res,
                &err,
            );
            const chisqr = @abs(c_imports.gsl_monte_vegas_chisq(mstate));
            if (@abs(chisqr) - 1 < 0.5) {
                good += 1;
            } else {
                good = 0;
            }
            inflog.info("chisqr {d}", .{chisqr});
        }
        const chisqr = c_imports.gsl_monte_vegas_chisq(mstate);
        std.debug.print("det is {d}\n", .{self.cholesky_l_det});
        return .{ .integral = res, .err = err, .chisqr = chisqr };
    }

    pub fn init(allocator: std.mem.Allocator, fit: *llfit.Fit, cov: [][]f64, options: TMCIOptions) !TransformedMCIntegrator {
        const gsl_mat = c_imports.gsl_matrix_alloc(cov.len, cov[0].len);
        for (cov, 0..) |row, i| {
            for (row, 0..) |el, j| {
                c_imports.gsl_matrix_set(gsl_mat, i, j, el);
            }
        }

        // From GSL docs
        // This function factorizes the positive-definite symmetric square
        // matrix A into the Cholesky decomposition A = L L^T. On output the
        // diagonal and lower triangular part of the input matrix A contain the
        // matrix L. The upper triangular part of the input matrix contains
        // L^T, the diagonal terms being identical for both L and L^T.
        _ = c_imports.gsl_linalg_cholesky_decomp(gsl_mat);
        var det: f64 = 1;
        for (0..gsl_mat.*.size1) |i| det *= c_imports.gsl_matrix_get(gsl_mat, i, i);

        const highs = try allocator.alloc(f64, fit._free.items.len);
        const lows = try allocator.alloc(f64, fit._free.items.len);
        for (0..fit._free.items.len) |idx| {
            highs[idx] = options.sigmas;
            lows[idx] = -1 * options.sigmas;
        }

        return .{
            .cholesky_l = gsl_mat,
            .cholesky_l_det = det,
            .fit = fit,
            .highs = highs,
            .lows = lows,
            .options = options,
        };
    }

    pub fn deinit(self: TransformedMCIntegrator, allocator: std.mem.Allocator) void {
        allocator.free(self.lows);
        allocator.free(self.highs);
        c_imports.gsl_matrix_free(self.cholesky_l);
    }
};

pub fn integratePosteriorDensity(
    allocator: std.mem.Allocator,
    fit: *llfit.Fit,
    lows: []f64,
    highs: []f64,
    options: MCIntegrator.MCIntegratorOptions,
) !MCIntegrator.MCIntegratorResult {
    var integral: MCIntegrator = try .init(allocator, fit, lows, highs, options);
    defer integral.deinit(allocator);
    return try integral.integrate(allocator);
}
