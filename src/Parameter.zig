const std = @import("std");

pub const Parameter = @This();

value: f64 = 1,
expectation: f64 = 1,
sigma: f64 = std.math.inf(f64),
name: []const u8 = "",
free: bool = true,
bounds: [2]f64 = .{ 0, std.math.inf(f64) },
