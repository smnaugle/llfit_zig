const std = @import("std");
const config = @import("config");

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
    const Profiling = struct {
        tot_time: i64 = 0,
        num_runs: i64 = 0,
        timer: std.Io.Clock = .real,
        io: std.Io.Threaded = .init_single_threaded,
    };
    name: []const u8 = "",
    parameter: Parameter = .{},
    /// An optional pointer to allow for the storage of additional state.
    data: ?*anyopaque = null,

    // The systematics can be applied directly to the signal, no need to return anything
    applySystematicFn: FuncType = noTransform,

    profiling: Profiling = .{},

    pub const SystematicOptions = struct {
        name: []const u8,
        value: f64 = 1,
        expectation: ?f64 = null,
        sigma: f64 = std.math.inf(f64),
        bounds: [2]f64 = .{ 0, std.math.inf(f64) },
        free: bool = false,
        applySystematicFn: FuncType = noTransform,
        data: ?*anyopaque = null,
    };
    pub fn init(options: SystematicOptions) Systematic {
        var sys = Systematic{};
        sys.name = options.name;
        sys.parameter.name = options.name;
        sys.parameter.value = options.value;
        if (options.expectation) |expectation| {
            sys.parameter.expectation = expectation;
        } else {
            sys.parameter.expectation = options.value;
        }
        sys.parameter.sigma = options.sigma;
        sys.parameter.bounds = options.bounds;
        sys.parameter.free = options.free;
        sys.applySystematicFn = options.applySystematicFn;
        sys.data = options.data;
        return sys;
    }
    pub fn deinit(self: *Systematic) void {
        _ = self;
        return;
    }

    pub fn applySystematic(self: *Systematic, signal: *Signal) void {
        var start: std.Io.Timestamp = .zero;
        if (comptime config.systematic_profiling) start = self.profiling.timer.now(self.profiling.io.io());
        self.applySystematicFn(self, signal);
        if (comptime config.systematic_profiling) {
            const end = self.profiling.timer.now(self.profiling.io.io());
            const dt = start.durationTo(end).toMicroseconds();
            self.profiling.tot_time += dt;
            self.profiling.num_runs += 1;
        }
    }
};
