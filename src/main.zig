const std = @import("std");

const fit = @import("llfit");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Memory leak...\n", .{});
    };
    const allocator = gpa.allocator();
    var fitter: fit.Fit = .init(allocator, "fit");
    defer fitter.deinit();
    const ppo = try fitter.addDataset("ppo");
    const energy_shift = try fitter.addSystematic(.{ .name = "energy_shift" });
    const edim = try ppo.addDimension("energy", &.{ 1, 2, 3, 4, 5 });
    const bipo214 = try ppo.addSignal("Bipo214", &.{
        .{ .dimension = edim, .points = &.{ 1, 2, 4 } },
        .{ .dimension = edim, .points = &.{ 1, 2, 4 } },
    });
    try bipo214.addSystematic(energy_shift);
    // var dim = try fit.Dimension.init(
    //     allocator,
    //     "energy",
    //     &[_]f64{ 1, 2, 3, 4, 5 },
    // );
    // defer dim.deinit();
    // var esyst = fit.Systematic.init(.{ .expectation = 1, .sigma = 1, .value = 1 });
    // var sig = try fit.Signal.init(allocator, "test");
    // defer sig.deinit();
    // try sig.addSystematic(&esyst);
    // std.debug.print("dim {}\n", .{dim});
    // std.debug.print("syst {}\n", .{esyst});
    // std.debug.print("sig {}\n", .{sig});
    std.debug.print("fit: {}\n", .{fitter});
    std.debug.print("dataset: {s}\n", .{ppo.name});
    std.debug.print("eshift: {s}\n", .{energy_shift.name});
    std.debug.print("edim: {s}\n", .{edim.name});
    std.debug.print("signal: {}\n", .{bipo214.*});
    std.debug.print("systematic: {}\n", .{bipo214.systematics.items[0].*});
}
