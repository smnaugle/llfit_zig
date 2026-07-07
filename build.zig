const std = @import("std");

fn buildGSL(b: *std.Build) ?*std.Build {
    const gsl_dep = b.dependency("gsl", .{});

    const path_buf = b.allocator.alloc(u8, std.fs.max_path_bytes) catch @panic("OOM");
    defer b.allocator.free(path_buf);

    var io = std.Io.Threaded.init_single_threaded;

    var exists: bool = true;
    _ = b.cache_root.handle.openDir(io.io(), "gsl_install/lib/", .{}) catch {
        exists = false;
    };
    if (exists) return null;

    const abs_install_dir = b.cache_root.handle.createDirPathOpen(
        io.io(),
        "gsl_install/",
        .{},
    ) catch @panic("Cannot make directory");
    const num_bytes = abs_install_dir.realPath(io.io(), path_buf) catch @panic("Cannot get full path");
    abs_install_dir.close(io.io());

    const prefix_opt = std.mem.concatWithSentinel(b.allocator, u8, &.{ "--prefix=", path_buf[0..num_bytes] }, 0) catch @panic("OOM");
    defer b.allocator.free(prefix_opt);

    const gsl_configure = gsl_dep.builder.addSystemCommand(&.{
        "./configure",
        prefix_opt,
    });
    gsl_configure.setCwd(gsl_dep.path(""));
    gsl_configure.setName("Configure gsl");

    const gsl_build = gsl_dep.builder.addSystemCommand(&.{
        "make",
    });
    gsl_build.setCwd(gsl_dep.path(""));
    gsl_build.setName("Make gsl");
    gsl_build.step.dependOn(&gsl_configure.step);
    const gsl_install = gsl_dep.builder.addSystemCommand(&.{
        "make",
        "install",
    });
    gsl_install.setCwd(gsl_dep.path(""));
    gsl_install.setName("Install gsl");
    gsl_install.step.dependOn(&gsl_build.step);

    gsl_dep.builder.default_step.dependOn(&gsl_install.step);
    return gsl_dep.builder;
}

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

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c_imports.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const gsl_install_dir = b.cache_root.join(b.allocator, &.{"gsl_install/"}) catch @panic("OOM");
    const gsl_build = buildGSL(b);

    translate_c.addIncludePath(b.path(b.pathJoin(&.{ nlopt_install_dir, "/include" })));
    translate_c.addIncludePath(b.path(b.pathJoin(&.{ gsl_install_dir, "/include" })));

    const tc_mod = translate_c.createModule();

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
    if (gsl_build) |gsl| lib.step.dependOn(gsl.default_step);
    lib.step.dependOn(&nlopt_build.step);
    const nlopt_lib_path = b.pathJoin(&.{ nlopt_install_dir, "/lib" });
    lib.root_module.addLibraryPath(b.path(nlopt_lib_path));
    lib.root_module.linkSystemLibrary("nlopt", .{ .preferred_link_mode = .static });
    lib.root_module.linkSystemLibrary("gsl", .{ .preferred_link_mode = .static });
    const nlopt_inc_path = b.pathJoin(&.{ nlopt_install_dir, "/include" });
    lib.root_module.addIncludePath(b.path(nlopt_inc_path));
    lib.use_new_linker = false;
    lib.root_module.addLibraryPath(b.path(b.pathJoin(&.{ gsl_install_dir, "/lib" })));
    lib.root_module.addIncludePath(b.path(b.pathJoin(&.{ gsl_install_dir, "/include" })));
    lib.root_module.addImport("c_imports", tc_mod);

    const prof_opt = b.option(bool, "systematic_profiling", "Profile systematics") orelse false;
    const lib_options = b.addOptions();
    lib_options.addOption(bool, "systematic_profiling", prof_opt);
    lib.root_module.addOptions("config", lib_options);

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
    if (gsl_build) |gsl| exe.step.dependOn(gsl.default_step);
    exe.root_module.addImport("c_imports", tc_mod);
    exe.root_module.addImport("llfit", lib.root_module);
    exe.use_new_linker = false;
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tests_run = b.addRunArtifact(tests);
    const tests_step = b.step("test", "Run tests");
    tests_step.dependOn(&tests_run.step);
}
