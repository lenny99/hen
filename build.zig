const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chicken_build = LibChicken.build(b);
    b.getInstallStep().dependOn(chicken_build.step);

    const chicken_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor-out/chicken-core/include/chicken/chicken.h"),
        .target = target,
        .optimize = optimize,
    });
    chicken_c.step.dependOn(chicken_build.step);
    chicken_c.addIncludePath(b.path("vendor-out/chicken-core/include"));
    const chicken_c_import = std.Build.Module.Import{ .name = "chicken", .module = chicken_c.createModule() };

    const uuid = b.dependency("uuid", .{ .target = target });
    const ztf = b.dependency("zig-test-framework", .{ .target = target });

    const msgpack_dep = b.dependency("zig_msgpack", .{ .target = target, .optimize = optimize });
    const msgpack_import = std.Build.Module.Import{ .name = "msgpack", .module = msgpack_dep.module("msgpack") };

    const factory = ModuleFactory{
        .b = b,
        .target = target,
        .optimize = optimize,
        .chicken = &chicken_build,
        .test_step = b.step("test", "Run tests"),
    };

    const environment = factory.pair(.{
        .name = "environment",
        .root = "src/environment/root.zig",
        .imports = &.{chicken_c_import},
        .link_libc = true,
        .link_chicken = true,
        .test_root = "tests/environment/root.zig",
        .test_name = "environment-tests",
        .test_link_libc = true,
        .test_link_chicken = true,
    });
    factory.testModule(environment, .{
        .root = "tests/environment/env.zig",
        .name = "environment-env-tests",
        .link_libc = true,
        .link_chicken = true,
    });
    factory.unitTests(environment.module, "environment-render-tests");

    const uuid_import = std.Build.Module.Import{ .name = "uuid", .module = uuid.module("uuid") };
    const environment_import = std.Build.Module.Import{ .name = environment.name, .module = environment.module };

    const generations = factory.pair(.{
        .name = "generations",
        .root = "src/generations/root.zig",
        .optimize = true,
        .imports = &.{ environment_import, uuid_import },
        .test_root = "tests/generations/root.zig",
        .test_name = "generation-data-tests",
        .test_extra_imports = &.{environment_import},
        .test_link_libc = true,
        .test_link_chicken = true,
    });
    const generations_import = std.Build.Module.Import{ .name = generations.name, .module = generations.module };
    factory.testModule(generations, .{
        .root = "tests/generations/load.zig",
        .name = "generation-load-tests",
        .extra_imports = &.{environment_import},
        .link_libc = true,
        .link_chicken = true,
    });
    factory.unitTests(generations.module, "generation-tests");

    const instance = factory.module(.{
        .name = "instance",
        .root = "src/instance/root.zig",
        .imports = &.{ uuid_import, environment_import, generations_import },
    });
    const instance_import = std.Build.Module.Import{ .name = instance.name, .module = instance.module };
    factory.unitTests(instance.module, null);

    const http = factory.module(.{
        .name = "http",
        .root = "src/http/root.zig",
        .optimize = true,
        .link_libc = true,
    });
    const http_import = std.Build.Module.Import{ .name = http.name, .module = http.module };

    const socket = factory.module(.{
        .name = "socket",
        .root = "src/socket/root.zig",
        .imports = &.{msgpack_import},
    });
    factory.testModule(socket, .{
        .root = "tests/socket/root.zig",
        .name = "socket-tests",
    });

    factory.testModule(instance, .{
        .root = "tests/instance/session.zig",
        .name = "instance-session-tests",
        .extra_imports = &.{.{ .name = "zig_test_framework", .module = ztf.module("zig_test_framework") }},
    });

    const provider = factory.pair(.{
        .name = "provider",
        .root = "src/providers/root.zig",
        .optimize = true,
        .imports = &.{ instance_import, http_import },
        .test_root = "tests/providers/root.zig",
        .test_name = "provider-tests",
        .test_extra_imports = &.{ instance_import, http_import, .{ .name = "zig_test_framework", .module = ztf.module("zig_test_framework") } },
    });
    const provider_import = std.Build.Module.Import{ .name = provider.name, .module = provider.module };

    const exe = b.addExecutable(.{
        .name = "hen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                instance_import,
                http_import,
                provider_import,
                environment_import,
                generations_import,
                uuid_import,
            },
        }),
    });

    b.installArtifact(exe);
    exe.step.dependOn(chicken_build.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    factory.unitTests(exe.root_module, null);
}

fn rootPath(b: *std.Build, sub_path: []const u8) []const u8 {
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, ".", b.allocator) catch @panic("unable to resolve cwd");
    const joined = b.root.joinString(b.allocator, sub_path) catch @panic("OOM");
    return b.pathResolve(&.{ cwd, joined });
}

