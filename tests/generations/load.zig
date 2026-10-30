const std = @import("std");
const generations = @import("generations");
const environment = @import("environment");

const allocator = std.testing.allocator;
const io = std.testing.io;

const fixture_root = "tests/generations/testdata/root";
const fixture_id = "00000000-0000-4000-8000-000000000100";
const fixture_var = "GENERATIONS_TEST_FIXTURE_FOO";

const fixture_environ_value = "fixture-value";

const beta_source =
    \\(import scheme (chicken base) (chicken condition) (chicken port) hen-plugin)
    \\
    \\(define beta-value "beta-value")
    \\
    \\(register-tool! 'probe
    \\  #:summary "Returns beta's value."
    \\  #:when "A beta tool answers one value."
    \\  #:description "A simple probe tool from beta."
    \\  #:shape '(text)
    \\  #:handler (lambda (args) beta-value))
;

const beta_test =
    \\(hen:tools/call! 'beta-probe '())
    \\(hen:assert! (hen:tools/fetch) "beta-value")
;

const alpha_replacement_source =
    \\(import scheme (chicken base) (chicken condition) (chicken port) hen-plugin)
    \\
    \\(define alpha-pin (config 'alpha-pin #:sources (env "GENERATIONS_TEST_FIXTURE_FOO")))
    \\
    \\(register-tool! 'pin
    \\  #:summary "Updated pin summary."
    \\  #:when "A pin tool answers one value."
    \\  #:description "The updated pin description."
    \\  #:shape '(text)
    \\  #:handler (lambda (args) alpha-pin))
;

const gamma_source =
    \\(import scheme (chicken base) (chicken condition) (chicken port) hen-plugin)
    \\
    \\(register-module! 'side)
    \\
    \\(register-tool! 'probe
    \\  #:summary "A sideways probe."
    \\  #:when "A sideways tool answers one value."
    \\  #:description "Published under a module the manifest does not declare."
    \\  #:handler (lambda (args) "side-value"))
;

const broken_source = "(undefined-source-symbol)\n";

const delta_source =
    \\(import scheme (chicken base) (chicken condition) (chicken port) hen-plugin)
    \\
    \\(define delta-value "delta-value")
    \\
    \\(register-tool! 'probe
    \\  #:summary "Returns delta's value."
    \\  #:when "A delta tool answers one value."
    \\  #:description "A simple probe tool from delta."
    \\  #:shape '(text)
    \\  #:handler (lambda (args) delta-value))
;

const delta_test = "(hen:assert! \"one\" \"two\")\n";

test "a missing config value fails before the runtime starts" {
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    try std.testing.expectError(
        error.ConfigUnresolved,
        generations.prepare(io, allocator, fixture_root, fixture_id, &environ),
    );
}

test "the committed fixture manifest matches the committed tree" {
    const gen_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ fixture_root, fixture_id });
    defer allocator.free(gen_path);

    const cwd = std.Io.Dir.cwd();
    var gen_dir = try cwd.openDir(io, gen_path, .{});
    defer gen_dir.close(io);
    const written = try generations.manifest.read(io, allocator, gen_dir, "manifest.sexp");
    defer generations.manifest.freeManifest(allocator, written);

    try std.testing.expectEqualStrings(environment.bridge_api_version, written.api);
    try std.testing.expectEqual(@as(usize, 1), written.modules.len);
    try std.testing.expectEqualStrings("alpha", written.modules[0].name.text);
    try std.testing.expectEqual(@as(usize, 1), written.config.len);
    try std.testing.expect(written.config[0].secret == false);

    const hash = try generations.computeHash(io, allocator, gen_dir, &written);
    defer allocator.free(hash);
    try std.testing.expectEqualStrings(written.hash, hash);
}

test "the fixture generation loads into a fresh Env in the manifest order" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put(fixture_var, fixture_environ_value);

    const prepared = try generations.prepare(io, a, fixture_root, fixture_id, &environ);
    defer generations.freePrepared(a, prepared);

    try std.testing.expectEqual(@as(usize, 1), prepared.entries.len);
    try std.testing.expectEqualStrings("alpha", prepared.entries[0].name.text);
    try std.testing.expect(std.fs.path.isAbsolute(prepared.entries[0].path.text));
    try std.testing.expectEqualStrings(fixture_var, prepared.configs[0].source_var.text);
    try std.testing.expectEqualStrings(fixture_environ_value, prepared.configs[0].value.text);

    var env = try generations.initEnv(a, prepared);

    const descs = try env.tools(a);
    try std.testing.expectEqual(@as(usize, 1), descs.len);
    try std.testing.expectEqualStrings("alpha-pin", descs[0].name);
    try std.testing.expectEqualStrings("Returns the fixture value.", descs[0].summary);
    try std.testing.expectEqualStrings("A pin tool answers one value.", descs[0].when);

    const observed = try env.call(a, "(hen:tools/call! 'alpha-pin '())");
    try std.testing.expectEqualStrings(fixture_environ_value, observed);

    const internals = try env.call(a, "alpha-pin");
    try std.testing.expect(std.mem.startsWith(u8, internals, "Error: "));
    try std.testing.expect(std.mem.indexOf(u8, internals, "unbound variable") != null);
}

fn scratchDirPath(sub_path: []const u8) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, sub_path });
}

fn fixtureEnviron() !std.process.Environ.Map {
    var environ = std.process.Environ.Map.init(allocator);
    errdefer environ.deinit();
    try environ.put(fixture_var, fixture_environ_value);
    return environ;
}

fn copyTree(a: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, destination);
    var dir = try cwd.openDir(io, source, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const source_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ source, entry.name });
        const destination_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ destination, entry.name });
        switch (entry.kind) {
            .directory => try copyTree(a, source_path, destination_path),
            .file => {
                const bytes = try cwd.readFileAlloc(io, source_path, a, .limited(4 * 1024 * 1024));
                try cwd.writeFile(io, .{ .sub_path = destination_path, .data = bytes });
            },
            else => {},
        }
    }
}

