const std = @import("std");
const uuid = @import("uuid");
const environment = @import("environment");
const ledger = @import("ledger.zig");

const max_file_bytes = 4 * 1024 * 1024;
const default_api = "1";

pub const Manifest = struct {
    api: []const u8,
    parent: ?[]const u8 = null,
    modules: []const Module = &.{},
    config: []const ConfigDecl = &.{},
    capabilities: []const []const u8 = &.{},
    caps: []const Cap = &.{},
    provider: ?Provider = null,
    hash: []const u8 = "",

    pub const Module = struct {
        name: environment.ModuleName,
        entry: []const u8,
    };

    pub const ConfigDecl = struct {
        name: []const u8,
        env_source: ?environment.ConfigSourceVar = null,
        secret: bool = false,
        literal: ?environment.ConfigLiteral = null,
    };

    pub const Cap = struct {
        name: []const u8,
        value: i64,
    };

    pub const Provider = struct {
        endpoints: []const []const u8,
        api_kind: []const u8,
        key_source: []const u8,
        models: []const []const u8,
    };
};

pub const Candidate = struct {
    id: []const u8,
    hash: []const u8,
};

pub const ParseError = std.mem.Allocator.Error || error{ManifestMalformed};

pub const ReadError = std.mem.Allocator.Error ||
    std.Io.Dir.ReadFileAllocError ||
    error{ManifestMalformed};

pub const HashError = environment.Error ||
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.Iterator.Error ||
    std.mem.Allocator.Error;

pub const BuildError = ledger.AppendError ||
    std.mem.Allocator.Error ||
    std.Io.RandomSecureError ||
    error{ IdExists, ParentMissing, ManifestMalformed, ConfigUnresolved, SecretLiteral } ||
    environment.Error ||
    std.Io.Dir.WriteFileError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.StatFileError;

