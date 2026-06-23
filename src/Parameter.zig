const std = @import("std");

pub const Parameter = @This();

value: f64 = 1,
expectation: f64 = 1,
sigma: f64 = std.math.inf(f64),
name: []const u8 = "",
free: bool = true,
bounds: [2]f64 = .{ 0, std.math.inf(f64) },

pub fn setFrom(self: *Parameter, other: Parameter) void {
    for (@typeInfo(self).@"struct".fields) |field| {
        @field(self, field.name) = @field(other, field.name);
    }
}

pub fn copyShallow(self: Parameter) Parameter {
    return .{
        .value = self.value,
        .expectation = self.expectation,
        .sigma = self.sigma,
        .name = self.name,
        .free = self.free,
        .bounds = self.bounds,
    };
}