fn findCheck(report: generations.GateReport, name: []const u8) ?generations.GateCheck {
    for (report.checks) |check| {
        if (std.mem.eql(u8, check.name, name)) return check;
    }
    return null;
}

test "the gate passes the fixture candidate and records the evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try scratchDirPath(&tmp.sub_path);
    defer allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try copyTree(scratch, fixture_root, root_path);

    var environ = try fixtureEnviron();
    defer environ.deinit();

    const report = try generations.runGate(io, allocator, root_path, fixture_id, &environ);
    defer generations.freeGateReport(allocator, report);

    try std.testing.expectEqual(generations.GateResult.pass, report.result);
    try std.testing.expectEqualStrings(fixture_id, report.id);
    try std.testing.expectEqualStrings("", report.parent);

    const names = [_][]const u8{
        "module-load",
        "tools-list",
        "lint",
        "smoke",
        "test:tests/alpha.scm",
        "undo",
        "capabilities",
    };
    try std.testing.expectEqual(names.len, report.checks.len);
    for (names, report.checks) |expected, check| {
        try std.testing.expectEqualStrings(expected, check.name);
        try std.testing.expectEqual(generations.GateResult.pass, check.result);
    }
    try std.testing.expectEqualStrings("0 tools after undo", findCheck(report, "undo").?.detail);

    try std.testing.expectEqual(@as(usize, 1), report.diff.added.len);
    try std.testing.expectEqualStrings("alpha-pin", report.diff.added[0]);
    try std.testing.expectEqual(@as(usize, 0), report.diff.removed.len);
    try std.testing.expectEqual(@as(usize, 0), report.diff.changed.len);

    try std.testing.expect(std.mem.startsWith(u8, report.sexp, "(gate (generation \""));
    try std.testing.expect(std.mem.endsWith(u8, report.sexp, "(result pass))"));

    const events = try generations.ledger.read(io, allocator, root_path);
    defer generations.ledger.freeEvents(allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    const last = events[events.len - 1];
    try std.testing.expectEqualStrings(fixture_id, last.id);
    try std.testing.expectEqualStrings("", last.parent);
    try std.testing.expectEqual(generations.LedgerStatus.candidate, last.status);
    try std.testing.expect(std.mem.startsWith(u8, last.evidence, "(gate (generation \""));

    const registry_path = try std.fmt.allocPrint(scratch, "{s}/{s}/registry.sexp", .{ root_path, fixture_id });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, registry_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "(\"alpha-pin\" \"Returns the fixture value.\""));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "(text))\n"));
}

