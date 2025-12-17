const std = @import("std");

const Signal = @import("signal.zig").Signal;
const Dimension = @import("Dimension.zig");

pub fn noTransform(systematic: *Systematic, signal: *Signal) void {
    _ = signal;
    _ = systematic;
    return;
}

const FuncType = *const fn (*Systematic, *Signal) void;

pub const Systematic = struct {
    name: []const u8 = "",
    value: f64 = undefined,
    expectation: f64 = undefined,
    sigma: f64 = undefined,
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
        sys.name = options.name;
        sys.value = options.value;
        if (options.expectation) |expectation| {
            sys.expectation = expectation;
        } else {
            sys.expectation = options.value;
        }
        sys.sigma = options.value;
        sys.applySystematicFn = options.applySystematicFn;
        return sys;
    }
    pub fn deinit(self: *Systematic) void {
        _ = self;
        return;
    }

    pub fn applySystematic(self: *Systematic, signal: *Signal) void {
        self.applySystematicFn(signal);
    }
};
