const std = @import("std");

pub fn zeroArray(array: []f64) void {
    for (array) |*elem| {
        elem.* = 0;
    }
}

pub fn linearSpacedBins(allocator: std.mem.Allocator, comptime T: type, start: T, stop: T, nbins: usize) ![]T {
    switch (@typeInfo(T)) {
        .float => {},
        inline else => @compileError("Cannot create bins from non-float inputs"),
    }
    if (nbins == 0) return &.{};
    if (nbins == 1) {
        const bins = try allocator.alloc(T, 1);
        bins[0] = start;
        return bins;
    }
    var bins = try allocator.alloc(T, nbins);
    const step = (stop - start) / @as(T, @floatFromInt(nbins - 1));
    for (0..nbins) |idx| {
        bins[idx] = start + @as(f64, @floatFromInt(idx)) * step;
    }
    return bins;
}

pub fn interp(comptime T: type, xs: []const T, ys: []const T, pt: T) T {
    const Cmp = struct {
        pub fn comp(context: T, item: T) std.math.Order {
            return std.math.order(context, item);
        }
    };
    var ub = std.sort.upperBound(f64, xs, pt, Cmp.comp);
    if (ub == xs.len) {
        // Occurs when pt > xs[-1], but we handle this gracefully if we just
        // index the last element in xs
        ub -= 1;
    }
    if (ub == 0) {
        return std.math.lerp(ys[1], ys[0], (xs[1] - pt) / (xs[1] - xs[0]));
    } else {
        return std.math.lerp(ys[ub - 1], ys[ub], (pt - xs[ub - 1]) / (xs[ub] - xs[ub - 1]));
    }
}

test "interp" {
    const inner = struct {
        fn doTest(xs: []const f64, ys: []const f64, x: f64, exp: f64) !void {
            const tp = interp(f64, xs, ys, x);
            std.testing.expect(std.math.approxEqRel(f64, tp, exp, @sqrt(std.math.floatEps(f64)))) catch |e| {
                std.log.err("Interp at {d} got {d} not {d}", .{ x, tp, exp });
                return e;
            };
        }
    };

    const xs = [_]f64{ 1, 2, 3, 4, 5 };
    const ys = [_]f64{ 3, 2, 3, 1, 5 };

    try inner.doTest(&xs, &ys, 1.1, 2.9);
    try inner.doTest(&xs, &ys, 1, 3);
    try inner.doTest(&xs, &ys, 5, 5);
    try inner.doTest(&xs, &ys, 6, 9);
    try inner.doTest(&xs, &ys, 3, 3);
    try inner.doTest(&xs, &ys, -1, 5);
}
