const std = @import("std");
const config = @import("config");

const Allocator = @import("std").mem.Allocator;

const utilities = @import("utilities.zig");
const Parameter = @import("Parameter.zig");
const Histogram = @import("histogram.zig").Histogram;
const Signal = @import("signal.zig").Signal;
const Dataset = @import("fit.zig").Dataset;

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
    name: []const u8,

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
                .name = self.parameter.name,
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
        if (resid > 5) {
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
    bins: []f64,
    bin_centers: []f64,
    gaussian_pdf: []f64,
    fine_bins: []f64,
    rebin_factor: usize = 10,

    pub fn init(allocator: Allocator, parameter: Parameter, bins: []const f64, dimension: usize) !@This() {
        // Dupe name to guarantee ownership
        var owned_param = parameter.copyShallow();
        owned_param.name = try allocator.dupe(u8, parameter.name);

        const owned_bins = try allocator.dupe(f64, bins);
        const nbins = owned_bins.len - 1;

        const bin_centers = try allocator.alloc(f64, nbins);
        for (0..nbins) |idx| {
            bin_centers[idx] = (bins[idx] + bins[idx + 1]) / 2;
        }

        //FIXME: Make this not constant
        const pdf_bins: usize = 111;
        const rebin_factor: usize = 10;
        const gauss_pdf: []f64 = try allocator.alloc(f64, pdf_bins);

        const fine_bins_len = (bins.len - 1) * rebin_factor + 1;
        const fine_bins = try utilities.linearSpacedBins(allocator, f64, bins[0], bins[bins.len - 1], fine_bins_len);

        const iter_buf = try allocator.alloc(u8, @sizeOf(*f64) * nbins + @sizeOf(f64) * nbins * 1 + @sizeOf(f64) * fine_bins.len * 3);

        return .{
            .parameter = owned_param,
            .dimension = dimension,
            .slice_iter_buf = iter_buf,
            .bin_centers = bin_centers,
            .bins = owned_bins,
            .gaussian_pdf = gauss_pdf,
            .fine_bins = fine_bins,
        };
    }

    fn gaussian(x: f64, s: f64, m: f64) f64 {
        const norm = 1 / (s * std.math.sqrt(2 * std.math.pi));
        const exp_arg = -0.5 * std.math.pow(f64, (x - m) / s, 2);
        return (1 / norm) * std.math.exp(exp_arg);
    }

    pub fn apply(ptr: *anyopaque, histogram: *Histogram) void {
        const self: *SmearSystematic = @ptrCast(@alignCast(ptr));
        if (self.parameter.value <= 0) return;
        const bins = self.bins;
        const nbins = bins.len - 1;
        var bin_centers = self.bin_centers;
        for (0..nbins) |bin_idx| bin_centers[bin_idx] = (bins[bin_idx] + bins[bin_idx + 1]) / 2;

        const new_sigma = self.parameter.value;
        if (std.math.isNan(new_sigma)) {
            std.log.err("nan sigma in smear {d}", .{self.parameter.value});
        }
        const original_bin_width = bins[1] - bins[0];
        // Divide PDF binning by factor of 10
        const rebin_factor: usize = self.rebin_factor;
        const new_bin_width: f64 = original_bin_width / @as(f64, @floatFromInt(rebin_factor));
        // if (new_bin_width > 2 * new_sigma) {
        //     syslog.warn("Using bin widths larger than 2 sigma in smearing", .{});
        //     syslog.warn("bin_width: {d}, sigma: {d}", .{ new_bin_width, new_sigma });
        // }

        // var nbins_fine: usize = @intFromFloat(std.math.ceil(new_sigma * 8 / new_bin_width));
        var nbins_fine: usize = 111;
        // Fine bins must always be centered at 0
        if (nbins_fine % 2 == 0) nbins_fine += 1;

        const midpoint = (new_bin_width * @as(f64, @floatFromInt(nbins_fine))) / 2;
        const gaussian_pdf = self.gaussian_pdf;
        var gsum: f64 = 0;
        for (0..gaussian_pdf.len) |idx| {
            const x = (@as(f64, @floatFromInt(idx)) * new_bin_width + 0.5 * new_bin_width) - midpoint;
            gaussian_pdf[idx] = gaussian(x, new_sigma, 0);
            gsum += gaussian_pdf[idx] * new_bin_width;
        }
        if (gsum != 0) {
            for (0..gaussian_pdf.len) |idx| gaussian_pdf[idx] *= 1 / gsum;
        } else {
            gaussian_pdf[@as(usize, @intFromFloat(@as(f64, @floatFromInt(gaussian_pdf.len)) / 2))] = 0;
        }

        // This is the number of bins needed to split the histogram into new finely
        // binned histogram. Not totally trivial since we have to go from bin edges
        // to bins and then add on the last bin again. That is where the + 1 comes
        // from.

        var fba: std.heap.FixedBufferAllocator = .init(self.slice_iter_buf);
        const alloc = fba.allocator();
        var hist_iter = histogram.sliceIterator(alloc, self.dimension) catch @panic("FBA OOM");

        // Some potential optimizations:
        // These allocations all only need to happen only when we generate the PDF,
        // so we could move them all into the context struct.
        // The hist slice could also live in the systematic struct.
        const smeared_hist = alloc.alloc(f64, self.fine_bins.len - 1) catch @panic("FBA OOM");
        var fine_bin_centers = alloc.alloc(f64, self.fine_bins.len - 1) catch @panic("FBA OOM");
        for (0..fine_bin_centers.len) |idx| fine_bin_centers[idx] = self.fine_bins[idx] + (self.fine_bins[idx + 1] - self.fine_bins[idx]) / 2;
        var interp_hist = alloc.alloc(f64, fine_bin_centers.len) catch @panic("FBA OOM");
        var hist_slice = alloc.alloc(f64, nbins) catch @panic("FBA OOM");
        while (hist_iter.next()) |slice| {
            // Don't bother smearing flat distributions
            var all_same: bool = true;
            for (0..slice.len) |idx| {
                if (slice[idx].* != slice[0].*) all_same = false;
                hist_slice[idx] = slice[idx].*;
            }
            if (all_same) continue;
            for (0..fine_bin_centers.len) |idx| {
                var interp = utilities.interp(f64, bin_centers, hist_slice, fine_bin_centers[idx]);
                if (interp < 0) interp = 0;
                interp_hist[idx] = interp;
            }
            for (0..interp_hist.len) |c_idx| {
                // Clear contents from last iter
                smeared_hist[c_idx] = 0;
                for (self.gaussian_pdf, 0..) |p, p_idx| {
                    const g_idx: i64 = @as(i64, @intCast(p_idx)) - @as(i64, @intCast(self.gaussian_pdf.len / 2));
                    const diff = @abs(@as(i64, @intCast(c_idx)) + g_idx);
                    if ((diff < 0) or (diff > (interp_hist.len - 1))) continue;
                    smeared_hist[c_idx] += interp_hist[diff] * p;
                }
            }
            var norm: f64 = 0;
            var new_norm: f64 = 0;
            for (0..slice.len) |idx| {
                const offset = std.math.ceil(@as(f64, @floatFromInt(self.rebin_factor)) / 2);
                const smear_idx = idx * (self.rebin_factor) + @as(usize, @intFromFloat(offset)) - 1;
                norm += slice[idx].*;
                slice[idx].* = smeared_hist[smear_idx];
                new_norm += slice[idx].*;
            }

            const factor = norm / new_norm;
            if (new_norm != 0 and std.math.isFinite(factor)) {
                for (0..nbins) |bin_idx| slice[bin_idx].* *= factor;
            } else {
                for (0..nbins) |bin_idx| slice[bin_idx].* = 0;
            }
        }
    }

    pub fn getParams(ptr: *anyopaque) []const *Parameter {
        const self: *SmearSystematic = @ptrCast(@alignCast(ptr));
        return &.{&self.parameter};
    }

    pub fn toSystematic(self: *SmearSystematic) Systematic {
        return .{ .ptr = @ptrCast(self), .name = self.parameter.name, .vtable = &.{
            .apply = apply,
            .getParams = getParams,
        } };
    }

    pub fn deinit(self: SmearSystematic, allocator: Allocator) void {
        allocator.free(self.parameter.name);
        allocator.free(self.slice_iter_buf);
        allocator.free(self.bin_centers);
        allocator.free(self.bins);
        allocator.free(self.gaussian_pdf);
        allocator.free(self.fine_bins);
    }
};

test "smear_test" {
    const alloc = std.testing.allocator;
    var rng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const bins = try utilities.linearSpacedBins(alloc, f64, -5, 5, 20);
    defer alloc.free(bins);

    var shift: SmearSystematic = try .init(alloc, .{ .free = true, .bounds = .{ 0, 1 }, .name = "smear", .value = 0.0 }, bins, 0);
    defer shift.deinit(alloc);

    var points: [10000]f64 = undefined;
    for (0..points.len) |idx| points[idx] = rng.random().floatNorm(f64);
    var hist: Histogram = try .init(alloc, &.{bins}, &.{&points}, .{});
    defer hist.deinit();

    shift.parameter.value = 0.5;
    for (0..points.len) |idx| points[idx] += rng.random().floatNorm(f64) * shift.parameter.value;
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
