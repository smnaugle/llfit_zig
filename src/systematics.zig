const Signal = @import("signal.zig").Signal;

pub const Systematic = struct {
    value: f64 = undefined,
    expectation: f64 = undefined,
    sigma: f64 = undefined,
    applySystematicFn: *const fn (*Signal) []f64 = undefined,

    const SystematicOptions = struct {
        value: f64 = undefined,
        expectation: f64 = undefined,
        sigma: f64 = undefined,
    };
    pub fn init(options: SystematicOptions) Systematic {
        var sys = Systematic{};
        sys.value = options.value;
        sys.expectation = options.value;
        sys.sigma = options.value;
        return sys;
    }

    pub fn applySystematic(self: *Systematic, signal: *Signal) void {
        _ = self.applySystematicFn(signal);
    }
};

