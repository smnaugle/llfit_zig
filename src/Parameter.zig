const std = @import("std");

const Fit = @import("root.zig").Fit;
const utilities = @import("utilities.zig");

/// This is the class that represents a parameter of a fit.
///
/// This class does not own any of it's own data because it is useful to be
/// able to move and copy parameters without thinking of memory management.
///
/// Users must take care to make sure necessary data (like names and any heap
/// allocated fields in Prior structs) have the correct lifetimes.
pub const Parameter = @This();

value: f64,
name: []const u8,
free: bool,
bounds: [2]f64,
prior: Prior = .{ .gaussian = .{} },

const Prior = union(enum) {
    gaussian: struct {
        expectation: f64 = 0,
        sigma: f64 = std.math.inf(f64),
    },
    numeric: struct {
        values: []f64 = &.{},
        probability: []f64 = &.{},
    },
    interface: struct {
        data: ?*anyopaque = null,
        prior_function: *const fn (*Parameter, ?*anyopaque) f64,
    },
};

/// Returns the __unnormalized negative__ log-likelihood value of a Gaussian penalty term
fn gaussianPenalty(value: f64, mean: f64, sigma: f64) f64 {
    return 0.5 * std.math.pow(f64, (value - mean) / sigma, 2);
}

pub fn getPriorNLL(self: *Parameter) f64 {
    switch (self.prior) {
        .gaussian => |prior| {
            return gaussianPenalty(self.value, prior.expectation, prior.sigma);
        },
        .numeric => |num| {
            return utilities.interp(f64, num.values, num.probability, self.value);
        },
        .interface => |intf| {
            return intf.prior_function(self, intf.data);
        },
    }
}

fn verifyStep(self: Parameter, step_size: f64) f64 {
    const max_tries = 100;
    var low_step: f64 = step_size;
    var low_tries: usize = 0;
    while (self.value - step_size < self.bounds[0]) : (low_tries += 1) {
        if (low_tries >= max_tries) {
            low_step = self.bounds[0];
            break;
        }
        low_step /= 2;
    }
    var high_step: f64 = step_size;
    var high_tries: usize = 0;
    while (self.value + low_step > self.bounds[1]) : (high_tries += 1) {
        if (high_tries >= max_tries) {
            high_step = self.bounds[0];
            break;
        }
        high_step /= 2;
    }
    return std.sort.min(f64, &.{ low_step, high_step }, {}, std.sort.asc(f64)).?;
}

/// Returns a reasonable step size for minimizers to move this parameter at
/// based on the prior
// TODO: Should this get a pointer to the fit and call getNLL?
pub fn getStep(self: Parameter) [2]f64 {
    switch (self.prior) {
        .gaussian => |gaussian| {
            return .{ gaussian.sigma, gaussian.sigma };
        },
        // Could update these to be based on the prior as well
        .numeric, .interface => {
            var step = self.value / 10;
            step = verifyStep(self, step);
            return .{ step, step };
        },
    }
}

pub fn setFrom(self: *Parameter, other: Parameter) void {
    inline for (@typeInfo(@TypeOf(self.*)).@"struct".fields) |field| {
        @field(self, field.name) = @field(other, field.name);
    }
}

pub fn copyShallow(self: Parameter) Parameter {
    return .{
        .value = self.value,
        .name = self.name,
        .free = self.free,
        .bounds = self.bounds,
        .prior = self.prior,
    };
}

pub fn clampValue(self: Parameter, value: f64) f64 {
    if (value < self.bounds[0]) return self.bounds[0];
    if (value > self.bounds[1]) return self.bounds[1];
    return value;
}

pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{s}: {d}\n", .{ self.name, self.value });
}
