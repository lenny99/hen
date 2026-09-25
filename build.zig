const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chicken_build = LibChicken.build(b);
    b.getInstallStep().dependOn(chicken_build.step);

    const chicken_module = b.addModule("chicken", .{
        .root_source_file = b.path("src/chicken/root.zig"),
        .target = target,
        .link_libc = true,
    });
    (&chicken_build).link(chicken_module);

    const uuid = b.dependency("uuid", .{ .target = target });
    const agent_module = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "uuid", .module = uuid.module("uuid") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "hen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent_module },
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

    const chicken_tests = b.addTest(.{
        .root_module = chicken_module,
    });

    const run_chicken_tests = b.addRunArtifact(chicken_tests);

    const agent_tests = b.addTest(.{
        .root_module = agent_module,
    });

    const run_agent_tests = b.addRunArtifact(agent_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_chicken_tests.step);
    test_step.dependOn(&run_agent_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

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
