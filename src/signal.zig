const std = @import("std");

const syts = @import("systematics.zig");

pub const Signal = struct {
    value: f64 = 0,
    expectation: f64 = 0,
    sigma: f64 = std.math.inf(f64),
    name: []const u8 = "",

    input_mc: std.AutoHashMap([]const u8, []f64) = undefined,
    systematics: std.ArrayList(*syts.Systematic) = .{},

    _allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Signal {
        var sig = Signal{};
        sig._allocator = allocator;
        sig.input_mc = .init(sig._allocator);
        sig.name = name;
        return sig;
    }

    pub fn addSystematic(self: *Signal, systematic: *syts.Systematic) !void {
        try self.systematics.append(self._allocator, systematic);
    }

    pub fn getProbability(self: *Signal, xs: []f64) [][]f64 {
        _ = self;
        _ = xs;
    }
};
