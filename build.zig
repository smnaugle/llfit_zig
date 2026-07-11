const std = @import("std");

fn buildGSL(b: *std.Build, threads: usize) *std.Build.Step {
    const step = b.step("gsl", "Build gsl");
    const gsl_dep = b.dependency("gsl", .{});

    const path_buf = b.allocator.alloc(u8, std.fs.max_path_bytes) catch @panic("OOM");
    defer b.allocator.free(path_buf);

    var io = std.Io.Threaded.init_single_threaded;

    const exists = exblk: {
        gsl_dep.builder.build_root.handle.access(io.io(), "install/lib/libgsl.a", .{}) catch {
            gsl_dep.builder.build_root.handle.access(io.io(), "install/lib/libgsl.so", .{}) catch {
                break :exblk false;
            };
        };
        break :exblk true;
    };

    if (exists) return step;

    gsl_dep.builder.build_root.handle.createDirPath(
        io.io(),
        "install/",
    ) catch @panic("Cannot make directory");

    const absolute_path = gsl_dep.builder.build_root.path.?;
    const install_path = b.pathJoin(&.{ absolute_path, "/install" });
    const gsl_configure = gsl_dep.builder.addSystemCommand(&.{
        "./configure",
        "--prefix",
        install_path,
    });
    gsl_configure.setCwd(gsl_dep.path(""));
    gsl_configure.setName("Configure gsl");

    const gsl_build = gsl_dep.builder.addSystemCommand(&.{
        "make",
        "-j",
        b.fmt("{d}", .{threads}),
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
    step.dependOn(&gsl_install.step);
    return step;
}

fn buildNLOPT(b: *std.Build, threads: usize) *std.Build.Step {
    const step = b.step("nlopt", "Build nlopt");
    const dep = b.dependency("nlopt", .{});
    const src_dir = dep.builder.build_root.path.?;
    const build_dir = dep.builder.pathJoin(&.{ src_dir, "build" });
    const install_dir = dep.builder.pathJoin(&.{ src_dir, "install" });

    const nlopt_configure = dep.builder.addSystemCommand(&.{
        "cmake",
        "-S",
        src_dir,
        "-B",
        build_dir,
        b.fmt("-DCMAKE_INSTALL_PREFIX={s}", .{install_dir}),
        "-DCMAKE_INSTALL_MESSAGE=NEVER",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DNLOPT_CXX=OFF",
    });
    nlopt_configure.setName("Configure NLOPT");

    const nlopt_build = dep.builder.addSystemCommand(&.{
        "make",
        "-C",
        build_dir,
        "install",
        "-j",
        b.fmt("{d}", .{threads}),
    });
    nlopt_build.setName("Make and install NLOPT");
    nlopt_build.step.dependOn(&nlopt_configure.step);
    step.dependOn(&nlopt_build.step);
    return step;
}

pub fn build(b: *std.Build) void {
    const prof_opt = b.option(bool, "systematic_profiling", "Profile systematics") orelse false;
    const dependency_threads = b.option(usize, "threads", "Number of threads to use when compiling dependencies") orelse 1;

    const target = std.Build.standardTargetOptions(b, .{});
    const optimize = std.Build.standardOptimizeOption(b, .{});

    const gsl_step = buildGSL(b, dependency_threads);
    const gsl_dep = b.dependency("gsl", .{});

    const nlopt_step = buildNLOPT(b, dependency_threads);
    const nlopt_dep = b.dependency("nlopt", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c_imports.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    translate_c.addIncludePath(gsl_dep.path("install/include"));
    translate_c.addIncludePath(nlopt_dep.path("install/include"));

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
    lib.step.dependOn(&translate_c.step);
    lib.step.dependOn(nlopt_step);
    lib.step.dependOn(gsl_step);
    lib.root_module.addLibraryPath(nlopt_dep.path("install/lib"));
    lib.root_module.linkSystemLibrary("nlopt", .{ .preferred_link_mode = .static });

    lib.root_module.addLibraryPath(gsl_dep.path("install/lib"));
    lib.root_module.linkSystemLibrary("gsl", .{ .preferred_link_mode = .static });

    lib.root_module.addImport("c_imports", tc_mod);

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
    exe.root_module.addImport("c_imports", tc_mod);
    exe.root_module.addImport("llfit", lib.root_module);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.step.dependOn(&lib.step);
    const tests_run = b.addRunArtifact(tests);
    const tests_step = b.step("test", "Run tests");
    tests_step.dependOn(&tests_run.step);
}
