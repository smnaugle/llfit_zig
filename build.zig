const std = @import("std");

pub fn build(b: *std.Build) void {
    const nlopt_dep = b.dependency("nlopt", .{});

    const nlopt_src = nlopt_dep.path("");
    const nlopt_build_dir = b.cache_root.join(b.allocator, &.{"nlopt_build"}) catch unreachable;
    const nlopt_install_dir = b.cache_root.join(b.allocator, &.{"nlopt_install"}) catch unreachable;

    const nlopt_lib_file = b.pathJoin(&.{ nlopt_install_dir, "lib/libnlopt.so" });
    const lib_exists = if (std.fs.accessAbsolute(b.pathFromRoot(nlopt_lib_file), .{})) |_| true else |_| false;

    var nlopt_step = b.step("nlopt_install", "");
    if (!lib_exists) {
        const nlopt_configure = b.addSystemCommand(&.{
            "cmake",
            "-S",
            nlopt_src.getPath(b),
            "-B",
            nlopt_build_dir,
            b.fmt("-DCMAKE_INSTALL_PREFIX={s}", .{nlopt_install_dir}),
        });

        const nlopt_build = b.addSystemCommand(&.{
            "make",
            "-C",
            nlopt_build_dir,
            "install",
        });
        nlopt_build.step.dependOn(&nlopt_configure.step);
        nlopt_step = &nlopt_build.step;
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
    if (!lib_exists) {
        lib.step.dependOn(nlopt_step);
    }
    lib.root_module.addLibraryPath(b.path(b.pathJoin(&.{ nlopt_install_dir, "lib" })));
    lib.root_module.linkSystemLibrary("nlopt", .{});
    lib.root_module.addSystemIncludePath(b.path(b.pathJoin(&.{ nlopt_install_dir, "include" })));
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
    b.installArtifact(exe);
}
