const std = @import("std");

pub fn build(b: *std.Build) void {
    const nlopt_dep = b.dependency("nlopt", .{});
    const nlopt_src = nlopt_dep.builder.build_root.path.?;
    const nlopt_build_dir = b.cache_root.join(b.allocator, &.{"nlopt_build/"}) catch @panic("OOM");
    const nlopt_install_dir = b.cache_root.join(b.allocator, &.{"nlopt_install/"}) catch @panic("OOM");

    const nlopt_configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        nlopt_src,
        "-B",
        nlopt_build_dir,
        b.fmt("-DCMAKE_INSTALL_PREFIX={s}", .{nlopt_install_dir}),
        "-DCMAKE_INSTALL_MESSAGE=NEVER",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DNLOPT_CXX=OFF",
    });
    nlopt_configure.setName("Configure NLOPT");
    nlopt_configure.step.dependOn(nlopt_dep.builder.default_step);

    const nlopt_build = b.addSystemCommand(&.{
        "make",
        "-C",
        nlopt_build_dir,
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
    const nlopt_lib_path = b.pathJoin(&.{ nlopt_install_dir, "/lib" });
    lib.root_module.addLibraryPath(b.path(nlopt_lib_path));
    lib.root_module.linkSystemLibrary("nlopt", .{ .preferred_link_mode = .static });
    const nlopt_inc_path = b.pathJoin(&.{ nlopt_install_dir, "/include" });
    lib.root_module.addIncludePath(b.path(nlopt_inc_path));
    lib.use_new_linker = false;
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
    exe.step.dependOn(&lib.step);
    exe.root_module.addImport("llfit", lib.root_module);
    exe.use_new_linker = false;
    b.installArtifact(exe);
}
