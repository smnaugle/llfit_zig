const std = @import("std");
const fit = @import("fit.zig");
pub const DataPoints = struct { dimension_name: []const u8 = &.{}, points: []const f64 = &.{} };
pub const Fit = fit.Fit;
pub const Dataset = fit.Dataset;
pub const Dimension = @import("Dimension.zig");
pub const Signal = @import("signal.zig").Signal;
pub const SystematicOptions = @import("systematics.zig").Systematic.SystematicOptions;
pub const Systematic = @import("systematics.zig").Systematic;
pub const Histogram = @import("histogram.zig").Histogram;
pub const DimensionPoints = struct { dimension: *Dimension = undefined, points: []const f64 = &.{} };

pub const Parameter = @import("Parameter.zig");

const utilities = @import("utilities.zig");
pub const linearSpacedBins = utilities.linearSpacedBins;

pub const minimization = @import("minimization.zig");
