const std = @import("std");
const generations = @import("generations");
const environment = @import("environment");

const manifest = generations.manifest;
const ledger = generations.ledger;
const Manifest = generations.Manifest;

const alpha_source = "(define alpha-budget 42)\n";
const alpha_test = "(assert #t)\n";

const Root = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn deinit(self: *Root, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn startRoot(allocator: std.mem.Allocator) !Root {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    return .{ .tmp = tmp, .path = path };
}

fn seedParentGeneration(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
    config: []const Manifest.ConfigDecl,
) !void {
    const cwd = std.Io.Dir.cwd();
    const gen_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id });
    defer allocator.free(gen_dir);
    const sources_dir = try std.fmt.allocPrint(allocator, "{s}/sources", .{gen_dir});
    defer allocator.free(sources_dir);
    const tests_dir = try std.fmt.allocPrint(allocator, "{s}/tests", .{gen_dir});
    defer allocator.free(tests_dir);
    try cwd.createDirPath(io, sources_dir);
    try cwd.createDirPath(io, tests_dir);
    const module_path = try std.fmt.allocPrint(allocator, "{s}/sources/alpha.scm", .{gen_dir});
    defer allocator.free(module_path);
    try cwd.writeFile(io, .{ .sub_path = module_path, .data = alpha_source });
    const test_path = try std.fmt.allocPrint(allocator, "{s}/tests/alpha.scm", .{gen_dir});
    defer allocator.free(test_path);
    try cwd.writeFile(io, .{ .sub_path = test_path, .data = alpha_test });

    var parent = Manifest{
        .api = "1",
        .modules = &.{
            .{ .name = environment.ModuleName.init("alpha"), .entry = "sources/alpha.scm" },
        },
        .config = config,
        .capabilities = &.{"seeded"},
        .caps = &.{.{ .name = "limit", .value = 7 }},
    };
    var gen = try cwd.openDir(io, gen_dir, .{});
    defer gen.close(io);
    const hash = try manifest.computeHash(io, allocator, gen, &parent);
    defer allocator.free(hash);
    parent.hash = hash;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try manifest.write(allocator, &text, &parent);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.sexp", .{gen_dir});
    defer allocator.free(manifest_path);
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = text.items });
    try ledger.append(io, allocator, root, .{
        .id = id,
        .parent = "",
        .hash = hash,
        .status = .candidate,
        .evidence = "",
    });
}

const parent_id = "00000000-0000-4000-8000-000000000001";

fn defaultParentConfig() []const Manifest.ConfigDecl {
    const decls = [_]Manifest.ConfigDecl{
        .{ .name = "plain", .env_source = environment.ConfigSourceVar.init("GENERATIONS_TEST_FOO") },
        .{ .name = "secret", .env_source = environment.ConfigSourceVar.init("GENERATIONS_TEST_SECRET"), .secret = true },
        .{ .name = "fixed", .literal = environment.ConfigLiteral.init("already-baked") },
    };
    return &decls;
}

