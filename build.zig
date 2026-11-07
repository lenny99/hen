const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ctx = Builder{
        .b = b,
        .target = target,
        .optimize = optimize,
        .test_step = b.step("test", "Run tests"),
    };

    const elz = ctx.vendor("elz", "vendors/element-0/src/lib.zig", .{ .link_libc = true });

    const uuid = ctx.dep("uuid", "uuid", .{});
    const ztf = ctx.dep("zig-test-framework", "zig_test_framework", .{});
    const msgpack = ctx.dep("zig_msgpack", "msgpack", .{ .optimize = optimize });
    const vaxis = ctx.dep("vaxis", "vaxis", .{ .optimize = optimize });

    const contract = ctx.module("contract", .{});

    const environment = ctx.module("environment", .{
        .imports = &.{ elz.import, contract.import },
        .link_libc = true,
    });
    ctx.tests(environment, .{ .files = &.{"root"} });
    ctx.sourceTests(environment, "render");

    const instance = ctx.module("instance", .{
        .imports = &.{ uuid.import, contract.import },
    });
    ctx.sourceTests(instance, "unit");
    ctx.tests(instance, .{
        .files = &.{"session"},
        .extra_imports = &.{ztf.import},
    });

    const http = ctx.module("http", .{
        .optimize = optimize,
        .link_libc = true,
    });

    const socket = ctx.module("socket", .{ .imports = &.{msgpack.import} });
    ctx.tests(socket, .{ .files = &.{ "root", "codec", "protocol" } });

    const client = ctx.module("client", .{
        .imports = &.{ socket.import, vaxis.import },
    });
    ctx.sourceTests(client, "unit");

    const provider = ctx.module("provider", .{
        .optimize = optimize,
        .imports = &.{ instance.import, http.import },
    });
    ctx.tests(provider, .{
        .files = &.{"root"},
        .extra_imports = &.{ instance.import, http.import, ztf.import },
    });

    const hen = ctx.exec("hen", .{
        .imports = &.{ socket.import, client.import },
    });
    ctx.sourceTests(hen, "unit");

    _ = ctx.exec("hend", .{
        .imports = &.{
            instance.import,
            environment.import,
            http.import,
            provider.import,
            uuid.import,
            socket.import,
        },
    });

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(hen.exe.?);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
}

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,

    const Mod = struct {
        name: []const u8,
        module: *std.Build.Module,
        import: std.Build.Module.Import,
        link_libc: ?bool,
        exe: ?*std.Build.Step.Compile = null,
    };

    const Options = struct {
        imports: []const std.Build.Module.Import = &.{},
        link_libc: ?bool = null,
        optimize: ?std.builtin.OptimizeMode = null,
    };

    const TestOptions = struct {
        files: []const []const u8,
        extra_imports: []const std.Build.Module.Import = &.{},
    };

    const DepOptions = struct {
        optimize: ?std.builtin.OptimizeMode = null,
    };

    fn module(self: Builder, name: []const u8, opts: Options) Mod {
        const root = self.b.fmt("src/{s}/root.zig", .{name});
        const mod = self.b.addModule(name, .{
            .root_source_file = self.b.path(root),
            .imports = opts.imports,
            .target = self.target,
            .optimize = opts.optimize,
            .link_libc = opts.link_libc,
        });
        return expose(name, mod, opts.link_libc);
    }

    fn exec(self: Builder, name: []const u8, opts: Options) Mod {
        const root = self.b.fmt("src/{s}/main.zig", .{name});
        const mod = self.b.createModule(.{
            .root_source_file = self.b.path(root),
            .imports = opts.imports,
            .target = self.target,
            .optimize = self.optimize,
        });
        const exe = self.b.addExecutable(.{ .name = name, .root_module = mod });
        self.b.installArtifact(exe);
        var m = Builder.expose(name, mod, opts.link_libc);
        m.exe = exe;
        return m;
    }

    fn vendor(self: Builder, name: []const u8, root: []const u8, opts: Options) Mod {
        const mod = self.b.addModule(name, .{
            .root_source_file = self.b.path(root),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = opts.link_libc,
        });
        mod.linkSystemLibrary("c", .{});
        return expose(name, mod, opts.link_libc);
    }

    fn dep(self: Builder, dep_name: []const u8, module_name: []const u8, opts: DepOptions) Mod {
        const package = self.b.dependency(dep_name, .{
            .target = self.target,
            .optimize = opts.optimize,
        });
        return expose(module_name, package.module(module_name), null);
    }

    fn expose(name: []const u8, mod: *std.Build.Module, link_libc: ?bool) Mod {
        return .{
            .name = name,
            .module = mod,
            .import = .{ .name = name, .module = mod },
            .link_libc = link_libc,
        };
    }

    fn tests(self: Builder, m: Mod, opts: TestOptions) void {
        for (opts.files) |file| {
            const stem = std.fs.path.stem(file);
            const name = if (std.mem.eql(u8, stem, "root"))
                self.b.fmt("{s}-tests", .{m.name})
            else
                self.b.fmt("{s}-{s}-tests", .{ m.name, stem });
            const test_root = self.b.fmt("tests/{s}/{s}.zig", .{ m.name, file });
            self.testModule(m, test_root, name, opts.extra_imports);
        }
    }

    fn sourceTests(self: Builder, m: Mod, stem: []const u8) void {
        self.unitTests(m.module, self.b.fmt("{s}-{s}-tests", .{ m.name, stem }));
    }

    fn testModule(self: Builder, m: Mod, root: []const u8, name: []const u8, extra: []const std.Build.Module.Import) void {
        const imports = self.b.graph.arena.alloc(std.Build.Module.Import, extra.len + 1) catch @panic("OOM");
        imports[0] = m.import;
        @memcpy(imports[1..], extra);
        const mod = self.b.createModule(.{
            .root_source_file = self.b.path(root),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = m.link_libc,
            .imports = imports,
        });
        self.unitTests(mod, name);
    }

    fn unitTests(self: Builder, mod: *std.Build.Module, name: []const u8) void {
        const artifact = self.b.addTest(.{
            .name = name,
            .root_module = mod,
        });
        const run = self.b.addRunArtifact(artifact);
        self.test_step.dependOn(&run.step);
    }
};
