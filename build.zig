const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const elz = b.addModule("elz", .{
        .root_source_file = b.path("vendors/element-0/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    elz.linkSystemLibrary("c", .{});
    const elz_import = std.Build.Module.Import{ .name = "elz", .module = elz };

    const uuid = b.dependency("uuid", .{ .target = target });
    const ztf = b.dependency("zig-test-framework", .{ .target = target });

    const msgpack_dep = b.dependency("zig_msgpack", .{ .target = target, .optimize = optimize });
    const msgpack_import = std.Build.Module.Import{ .name = "msgpack", .module = msgpack_dep.module("msgpack") };

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_import = std.Build.Module.Import{ .name = "vaxis", .module = vaxis_dep.module("vaxis") };

    const factory = ModuleFactory{
        .b = b,
        .target = target,
        .optimize = optimize,
        .test_step = b.step("test", "Run tests"),
    };

    const contract = factory.module(.{
        .name = "contract",
        .root = "src/contract/root.zig",
    });
    const contract_import = std.Build.Module.Import{ .name = "contract", .module = contract.module };

    const environment = factory.pair(.{
        .name = "environment",
        .root = "src/environment/root.zig",
        .imports = &.{ elz_import, contract_import },
        .link_libc = true,
        .test_root = "tests/environment/root.zig",
        .test_name = "environment-tests",
        .test_link_libc = true,
    });
    factory.unitTests(environment.module, "environment-render-tests");

    const uuid_import = std.Build.Module.Import{ .name = "uuid", .module = uuid.module("uuid") };
    const environment_import = std.Build.Module.Import{ .name = environment.name, .module = environment.module };

    const instance = factory.module(.{
        .name = "instance",
        .root = "src/instance/root.zig",
        .imports = &.{ uuid_import, contract_import },
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
    factory.testModule(socket, .{
        .root = "tests/socket/codec.zig",
        .name = "socket-codec-tests",
    });
    factory.testModule(socket, .{
        .root = "tests/socket/protocol.zig",
        .name = "socket-protocol-tests",
    });

    const client = factory.module(.{
        .name = "client",
        .root = "src/client/root.zig",
        .imports = &.{
            .{ .name = "socket", .module = socket.module },
            vaxis_import,
        },
    });
    factory.unitTests(client.module, "client-unit-tests");

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

    const hen = b.addExecutable(.{
        .name = "hen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "socket", .module = socket.module },
                .{ .name = "client", .module = client.module },
            },
        }),
    });
    b.installArtifact(hen);

    const hend = b.addExecutable(.{
        .name = "hend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hend/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                instance_import,
                environment_import,
                http_import,
                provider_import,
                uuid_import,
                .{ .name = "socket", .module = socket.module },
            },
        }),
    });
    b.installArtifact(hend);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(hen);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    factory.unitTests(hen.root_module, null);
}

const ModuleFactory = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    };

    const TestOptions = struct {
        root: []const u8,
        name: []const u8,
        extra_imports: []const std.Build.Module.Import = &.{},
        link_libc: ?bool = null,
    };

    const PairOptions = struct {
        name: []const u8,
        root: []const u8,
        link_libc: ?bool = null,
        optimize: bool = false,
        imports: []const std.Build.Module.Import = &.{},
        test_root: []const u8,
        test_name: []const u8,
        test_extra_imports: []const std.Build.Module.Import = &.{},
        test_link_libc: ?bool = null,
    };

    fn module(self: ModuleFactory, options: ImplOptions) Impl {
        const mod = self.b.addModule(options.name, .{
            .root_source_file = self.b.path(options.root),
            .imports = options.imports,
            .target = self.target,
            .optimize = if (options.optimize) self.optimize else null,
            .link_libc = options.link_libc,
        });
        return .{ .name = options.name, .module = mod };
    }

    fn pair(self: ModuleFactory, options: PairOptions) Impl {
        const impl = self.module(.{
            .name = options.name,
            .root = options.root,
            .link_libc = options.link_libc,
            .optimize = options.optimize,
            .imports = options.imports,
        });
        self.testModule(impl, .{
            .root = options.test_root,
            .name = options.test_name,
            .extra_imports = options.test_extra_imports,
            .link_libc = options.test_link_libc,
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