test "the builder forks a parent into an immutable candidate and the ledger keeps every event" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root = try startRoot(a);
    defer root.deinit(a);
    const cwd = std.Io.Dir.cwd();

    try seedParentGeneration(io, a, root.path, parent_id, defaultParentConfig());

    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("GENERATIONS_TEST_FOO", "resolved-1");

    const child = try generations.buildCandidate(io, a, root.path, parent_id, &environ, "beta", "(define beta #t)\n", "(assert #t)\n");
    defer a.free(child.id);
    defer a.free(child.hash);

    try std.testing.expect(!std.mem.eql(u8, child.id, parent_id));

    const child_path = try std.fmt.allocPrint(a, "{s}/{s}/manifest.sexp", .{ root.path, child.id });
    defer a.free(child_path);
    const child_manifest = try manifest.read(io, a, cwd, child_path);
    defer manifest.freeManifest(a, child_manifest);

    try std.testing.expectEqualStrings(parent_id, child_manifest.parent.?);
    try std.testing.expectEqualStrings("1", child_manifest.api);
    try std.testing.expectEqual(@as(usize, 2), child_manifest.modules.len);
    try std.testing.expectEqualStrings("alpha", child_manifest.modules[0].name.text);
    try std.testing.expectEqualStrings("sources/alpha.scm", child_manifest.modules[0].entry);
    try std.testing.expectEqualStrings("beta", child_manifest.modules[1].name.text);
    try std.testing.expectEqualStrings("sources/beta.scm", child_manifest.modules[1].entry);
    try std.testing.expectEqual(@as(usize, 3), child_manifest.config.len);
    try std.testing.expectEqualStrings("resolved-1", child_manifest.config[0].literal.?.text);
    try std.testing.expectEqualStrings("GENERATIONS_TEST_FOO", child_manifest.config[0].env_source.?.text);
    try std.testing.expect(child_manifest.config[1].secret);
    try std.testing.expect(child_manifest.config[1].literal == null);
    try std.testing.expectEqualStrings("already-baked", child_manifest.config[2].literal.?.text);
    try std.testing.expect(child_manifest.provider == null);
    try std.testing.expectEqualStrings("seeded", child_manifest.capabilities[0]);
    try std.testing.expectEqual(@as(i64, 7), child_manifest.caps[0].value);

    const child_open_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root.path, child.id });
    defer a.free(child_open_path);
    var child_dir = try cwd.openDir(io, child_open_path, .{});
    defer child_dir.close(io);
    const copied_module = try child_dir.readFileAlloc(io, "sources/alpha.scm", a, .limited(64));
    try std.testing.expectEqualStrings(alpha_source, copied_module);
    const copied_test = try child_dir.readFileAlloc(io, "tests/alpha.scm", a, .limited(64));
    try std.testing.expectEqualStrings(alpha_test, copied_test);
    const new_test = try child_dir.readFileAlloc(io, "tests/beta.scm", a, .limited(64));
    try std.testing.expectEqualStrings("(assert #t)\n", new_test);
    a.free(copied_module);
    a.free(copied_test);
    a.free(new_test);

    var blanked = child_manifest;
    blanked.hash = "";
    const recomputed = try manifest.computeHash(io, a, child_dir, &blanked);
    defer a.free(recomputed);
    try std.testing.expectEqualStrings(child_manifest.hash, recomputed);

    const events = try ledger.read(io, a, root.path);
    defer ledger.freeEvents(a, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings(parent_id, events[0].id);
    try std.testing.expectEqual(generations.LedgerStatus.candidate, events[0].status);
    try std.testing.expectEqualStrings(child.id, events[1].id);
    try std.testing.expectEqualStrings(parent_id, events[1].parent);
    try std.testing.expectEqualStrings(child_manifest.hash, events[1].hash);

    try ledger.setActive(io, a, root.path, child.id);
    const active = try ledger.getActive(io, a, root.path);
    defer a.free(active);
    try std.testing.expectEqualStrings(child.id, active);

    try ledger.setActive(io, a, root.path, parent_id);
    const rolled_back = try ledger.getActive(io, a, root.path);
    defer a.free(rolled_back);
    try std.testing.expectEqualStrings(parent_id, rolled_back);

    const promoted = try ledger.read(io, a, root.path);
    defer ledger.freeEvents(a, promoted);
    try std.testing.expectEqual(@as(usize, 4), promoted.len);
    try std.testing.expectEqual(generations.LedgerStatus.promoted, promoted[2].status);
    try std.testing.expectEqualStrings(child.id, promoted[2].id);
    try std.testing.expectEqual(generations.LedgerStatus.promoted, promoted[3].status);
    try std.testing.expectEqualStrings(parent_id, promoted[3].id);

    try std.testing.expectError(error.GenerationMissing, ledger.setActive(io, a, root.path, "ffffffff-0000-4000-8000-000000000009"));
}

fn parseEventFieldTree(allocator: std.mem.Allocator, text: []const u8) !void {
    const datum = try environment.parseDatum(allocator, text);
    defer environment.freeDatum(allocator, datum);
    const fields = switch (datum) {
        .list => |items| items,
        else => return error.NotAList,
    };
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    for (fields) |field| {
        switch (field) {
            .list => |items| try std.testing.expectEqual(@as(usize, 2), items.len),
            else => return error.NotAnEventField,
        }
    }
}

