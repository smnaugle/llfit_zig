const std = @import("std");

const fit = @import("llfit");

fn scale(sys: *fit.Systematic, sig: *fit.Signal) void {
    std.debug.print("scaling\n", .{});
    const energies = sig._scratch_points[0];
    for (energies) |*e| {
        e.* *= sys.value;
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
    const energy_shift = try fitter.addSystematic(.{ .name = "energy_shift", .value = 2, .applySystematicFn = &scale });
    const edim = try ppo.addDimension("energy", &.{ 1, 2, 3, 4, 5 });
    const rdim = try ppo.addDimension("radius", &.{ 0, 1000, 2000, 3000 });
    try ppo.addData(&.{
        .{ .dimension = edim, .points = &.{ 1.2, 1.2, 4.5 } },
        .{ .dimension = rdim, .points = &.{ 100, 400, 2500 } },
    });
    const bipo214 = try ppo.addSignal("Bipo214", &.{
        .{ .dimension = edim, .points = &.{ 1.2, 1.2, 4.5 } },
        .{ .dimension = rdim, .points = &.{ 100, 400, 2500 } },
    });
    try bipo214.addSystematic(energy_shift);
    const probs = try bipo214.getProbability();
    std.debug.print("hist: {any}\n", .{probs});
    std.debug.print("data: {any}\n", .{ppo.data_counts});
}
