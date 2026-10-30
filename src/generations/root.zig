const std = @import("std");

pub const manifest = @import("manifest.zig");
pub const ledger = @import("ledger.zig");
pub const load = @import("load.zig");
pub const gate = @import("gate.zig");

pub const Manifest = manifest.Manifest;
pub const Candidate = manifest.Candidate;
pub const LedgerStatus = ledger.Status;
pub const LedgerEvent = ledger.Event;
pub const Prepared = load.Prepared;
pub const GateReport = gate.Report;
pub const GateCheck = gate.Check;
pub const GateDiff = gate.Diff;
pub const GateResult = gate.Result;

pub const buildCandidate = manifest.buildCandidate;
pub const writeCandidate = manifest.writeCandidate;
pub const computeHash = manifest.computeHash;
pub const prepare = load.prepare;
pub const initEnv = load.initEnv;
pub const freePrepared = load.freePrepared;
pub const runGate = gate.run;
pub const freeGateReport = gate.freeReport;

test {
    _ = manifest;
    _ = ledger;
    _ = load;
    _ = gate;
}
