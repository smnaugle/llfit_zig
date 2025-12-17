const std = @import("std");

const Signal = @import("signal.zig").Signal;

pub fn noTransform(signal: *Signal) void {
    _ = signal;
    return;
}

pub const Systematic = struct {
    name: []const u8 = "",
    value: f64 = undefined,
    expectation: f64 = undefined,
    sigma: f64 = undefined,
    // The systematics can be applied directly to the signal, no need to return anything
    applySystematicFn: *const fn (*Signal) void = noTransform,

    pub const SystematicOptions = struct {
        name: []const u8,
        value: f64 = 1,
        expectation: f64 = 1,
        sigma: f64 = std.math.inf(f64),
        applySystematicFn: *const fn (*Signal) void = undefined,
    };
    pub fn init(options: SystematicOptions) Systematic {
        var sys = Systematic{};
        sys.name = options.name;
        sys.value = options.value;
        sys.expectation = options.value;
        sys.sigma = options.value;
        sys.applySystematicFn = options.applySystematicFn;
        return sys;
    }
    pub fn deinit(self: *Systematic) void {
        _ = self;
        return;
    }

    pub fn applySystematic(self: *Systematic, signal: *Signal) void {
        _ = self.applySystematicFn(signal);
    }
};
