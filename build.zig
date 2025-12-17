const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = std.Build.standardTargetOptions(b, .{});
    const optimize = std.Build.standardOptimizeOption(b, .{ .preferred_optimize_mode = .Debug });
    const mod = b.addModule("llfit", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "llfit_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("llfit", mod);
    b.installArtifact(exe);
}
