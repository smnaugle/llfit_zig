const std = @import("std");

const fit = @import("llfit");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var dim = try fit.Dimension.init(
        allocator,
        "energy",
        &[_]f64{ 1, 2, 3, 4, 5 },
    );
    defer dim.deinit();
    var esyst = fit.Systematic.init(.{ .expectation = 1, .sigma = 1, .value = 1 });
    var sig = try fit.Signal.init(allocator, "test");
    try sig.addSystematic(&esyst);
    std.debug.print("dim {}\n", .{dim});
    std.debug.print("syst {}\n", .{esyst});
    std.debug.print("sig {}\n", .{sig});
}