test "ledger event lines parse with the shared written-representation parser" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root = try startRoot(a);
    defer root.deinit(a);

    try ledger.append(io, a, root.path, .{ .id = "id-1", .parent = "", .hash = "ab\"c", .status = .candidate, .evidence = "e\nd" });

    const ledger_path = try std.fmt.allocPrint(a, "{s}/ledger.sexp", .{root.path});
    defer a.free(ledger_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, ledger_path, a, .limited(1024));
    defer a.free(text);
    try parseEventFieldTree(a, text);

    const events = try ledger.read(io, a, root.path);
    defer ledger.freeEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ab\"c", events[0].hash);
    try std.testing.expectEqualStrings("e\nd", events[0].evidence);
}

test "identical trees hash identically and edits change the hash" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root = try startRoot(a);
    defer root.deinit(a);

    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();

    const first = try generations.buildCandidate(io, a, root.path, null, &environ, "alpha", alpha_source, null);
    defer a.free(first.id);
    defer a.free(first.hash);
    const second = try generations.buildCandidate(io, a, root.path, null, &environ, "alpha", alpha_source, null);
    defer a.free(second.id);
    defer a.free(second.hash);
    const third = try generations.buildCandidate(io, a, root.path, null, &environ, "alpha", "(define alpha-budget 43)\n", null);
    defer a.free(third.id);
    defer a.free(third.hash);
    const fourth = try generations.buildCandidate(io, a, root.path, null, &environ, "alpha", alpha_source, alpha_test);
    defer a.free(fourth.id);
    defer a.free(fourth.hash);
    const fifth = try generations.buildCandidate(io, a, root.path, null, &environ, "beta", alpha_source, null);
    defer a.free(fifth.id);
    defer a.free(fifth.hash);

    try std.testing.expectEqualStrings(first.hash, second.hash);
    try std.testing.expect(!std.mem.eql(u8, first.hash, third.hash));
    try std.testing.expect(!std.mem.eql(u8, first.hash, fourth.hash));
    try std.testing.expect(!std.mem.eql(u8, first.hash, fifth.hash));

    const counted = try ledger.read(io, a, root.path);
    defer ledger.freeEvents(a, counted);
    try std.testing.expectEqual(@as(usize, 5), counted.len);
}

test "a fixed id can only be written once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root = try startRoot(a);
    defer root.deinit(a);

    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();

    const seeded = try generations.writeCandidate(io, a, root.path, "aaaaaaaa-0000-4000-8000-000000000002", null, &environ, "alpha", alpha_source, null);
    defer a.free(seeded.hash);
    try std.testing.expectEqualStrings("aaaaaaaa-0000-4000-8000-000000000002", seeded.id);

    try std.testing.expectError(error.IdExists, generations.writeCandidate(io, a, root.path, "aaaaaaaa-0000-4000-8000-000000000002", null, &environ, "alpha", alpha_source, null));

    const events = try ledger.read(io, a, root.path);
    defer ledger.freeEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
}

test "unresolvable config refuses to bake" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root = try startRoot(a);
    defer root.deinit(a);

    const unresolved = [_]Manifest.ConfigDecl{
        .{ .name = "plain", .env_source = environment.ConfigSourceVar.init("GENERATIONS_TEST_MISSING_VAR") },
    };
    try seedParentGeneration(io, a, root.path, parent_id, &unresolved);

    const broken_secret_id = "00000000-0000-4000-8000-000000000002";
    const broken_secret = [_]Manifest.ConfigDecl{
        .{ .name = "broken", .env_source = environment.ConfigSourceVar.init("ANY"), .secret = true, .literal = environment.ConfigLiteral.init("oops") },
    };
    try seedParentGeneration(io, a, root.path, broken_secret_id, &broken_secret);

    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();

    try std.testing.expectError(error.ConfigUnresolved, generations.buildCandidate(io, a, root.path, parent_id, &environ, "beta", "(define beta #t)\n", null));
    try std.testing.expectError(error.SecretLiteral, generations.buildCandidate(io, a, root.path, broken_secret_id, &environ, "beta", "(define beta #t)\n", null));

    const events = try ledger.read(io, a, root.path);
    defer ledger.freeEvents(a, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
}