pub fn write(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    manifest: *const Manifest,
) environment.Error!void {
    try out.appendSlice(allocator, "(manifest");
    try out.appendSlice(allocator, " (api ");
    try environment.writeSchemeString(allocator, out, manifest.api);
    try out.appendSlice(allocator, ")");
    if (manifest.parent) |parent| {
        try out.appendSlice(allocator, " (parent ");
        try environment.writeSchemeString(allocator, out, parent);
        try out.appendSlice(allocator, ")");
    }
    try out.appendSlice(allocator, " (modules");
    for (manifest.modules) |module| {
        try out.appendSlice(allocator, " (module ");
        try environment.writeSchemeString(allocator, out, module.name.text);
        try out.appendSlice(allocator, " ");
        try environment.writeSchemeString(allocator, out, module.entry);
        try out.appendSlice(allocator, ")");
    }
    try out.appendSlice(allocator, ")");
    try out.appendSlice(allocator, " (config");
    for (manifest.config) |decl| {
        try out.appendSlice(allocator, " (decl ");
        try environment.writeSchemeString(allocator, out, decl.name);
        try out.appendSlice(allocator, " ");
        if (decl.env_source) |env_source| {
            try out.appendSlice(allocator, "(env ");
            try environment.writeSchemeString(allocator, out, env_source.text);
            try out.appendSlice(allocator, ")");
        } else {
            try out.appendSlice(allocator, "()");
        }
        try out.appendSlice(allocator, if (decl.secret) " #t" else " #f");
        try out.appendSlice(allocator, " ");
        if (decl.literal) |literal| {
            try environment.writeSchemeString(allocator, out, literal.text);
        } else {
            try out.appendSlice(allocator, "()");
        }
        try out.appendSlice(allocator, ")");
    }
    try out.appendSlice(allocator, ")");
    try out.appendSlice(allocator, " (capabilities");
    for (manifest.capabilities) |capability| {
        try out.appendSlice(allocator, " ");
        try environment.writeSchemeString(allocator, out, capability);
    }
    try out.appendSlice(allocator, ")");
    try out.appendSlice(allocator, " (caps");
    for (manifest.caps) |cap| {
        const value = try std.fmt.allocPrint(allocator, "{d}", .{cap.value});
        defer allocator.free(value);
        try out.appendSlice(allocator, " (cap ");
        try environment.writeSchemeString(allocator, out, cap.name);
        try out.appendSlice(allocator, " ");
        try out.appendSlice(allocator, value);
        try out.appendSlice(allocator, ")");
    }
    try out.appendSlice(allocator, ")");
    if (manifest.provider) |provider| {
        try out.appendSlice(allocator, " (provider");
        try out.appendSlice(allocator, " (endpoints");
        for (provider.endpoints) |endpoint| {
            try out.appendSlice(allocator, " ");
            try environment.writeSchemeString(allocator, out, endpoint);
        }
        try out.appendSlice(allocator, ")");
        try out.appendSlice(allocator, " (api-kind ");
        try environment.writeSchemeString(allocator, out, provider.api_kind);
        try out.appendSlice(allocator, ")");
        try out.appendSlice(allocator, " (key-source ");
        try environment.writeSchemeString(allocator, out, provider.key_source);
        try out.appendSlice(allocator, ")");
        try out.appendSlice(allocator, " (models");
        for (provider.models) |model| {
            try out.appendSlice(allocator, " ");
            try environment.writeSchemeString(allocator, out, model);
        }
        try out.appendSlice(allocator, ")");
        try out.appendSlice(allocator, ")");
    }
    try out.appendSlice(allocator, " (hash ");
    try environment.writeSchemeString(allocator, out, manifest.hash);
    try out.appendSlice(allocator, "))");
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Manifest {
    const datum = environment.parseDatum(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ManifestMalformed,
    };
    defer environment.freeDatum(allocator, datum);

    var manifest = Manifest{ .api = "" };
    errdefer freeManifest(allocator, manifest);

    var modules: std.ArrayList(Manifest.Module) = .empty;
    errdefer {
        freeModules(allocator, modules.items);
        modules.deinit(allocator);
    }
    var config_decls: std.ArrayList(Manifest.ConfigDecl) = .empty;
    errdefer {
        freeConfigDecls(allocator, config_decls.items);
        config_decls.deinit(allocator);
    }
    var capabilities: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeStrings(allocator, capabilities.items);
        capabilities.deinit(allocator);
    }
    var caps: std.ArrayList(Manifest.Cap) = .empty;
    errdefer {
        freeCaps(allocator, caps.items);
        caps.deinit(allocator);
    }
    var endpoints: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeStrings(allocator, endpoints.items);
        endpoints.deinit(allocator);
    }
    var models: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeStrings(allocator, models.items);
        models.deinit(allocator);
    }

    const fields = switch (datum) {
        .list => |items| items,
        else => return error.ManifestMalformed,
    };
    if (fields.len == 0) return error.ManifestMalformed;
    const head = switch (fields[0]) {
        .symbol => |text| text,
        else => return error.ManifestMalformed,
    };
    if (!std.mem.eql(u8, head, "manifest")) return error.ManifestMalformed;

    var have_api = false;
    var have_modules = false;
    var have_config = false;
    var have_capabilities = false;
    var have_caps = false;
    var have_hash = false;

    for (fields[1..]) |field| {
        const items = switch (field) {
            .list => |items| items,
            else => return error.ManifestMalformed,
        };
        if (items.len == 0) return error.ManifestMalformed;
        const label = switch (items[0]) {
            .symbol => |text| text,
            else => return error.ManifestMalformed,
        };

        if (std.mem.eql(u8, label, "api")) {
            if (have_api) return error.ManifestMalformed;
            have_api = true;
            const text_value = try requiredString(allocator, items[1..]);
            if (text_value.len == 0) return error.ManifestMalformed;
            manifest.api = text_value;
        } else if (std.mem.eql(u8, label, "parent")) {
            if (manifest.parent != null) return error.ManifestMalformed;
            manifest.parent = try requiredString(allocator, items[1..]);
        } else if (std.mem.eql(u8, label, "modules")) {
            if (have_modules) return error.ManifestMalformed;
            have_modules = true;
            for (items[1..]) |module_item| {
                const module_fields = switch (module_item) {
                    .list => |module_fields| module_fields,
                    else => return error.ManifestMalformed,
                };
                if (module_fields.len != 3) return error.ManifestMalformed;
                const module_label = switch (module_fields[0]) {
                    .symbol => |text| text,
                    else => return error.ManifestMalformed,
                };
                if (!std.mem.eql(u8, module_label, "module")) return error.ManifestMalformed;
                const name = try requiredString(allocator, module_fields[1..2]);
                errdefer allocator.free(name);
                const entry = try requiredString(allocator, module_fields[2..3]);
                errdefer allocator.free(entry);
                try modules.append(allocator, .{ .name = environment.ModuleName.init(name), .entry = entry });
            }
        } else if (std.mem.eql(u8, label, "config")) {
            if (have_config) return error.ManifestMalformed;
            have_config = true;
            for (items[1..]) |decl_item| {
                const decl_fields = switch (decl_item) {
                    .list => |decl_fields| decl_fields,
                    else => return error.ManifestMalformed,
                };
                if (decl_fields.len != 5) return error.ManifestMalformed;
                const decl_label = switch (decl_fields[0]) {
                    .symbol => |text| text,
                    else => return error.ManifestMalformed,
                };
                if (!std.mem.eql(u8, decl_label, "decl")) return error.ManifestMalformed;
                const name = try requiredString(allocator, decl_fields[1..2]);
                errdefer allocator.free(name);
                var env_source: ?environment.ConfigSourceVar = null;
                errdefer if (env_source) |env_var| allocator.free(env_var.text);
                const env_list = switch (decl_fields[2]) {
                    .list => |env_list| env_list,
                    else => return error.ManifestMalformed,
                };
                if (env_list.len > 0) {
                    if (env_list.len != 2) return error.ManifestMalformed;
                    const env_label = switch (env_list[0]) {
                        .symbol => |text| text,
                        else => return error.ManifestMalformed,
                    };
                    if (!std.mem.eql(u8, env_label, "env")) return error.ManifestMalformed;
                    env_source = environment.ConfigSourceVar.init(try requiredString(allocator, env_list[1..2]));
                }
                const secret = switch (decl_fields[3]) {
                    .boolean => |secret| secret,
                    else => return error.ManifestMalformed,
                };
                var literal: ?environment.ConfigLiteral = null;
                errdefer if (literal) |owned| allocator.free(owned.text);
                switch (decl_fields[4]) {
                    .string => |text| literal = environment.ConfigLiteral.init(try allocator.dupe(u8, text)),
                    .list => |empty| if (empty.len != 0) return error.ManifestMalformed,
                    else => return error.ManifestMalformed,
                }
                try config_decls.append(allocator, .{
                    .name = name,
                    .env_source = env_source,
                    .secret = secret,
                    .literal = literal,
                });
            }
        } else if (std.mem.eql(u8, label, "capabilities")) {
            if (have_capabilities) return error.ManifestMalformed;
            have_capabilities = true;
            for (items[1..]) |item| {
                const text = switch (item) {
                    .string => |text| text,
                    else => return error.ManifestMalformed,
                };
                const owned = try allocator.dupe(u8, text);
                try capabilities.append(allocator, owned);
            }
        } else if (std.mem.eql(u8, label, "caps")) {
            if (have_caps) return error.ManifestMalformed;
            have_caps = true;
            for (items[1..]) |cap_item| {
                const cap_fields = switch (cap_item) {
                    .list => |cap_fields| cap_fields,
                    else => return error.ManifestMalformed,
                };
                if (cap_fields.len != 3) return error.ManifestMalformed;
                const cap_label = switch (cap_fields[0]) {
                    .symbol => |text| text,
                    else => return error.ManifestMalformed,
                };
                if (!std.mem.eql(u8, cap_label, "cap")) return error.ManifestMalformed;
                const name = try requiredString(allocator, cap_fields[1..2]);
                errdefer allocator.free(name);
                const value = switch (cap_fields[2]) {
                    .integer => |value| value,
                    else => return error.ManifestMalformed,
                };
                try caps.append(allocator, .{ .name = name, .value = value });
            }
        } else if (std.mem.eql(u8, label, "provider")) {
            if (manifest.provider != null) return error.ManifestMalformed;
            manifest.provider = Manifest.Provider{
                .api_kind = "",
                .key_source = "",
                .endpoints = &.{},
                .models = &.{},
            };
            var have_endpoints = false;
            var have_api_kind = false;
            var have_key_source = false;
            var have_models = false;
            for (items[1..]) |sub_item| {
                const sub_fields = switch (sub_item) {
                    .list => |sub_fields| sub_fields,
                    else => return error.ManifestMalformed,
                };
                if (sub_fields.len == 0) return error.ManifestMalformed;
                const sub_label = switch (sub_fields[0]) {
                    .symbol => |text| text,
                    else => return error.ManifestMalformed,
                };
                if (std.mem.eql(u8, sub_label, "endpoints")) {
                    if (have_endpoints) return error.ManifestMalformed;
                    have_endpoints = true;
                    for (sub_fields[1..]) |item| {
                        const text = switch (item) {
                            .string => |text| text,
                            else => return error.ManifestMalformed,
                        };
                        const owned = try allocator.dupe(u8, text);
                        try endpoints.append(allocator, owned);
                    }
                } else if (std.mem.eql(u8, sub_label, "api-kind")) {
                    if (have_api_kind) return error.ManifestMalformed;
                    have_api_kind = true;
                    manifest.provider.?.api_kind = try requiredString(allocator, sub_fields[1..]);
                } else if (std.mem.eql(u8, sub_label, "key-source")) {
                    if (have_key_source) return error.ManifestMalformed;
                    have_key_source = true;
                    manifest.provider.?.key_source = try requiredString(allocator, sub_fields[1..]);
                } else if (std.mem.eql(u8, sub_label, "models")) {
                    if (have_models) return error.ManifestMalformed;
                    have_models = true;
                    for (sub_fields[1..]) |item| {
                        const text = switch (item) {
                            .string => |text| text,
                            else => return error.ManifestMalformed,
                        };
                        const owned = try allocator.dupe(u8, text);
                        try models.append(allocator, owned);
                    }
                } else {
                    return error.ManifestMalformed;
                }
            }
            if (!have_endpoints or !have_api_kind or !have_key_source or !have_models) {
                return error.ManifestMalformed;
            }
        } else if (std.mem.eql(u8, label, "hash")) {
            if (have_hash) return error.ManifestMalformed;
            have_hash = true;
            manifest.hash = try requiredString(allocator, items[1..]);
        } else {
            return error.ManifestMalformed;
        }
    }

    if (!have_api or !have_modules or !have_hash) return error.ManifestMalformed;

    manifest.modules = try modules.toOwnedSlice(allocator);
    manifest.config = try config_decls.toOwnedSlice(allocator);
    manifest.capabilities = try capabilities.toOwnedSlice(allocator);
    manifest.caps = try caps.toOwnedSlice(allocator);
    if (manifest.provider) |*provider| {
        provider.endpoints = try endpoints.toOwnedSlice(allocator);
        provider.models = try models.toOwnedSlice(allocator);
    }

    return manifest;
}

