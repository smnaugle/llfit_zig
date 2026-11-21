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

    var io: std.Io.Threaded = .init_single_threaded;
    defer io.deinit();

    const allocator = gpa.allocator();
    var fitter: fit.Fit = try .init(allocator, "fit");
    defer fitter.deinit();
    const ppo = try fitter.addDataset("ppo");
    _ = try ppo.addDimension("energy", &.{ 1, 2, 3, 4, 5 });
    _ = try ppo.addDimension("radius", &.{ 0, 1000, 2000, 3000 });
    var eshift_syst: fit.ShiftSystematic = try .init(
        allocator,
        .{
            .name = "energy_shift",
            .value = 0.0,
            .free = true,
            .bounds = [2]f64{ -10, 10 },
        },
        ppo.dimensions.items[0].bins,
        0,
    );
    defer eshift_syst.deinit(allocator);
    try fitter.addSystematic(eshift_syst.toSystematic());
    try ppo.addData(&.{
        .{ .dimension_name = "energy", .points = &.{ 1.2, 1.2, 3.3, 3.2, 4.2, 4.5 } },
        .{ .dimension_name = "radius", .points = &.{ 100, 400, 2000, 1500, 1200, 2500 } },
    });
    const bipo214 = try ppo.addSignal(
        "Bipo214",
        &.{
            .{ .dimension_name = "energy", .points = &.{ 1.2, 1.2, 1.5 } },
            .{ .dimension_name = "radius", .points = &.{ 100, 400, 2500 } },
        },
        .{},
    );
    const tl208 = try ppo.addSignal(
        "Tl208",
        &.{
            .{ .dimension_name = "energy", .points = &.{ 3.2, 4.2, 4.5 } },
            .{ .dimension_name = "radius", .points = &.{ 100, 400, 2500 } },
        },
        .{},
    );
    _ = tl208;
    try ppo.linkSystematic("energy_shift");
    try fitter.updateParameters();
    const probs = bipo214.getProbability();
    std.debug.print("hist: {any}\n", .{probs});
    std.debug.print("data: {any}\n", .{ppo.data_counts});
    std.debug.print("eval: {d}\n", .{fitter.getNLL()});
    std.debug.print("eval: {f}\n", .{fitter.minimize(null)});
    for (fitter._parameters.items) |sig| {
        std.debug.print("{s}\n", .{sig.name});
        std.debug.print("{d}\n", .{sig.value});
    }
}
