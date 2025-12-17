const std = @import("std");

const syts = @import("systematics.zig");
const fit = @import("root.zig");

// TODO: Implement interface for signals to support binned and KDE PDFs.
pub const Signal = struct {
    value: f64 = 0,
    expectation: f64 = 0,
    sigma: f64 = std.math.inf(f64),
    name: []const u8 = "",

    input_mc: fit.DataPoints = undefined,
    systematics: std.ArrayList(*syts.Systematic) = .empty,
    needs_binning: bool = true,
    dimensions: []*fit.Dimension = &.{},

    _allocator: std.mem.Allocator = undefined,
    _last_counts: [][]f64 = &.{},

    pub const DimensionPoints = struct {
        dimension: *fit.Dimension = undefined,
        points: []const f64 = &.{},
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, points: []const Signal.DimensionPoints) !Signal {
        var sig = Signal{};
        sig._allocator = allocator;
        sig.input_mc = .init(allocator);
        sig.dimensions = try allocator.alloc(*fit.Dimension, points.len);
        for (points, 0..) |p, idx| {
            try sig.input_mc.putNoClobber(p.dimension.name, try sig._allocator.dupe(f64, p.points));
            sig.dimensions[idx] = p.dimension;
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
        self._allocator.free(self.dimensions);
        self.input_mc.deinit();
        self.systematics.deinit(self._allocator);
    }

    /// Add a systematic effect to the signal
    ///
    /// Systematics are applied in the order they are added to the signal.
    /// If a systematic bins the data, ie a resolution systematic, it must be
    /// added last and it __must__ bin the data and then set the `Signal.needs_binning`
    /// flag to false.
    pub fn addSystematic(self: *Signal, systematic: *syts.Systematic) !void {
        try self.systematics.append(self._allocator, systematic);
    }

    pub fn getProbability(self: *Signal) [][]f64 {
        for (self.systematics.items) |systematic| {
            systematic.applySystematic(self);
        }
        if (self.needs_binning) {
            // self._last_counts = util.binData(self.input_mc);
            self.needs_binning = false;
        }
    }
};
