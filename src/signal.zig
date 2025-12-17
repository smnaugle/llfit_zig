const std = @import("std");

const syts = @import("systematics.zig");
const fit = @import("root.zig");

pub const Signal = struct {
    value: f64 = 0,
    expectation: f64 = 0,
    sigma: f64 = std.math.inf(f64),
    name: []const u8 = "",

    input_mc: fit.DataPoints = undefined,
    systematics: std.ArrayList(*syts.Systematic) = .{},

    _allocator: std.mem.Allocator = undefined,

    pub const DimensionPoints = struct {
        dimension: *fit.Dimension = undefined,
        points: []const f64 = &.{},
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, points: []const Signal.DimensionPoints) !Signal {
        var sig = Signal{};
        sig._allocator = allocator;
        sig.input_mc = .init(allocator);
        for (points) |p| {
            try sig.input_mc.putNoClobber(p.dimension.name, try sig._allocator.dupe(f64, p.points));
        }
        sig.name = name;
        return sig;
    }

    pub fn deinit(self: *Signal) void {
        var mc_iter = self.input_mc.iterator();
        while (mc_iter.next()) |it| {
            const value = it.value_ptr;
            self._allocator.free(value.*);
        }
        self.input_mc.deinit();
        self.systematics.deinit(self._allocator);
    }

    pub fn addSystematic(self: *Signal, systematic: *syts.Systematic) !void {
        try self.systematics.append(self._allocator, systematic);
    }

    pub fn getProbability(self: *Signal, xs: []f64) [][]f64 {
        _ = self;
        _ = xs;
    }
};
