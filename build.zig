const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chicken = LibChicken.build(b);
    b.getInstallStep().dependOn(chicken.step);

    const mod = b.addModule("hen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    (&chicken).link(mod);

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

const LibChicken = struct {
    b: *std.Build,
    step: *std.Build.Step,
    prefix: []u8,

    fn build(b: *std.Build) @This() {
        const prefix = b.pathFromRoot("vendor-out/chicken-core");
        const path = b.path("vendors/chicken-core");

        const configure_script =
            \\# Skip reconfiguration when config.make exists, records this prefix, and
            \\# the configure script itself has not changed.
            \\if [ -f config.make ] && grep -qF "PREFIX = $1" config.make && [ ! ./configure -nt config.make ]; then
            \\    echo "chicken: config.make is up to date, skipping configure"
            \\    exit 0
            \\fi
            \\./configure --prefix "$1" --chicken '$(which chicken)/..'
        ;
        const configure = b.addSystemCommand(&.{ "sh", "-c", configure_script, "sh", prefix });
        {
            configure.setCwd(path);
        }

        const make = b.addSystemCommand(&.{ "make", "-j" });
        {
            make.setCwd(path);
            make.step.dependOn(&configure.step);
        }

        const install_script =
            \\lib="$1/lib/libchicken-static.a"
            \\# Skip installation when the installed static library exists and nothing
            \\# in the source tree is newer than it.
            \\if [ -f "$lib" ] && [ -z "$(find . -name .git -prune -o -newer "$lib" -print -quit)" ]; then
            \\    echo "chicken: installed files are up to date, skipping make install"
            \\    exit 0
            \\fi
            \\make install
        ;
        const install = b.addSystemCommand(&.{ "sh", "-c", install_script, "sh", prefix });
        {
            install.setCwd(path);
            install.step.dependOn(&make.step);
        }

        const chicken = b.step("chicken", "build chicken");
        {
            chicken.dependOn(&install.step);
        }

        return @This(){ .b = b, .step = chicken, .prefix = prefix };
    }

    fn link(self: *const @This(), mod: *std.Build.Module) void {
        const b = self.b;
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ self.prefix, "include" }) });
        mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ self.prefix, "lib/libchicken-static.a" }) });
        mod.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    }
};
