const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chicken_build = LibChicken.build(b);
    b.getInstallStep().dependOn(chicken_build.step);

    const uuid = b.dependency("uuid", .{ .target = target });
    const ztf = b.dependency("zig-test-framework", .{ .target = target });

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

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    factory.unitTests(exe.root_module, null);
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
        self.test_step.dependOn(&run.step);
    }
};

const LibChicken = struct {
    owner: *std.Build,
    step: *std.Build.Step,
    prefix: []u8,

    /// Stamp recipe version. Bump when the configure/install commands below
    /// change, so installs made by an older recipe are invalidated.
    const recipe = "v1";

    /// One step owns the whole vendored-CHICKEN build: guard, configure,
    /// make, install, stamp. Cached while vendor-out/chicken-core/.chicken-
    /// commit records the current vendors/chicken-core commit and the
    /// installed artifacts exist. `zig build -Dchicken-force=true` bypasses
    /// the cache and refreshes the stamp.
    fn build(b: *std.Build) @This() {
        const prefix = b.pathFromRoot("vendor-out/chicken-core");
        const force = b.option(bool, "chicken-force", "force rebuilding vendored CHICKEN") orelse false;

        const chicken = b.step("chicken", "build chicken");
        chicken.makeFn = if (force) makeForce else make;

        return .{ .owner = b, .step = chicken, .prefix = prefix };
    }

    fn link(self: *const @This(), mod: *std.Build.Module) void {
        const owner = self.owner;
        mod.addIncludePath(.{ .cwd_relative = owner.pathJoin(&.{ self.prefix, "include" }) });
        mod.addObjectFile(.{ .cwd_relative = owner.pathJoin(&.{ self.prefix, "lib/libchicken-static.a" }) });
        mod.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    }

    /// Cache key: "<recipe>:<chicken-core commit>" plus "-dirty" when tracked
    /// files differ from HEAD. Null when git or the repository is
    /// unavailable, which means: always build, never write the stamp.
    fn commitKey(b: *std.Build, io: std.Io) ?[]const u8 {
        const src = b.pathFromRoot("vendors/chicken-core");
        const head = std.process.run(b.allocator, io, .{
            .argv = &.{ "git", "-C", src, "rev-parse", "HEAD" },
        }) catch return null;
        const code: u8 = switch (head.term) {
            .exited => |c| c,
            else => return null,
        };
        if (code != 0) return null;
        const hash = std.mem.trim(u8, head.stdout, " \t\r\n");
        if (hash.len == 0) return null;

        // Tracked local edits change the build without changing the commit,
        // so they mark the key -dirty and force a rebuild. Different edits
        // between two dirty states are not distinguished; -Dchicken-force
        // covers that.
        const dirty = std.process.run(b.allocator, io, .{
            .argv = &.{ "git", "-C", src, "diff-index", "--quiet", "HEAD", "--" },
        }) catch return b.fmt("{s}:{s}-dirty", .{ recipe, hash });
        const clean = switch (dirty.term) {
            .exited => |c| c == 0,
            else => false,
        };
        return if (clean)
            b.fmt("{s}:{s}", .{ recipe, hash })
        else
            b.fmt("{s}:{s}-dirty", .{ recipe, hash });
    }

    /// Guarded build: skip the configure/make/install chain while the stamp
    /// records this key and the installed artifacts exist.
    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const b = step.owner;
        const io = b.graph.io;

        const key = commitKey(b, io);
        if (key) |k| {
            if (stampMatches(io, b, k) and artifactsExist(io, b)) {
                std.debug.print("chicken: {s} up to date, skipping configure/make/install\n", .{k});
                return;
            }
        }

        try runChain(b, step, options, io);
        if (key) |k| try writeStamp(io, b, k);
    }

    /// -Dchicken-force=true: same chain, no guard; refreshes the stamp.
    fn makeForce(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const b = step.owner;
        const io = b.graph.io;

        const key = commitKey(b, io);
        try runChain(b, step, options, io);
        if (key) |k| try writeStamp(io, b, k);
    }

    fn runChain(
        b: *std.Build,
        step: *std.Build.Step,
        options: std.Build.Step.MakeOptions,
        io: std.Io,
    ) anyerror!void {
        const src = b.pathFromRoot("vendors/chicken-core");
        const prefix = b.pathFromRoot("vendor-out/chicken-core");
        // Byte-identical to the previous configure/make/install Run steps;
        // "$(which chicken)/.." stays literal, as before.
        try runCmd(step, options, io, &.{ "./configure", "--prefix", prefix, "--chicken", "$(which chicken)/.." }, src);
        try runCmd(step, options, io, &.{ "make", "-j" }, src);
        try runCmd(step, options, io, &.{ "make", "install" }, src);
    }

    fn runCmd(
        step: *std.Build.Step,
        options: std.Build.Step.MakeOptions,
        io: std.Io,
        argv: []const []const u8,
        cwd: []const u8,
    ) anyerror!void {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .progress_node = options.progress_node,
        }) catch |err| return step.fail("chicken: unable to spawn {s}: {t}", .{ argv[0], err });
        const term = child.wait(io) catch |err| return step.fail("chicken: {s} failed: {t}", .{ argv[0], err });
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => return step.fail("chicken: {s} terminated abnormally", .{argv[0]}),
        };
        if (code != 0) return step.fail("chicken: {s} exited with code {d}", .{ argv[0], code });
    }

    fn stampMatches(io: std.Io, b: *std.Build, key: []const u8) bool {
        const stamp = b.pathJoin(&.{ b.pathFromRoot("vendor-out/chicken-core"), ".chicken-commit" });
        const recorded = std.Io.Dir.cwd().readFileAlloc(io, stamp, b.allocator, std.Io.Limit.limited(128)) catch return false;
        return std.mem.eql(u8, std.mem.trim(u8, recorded, " \t\r\n"), key);
    }

    fn artifactsExist(io: std.Io, b: *std.Build) bool {
        const cwd = std.Io.Dir.cwd();
        const prefix = b.pathFromRoot("vendor-out/chicken-core");
        _ = cwd.statFile(io, b.pathJoin(&.{ prefix, "lib/libchicken-static.a" }), .{}) catch return false;
        _ = cwd.statFile(io, b.pathJoin(&.{ prefix, "include/chicken" }), .{}) catch return false;
        return true;
    }

    /// Record the key only after the chain succeeded, so a failed build
    /// never poisons the cache.
    fn writeStamp(io: std.Io, b: *std.Build, key: []const u8) !void {
        const stamp = b.pathJoin(&.{ b.pathFromRoot("vendor-out/chicken-core"), ".chicken-commit" });
        const line = try std.fmt.allocPrint(b.allocator, "{s}\n", .{key});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stamp, .data = line });
    }
};
