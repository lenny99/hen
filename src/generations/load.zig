const std = @import("std");
const environment = @import("environment");
const manifest = @import("manifest.zig");

const max_file_bytes = 4 * 1024 * 1024;

/// Everything a fresh runtime needs from one generation: the module entries
/// in manifest load order with absolute source paths, and the configuration
/// values the host resolved out of the process environment and the manifest.
pub const Prepared = struct {
    entries: []environment.ModuleEntry,
    configs: []environment.ConfigValue,
};

pub const PrepareError = std.mem.Allocator.Error ||
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.RealPathFileAllocError ||
    error{ ManifestMalformed, ApiMismatch, ConfigUnresolved, SecretLiteral, ModuleNameInvalid };

/// Validate one generation and resolve everything §12 steps 1–2 need before
/// any runtime starts: manifest structure, the api version, module entry
/// paths, and the config values. Missing config values fail here, by
/// construction order, never inside a running module.
pub fn prepare(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
    environ: *const std.process.Environ.Map,
) PrepareError!Prepared {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const gen_dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, id });
    var gen_dir = try cwd.openDir(io, gen_dir_path, .{});
    defer gen_dir.close(io);

    const read = try manifest.read(io, a, gen_dir, "manifest.sexp");
    defer manifest.freeManifest(a, read);

    if (!std.mem.eql(u8, read.api, environment.bridge_api_version)) return error.ApiMismatch;

    var entries: std.ArrayList(environment.ModuleEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name.text);
            allocator.free(entry.path.text);
        }
        entries.deinit(allocator);
    }
    var configs: std.ArrayList(environment.ConfigValue) = .empty;
    errdefer {
        for (configs.items) |config| {
            allocator.free(config.source_var.text);
            allocator.free(config.value.text);
        }
        configs.deinit(allocator);
    }

    for (read.modules) |module| {
        if (!moduleNameOk(module.name.text)) return error.ModuleNameInvalid;
        if (std.mem.eql(u8, module.name.text, "hen-plugin")) return error.ModuleNameInvalid;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ gen_dir_path, module.entry });
        const absolute = try cwd.realPathFileAlloc(io, rel, a);
        const path = try allocator.dupe(u8, absolute);
        errdefer allocator.free(path);
        const name = try allocator.dupe(u8, module.name.text);
        errdefer allocator.free(name);
        try entries.append(allocator, .{ .name = environment.ModuleName.init(name), .path = environment.ModulePath.init(path) });
    }

    for (read.config) |decl| {
        if (decl.secret and decl.literal != null) return error.SecretLiteral;
        if (decl.literal == null and decl.env_source == null) return error.ConfigUnresolved;
        const env_source = decl.env_source orelse continue;
        const value: []const u8 = if (decl.literal) |literal|
            literal.text
        else
            (environ.get(env_source.text) orelse return error.ConfigUnresolved);
        const var_name = try allocator.dupe(u8, env_source.text);
        errdefer allocator.free(var_name);
        const resolved = try allocator.dupe(u8, value);
        errdefer allocator.free(resolved);
        try configs.append(allocator, .{ .source_var = environment.ConfigSourceVar.init(var_name), .value = environment.ConfigLiteral.init(resolved) });
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .configs = try configs.toOwnedSlice(allocator),
    };
}

fn moduleNameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Build the runtime from a prepared generation: the host registry first,
/// then the config values, then the module wrappers in load order.
pub fn initEnv(
    allocator: std.mem.Allocator,
    prepared: Prepared,
) environment.Error!environment.Env {
    return environment.Env.initGeneration(allocator, prepared.entries, prepared.configs);
}

pub fn freePrepared(allocator: std.mem.Allocator, prepared: Prepared) void {
    for (prepared.entries) |entry| {
        allocator.free(entry.name.text);
        allocator.free(entry.path.text);
    }
    allocator.free(prepared.entries);
    for (prepared.configs) |config| {
        allocator.free(config.source_var.text);
        allocator.free(config.value.text);
    }
    allocator.free(prepared.configs);
}

fn tmpGenerationPath(sub_path: []const u8) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    return std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, sub_path });
}