pub fn read(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
) ReadError!Manifest {
    const text = try dir.readFileAlloc(io, sub_path, allocator, .limited(max_file_bytes));
    defer allocator.free(text);
    return parse(allocator, text);
}

pub fn freeManifest(allocator: std.mem.Allocator, manifest: Manifest) void {
    allocator.free(manifest.api);
    if (manifest.parent) |parent| allocator.free(parent);
    freeModules(allocator, manifest.modules);
    allocator.free(manifest.modules);
    freeConfigDecls(allocator, manifest.config);
    allocator.free(manifest.config);
    freeStrings(allocator, manifest.capabilities);
    allocator.free(manifest.capabilities);
    freeCaps(allocator, manifest.caps);
    allocator.free(manifest.caps);
    if (manifest.provider) |provider| {
        freeStrings(allocator, provider.endpoints);
        allocator.free(provider.endpoints);
        allocator.free(provider.api_kind);
        allocator.free(provider.key_source);
        freeStrings(allocator, provider.models);
        allocator.free(provider.models);
    }
    allocator.free(manifest.hash);
}

pub fn computeHash(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    manifest: *const Manifest,
) HashError![]u8 {
    var hashed = manifest.*;
    hashed.hash = "";
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try write(allocator, &buffer, &hashed);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(buffer.items);

    for (hashed.modules) |module| {
        const bytes = try dir.readFileAlloc(io, module.entry, allocator, .limited(max_file_bytes));
        defer allocator.free(bytes);
        hasher.update(bytes);
    }

    var tests_dir = try dir.openDir(io, "tests", .{ .iterate = true });
    defer tests_dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var it = tests_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = try allocator.dupe(u8, entry.name);
        try names.append(allocator, name);
    }
    std.mem.sort([]u8, names.items, {}, nameLessThan);
    for (names.items) |name| {
        const bytes = try tests_dir.readFileAlloc(io, name, allocator, .limited(max_file_bytes));
        defer allocator.free(bytes);
        hasher.update(name);
        hasher.update(bytes);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn buildCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    parent_id: ?[]const u8,
    environ: *const std.process.Environ.Map,
    module_name: []const u8,
    module_source: []const u8,
    test_source: ?[]const u8,
) BuildError!Candidate {
    const generator = uuid.Generator.init(allocator, io);
    const id = try generator.toString(try generator.v4());
    errdefer allocator.free(id);
    return writeCandidate(io, allocator, root, id, parent_id, environ, module_name, module_source, test_source);
}