const ModuleFactory = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    chicken: *const LibChicken,
    test_step: *std.Build.Step,

    const Impl = struct {
        name: []const u8,
        module: *std.Build.Module,
    };

    const ImplOptions = struct {
        name: []const u8,
        root: []const u8,
        link_libc: ?bool = null,
        optimize: bool = false,
        imports: []const std.Build.Module.Import = &.{},
        link_chicken: bool = false,
    };

    const TestOptions = struct {
        root: []const u8,
        name: []const u8,
        extra_imports: []const std.Build.Module.Import = &.{},
        link_libc: ?bool = null,
        link_chicken: bool = false,
    };

    const PairOptions = struct {
        name: []const u8,
        root: []const u8,
        link_libc: ?bool = null,
        optimize: bool = false,
        imports: []const std.Build.Module.Import = &.{},
        link_chicken: bool = false,
        test_root: []const u8,
        test_name: []const u8,
        test_extra_imports: []const std.Build.Module.Import = &.{},
        test_link_libc: ?bool = null,
        test_link_chicken: bool = false,
    };

    fn module(self: ModuleFactory, options: ImplOptions) Impl {
        const mod = self.b.addModule(options.name, .{
            .root_source_file = self.b.path(options.root),
            .imports = options.imports,
            .target = self.target,
            .optimize = if (options.optimize) self.optimize else null,
            .link_libc = options.link_libc,
        });
        if (options.link_chicken) self.chicken.link(mod);
        return .{ .name = options.name, .module = mod };
    }

    fn pair(self: ModuleFactory, options: PairOptions) Impl {
        const impl = self.module(.{
            .name = options.name,
            .root = options.root,
            .link_libc = options.link_libc,
            .optimize = options.optimize,
            .imports = options.imports,
            .link_chicken = options.link_chicken,
        });
        self.testModule(impl, .{
            .root = options.test_root,
            .name = options.test_name,
            .extra_imports = options.test_extra_imports,
            .link_libc = options.test_link_libc,
            .link_chicken = options.test_link_chicken,
        });
        return impl;
    }

    fn testModule(self: ModuleFactory, impl: Impl, options: TestOptions) void {
        const imports = self.b.graph.arena.alloc(std.Build.Module.Import, options.extra_imports.len + 1) catch @panic("OOM");
        imports[0] = .{ .name = impl.name, .module = impl.module };
        @memcpy(imports[1..], options.extra_imports);
        const mod = self.b.createModule(.{
            .root_source_file = self.b.path(options.root),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = options.link_libc,
            .imports = imports,
        });
        if (options.link_chicken) self.chicken.link(mod);
        self.unitTests(mod, options.name);
    }

    fn unitTests(self: ModuleFactory, mod: *std.Build.Module, name: ?[]const u8) void {
        const tests = self.b.addTest(.{
            .name = name orelse "test",
            .root_module = mod,
        });
        const run = self.b.addRunArtifact(tests);
        tests.step.dependOn(self.chicken.step);
        self.test_step.dependOn(&run.step);
    }
};

const LibChicken = struct {
    owner: *std.Build,
    step: *std.Build.Step,
    prefix: []const u8,

    /// Stamp recipe version. Bump when the configure/install commands below
    /// change, so installs made by an older recipe are invalidated.
    const recipe = "v1";

    /// One step owns the whole vendored-CHICKEN build: guard, configure,
    /// make, install, stamp. Cached while vendor-out/chicken-core/.chicken-
    /// commit records the current vendors/chicken-core commit and the
    /// installed artifacts exist. `zig build -Dchicken-force=true` bypasses
    /// the cache and refreshes the stamp.
    fn build(b: *std.Build) @This() {
        const prefix = rootPath(b, "vendor-out/chicken-core");
        const src = rootPath(b, "vendors/chicken-core");
        const force = b.option(bool, "chicken-force", "force rebuilding vendored CHICKEN") orelse false;

        const script = b.fmt(
            \\set -eu
            \\src=$1
            \\prefix=$2
            \\force=$3
            \\if ! chicken_bin=$(command -v chicken); then
            \\  echo "chicken: bootstrap chicken executable not found in PATH" >&2
            \\  exit 1
            \\fi
            \\key=
            \\if head=$(git -C "$src" rev-parse HEAD 2>/dev/null); then
            \\  key="{s}:$head"
            \\  if ! git -C "$src" diff-index --quiet HEAD -- 2>/dev/null; then
            \\    key="$key-dirty"
            \\  fi
            \\fi
            \\stamp="$prefix/.chicken-commit"
            \\if [ "$force" != true ] && [ -n "$key" ] && [ -f "$stamp" ] &&
            \\   [ "$(cat "$stamp")" = "$key" ] &&
            \\   [ -f "$prefix/lib/libchicken-static.a" ] &&
            \\   [ -d "$prefix/include/chicken" ]; then
            \\  echo "chicken: $key up to date, skipping configure/make/install"
            \\  exit 0
            \\fi
            \\cd "$src"
            \\./configure --prefix "$prefix" --chicken "$chicken_bin"
            \\make -j
            \\make install
            \\if [ -n "$key" ]; then
            \\  printf '%s\n' "$key" > "$stamp"
            \\fi
        , .{recipe});

        const run = b.addSystemCommand(&.{ "sh", "-c", script });
        run.setName("build chicken");
        run.addArg("sh");
        run.addArg(src);
        run.addArg(prefix);
        run.addArg(if (force) "true" else "false");

        const chicken = b.step("chicken", "build chicken");
        chicken.dependOn(&run.step);

        return .{ .owner = b, .step = chicken, .prefix = prefix };
    }

    fn link(self: *const @This(), mod: *std.Build.Module) void {
        const owner = self.owner;
        mod.addIncludePath(owner.graph.cwdRelativePath(owner.pathJoin(&.{ self.prefix, "include" })));
        mod.addObjectFile(owner.graph.cwdRelativePath(owner.pathJoin(&.{ self.prefix, "lib/libchicken-static.a" })));
        mod.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    }
};
