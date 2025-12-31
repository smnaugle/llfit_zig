const std = @import("std");

pub fn build(b: *std.Build) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const nlopt_path = b.option([]const u8, "nlopt_install_dir", "Path where NLOPT is installed") orelse "";
    var nlopt_inc_path: []u8 = "";
    defer arena.deinit();
    const allocator = arena.allocator();
    const has_nlopt_path = !std.mem.eql(u8, nlopt_path, "");
    if (has_nlopt_path) {
        nlopt_inc_path = std.mem.concat(allocator, u8, &.{ nlopt_path, "include/" }) catch |err| {
            std.debug.panic("{}", .{err});
            return;
        };
        b.addSearchPrefix(nlopt_path);
    } else {
        std.log.warn("nlopt_install_dir build option is not set, assuming that the library is installed on default path", .{});
    }

    const target = std.Build.standardTargetOptions(b, .{});
    const optimize = std.Build.standardOptimizeOption(b, .{});
    const mod = b.addModule("llfit", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    mod.linkSystemLibrary("nlopt", .{});
    if (has_nlopt_path) {
        std.debug.print("{s}\n", .{nlopt_inc_path});
        mod.addSystemIncludePath(.{ .cwd_relative = nlopt_inc_path });
    }
    const exe = b.addExecutable(.{
        .name = "llfit_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    exe.root_module.addImport("llfit", mod);
    b.installArtifact(exe);
    if (has_nlopt_path) {
        std.debug.print("{s}\n", .{nlopt_inc_path});
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = nlopt_inc_path });
    }
}