pub fn writeCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
    parent_id: ?[]const u8,
    environ: *const std.process.Environ.Map,
    module_name: []const u8,
    module_source: []const u8,
    test_source: ?[]const u8,
) BuildError!Candidate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    const gen_dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, id });
    if (cwd.statFile(io, gen_dir_path, .{})) |_| return error.IdExists else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }

    var parent_parent_dir: ?std.Io.Dir = null;
    var parent: ?Manifest = null;
    if (parent_id) |pid| {
        const parent_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, pid });
        parent_parent_dir = cwd.openDir(io, parent_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ParentMissing,
            else => |e| return e,
        };
        parent = read(io, a, parent_parent_dir.?, "manifest.sexp") catch |err| switch (err) {
            error.FileNotFound => return error.ParentMissing,
            error.ManifestMalformed => return error.ManifestMalformed,
            else => |rest| return rest,
        };
    }

    try cwd.createDirPath(io, try std.fmt.allocPrint(a, "{s}/sources", .{gen_dir_path}));
    try cwd.createDirPath(io, try std.fmt.allocPrint(a, "{s}/tests", .{gen_dir_path}));

    if (parent_parent_dir) |parent_dir| {
        defer parent_dir.close(io);
        if (parent) |p| {
            for (p.modules) |module| {
                const bytes = try parent_dir.readFileAlloc(io, module.entry, a, .limited(max_file_bytes));
                const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ gen_dir_path, module.entry });
                try cwd.writeFile(io, .{ .sub_path = dest, .data = bytes });
            }
        }
        if (parent_dir.openDir(io, "tests", .{ .iterate = true })) |dd| {
            var tests_dir = dd;
            defer tests_dir.close(io);
            var it = tests_dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) continue;
                const bytes = try tests_dir.readFileAlloc(io, entry.name, a, .limited(max_file_bytes));
                const dest = try std.fmt.allocPrint(a, "{s}/tests/{s}", .{ gen_dir_path, entry.name });
                try cwd.writeFile(io, .{ .sub_path = dest, .data = bytes });
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }

    const module_entry = try std.fmt.allocPrint(a, "sources/{s}.scm", .{module_name});
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ gen_dir_path, module_entry }),
        .data = module_source,
    });
    if (test_source) |source| {
        try cwd.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(a, "{s}/tests/{s}.scm", .{ gen_dir_path, module_name }),
            .data = source,
        });
    }

    var child = Manifest{ .api = default_api };
    var modules: std.ArrayList(Manifest.Module) = .empty;
    var replaced = false;
    if (parent) |p| {
        child.api = p.api;
        child.capabilities = p.capabilities;
        child.caps = p.caps;
        child.provider = p.provider;
        for (p.modules) |module| {
            if (std.mem.eql(u8, module.name.text, module_name)) {
                replaced = true;
                try modules.append(a, .{ .name = module.name, .entry = module_entry });
            } else {
                try modules.append(a, module);
            }
        }
    }
    if (!replaced) try modules.append(a, .{ .name = environment.ModuleName.init(module_name), .entry = module_entry });
    child.modules = try modules.toOwnedSlice(a);

    var config_decls: std.ArrayList(Manifest.ConfigDecl) = .empty;
    if (parent) |p| {
        for (p.config) |decl| {
            var baked = decl;
            if (decl.secret) {
                if (decl.literal != null) return error.SecretLiteral;
                baked.literal = null;
            } else if (decl.literal == null) {
                const source = decl.env_source orelse return error.ConfigUnresolved;
                baked.literal = environment.ConfigLiteral.init(environ.get(source.text) orelse return error.ConfigUnresolved);
            }
            try config_decls.append(a, baked);
        }
    }
    child.config = try config_decls.toOwnedSlice(a);
    child.parent = parent_id;

    var gen_dir = try cwd.openDir(io, gen_dir_path, .{});
    defer gen_dir.close(io);
    const hash = try computeHash(io, a, gen_dir, &child);
    child.hash = hash;

    var serialized: std.ArrayList(u8) = .empty;
    try write(a, &serialized, &child);
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/manifest.sexp", .{gen_dir_path}),
        .data = serialized.items,
    });

    try ledger.append(io, allocator, root, .{
        .id = id,
        .parent = parent_id orelse "",
        .hash = hash,
        .status = .candidate,
        .evidence = "",
    });

    return .{ .id = id, .hash = try allocator.dupe(u8, hash) };
}

