const std = @import("std");
const config = @import("config");

const Allocator = @import("std").mem.Allocator;

const utilities = @import("utilities.zig");
const Parameter = @import("Parameter.zig");
const Histogram = @import("histogram.zig").Histogram;

pub const Systematic = struct {
    const Profiling = struct {
        pub fn start(self: Profiling) void {
            self.stamp = .now(self.io, self.timer);
        }
        pub fn end(self: Profiling) void {
            self.num_runs += 1;
            const dt = self.stamp.durationTo(.now(self.io, self.timer));
            self.tot_time += dt.toMicroseconds();
        }
        tot_time: i64 = 0,
        num_runs: i64 = 0,
        timer: std.Io.Clock = .real,
        io: std.Io.Threaded = .init_single_threaded,
        stamp: std.Io.Timestamp = .zero,
    };
    pub const SystematicOptions = struct {
        value: f64 = 1,
        expectation: ?f64 = null,
        sigma: f64 = std.math.inf(f64),
        bounds: [2]f64 = .{ 0, std.math.inf(f64) },
        free: bool = false,
    };

    profiling: Profiling = .{},

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        apply: *const fn (ptr: *anyopaque, *Histogram) void,
        getParams: *const fn (ptr: *anyopaque) []const *Parameter,
    };

    pub fn apply(self: Systematic, histogram: *Histogram) void {
        if (comptime config.systematic_profiling) self.profiling.start();
        defer if (comptime config.systematic_profiling) self.profiling.end();
        self.vtable.apply(self.ptr, histogram);
    }

    pub fn getParams(self: Systematic) []const *Parameter {
        return self.vtable.getParams(self.ptr);
    }
};

pub fn DomainSystematic(tranformation: enum { shift, scale }) type {
    return struct {
        parameter: Parameter,
        dimension: usize,
        slice_iter_buf: []u8,
        bin_centers: []f64,

        pub fn init(allocator: Allocator, parameter: Parameter, bins: []const f64, dimension: usize) !@This() {
            // Dupe name to guarantee ownership
            var owned_param = parameter.copyShallow();
            owned_param.name = try allocator.dupe(u8, parameter.name);

            const nbins = bins.len - 1;
            const iter_buf = try allocator.alloc(u8, @sizeOf(*f64) * nbins + @sizeOf(f64) * nbins * 2);

            const bin_centers = try allocator.alloc(f64, nbins);
            for (0..nbins) |idx| {
                bin_centers[idx] = (bins[idx] + bins[idx + 1]) / 2;
            }
            return .{
                .parameter = owned_param,
                .dimension = dimension,
                .slice_iter_buf = iter_buf,
                .bin_centers = bin_centers,
            };
        }

        fn allocError(err: anyerror) noreturn {
            std.log.err("{any}", .{err});
            std.debug.panic("", .{});
        }

        pub fn apply(ptr: *anyopaque, hist: *Histogram) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var fba = std.heap.FixedBufferAllocator.init(self.slice_iter_buf);

            const slice = fba.allocator().alloc(f64, self.bin_centers.len) catch |e| allocError(e);

            var iter = hist.sliceIterator(fba.allocator(), self.dimension) catch |e| allocError(e);
            while (iter.next()) |ptr_slice| {
                for (0..slice.len) |bin_idx| {
                    slice[bin_idx] = ptr_slice[bin_idx].*;
                }
                var old_sum: f64 = 0;
                var new_sum: f64 = 0;
                for (0..ptr_slice.len) |bin_idx| {
                    const x = self.bin_centers[bin_idx];
                    old_sum += ptr_slice[bin_idx].*;
                    var interp_val: f64 = undefined;
                    switch (tranformation) {
                        .scale => {
                            interp_val = utilities.interp(f64, self.bin_centers, slice, x / self.parameter.value);
                        },
                        .shift => {
                            interp_val = utilities.interp(f64, self.bin_centers, slice, x - self.parameter.value);
                        },
                    }
                    interp_val = std.math.clamp(interp_val, 0, std.math.inf(f64));
                    ptr_slice[bin_idx].* = interp_val;
                    new_sum += ptr_slice[bin_idx].*;
                }

                const factor = old_sum / new_sum;
                if (new_sum != 0 and std.math.isFinite(factor)) {
                    for (0..ptr_slice.len) |bin_idx| ptr_slice[bin_idx].* *= factor;
                } else {
                    for (0..ptr_slice.len) |bin_idx| ptr_slice[bin_idx].* = 0;
                }
            }
        }

        pub fn getParams(ptr: *anyopaque) []const *Parameter {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return &.{&self.parameter};
        }

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.parameter.name);
            allocator.free(self.bin_centers);
            allocator.free(self.slice_iter_buf);
        }

        pub fn toSystematic(self: *@This()) Systematic {
            return .{
                .vtable = &.{
                    .apply = apply,
                    .getParams = getParams,
                },
                .ptr = @ptrCast(self),
            };
        }
    };
}
pub const ShiftSystematic = DomainSystematic(.shift);
pub const ScaleSystematic = DomainSystematic(.scale);

