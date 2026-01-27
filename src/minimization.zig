const std = @import("std");

const llfit = @import("fit.zig");
const nlopt = @cImport({
    @cInclude("nlopt.h");
});

var count: u64 = 1;
const MSG_COUNT = 100;
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
        ret = 1e200;
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

    pub fn format(self: FitResult, writer: *std.io.Writer) !void {
        try writer.print("{{status: {d}, status_string: {s}, value: {d}}}", .{ self.status, self.status_string, self.value });
    }
};

pub fn minimize(fit: *llfit.Fit) !FitResult {
    const optimizer = nlopt.nlopt_create(nlopt.NLOPT_LN_NELDERMEAD, @intCast(fit._free.items.len)) orelse {
        std.debug.panic("Could not get optimizer", .{});
    };
    defer nlopt.nlopt_destroy(optimizer);

    if (nlopt.nlopt_set_min_objective(optimizer, wrapperNLL, fit) < 0) {
        std.debug.panic("Could not set optimizer objective function", .{});
    }

    _ = nlopt.nlopt_set_ftol_abs(optimizer, 1e-5);

    var lbs = try fit._allocator.alloc(f64, fit._free.items.len);
    defer fit._allocator.free(lbs);
    var ubs = try fit._allocator.alloc(f64, fit._free.items.len);
    defer fit._allocator.free(ubs);
    var xs = try fit._allocator.alloc(f64, fit._free.items.len);
    defer fit._allocator.free(xs);
    for (fit._free.items, 0..) |param, idx| {
        xs[idx] = param.value;
        lbs[idx] = param.bounds[0];
        ubs[idx] = param.bounds[1];
    }
    if (nlopt.nlopt_set_lower_bounds(optimizer, lbs.ptr) < 0) {
        std.debug.panic("Could not set lower bounds {any}", .{lbs});
    }
    if (nlopt.nlopt_set_upper_bounds(optimizer, ubs.ptr) < 0) {
        std.debug.panic("Could not set upper bounds {any}", .{ubs});
    }
    var res: f64 = 0;
    const opt_code = nlopt.nlopt_optimize(optimizer, xs.ptr, &res);
    const fit_result: FitResult = .{ .value = res, .status = @intCast(opt_code), .status_string = std.mem.span(nlopt.nlopt_result_to_string(opt_code)) };
    return fit_result;
}
