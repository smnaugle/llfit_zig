const std = @import("std");

const llfit = @import("fit.zig");
const Parameter = @import("Parameter.zig");
const nlopt = @import("c_imports");

var count: u64 = 1;
pub var MSG_COUNT: u64 = 100;
pub fn wrapperNLL(opt: c_uint, xs: [*c]const f64, grad: [*c]f64, fit_ptr: ?*anyopaque) callconv(.c) f64 {
    if (grad != null) {
        std.debug.panic("non-null grad", .{});
    }
    if (fit_ptr == null) {
        std.debug.panic("Null fit information", .{});
    }
    const fit: *llfit.Fit = @ptrCast(@alignCast(fit_ptr));
    for (fit._free.items, 0..) |param, idx| {
        param.*.value = xs[idx];
        std.log.debug("Setting {s} to {d}", .{ param.name, param.value });
    }
    _ = opt;
    var ret = fit.getNLL();

    if (!std.math.isFinite(ret)) {
        std.log.warn("nan or inf in likelihood", .{});
        for (fit._free.items) |param| {
            std.log.warn("{s} is {d}", .{ param.name, param.value });
        }
        for (fit.datasets.items) |dataset| {
            std.log.warn("Probabilities for {s}: {any}", .{ dataset.name, dataset._total_pdf_scratch });
            std.log.warn("Data counts: {any}", .{dataset.data_counts});
            ret = 1e200;
        }
    }

    std.log.debug("NLL: {d}", .{ret});
    if ((count % MSG_COUNT) == 0) {
        for (fit._free.items, 0..) |param, idx| {
            param.*.value = xs[idx];
            std.log.info("{s} is {d}", .{ param.name, param.value });
        }
        std.log.info("NLL: {d}", .{ret});
        count = 1;
    }
    count += 1;
    return ret;
}

pub const FitResult = struct {
    status: i8 = 0,
    status_string: []const u8 = &.{},
    value: f64 = 0,

    pub fn format(self: FitResult, writer: *std.Io.Writer) !void {
        try writer.print("{{status: {d}, status_string: {s}, value: {d}}}", .{ self.status, self.status_string, self.value });
    }
};

pub const Optimizer = struct {
    const VTable = struct {
        minimize: *const fn (*anyopaque, std.mem.Allocator) FitResult,
    };
    vtable: VTable,
    ptr: *anyopaque,
    fit: *llfit.Fit,

    pub fn minimize(self: Optimizer, allocator: std.mem.Allocator) FitResult {
        return self.vtable.minimize(self.ptr, allocator);
    }
};

pub const SimpleOptimizer = struct {
    fit: *llfit.Fit,
    optimizer_name: []const u8,
    maxeval: usize = 0,
    ftol_abs: ?f64 = 1e-4,
    xtol_abs: ?f64 = null,
    ftol_rel: ?f64 = null,
    xtol_rel: ?f64 = null,

    fn allocError(err: anytype) noreturn {
        std.debug.panic("Allocator error: {any}\n", .{err});
    }
    pub fn minimize(ptr: *anyopaque, allocator: std.mem.Allocator) FitResult {
        const self: *SimpleOptimizer = @ptrCast(@alignCast(ptr));

        const opt_c_str = allocator.dupeZ(u8, self.optimizer_name) catch |err| allocError(err);
        defer allocator.free(opt_c_str);
        const opt_code = nlopt.nlopt_algorithm_from_string(opt_c_str);
        const opt = nlopt.nlopt_create(opt_code, @intCast(self.fit._free.items.len)) orelse {
            std.debug.panic("Could not get optimizer", .{});
        };
        defer nlopt.nlopt_destroy(opt);

        if (nlopt.nlopt_set_min_objective(opt, wrapperNLL, self.fit) < 0) {
            std.debug.panic("Could not set optimizer objective function", .{});
        }

        if (self.ftol_abs != null and nlopt.nlopt_set_ftol_abs(opt, self.ftol_abs.?) < 0) {
            std.debug.panic("Could not set convergence tolerance", .{});
        }

        if (self.xtol_abs != null and nlopt.nlopt_set_xtol_abs1(opt, self.xtol_abs.?) < 0) {
            std.debug.panic("Could not set convergence tolerance", .{});
        }

        if (self.ftol_rel != null and nlopt.nlopt_set_ftol_rel(opt, self.ftol_rel.?) < 0) {
            std.debug.panic("Could not set convergence tolerance", .{});
        }

        if (self.xtol_rel != null and nlopt.nlopt_set_xtol_rel(opt, self.xtol_rel.?) < 0) {
            std.debug.panic("Could not set convergence tolerance", .{});
        }

        const dxs = self.fit.getStepSizes(allocator) catch |err| allocError(err);
        defer allocator.free(dxs);
        _ = nlopt.nlopt_set_initial_step(opt, dxs.ptr);
        _ = nlopt.nlopt_set_maxeval(opt, @intCast(self.maxeval));

        var lbs = allocator.alloc(f64, self.fit._free.items.len) catch |err| allocError(err);
        defer allocator.free(lbs);
        var ubs = allocator.alloc(f64, self.fit._free.items.len) catch |err| allocError(err);
        defer allocator.free(ubs);
        var xs = allocator.alloc(f64, self.fit._free.items.len) catch |err| allocError(err);
        defer allocator.free(xs);
        for (self.fit._free.items, 0..) |param, idx| {
            xs[idx] = param.value;
            lbs[idx] = param.bounds[0];
            ubs[idx] = param.bounds[1];
        }
        if (nlopt.nlopt_set_lower_bounds(opt, lbs.ptr) < 0) {
            std.debug.panic("Could not set lower bounds {any}", .{lbs});
        }
        if (nlopt.nlopt_set_upper_bounds(opt, ubs.ptr) < 0) {
            std.debug.panic("Could not set upper bounds {any}", .{ubs});
        }
        var res: f64 = 0;
        const res_code = nlopt.nlopt_optimize(opt, xs.ptr, &res);
        for (self.fit._free.items, 0..) |param, idx| {
            param.value = xs[idx];
        }
        const fit_result: FitResult = .{ .value = res, .status = @intCast(res_code), .status_string = std.mem.span(nlopt.nlopt_result_to_string(res_code)) };
        return fit_result;
    }

    pub fn optimizer(self: *SimpleOptimizer) Optimizer {
        return .{
            .ptr = self,
            .fit = self.fit,
            .vtable = .{ .minimize = SimpleOptimizer.minimize },
        };
    }
};