fn requiredString(allocator: std.mem.Allocator, items: []const environment.Datum) ParseError![]u8 {
    if (items.len != 1) return error.ManifestMalformed;
    return switch (items[0]) {
        .string => |text| allocator.dupe(u8, text),
        else => error.ManifestMalformed,
    };
}

fn freeModules(allocator: std.mem.Allocator, modules: []const Manifest.Module) void {
    for (modules) |module| {
        allocator.free(module.name.text);
        allocator.free(module.entry);
    }
}

fn freeConfigDecls(allocator: std.mem.Allocator, decls: []const Manifest.ConfigDecl) void {
    for (decls) |decl| {
        allocator.free(decl.name);
        if (decl.env_source) |source| allocator.free(source.text);
        if (decl.literal) |literal| allocator.free(literal.text);
    }
}

fn freeCaps(allocator: std.mem.Allocator, caps: []const Manifest.Cap) void {
    for (caps) |cap| allocator.free(cap.name);
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "manifest round-trips through its written representation" {
    const a = std.testing.allocator;
    const source = Manifest{
        .api = "1",
        .parent = "0f19c1d2-d0c7-4a67-9d0e-13bfa4c2aaa1",
        .modules = &.{
            .{ .name = environment.ModuleName.init("alpha"), .entry = "sources/alpha.scm" },
            .{ .name = environment.ModuleName.init("beta"), .entry = "sources/beta.scm" },
        },
        .config = &.{
            .{ .name = "plain", .env_source = environment.ConfigSourceVar.init("PLAIN_VAR"), .literal = environment.ConfigLiteral.init("resolved") },
            .{ .name = "hidden", .env_source = environment.ConfigSourceVar.init("SECRET_VAR"), .secret = true },
            .{ .name = "fixed", .literal = environment.ConfigLiteral.init("42") },
            .{ .name = "unset" },
        },
        .capabilities = &.{ "spawn", "promote" },
        .caps = &.{ .{ .name = "brain", .value = -3 }, .{ .name = "seconds", .value = 120 } },
        .provider = .{
            .endpoints = &.{ "https://opencode.ai", "https://mirror.local" },
            .api_kind = "openai",
            .key_source = "env:OPENCODE_API_KEY",
            .models = &.{ "model-a", "model-b" },
        },
        .hash = "5a1d1aa1a0f5",
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try write(a, &out, &source);

    const parsed = try parse(a, out.items);
    defer freeManifest(a, parsed);

    try std.testing.expectEqualStrings(source.api, parsed.api);
    try std.testing.expectEqualStrings(source.parent.?, parsed.parent.?);
    try std.testing.expectEqual(source.modules.len, parsed.modules.len);
    for (source.modules, parsed.modules) |expected, got| {
        try std.testing.expectEqualStrings(expected.name.text, got.name.text);
        try std.testing.expectEqualStrings(expected.entry, got.entry);
    }
    try std.testing.expectEqual(source.config.len, parsed.config.len);
    for (source.config, parsed.config) |expected, got| {
        try std.testing.expectEqualStrings(expected.name, got.name);
        if (expected.env_source) |env_source| {
            try std.testing.expectEqualStrings(env_source.text, got.env_source.?.text);
        } else {
            try std.testing.expect(got.env_source == null);
        }
        try std.testing.expectEqual(expected.secret, got.secret);
        if (expected.literal) |literal| {
            try std.testing.expectEqualStrings(literal.text, got.literal.?.text);
        } else {
            try std.testing.expect(got.literal == null);
        }
    }
    try std.testing.expectEqual(source.capabilities.len, parsed.capabilities.len);
    for (source.capabilities, parsed.capabilities) |expected, got| {
        try std.testing.expectEqualStrings(expected, got);
    }
    try std.testing.expectEqual(source.caps.len, parsed.caps.len);
    for (source.caps, parsed.caps) |expected, got| {
        try std.testing.expectEqualStrings(expected.name, got.name);
        try std.testing.expectEqual(expected.value, got.value);
    }
    const provider = parsed.provider.?;
    try std.testing.expectEqualStrings(source.provider.?.api_kind, provider.api_kind);
    try std.testing.expectEqualStrings(source.provider.?.key_source, provider.key_source);
    try std.testing.expectEqual(source.provider.?.endpoints.len, provider.endpoints.len);
    for (source.provider.?.endpoints, provider.endpoints) |expected, got| {
        try std.testing.expectEqualStrings(expected, got);
    }
    try std.testing.expectEqual(source.provider.?.models.len, provider.models.len);
    for (source.provider.?.models, provider.models) |expected, got| {
        try std.testing.expectEqualStrings(expected, got);
    }
    try std.testing.expectEqualStrings(source.hash, parsed.hash);
}

test "write omits absent optional blocks" {
    const a = std.testing.allocator;
    const source = Manifest{ .api = "1", .hash = "h" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try write(a, &out, &source);
    try std.testing.expectEqualStrings(
        "(manifest (api \"1\") (modules) (config) (capabilities) (caps) (hash \"h\"))",
        out.items,
    );

    const parsed = try parse(a, out.items);
    defer freeManifest(a, parsed);
    try std.testing.expect(parsed.parent == null);
    try std.testing.expect(parsed.provider == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.modules.len);
}

test "parse rejects malformed manifests" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "(",
        "(manifest)",
        "(manifest (api \"1\"))",
        "(manifest (api \"1\") (modules))",
        "(manifest (api \"1\") (hash \"h\"))",
        "(manifest (api \"\") (modules) (hash \"h\"))",
        "(manifest (api \"1\") (api \"2\") (modules) (hash \"h\"))",
        "(manifest (api \"1\") (modules (module \"a\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules (module \"a\" \"b\" \"c\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules (tool \"a\" \"b\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (config (decl \"k\" \"VAR\" #f \"v\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (config (decl \"k\" (env \"VAR\") \"secret\" \"v\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (capabilities 3) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (caps (cap \"c\" \"3\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (provider (endpoints \"u\") (api-kind \"openai\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (provider (endpoints \"u\") (api-kind \"openai\") (key-source \"k\") (models \"m\") (endpoints \"v\")) (hash \"h\"))",
        "(manifest (api \"1\") (modules) (bogus) (hash \"h\"))",
        "(generation \"id\" (parent \"p\"))",
    };
    for (cases) |case| {
        try std.testing.expectError(error.ManifestMalformed, parse(a, case));
    }
}
