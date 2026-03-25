const std = @import("std");

pub fn build(b: *std.Build) void {
    const nlopt_dep = b.dependency("nlopt", .{});
    const nlopt_src = nlopt_dep.path("");
    const nlopt_build_dir = b.path(".zig-cache/nlopt_build/");
    const nlopt_install_dir = b.path(".zig-cache/nlopt_install/");
    const nlopt_configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        nlopt_src.getPath(b),
        "-B",
        nlopt_build_dir.getPath(b),
        b.fmt("-DCMAKE_INSTALL_PREFIX={s}", .{nlopt_install_dir.getPath(b)}),
        "-DCMAKE_INSTALL_MESSAGE=NEVER",
    });
    nlopt_configure.setName("Configure NLOPT");

    const nlopt_build = b.addSystemCommand(&.{
        "make",
        "-C",
        nlopt_build_dir.getPath(b),
        "install",
    });
    nlopt_build.setName("Make and install NLOPT");
    nlopt_build.step.dependOn(&nlopt_configure.step);

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
    lib.step.dependOn(&nlopt_build.step);
    lib.root_module.addLibraryPath(nlopt_install_dir.path(b, "lib"));
    lib.root_module.linkSystemLibrary("nlopt", .{});
    lib.root_module.addSystemIncludePath(nlopt_install_dir.path(b, "include"));
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
    exe.step.dependOn(&nlopt_build.step);
    exe.root_module.addImport("llfit", lib.root_module);
    b.installArtifact(exe);
}
