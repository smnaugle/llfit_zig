const std = @import("std");

pub fn build(b: *std.Build) void {
    const nlopt_path = b.option([]const u8, "nlopt_install_dir", "Path where NLOPT is installed") orelse "";
    var nlopt_inc_path: []u8 = "";
    const has_nlopt_path = !std.mem.eql(u8, nlopt_path, "");
    if (has_nlopt_path) {
        nlopt_inc_path = b.fmt("{s}/include", .{nlopt_path});
        b.addSearchPrefix(nlopt_path);
    } else {
        std.log.warn("nlopt_install_dir build option is not set, assuming that the library is installed on default path", .{});
    }

    const target = std.Build.standardTargetOptions(b, .{});
    const optimize = std.Build.standardOptimizeOption(b, .{});
    const mod = b.addModule("llfit", .{
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/root.zig"),
    });
    const lib = b.addLibrary(.{
        .name = "llfit",
        .root_module = mod,
    });
    if (has_nlopt_path) {
        lib.root_module.addSystemIncludePath(.{ .cwd_relative = nlopt_inc_path });
    }
    lib.root_module.linkSystemLibrary("nlopt", .{});
    b.installArtifact(lib);
    const exe = b.addExecutable(.{
        .name = "llfit_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("llfit", lib.root_module);
    if (has_nlopt_path) {
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = nlopt_inc_path });
    }
    b.installArtifact(exe);
}