fn writeGeneration(
    a: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    api: []const u8,
    modules: []const manifest.Manifest.Module,
    config: []const manifest.Manifest.ConfigDecl,
) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, try std.fmt.allocPrint(scratch, "{s}/sources", .{dir_path}));
    try cwd.createDirPath(io, try std.fmt.allocPrint(scratch, "{s}/tests", .{dir_path}));
    if (std.mem.eql(u8, "sources/alpha.scm", modules[0].entry)) {
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(scratch, "{s}/sources/alpha.scm", .{dir_path}), .data = "(define placeholder)\n" });
    }
    const written = manifest.Manifest{ .api = api, .modules = modules, .config = config, .hash = "h" };
    var out: std.ArrayList(u8) = .empty;
    try manifest.write(scratch, &out, &written);
    const manifest_path = try std.fmt.allocPrint(scratch, "{s}/manifest.sexp", .{dir_path});
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = out.items });
}

test "prepare resolves the fixture-shaped generation from the environment" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("GENERATIONS_TEST_FIXTURE_FOO", "value-1");

    const prepared = try prepare(io, a, "tests/generations/testdata/root", "00000000-0000-4000-8000-000000000100", &environ);
    defer freePrepared(a, prepared);
    try std.testing.expectEqualStrings("alpha", prepared.entries[0].name.text);
    try std.testing.expect(std.fs.path.isAbsolute(prepared.entries[0].path.text));
    try std.testing.expectEqualStrings("GENERATIONS_TEST_FIXTURE_FOO", prepared.configs[0].source_var.text);
    try std.testing.expectEqualStrings("value-1", prepared.configs[0].value.text);
}

test "prepare rejects a generation before any runtime would start" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpGenerationPath(&tmp.sub_path);
    defer a.free(dir_path);

    const modules = [_]manifest.Manifest.Module{.{ .name = environment.ModuleName.init("alpha"), .entry = "sources/alpha.scm" }};
    const config = [_]manifest.Manifest.ConfigDecl{.{ .name = "alpha-pin", .env_source = environment.ConfigSourceVar.init("GENERATIONS_TEST_MISSING") }};

    var empty_environ = std.process.Environ.Map.init(a);
    defer empty_environ.deinit();

    try writeGeneration(a, io, dir_path, "1", &modules, &config);
    try std.testing.expectError(error.ConfigUnresolved, prepare(io, a, dir_path, ".", &empty_environ));

    try writeGeneration(a, io, dir_path, "9", &modules, &config);
    try std.testing.expectError(error.ApiMismatch, prepare(io, a, dir_path, ".", &empty_environ));

    const secret_literal = [_]manifest.Manifest.ConfigDecl{
        .{ .name = "sneaky", .env_source = environment.ConfigSourceVar.init("GENERATIONS_TEST_MISSING"), .secret = true, .literal = environment.ConfigLiteral.init("baked") },
    };
    try writeGeneration(a, io, dir_path, "1", &modules, &secret_literal);
    try std.testing.expectError(error.SecretLiteral, prepare(io, a, dir_path, ".", &empty_environ));

    const hen_plugin = [_]manifest.Manifest.Module{.{ .name = environment.ModuleName.init("hen-plugin"), .entry = "sources/alpha.scm" }};
    try writeGeneration(a, io, dir_path, "1", &hen_plugin, &config);
    try std.testing.expectError(error.ModuleNameInvalid, prepare(io, a, dir_path, ".", &empty_environ));

    const spaced = [_]manifest.Manifest.Module{.{ .name = environment.ModuleName.init("no space"), .entry = "sources/alpha.scm" }};
    try writeGeneration(a, io, dir_path, "1", &spaced, &config);
    try std.testing.expectError(error.ModuleNameInvalid, prepare(io, a, dir_path, ".", &empty_environ));

    const absent = [_]manifest.Manifest.Module{.{ .name = environment.ModuleName.init("alpha"), .entry = "sources/absent.scm" }};
    try writeGeneration(a, io, dir_path, "1", &absent, &config);
    try std.testing.expectError(error.FileNotFound, prepare(io, a, dir_path, ".", &empty_environ));
}