fn testMatch(la: []f64, lb: []f64) bool {
    var allmatch: bool = true;
    for (0..la.len) |idx| {
        const a = la[idx];
        const b = lb[idx];
        var resid: f64 = 0;
        if (a > 1) {
            resid = @abs((b - a) / @sqrt(a));
        } else {
            resid = @abs(b - a / 1);
        }
        if (resid > 3) {
            std.log.err("{d}, {d}, {d}", .{ a, b, resid });
            allmatch = false;
        }
    }
    return allmatch;
}

test "shift_test" {
    const alloc = std.testing.allocator;
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const bins = try utilities.linearSpacedBins(alloc, f64, -5, 5, 20);
    defer alloc.free(bins);

    var shift: ShiftSystematic = try .init(alloc, .{ .value = 0, .name = "shift", .bounds = [2]f64{ -1, 1 }, .free = true }, bins, 0);
    defer shift.deinit(alloc);

    var points: [10000]f64 = undefined;
    for (0..points.len) |idx| points[idx] = rng.random().floatNorm(f64);
    var hist: Histogram = try .init(alloc, &.{bins}, &.{&points}, .{});
    defer hist.deinit();
    const contents = try arena.allocator().dupe(f64, hist.contents);

    shift.toSystematic().apply(&hist);
    try std.testing.expect(std.mem.eql(f64, contents, hist.contents));

    shift.parameter.value = 0.5;
    for (0..points.len) |idx| points[idx] += shift.parameter.value;
    const shift_hist: Histogram = try .init(alloc, &.{bins}, &.{&points}, .{});
    defer shift_hist.deinit();
    shift.toSystematic().apply(&hist);

    const allmatch = testMatch(shift_hist.contents, hist.contents);

    std.testing.expect(allmatch) catch |e| {
        var string = try arena.allocator().print("Non-matching bins\n", .{});
        for (0..shift_hist.contents.len) |idx| {
            const s = try arena.allocator().print("\t{d} vs {d}\n", .{ shift_hist.contents[idx], hist.contents[idx] });
            string = try std.mem.concat(arena.allocator(), u8, &.{ string, s });
        }
        std.log.err("{s}", .{string});
        std.log.err("{any}", .{e});
        return e;
    };
}

test "scale_test" {
    const alloc = std.testing.allocator;
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const bins = try utilities.linearSpacedBins(alloc, f64, -5, 5, 20);
    defer alloc.free(bins);

    var shift: ScaleSystematic = try .init(alloc, .{ .value = 1, .name = "scale", .bounds = [2]f64{ 0.1, 2 }, .free = true }, bins, 0);
    defer shift.deinit(alloc);

    var points: [10000]f64 = undefined;
    for (0..points.len) |idx| points[idx] = rng.random().floatNorm(f64);
    var hist: Histogram = try .init(alloc, &.{bins}, &.{&points}, .{});
    defer hist.deinit();
    const contents = try arena.allocator().dupe(f64, hist.contents);

    shift.toSystematic().apply(&hist);
    try std.testing.expect(std.mem.eql(f64, contents, hist.contents));

    shift.parameter.value = 0.5;
    for (0..points.len) |idx| points[idx] *= shift.parameter.value;
    const shift_hist: Histogram = try .init(alloc, &.{bins}, &.{&points}, .{});
    defer shift_hist.deinit();
    shift.toSystematic().apply(&hist);

    const allmatch = testMatch(shift_hist.contents, hist.contents);

    std.testing.expect(allmatch) catch |e| {
        var string = try arena.allocator().print("Non-matching bins\n", .{});
        for (0..shift_hist.contents.len) |idx| {
            const s = try arena.allocator().print("\t{d} vs {d}\n", .{ shift_hist.contents[idx], hist.contents[idx] });
            string = try std.mem.concat(arena.allocator(), u8, &.{ string, s });
        }
        std.log.err("{s}", .{string});
        std.log.err("{any}", .{e});
        return e;
    };
}

// TODO:
pub const SmearSystematic = struct {
    parameter: Parameter,
    dimension: usize,
    slice_iter_buf: []u8,
    bin_centers: []f64,

    pub fn init(allocator: Allocator, parameter: Parameter, bins: []const f64, dimension: usize) !@This() {
        // Dupe name to guarantee ownership
        var owned_param = parameter.copyShallow();
        owned_param.name = try allocator.dupe(u8, parameter.name);

        const nbins = bins.len - 1;
        const iter_buf = try allocator.alloc(u8, @sizeOf(*f64) * nbins + @sizeOf(f64) * nbins * 2);

        const bin_centers = try allocator.alloc(f64, nbins);
        for (0..nbins) |idx| {
            bin_centers[idx] = (bins[idx] + bins[idx + 1]) / 2;
        }
        return .{
            .parameter = owned_param,
            .dimension = dimension,
            .slice_iter_buf = iter_buf,
            .bin_centers = bin_centers,
        };
    }
};
