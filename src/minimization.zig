const std = @import("std");

const llfit = @import("fit.zig");
const nlopt = @cImport({
    @cInclude("nlopt.h");
});

pub fn wrapperNLL(opt: c_uint, xs: [*c]const f64, grad: [*c]f64, fit_ptr: ?*anyopaque) callconv(.c) f64 {
    if (@intFromPtr(grad) != 0) {
        std.debug.panic("non-null grad", .{});
    }
    const fit: *llfit.Fit = @ptrCast(@alignCast(fit_ptr));
    std.debug.print("{s}\n", .{fit.name});
    _ = opt;
    _ = xs;
    return 0;
}

pub const FitResult = struct {
    status: i8 = 0,
    value: f64 = 0,
    xs: []f64 = undefined,
};

pub fn minimize(fit: *llfit.Fit) f64 {
    const optimizer = nlopt.nlopt_create(nlopt.NLOPT_LD_LBFGS, 10) orelse {
        std.debug.panic("Could not get optimizer", .{});
    };
    defer nlopt.nlopt_destroy(optimizer);

    const err = nlopt.nlopt_set_min_objective(optimizer, wrapperNLL, fit);
    if (err < 0) {
        std.debug.panic("Could not set optimizer objective function", .{});
    }

    var xs = [_]f64{0.9};
    const rv = wrapperNLL(@intCast(@intFromPtr(optimizer)), &xs, null, fit);

    return rv;
}
