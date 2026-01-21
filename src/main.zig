const std = @import("std");

const fit = @import("llfit");

fn scale(sys: *fit.Systematic, sig: *fit.Signal) void {
    const energies = sig._scratch_points[0];
    for (energies) |*e| {
        e.* *= sys.parameter.value;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Memory leak...\n", .{});
    };
    const allocator = gpa.allocator();
    var fitter: fit.Fit = .init(allocator, "fit");
    defer fitter.deinit();
    const ppo = try fitter.addDataset("ppo");
    const energy_shift = try fitter.addSystematic(.{ .name = "energy_shift", .value = 1, .expectation = 1.0, .sigma = 0.01, .applySystematicFn = &scale });
    _ = try ppo.addDimension("energy", &.{ 1, 2, 3, 4, 5 });
    _ = try ppo.addDimension("radius", &.{ 0, 1000, 2000, 3000 });
    try ppo.addData(&.{
        .{ .dimension_name = "energy", .points = &.{ 1.2, 1.2, 3.3, 3.2, 4.2, 4.5 } },
        .{ .dimension_name = "radius", .points = &.{ 100, 400, 2000, 1500, 1200, 2500 } },
    });
    const bipo214 = try ppo.addSignal("Bipo214", &.{
        .{ .dimension_name = "energy", .points = &.{ 1.2, 1.2, 1.5 } },
        .{ .dimension_name = "radius", .points = &.{ 100, 400, 2500 } },
    });
    const tl208 = try ppo.addSignal("Tl208", &.{
        .{ .dimension_name = "energy", .points = &.{ 3.2, 4.2, 4.5 } },
        .{ .dimension_name = "radius", .points = &.{ 100, 400, 2500 } },
    });
    try bipo214.addSystematic(energy_shift);
    try tl208.addSystematic(energy_shift);
    try fitter.updateParameters();
    const probs = try bipo214.getProbability();
    std.debug.print("hist: {any}\n", .{probs});
    std.debug.print("data: {any}\n", .{ppo.data_counts});
    std.debug.print("eval: {d}\n", .{fitter.getNLL()});
    std.debug.print("eval: {f}\n", .{try fitter.minimize()});
    for (fitter._parameters.items) |sig| {
        std.debug.print("{s}\n", .{sig.name});
        std.debug.print("{d}\n", .{sig.value});
    }
}