test "the gate fails a candidate whose module source does not load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try scratchDirPath(&tmp.sub_path);
    defer allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try copyTree(scratch, fixture_root, root_path);

    var environ = try fixtureEnviron();
    defer environ.deinit();

    const candidate = try generations.buildCandidate(io, allocator, root_path, fixture_id, &environ, "broken", broken_source, null);
    defer allocator.free(candidate.id);
    defer allocator.free(candidate.hash);

    const report = try generations.runGate(io, allocator, root_path, candidate.id, &environ);
    defer generations.freeGateReport(allocator, report);

    try std.testing.expectEqual(generations.GateResult.fail, report.result);
    const module_load = findCheck(report, "module-load").?;
    try std.testing.expectEqual(generations.GateResult.fail, module_load.result);
    try std.testing.expect(std.mem.startsWith(u8, module_load.detail, "module load failed: Error: "));
    try std.testing.expect(findCheck(report, "smoke") == null);
    try std.testing.expectEqualStrings("0 tools after undo", findCheck(report, "undo").?.detail);

    try std.testing.expectEqual(@as(usize, 0), report.diff.added.len);
    try std.testing.expectEqual(@as(usize, 0), report.diff.removed.len);
    try std.testing.expectEqual(@as(usize, 0), report.diff.changed.len);
    try std.testing.expect(std.mem.indexOf(u8, report.sexp, "(result fail)") != null);

    const events = try generations.ledger.read(io, allocator, root_path);
    defer generations.ledger.freeEvents(allocator, events);
    const last = events[events.len - 1];
    try std.testing.expectEqualStrings(candidate.id, last.id);
    try std.testing.expectEqualStrings(fixture_id, last.parent);
    try std.testing.expectEqual(generations.LedgerStatus.failed, last.status);
    try std.testing.expect(std.mem.startsWith(u8, last.evidence, "(gate (generation \""));
}

test "the gate fails a candidate whose config value is missing before any runtime starts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try scratchDirPath(&tmp.sub_path);
    defer allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const sources_dir = try std.fmt.allocPrint(scratch, "{s}/sources", .{root_path});
    try cwd.createDirPath(io, sources_dir);
    const sources_path = try std.fmt.allocPrint(scratch, "{s}/sources/alpha.scm", .{root_path});
    try cwd.writeFile(io, .{ .sub_path = sources_path, .data = "(define alpha-pin \"pin\")\n" });
    const manifest_text = "(manifest (api \"1\") (modules (module \"alpha\" \"sources/alpha.scm\")) (config (decl \"alpha-pin\" (env \"GENERATIONS_TEST_ABSENT_FOO\") #f ())) (capabilities) (caps) (hash \"h\"))\n";
    const manifest_path = try std.fmt.allocPrint(scratch, "{s}/manifest.sexp", .{root_path});
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_text });

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    const report = try generations.runGate(io, allocator, root_path, ".", &environ);
    defer generations.freeGateReport(allocator, report);

    try std.testing.expectEqual(generations.GateResult.fail, report.result);
    try std.testing.expectEqual(@as(usize, 2), report.checks.len);
    const prepare_check = findCheck(report, "prepare").?;
    try std.testing.expectEqual(generations.GateResult.fail, prepare_check.result);
    try std.testing.expectEqualStrings("load failed: ConfigUnresolved", prepare_check.detail);
    try std.testing.expect(findCheck(report, "undo") == null);

    const events = try generations.ledger.read(io, allocator, root_path);
    defer generations.ledger.freeEvents(allocator, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings(".", events[0].id);
    try std.testing.expectEqualStrings("h", events[0].hash);
    try std.testing.expectEqual(generations.LedgerStatus.failed, events[0].status);

    const registry_path = try std.fmt.allocPrint(scratch, "{s}/registry.sexp", .{root_path});
    const cwd_result = cwd.statFile(io, registry_path, .{});
    try std.testing.expectError(error.FileNotFound, cwd_result);
}

test "the gate fails the lint on a tool outside the manifest modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try scratchDirPath(&tmp.sub_path);
    defer allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try copyTree(scratch, fixture_root, root_path);

    var environ = try fixtureEnviron();
    defer environ.deinit();

    const candidate = try generations.buildCandidate(io, allocator, root_path, fixture_id, &environ, "gamma", gamma_source, null);
    defer allocator.free(candidate.id);
    defer allocator.free(candidate.hash);

    const report = try generations.runGate(io, allocator, root_path, candidate.id, &environ);
    defer generations.freeGateReport(allocator, report);

    try std.testing.expectEqual(generations.GateResult.fail, report.result);
    const lint = findCheck(report, "lint").?;
    try std.testing.expectEqual(generations.GateResult.fail, lint.result);
    try std.testing.expect(std.mem.indexOf(u8, lint.detail, "module-less: side-probe") != null);
    try std.testing.expectEqual(generations.GateResult.pass, findCheck(report, "smoke").?.result);
    try std.testing.expectEqualStrings("0 tools after undo", findCheck(report, "undo").?.detail);

    const events = try generations.ledger.read(io, allocator, root_path);
    defer generations.ledger.freeEvents(allocator, events);
    try std.testing.expectEqual(generations.LedgerStatus.failed, events[events.len - 1].status);
}

