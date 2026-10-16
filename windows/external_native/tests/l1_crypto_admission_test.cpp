#include "diagnostics/l1_crypto_admission.h"
#include <cstdlib>
#include <iostream>

using namespace shiroha_l1_crypto;
namespace {
void check(bool condition, const char *reason) {
  if (!condition) {
    std::cerr << "FAIL: " << reason << "\n";
    std::exit(1);
  }
}
GrantTarget grant() {
  GrantTarget g;
  g.batch_id = "fake-batch";
  g.device_id = "fake-device";
  g.account_identity_sha256 = std::string(64, '1');
  g.source_sha = std::string(40, 'a');
  g.base_sha = std::string(40, 'b');
  g.exe_sha256 = std::string(64, '2');
  g.dependency_manifest_sha256 = std::string(64, '3');
  g.compiler_id = "fake-msvc";
  g.os_id = "fake-windows";
  g.toolchain_manifest_sha256 = std::string(64, '4');
  g.stop_owner = "operator";
  g.recovery_owner = "recovery";
  g.evidence_owner = "evidence";
  g.evidence_scope_id = "redacted-only";
  g.reviewer_id = "reviewer";
  g.verifier_id = "verifier";
  g.review_sha256 = std::string(64, '5');
  g.verification_sha256 = std::string(64, '6');
  g.user_approval_id = "fake-not-a-real-grant";
  g.user_scope = "L1-CRYPTO";
  g.non_elevated = g.reviewer_approved = g.verifier_approved = true;
  g.evidence_output_approved = g.user_approved = true;
  // Synthetic test limits, never a proposed/approved real resource budget.
  g.working_set_bytes = 1024;
  g.commit_bytes = 2048;
  g.handles = 10;
  g.window_start_ms = 100;
  g.window_end_ms = 100000;
  return g;
}
void completed_records(L1CryptoLedger &ledger, NativeObservation &native) {
  constexpr unsigned counts[] = {1, 3, 3, 6, 3, 45, 45};
  for (size_t i = 0; i < 7; ++i)
    ledger.abi_calls[i] = {counts[i], counts[i], counts[i], counts[i], 0, 0};
  ledger.abi_attempted_total = 106;
  ledger.attempted = ledger.returned = ledger.completed = 16;
  ledger.accepted = 16;
  ledger.successful = 12;
  ledger.releases_attempted = ledger.releases_succeeded = 45;
  ledger.buffers_allocated = 45;
  ledger.samples = 18;
  for (size_t i = 0; i < kNativeOpCount; ++i) {
    const auto count = kNativeLimits[i];
    native.calls[i] = {count, count, count, count, 0, 0};
  }
  native.acquired = native.released = 47;
}
void start(OfflineSupervisor &supervisor, FakeGrantCell &cell) {
  const auto target = grant();
  check(cell.issue(target), "issue Fake grant");
  check(supervisor.admit(cell, target, 100, "fake-trial"), "admit Fake model");
  check(cell.state() == GrantState::kConsumed, "consumed before launch");
  check(supervisor.launch_attempt(101, true), "Fake process-start attempt");
}
void samples(OfflineSupervisor &supervisor) {
  for (unsigned i = 0; i < 18; ++i)
    check(supervisor.sample({102 + i, 512, 1024, 4, i == 17 ? 16 : i}),
          "18 named checkpoints");
}

void grant_cases() {
  check(!kRealExecutionAuthorized, "model never authorizes real execution");
  const auto valid = grant();
  check(valid.valid(), "complete synthetic model");
  // Every string binding is independently mismatched, including approval scope
  // and review/verification record hashes, not just EXE hash or timestamp.
  std::string GrantTarget::*fields[] = {
      &GrantTarget::batch_id,
      &GrantTarget::device_id,
      &GrantTarget::account_identity_sha256,
      &GrantTarget::source_sha,
      &GrantTarget::base_sha,
      &GrantTarget::exe_sha256,
      &GrantTarget::dependency_manifest_sha256,
      &GrantTarget::compiler_id,
      &GrantTarget::os_id,
      &GrantTarget::toolchain_manifest_sha256,
      &GrantTarget::stop_owner,
      &GrantTarget::recovery_owner,
      &GrantTarget::evidence_owner,
      &GrantTarget::evidence_scope_id,
      &GrantTarget::reviewer_id,
      &GrantTarget::verifier_id,
      &GrantTarget::review_sha256,
      &GrantTarget::verification_sha256,
      &GrantTarget::user_approval_id,
      &GrantTarget::user_scope};
  for (auto field : fields) {
    FakeGrantCell cell;
    check(cell.issue(valid), "issued");
    auto mismatch = valid;
    (mismatch.*field)[0] = (mismatch.*field)[0] == 'a' ? 'b' : 'a';
    check(!cell.consume(mismatch, 100) && cell.state() == GrantState::kMismatch,
          "full identity binding");
    check(!cell.consume(valid, 100) && !cell.issue(valid),
          "mismatch consumes permanently");
  }
  for (unsigned field = 0; field < 12; ++field) {
    auto invalid = valid;
    switch (field) {
      case 0:
        invalid.non_elevated = false;
        break;
      case 1:
        invalid.reviewer_approved = false;
        break;
      case 2:
        invalid.verifier_approved = false;
        break;
      case 3:
        invalid.user_approved = false;
        break;
      case 4:
        invalid.evidence_output_approved = false;
        break;
      case 5:
        invalid.working_set_bytes = 0;
        break;
      case 6:
        invalid.commit_bytes = 0;
        break;
      case 7:
        invalid.handles = 0;
        break;
      case 8:
        invalid.max_execution_ms = 30001;
        break;
      case 9:
        invalid.window_end_ms = invalid.window_start_ms;
        break;
      case 10:
        invalid.abi_limits[5] = 46;
        break;
      case 11:
        invalid.batch_id = "C:\\private";
        break;
    }
    FakeGrantCell cell;
    check(!cell.issue(invalid) && cell.state() == GrantState::kRejected,
          "invalid/unsafe/unbounded grant");
    check(!cell.issue(valid), "rejected cell cannot reset");
  }
  for (uint64_t now : {uint64_t{99}, uint64_t{70001}, uint64_t{100000}}) {
    FakeGrantCell cell;
    check(cell.issue(valid), "issued");
    check(!cell.consume(valid, now) && cell.state() == GrantState::kExpired,
          "time window including execution horizon");
    check(!cell.consume(valid, 100), "expiry never resets");
  }
  {
    FakeGrantCell cell;
    check(cell.issue(valid), "issued");
    check(
        !cell.consume(valid, 100, true) && cell.state() == GrantState::kUnknown,
        "lost consume receipt");
    check(!cell.consume(valid, 100) && cell.consumption_attempts() == 1,
          "UNKNOWN never retries");
  }
  {
    FakeGrantCell cell;
    check(cell.issue(valid), "issued");
    check(cell.consume(valid, 100) && !cell.consume(valid, 100),
          "one conditional winner in Fake cell");
  }
}

void supervisor_cases() {
  {
    FakeGrantCell cell;
    OfflineSupervisor supervisor;
    start(supervisor, cell);
    samples(supervisor);
    check(supervisor.admission_open(200), "initially open");
    supervisor.begin_settlement();
    check(!supervisor.admission_open(201), "settlement closes admission");
    L1CryptoLedger ledger;
    NativeObservation native;
    completed_records(ledger, native);
    supervisor.settle(202, true, ledger, native);
    check(supervisor.state() == SupervisorState::kComplete &&
              supervisor.evidence().verdict == OfflineVerdict::kPass,
          "OFFLINE only complete evidence");
    check(std::strcmp(supervisor.evidence().evidence_class, "OFFLINE") == 0,
          "evidence class");
  }
  // Boundaries: exact 30,000 ms, blocked worker, monitor loss/backwards time,
  // sampled peaks/handles, missing sample and missing underlying release.
  for (unsigned kind = 0; kind < 14; ++kind) {
    FakeGrantCell cell;
    OfflineSupervisor supervisor;
    start(supervisor, cell);
    L1CryptoLedger ledger;
    NativeObservation native;
    completed_records(ledger, native);
    bool exited = true;
    uint64_t finish = 300;
    switch (kind) {
      case 0:
        samples(supervisor);
        check(supervisor.evidence().launch_attempt_ms == 101,
              "30 s clock starts at the process-start attempt");
        check(supervisor.admission_open(30100), "29999 ms still admits");
        check(!supervisor.admission_open(30101),
              "exact deadline closes admission");
        check(supervisor.state() == SupervisorState::kDeadlineExceeded,
              "deadline state");
        exited = false;
        finish = 30102;
        break;
      case 1:
        samples(supervisor);
        check(!supervisor.poll(200, false), "monitor failure");
        break;
      case 2:
        samples(supervisor);
        check(!supervisor.poll(100, true), "backwards clock");
        break;
      case 3:
        check(!supervisor.sample({102, 1025, 1024, 4, 0}),
              "working set ceiling");
        break;
      case 4:
        check(!supervisor.sample({102, 512, 2049, 4, 0}), "commit ceiling");
        break;
      case 5:
        check(!supervisor.sample({102, 512, 1024, 11, 0}), "handle ceiling");
        break;
      case 6:
        check(!supervisor.sample({102, 512, 1024, 4, 0}, false),
              "missing measurement");
        break;
      case 7:
        samples(supervisor);
        ledger.abi_calls[5].unknown = 1;
        break;
      case 8:
        samples(supervisor);
        native.quarantined = 1;
        native.unknown = true;
        break;
      case 9:
        samples(supervisor);
        native.calls[7].settled = 11;
        break;
      case 10:
        samples(supervisor);
        supervisor.worker_failed();
        break;
      case 11:
        break;  // worker claims complete, independent observer has no samples
      case 12:
        check(!supervisor.sample({102, 512, 1024, 4, 16}),
              "wrong sample position");
        break;
      case 13:
        samples(supervisor);
        ledger.completed = 0;
        break;
    }
    supervisor.begin_settlement();
    supervisor.settle(finish, exited, ledger, native);
    check(supervisor.evidence().verdict != OfflineVerdict::kPass,
          "no false PASS");
    check(!supervisor.admission_open(finish),
          "STOP closes new work permanently");
    if (kind == 0 || kind == 7 || kind == 8) {
      check(supervisor.evidence().verdict == OfflineVerdict::kUnknown,
            "in-flight/unknown effects");
      L1CryptoLedger forged;
      NativeObservation forged_native;
      completed_records(forged, forged_native);
      supervisor.settle(finish + 1, true, forged, forged_native);
      check(supervisor.evidence().verdict == OfflineVerdict::kUnknown,
            "UNKNOWN cannot be overwritten");
    }
  }
  {
    FakeGrantCell cell;
    OfflineSupervisor supervisor;
    const auto target = grant();
    check(cell.issue(target) && supervisor.admit(cell, target, 100, "trial"),
          "admitted");
    check(!supervisor.launch_attempt(101, false), "failed launch consumes");
    check(!supervisor.launch_attempt(102, true) && !cell.consume(target, 102),
          "no worker restart");
  }
  {
    FakeGrantCell cell;
    OfflineSupervisor supervisor;
    const auto target = grant();
    check(!supervisor.admit(cell, target, 100, "trial"), "unissued blocked");
  }
}
}  // namespace
int main() {
  grant_cases();
  supervisor_cases();
  std::cout << "PASS: OFFLINE grant bindings/one-use Fake cell/supervisor/18 "
               "checkpoints/UNKNOWN; real admission BLOCKED\n";
}
