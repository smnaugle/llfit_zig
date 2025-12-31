const std = @import("std");

const Signal = @import("signal.zig").Signal;
const Dimension = @import("Dimension.zig");
const Parameter = @import("Parameter.zig");

pub fn noTransform(systematic: *Systematic, signal: *Signal) void {
    _ = signal;
    _ = systematic;
    return;
}

const FuncType = *const fn (*Systematic, *Signal) void;

pub const Systematic = struct {
    parameter: Parameter = .{},

    dimensions: []const *Dimension = &.{},
    // The systematics can be applied directly to the signal, no need to return anything
    applySystematicFn: FuncType = noTransform,

    pub const SystematicOptions = struct {
        name: []const u8,
        value: f64 = 1,
        expectation: ?f64 = null,
        sigma: f64 = std.math.inf(f64),
        dimensions: []const *Dimension = &.{},
        applySystematicFn: FuncType = noTransform,
    };
    pub fn init(options: SystematicOptions) Systematic {
        var sys = Systematic{};
        sys.parameter.name = options.name;
        sys.parameter.value = options.value;
        if (options.expectation) |expectation| {
            sys.parameter.expectation = expectation;
        } else {
            sys.parameter.expectation = options.value;
        }
        sys.parameter.sigma = options.sigma;
        sys.applySystematicFn = options.applySystematicFn;
        return sys;
    }
    pub fn deinit(self: *Systematic) void {
        _ = self;
        return;
    }

    pub fn applySystematic(self: *Systematic, signal: *Signal) void {
        self.applySystematicFn(self, signal);
    }
};