test "the gate fails on a tool test that asserts a wrong value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try scratchDirPath(&tmp.sub_path);
    defer allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try copyTree(scratch, fixture_root, root_path);

    var environ = try fixtureEnviron();
    defer environ.deinit();

    const candidate = try generations.buildCandidate(io, allocator, root_path, fixture_id, &environ, "delta", delta_source, delta_test);
    defer allocator.free(candidate.id);
    defer allocator.free(candidate.hash);

    const report = try generations.runGate(io, allocator, root_path, candidate.id, &environ);
    defer generations.freeGateReport(allocator, report);

    try std.testing.expectEqual(generations.GateResult.fail, report.result);
    const delta_check = findCheck(report, "test:tests/delta.scm").?;
    try std.testing.expectEqual(generations.GateResult.fail, delta_check.result);
    try std.testing.expect(std.mem.startsWith(u8, delta_check.detail, "Error: "));
    try std.testing.expect(std.mem.indexOf(u8, delta_check.detail, "assertion failed") != null);
    try std.testing.expectEqual(generations.GateResult.pass, findCheck(report, "test:tests/alpha.scm").?.result);
    try std.testing.expectEqual(generations.GateResult.pass, findCheck(report, "lint").?.result);
    try std.testing.expectEqualStrings("0 tools after undo", findCheck(report, "undo").?.detail);

    const events = try generations.ledger.read(io, allocator, root_path);
    defer generations.ledger.freeEvents(allocator, events);
    try std.testing.expectEqual(generations.LedgerStatus.failed, events[events.len - 1].status);
}

test "the gate diffs the candidate registry against the parent records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try scratchDirPath(&tmp.sub_path);
    defer allocator.free(root_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try copyTree(scratch, fixture_root, root_path);

    var environ = try fixtureEnviron();
    defer environ.deinit();

    const base = try generations.runGate(io, allocator, root_path, fixture_id, &environ);
    defer generations.freeGateReport(allocator, base);
    try std.testing.expectEqual(generations.GateResult.pass, base.result);
    try std.testing.expectEqual(@as(usize, 1), base.diff.added.len);
    try std.testing.expectEqualStrings("alpha-pin", base.diff.added[0]);

    const candidate_a = try generations.buildCandidate(io, allocator, root_path, fixture_id, &environ, "beta", beta_source, beta_test);
    defer allocator.free(candidate_a.id);
    defer allocator.free(candidate_a.hash);
    const report_a = try generations.runGate(io, allocator, root_path, candidate_a.id, &environ);
    defer generations.freeGateReport(allocator, report_a);
    try std.testing.expectEqual(generations.GateResult.pass, report_a.result);
    try std.testing.expectEqual(@as(usize, 1), report_a.diff.added.len);
    try std.testing.expectEqualStrings("beta-probe", report_a.diff.added[0]);
    try std.testing.expectEqual(@as(usize, 0), report_a.diff.changed.len);
    try std.testing.expectEqual(@as(usize, 0), report_a.diff.removed.len);

    const cwd = std.Io.Dir.cwd();
    const sources_dir = try std.fmt.allocPrint(scratch, "{s}/cand-c/sources", .{root_path});
    try cwd.createDirPath(io, sources_dir);
    const sources_path = try std.fmt.allocPrint(scratch, "{s}/cand-c/sources/alpha.scm", .{root_path});
    try cwd.writeFile(io, .{ .sub_path = sources_path, .data = alpha_replacement_source });
    const manifest_c = try std.fmt.allocPrint(scratch, "(manifest (api \"1\") (parent \"{s}\") (modules (module \"alpha\" \"sources/alpha.scm\")) (config (decl \"alpha-pin\" (env \"GENERATIONS_TEST_FIXTURE_FOO\") #f ())) (capabilities) (caps) (hash \"h\"))\n", .{candidate_a.id});
    const manifest_path = try std.fmt.allocPrint(scratch, "{s}/cand-c/manifest.sexp", .{root_path});
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_c });

    const report_c = try generations.runGate(io, allocator, root_path, "cand-c", &environ);
    defer generations.freeGateReport(allocator, report_c);
    try std.testing.expectEqual(generations.GateResult.pass, report_c.result);
    try std.testing.expectEqualStrings(candidate_a.id, report_c.parent);
    try std.testing.expectEqual(@as(usize, 0), report_c.diff.added.len);
    try std.testing.expectEqual(@as(usize, 1), report_c.diff.changed.len);
    try std.testing.expectEqualStrings("alpha-pin", report_c.diff.changed[0]);
    try std.testing.expectEqual(@as(usize, 1), report_c.diff.removed.len);
    try std.testing.expectEqualStrings("beta-probe", report_c.diff.removed[0]);
    try std.testing.expectEqualStrings("0 tools after undo", findCheck(report_c, "undo").?.detail);
}
