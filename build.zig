const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chicken = buildChicken(b);
    b.getInstallStep().dependOn(chicken);

    const mod = b.addModule("hen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    mod.addIncludePath(b.path("vendor-out/chicken-core/include"));
    mod.addObjectFile(b.path("vendor-out/chicken-core/lib/libchicken-static.a"));
    mod.linkSystemLibrary("m", .{ .use_pkg_config = .no });

    const exe = b.addExecutable(.{
        .name = "hen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hen", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn buildChicken(b: *std.Build) *std.Build.Step {
    const prefix = b.pathFromRoot("vendor-out/chicken-core");
    const path = b.path("vendors/chicken-core");

    const configure = b.addSystemCommand(&.{ "./configure", "--prefix", prefix, "--chicken", "$(which chicken)/.." });
    {
        configure.setCwd(path);
    }

    const make = b.addSystemCommand(&.{ "make", "-j" });
    {
        make.setCwd(path);
        make.step.dependOn(&configure.step);
    }

    const install = b.addSystemCommand(&.{ "make", "install" });
    {
        install.setCwd(path);
        install.step.dependOn(&make.step);
    }

    const chicken = b.step("chicken", "build chicken");
    chicken.dependOn(&install.step);
    return chicken;
}
