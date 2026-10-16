#include "diagnostics/l1_windows_admission.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>
#include <type_traits>

using namespace shiroha_l1_crypto;
namespace {
static_assert(!std::is_copy_constructible_v<WindowsAdmissionCandidate>);
static_assert(!std::is_copy_assignable_v<WindowsAdmissionCandidate>);
static_assert(!std::is_move_constructible_v<WindowsAdmissionCandidate>);
static_assert(!std::is_move_assignable_v<WindowsAdmissionCandidate>);
void check(bool value, const char *reason) {
  if (!value) {
    std::cerr << "FAIL: " << reason << '\n';
    std::exit(1);
  }
}
WindowsBinding binding() {
  WindowsBinding b;
  auto &g = b.target;
  g.batch_id = "fake-batch";
  g.device_id = "fake-device";
  g.account_identity_sha256 = std::string(64, '1');
  g.source_sha = std::string(40, 'a');
  g.base_sha = std::string(40, 'b');
  g.exe_sha256 = std::string(64, '2');
  g.dependency_manifest_sha256 = std::string(64, '3');
  g.compiler_id = "fake-msvc";
  g.os_id = "fake-os";
  g.toolchain_manifest_sha256 = std::string(64, '4');
  g.stop_owner = "fake-stop";
  g.recovery_owner = "fake-recovery";
  g.evidence_owner = "fake-evidence";
  g.evidence_scope_id = "fake-scope";
  g.reviewer_id = "fake-reviewer";
  g.verifier_id = "fake-verifier";
  g.review_sha256 = std::string(64, '5');
  g.verification_sha256 = std::string(64, '6');
  g.user_approval_id = "fake-approval";
  g.user_scope = "L1-CRYPTO";
  g.non_elevated = g.reviewer_approved = g.verifier_approved = true;
  g.user_approved = g.evidence_output_approved = true;
  // Synthetic fixture data ONLY. No real user budget/window/account selected.
  g.working_set_bytes = 1024;
  g.commit_bytes = 2048;
  g.handles = 10;
  g.window_start_ms = 100;
  g.window_end_ms = 100000;
  b.account_sid = L"FAKE-SID";
  b.object_identity_sha256 = std::string(64, '7');
  b.primary_medium_token = b.protected_object = b.parent_chain_pinned = true;
  b.owner_matches = b.device_matches = b.artifact_pinned = true;
  b.dependencies_pinned = b.isolated_environment = b.explicit_handle_list =
      true;
  b.reparse = b.unexpected_privileges = false;
  return b;
}
struct FakeDurableStore {
  // Shared fake external journal survives client destruction/reconstruction.
  // NOT Windows disk persistence or a real cross-process/power-loss proof.
  std::mutex mutex;
  FakeGrantCell cell;
  WindowsBinding issued = binding();
  bool request_started = false, issued_persisted = false;
  bool lose_receipt = false, fail_persistence = false;
  bool start_request_started = false;
  unsigned start_attempts = 0;
  unsigned winners = 0, consume_calls = 0;
  void issue() { issued_persisted = cell.issue(issued.target); }
};
class FakeWindows final : public WindowsOperations {
 public:
  explicit FakeWindows(FakeDurableStore &store) : store(store) {
    worker.binding = observed;
    worker.authenticated = worker.observer_healthy = true;
    worker.logs_complete = true;
  }
  FakeDurableStore &store;
  WindowsBinding observed = binding();
  WorkerObservation worker;
  uint64_t time = 100;
  bool approval = true, clock_ok = true, inspect_ok = true, launch_ok = true;
  bool lost_start_receipt = false;
  bool start_exception = false;
  unsigned launches = 0;
  bool trusted_approval(const WindowsBinding &target) noexcept override {
    // The independently supplied Fake authority binds every field, not a bool
    // inside target. No such authority exists in the Windows backend.
    return approval && target.matches(store.issued);
  }
  bool inspect(WindowsBinding &out) noexcept override {
    out = observed;
    return inspect_ok;
  }
  bool now(uint64_t &out) noexcept override {
    out = time;
    return clock_ok;
  }
  ConsumptionRecord consume_once(const WindowsBinding &b,
                                 uint64_t at) noexcept override {
    std::lock_guard<std::mutex> guard(store.mutex);
    ++store.consume_calls;
    ConsumptionRecord r;
    r.persisted_issuance = store.issued_persisted;
    r.request_started = store.request_started;
    if (!store.issued_persisted || store.request_started ||
        !b.matches(store.issued)) {
      r.state = GrantState::kRejected;
      return r;
    }
    store.request_started = r.request_started = true;
    if (store.fail_persistence) {
      // External journal quarantines even if object bytes were never changed.
      r.unknown = true;
      r.state = GrantState::kUnknown;
      return r;
    }
    const bool consumed = store.cell.consume(b.target, at, store.lose_receipt);
    r.state = store.cell.state();
    r.unknown = store.lose_receipt;
    r.confirmed = consumed && !r.unknown;
    if (r.confirmed) ++store.winners;
    return r;
  }
  WorkerState start_worker(const WindowsBinding &b) noexcept override {
    std::lock_guard<std::mutex> guard(store.mutex);
    if (!store.request_started || store.cell.state() != GrantState::kConsumed ||
        !b.matches(store.issued) || store.start_request_started)
      return WorkerState::kStartFailed;
    // Same shared Fake journal, not another Grant state machine. Reserve before
    // the simulated launch, including exception/unknown acknowledgement.
    store.start_request_started = true;
    ++store.start_attempts;
    ++launches;
    return (lost_start_receipt || start_exception)
               ? WorkerState::kUnknown
               : (launch_ok ? WorkerState::kRunning
                            : WorkerState::kStartFailed);
  }
  WorkerObservation observe_worker() noexcept override { return worker; }
};
void records(L1CryptoLedger &l, NativeObservation &n) {
  constexpr unsigned counts[] = {1, 3, 3, 6, 3, 45, 45};
  for (size_t i = 0; i < 7; ++i)
    l.abi_calls[i] = {counts[i], counts[i], counts[i], counts[i], 0, 0};
  l.abi_attempted_total = 106;
  l.attempted = l.returned = l.completed = l.accepted = 16;
  l.successful = 12;
  l.buffers_allocated = l.releases_attempted = l.releases_succeeded = 45;
  l.samples = 18;
  for (size_t i = 0; i < kNativeOpCount; ++i)
    n.calls[i] = {kNativeLimits[i],
                  kNativeLimits[i],
                  kNativeLimits[i],
                  kNativeLimits[i],
                  0,
                  0};
  n.acquired = n.released = 47;
}
void concurrency_and_restart() {
  for (unsigned repeat = 0; repeat < 64; ++repeat) {
    FakeDurableStore store;
    store.issue();
    std::atomic<unsigned> ready{0}, success{0};
    std::atomic<bool> go{false};
    auto compete = [&] {
      FakeWindows os(store);
      WindowsAdmissionCandidate candidate(os);
      ++ready;
      while (!go.load()) std::this_thread::yield();
      if (candidate.admit(binding(), "fake-trial")) ++success;
      // Consumer destruction simulates crash before start. No rollback.
    };
    std::thread first(compete), second(compete);
    while (ready.load() != 2) std::this_thread::yield();
    go = true;
    first.join();
    second.join();
    check(success == 1 && store.winners == 1,
          "64 repeated races: exactly one Fake winner");
    FakeWindows restarted(store);
    WindowsAdmissionCandidate replay(restarted);
    check(!replay.admit(binding(), "fake-restart") && !replay.start() &&
              !restarted.launches,
          "crash/reconstructed consumer never replays");
  }
  for (bool lost : {false, true}) {
    FakeDurableStore store;
    store.issue();
    store.lose_receipt = lost;
    store.fail_persistence = !lost;
    {
      FakeWindows os(store);
      WindowsAdmissionCandidate c(os);
      check(!c.admit(binding(), "fake-trial") && !c.start() && !os.launches,
            "lost confirmation/write failure never starts");
      check(c.evidence().consumption.unknown && store.request_started,
            "UNKNOWN request retained independently of file bytes");
    }
    store.lose_receipt = store.fail_persistence = false;
    FakeWindows restarted(store);
    WindowsAdmissionCandidate c(restarted);
    check(!c.admit(binding(), "fake-replay") && !store.winners,
          "UNKNOWN restart permanently denied");
  }
}
void identity_and_denials() {
  for (unsigned kind = 0; kind < 26; ++kind) {
    FakeDurableStore store;
    if (kind != 0) store.issue();
    FakeWindows os(store);
    switch (kind) {
      case 0:
        break;
      case 1:
        os.approval = false;
        break;
      case 2:
        os.time = 100000;
        break;
      case 3:
        os.time = 70001;
        break;
      case 4:
        os.observed.account_sid = L"OTHER-FAKE-SID";
        break;
      case 5:
        os.observed.owner_matches = false;
        break;
      case 6:
        os.observed.device_matches = false;
        break;
      case 7:
        os.observed.object_identity_sha256[0] = '8';
        break;
      case 8:
        os.observed.reparse = true;
        break;
      case 9:
        os.observed.target.exe_sha256[0] = '9';
        break;
      case 10:
        os.observed.target.dependency_manifest_sha256[0] = '9';
        break;
      case 11:
        os.observed.target.source_sha[0] = '9';
        break;
      case 12:
        os.observed.target.base_sha[0] = '9';
        break;
      case 13:
        os.observed.primary_medium_token = false;
        break;
      case 14:
        os.observed.unexpected_privileges = true;
        break;
      case 15:
        os.observed.isolated_environment = false;
        break;
      case 16:
        os.observed.explicit_handle_list = false;
        break;
      case 17:
        os.observed.dependencies_pinned = false;
        break;
      case 18:
        os.observed.artifact_pinned = false;
        break;
      case 19:
        os.observed.parent_chain_pinned = false;
        break;
      case 20:
        os.observed.protected_object = false;
        break;
      case 21:
        os.clock_ok = false;
        break;
      case 22:
        os.inspect_ok = false;
        break;
      case 23:
        os.time = 99;
        break;
      case 24:
        os.observed.target.toolchain_manifest_sha256[0] = '9';
        break;
      case 25:
        os.observed.target.review_sha256[0] = '9';
        break;
    }
    WindowsAdmissionCandidate c(os);
    check(!c.admit(binding(), "fake-trial") && !c.start() && !os.launches,
          "unissued/unapproved/window/identity/object/artifact/token denied");
  }
  // A copied fake file has the same cell bytes but a different external pin.
  FakeDurableStore copy;
  copy.issue();
  copy.issued.object_identity_sha256[0] = '9';
  FakeWindows os(copy);
  WindowsAdmissionCandidate c(os);
  check(!c.admit(binding(), "fake-copy"),
        "copied object is no external authority");
  // Raw path/PEM/private data cannot enter pseudonymous evidence IDs.
  auto bad = binding();
  bad.target.batch_id = "C:\\private\\secret.pem";
  FakeDurableStore store;
  store.issue();
  FakeWindows other(store);
  WindowsAdmissionCandidate unsafe(other);
  check(!unsafe.admit(bad, "fake-trial") &&
            unsafe.evidence().observation.batch_id.empty(),
        "redaction fails before evidence population");
}
void supervisor_matrix() {
  for (unsigned kind = 0; kind < 15; ++kind) {
    FakeDurableStore store;
    store.issue();
    FakeWindows os(store);
    WindowsAdmissionCandidate c(os);
    NativeObservation native;
    L1CryptoLedger ledger;
    records(ledger, native);
    check(c.admit(binding(), "fake-trial") &&
              c.state() == SupervisorState::kGrantConsumed,
          "durable consume maps to E2 supervisor");
    if (kind == 1) os.launch_ok = false;
    if (kind == 14) os.lost_start_receipt = true;
    if (kind == 2) os.worker.binding.target.exe_sha256[0] = '9';
    if (kind == 1 || kind == 2 || kind == 14) {
      check(!c.start() && c.evidence().start_request_started &&
                os.launches == 1 && !c.start(),
            "launch failure/actual worker substitution: one start request, "
            "never restart");
      if (kind == 1)
        check(
            c.evidence().observation.worker_state == WorkerState::kStartFailed,
            "failed start is never recorded as RUNNING");
      else
        check(
            c.evidence().observation.worker_state == WorkerState::kUnknown &&
                c.evidence().observation.verdict == OfflineVerdict::kUnknown &&
                c.state() == SupervisorState::kSettlementUnknown,
            "lost receipt/unverified actual Worker retains UNKNOWN");
      continue;
    }
    check(c.start(), "Fake Worker start");
    for (unsigned i = 0; i < 18; ++i) {
      os.time = 101 + i;
      if (kind != 3)
        check(c.sample({os.time, 512, 1024, 4, i == 17 ? 16 : i}, native),
              "Fake sample");
    }
    os.time = 200;
    os.worker.exit_observed = os.worker.normal_exit = true;
    switch (kind) {
      case 0:
        break;
      case 3:
        break;  // Missing all independent samples despite worker PASS.
      case 4:
        os.time = 30100;
        os.worker.exit_observed = false;
        check(!c.poll(native), "exact 30 second deadline");
        ledger.abi_calls[1].unknown = 1;
        break;  // synchronous call never returned
      case 5:
        os.worker.normal_exit = false;
        break;
      case 6:
        os.worker.observer_healthy = false;
        break;
      case 7:
        os.worker.logs_complete = false;
        break;
      case 8:
        native.quarantined = 1;
        native.unknown = true;
        break;
      case 9:
        ledger.completed = 1;
        break;  // Early normal exit != success.
      case 10:
        native.fail("fake_native_stop");
        check(!c.poll(native), "native STOP closes supervisor admission");
        break;
      case 11:
        os.worker.authenticated = false;
        break;
      case 12:
        os.worker.binding.account_sid = L"OTHER-SID";
        break;
      case 13:
        os.worker.exit_observed = false;
        check(!c.sample({200, 1025, 1024, 4, 16}, native),
              "OS ceiling closes native gate");
        os.worker.exit_observed = true;
        break;
    }
    c.settle(ledger, native);
    const auto e = c.evidence();
    if (kind == 0) {
      check(e.observation.verdict == OfflineVerdict::kPass,
            "complete independent FAKE records only");
      check(std::strcmp(e.evidence_class, "OFFLINE") == 0 &&
                std::strcmp(e.os_backend, "FAKE") == 0 &&
                e.verifier == OfflineVerdict::kNotRun &&
                e.reviewer == OfflineVerdict::kNotRun,
            "offline pass never forges independent approval");
    } else {
      check(e.observation.verdict != OfflineVerdict::kPass,
            "missing/error/UNKNOWN never PASS");
      if (kind == 4 || kind == 6 || kind == 8 || kind == 11 || kind == 12)
        check(e.observation.verdict == OfflineVerdict::kUnknown,
              "unobserved effects remain UNKNOWN");
      check(!c.poll(native), "settled error remains closed");
      if (kind != 3 && kind != 9)
        check(native.stopped, "Supervisor/native cross stop latch");
    }
    check(!c.start() && os.launches == 1, "no automatic restart");
  }
}

// Test-only complete field snapshots. No object padding/pointer-address
// compare, no production serialization, path, SID, file or real evidence
// output.
void snapshot_counts(std::ostream &out, const CallCounts &c) {
  out << c.attempted << ',' << c.returned << ',' << c.accepted << ','
      << c.settled << ',' << c.unknown << ',' << c.returned_failure << ';';
}
std::string snapshot(const WindowsAdmissionEvidence &e, SupervisorState state) {
  std::ostringstream out;
  out << static_cast<int>(state) << '|' << e.evidence_class << '|'
      << e.os_backend << '|' << e.consumption.persisted_issuance
      << e.consumption.request_started << e.consumption.confirmed
      << e.consumption.unknown << '|' << static_cast<int>(e.consumption.state)
      << '|' << e.dependency_sha256 << '|' << e.toolchain_sha256 << '|'
      << e.account_sha256 << '|' << e.object_identity_sha256 << '|'
      << e.start_request_started << e.identity_verified
      << e.worker_identity_verified << e.normal_exit_observed << e.logs_complete
      << e.stop_requested << '|' << static_cast<int>(e.verifier) << '|'
      << static_cast<int>(e.reviewer) << '|' << e.recovery << '|';
  const auto &o = e.observation;
  out << o.evidence_class << '|' << o.batch_id << '|' << o.trial_id << '|'
      << o.source_sha << '|' << o.base_sha << '|' << o.artifact_sha256 << '|'
      << o.environment_id << '|' << o.reviewer_id << '|' << o.verifier_id << '|'
      << o.review_sha256 << '|' << o.verification_sha256 << '|';
  for (const auto &c : o.abi) snapshot_counts(out, c);
  const auto &n = o.native;
  for (const auto &c : n.calls) snapshot_counts(out, c);
  out << n.acquired << ',' << n.released << ',' << n.still_owned << ','
      << n.quarantined << '|' << n.stopped << n.unknown
      << n.first_failure_unknown << '|' << n.first_failure << '|'
      << o.buffers_acquired << ',' << o.buffers_live << '|' << o.sample_count
      << '|';
  for (const auto &s : o.samples)
    out << s.observed_at_ms << ',' << s.peak_working_set << ',' << s.peak_commit
        << ',' << s.handles << ',' << s.completed_calls << ';';
  out << static_cast<int>(o.worker_state) << '|' << o.completed_native_calls
      << '|' << o.launch_attempt_ms << ',' << o.process_end_ms << '|'
      << o.process_exit_observed << o.deadline_exceeded
      << o.settlement_incomplete << '|' << static_cast<int>(o.first_failure)
      << '|' << static_cast<int>(o.verdict) << '|' << o.sampled_handles_only
      << o.windows_internals_observable;
  return out.str();
}
std::string snapshot(const WindowsAdmissionCandidate &candidate) {
  return snapshot(candidate.evidence(), candidate.state());
}
std::string snapshot(const OfflineSupervisor &supervisor) {
  WindowsAdmissionEvidence e;
  e.observation = supervisor.evidence();
  return snapshot(e, supervisor.state());
}
void all_samples(WindowsAdmissionCandidate &c, FakeWindows &os,
                 NativeObservation &native) {
  for (unsigned i = 0; i < 18; ++i) {
    os.time = 101 + i;
    check(c.sample({os.time, 512, 1024, 4, i == 17 ? 16 : i}, native),
          "complete independent sample fixture");
  }
}
void unique_start_regressions() {
  // Compile-time assertions above reject the original `auto clone = admitted`
  // attack. Runtime ownership also survives all simulated launch outcomes.
  for (unsigned kind = 0; kind < 6; ++kind) {
    FakeDurableStore store;
    store.issue();
    FakeWindows os(store);
    os.launch_ok = kind != 1;
    os.lost_start_receipt = kind == 2;
    os.start_exception = kind == 3;
    store.lose_receipt = kind == 4;
    store.fail_persistence = kind == 5;
    WindowsAdmissionCandidate c(os);
    const bool admitted = c.admit(binding(), "fake-unique-start");
    check(admitted == (kind < 4), "consumption unknown never admits");
    const bool started = c.start();
    check(started == (kind == 0), "only confirmed launch succeeds");
    check(!c.start() && !c.start(), "same object never starts twice");
    if (kind >= 4) {
      check(!store.start_attempts && !os.launches,
            "failed/unknown consumption has no launch slot");
    } else {
      FakeWindows reconstructed(store);
      check(
          reconstructed.start_worker(binding()) == WorkerState::kStartFailed &&
              !reconstructed.launches && store.start_attempts == 1,
          "Fake backend denies duplicate batch, even after exception/lost ack");
    }
    WindowsAdmissionCandidate restarted(os);
    check(
        !restarted.admit(binding(), "fake-restart-start") && !restarted.start(),
        "restart cannot restore consumed or unknown start ownership");
  }
  // Competing Fake start ports use the SAME journal mutex as consumption.
  FakeDurableStore store;
  store.issue();
  FakeWindows issuer(store);
  WindowsAdmissionCandidate c(issuer);
  check(c.admit(binding(), "fake-start-race"), "race fixture consumed");
  std::atomic<unsigned> ready{0}, winners{0};
  std::atomic<bool> go{false};
  auto start = [&] {
    FakeWindows os(store);
    ++ready;
    while (!go.load()) std::this_thread::yield();
    if (os.start_worker(binding()) == WorkerState::kRunning) ++winners;
  };
  std::thread first(start), second(start);
  while (ready.load() != 2) std::this_thread::yield();
  go = true;
  first.join();
  second.join();
  check(winners == 1 && store.start_attempts == 1 && !c.start(),
        "two Fake start consumers plus original controller: one attempt");
}

unsigned terminal_snapshot_checks = 0;
void late_events(WindowsAdmissionCandidate &c, FakeWindows &os,
                 L1CryptoLedger &ledger, NativeObservation &native) {
  const auto before = snapshot(c);
  auto unchanged = [&] {
    check(snapshot(c) == before,
          "entire terminal state/evidence snapshot immutable");
    ++terminal_snapshot_checks;
  };
  os.time = 90000;
  check(!c.poll(native), "late poll denied");
  unchanged();
  check(!c.sample({90000, 4096, 8192, 99, 16}, native), "late sample denied");
  unchanged();
  os.worker.exit_observed = os.worker.normal_exit = true;
  check(!c.poll(native), "late actual exit cannot reopen terminal");
  unchanged();
  // Late complete records may not replace an UNKNOWN's original missing data.
  L1CryptoLedger late_ledger;
  NativeObservation late_native;
  records(late_ledger, late_native);
  c.settle(late_ledger, late_native);
  unchanged();
  c.settle(ledger, native);
  unchanged();
  c.request_stop(native);
  unchanged();
  c.request_stop(late_native);
  unchanged();
  check(!c.admit(binding(), "fake-late-admit") && !c.start(),
        "terminal cannot restart");
  unchanged();
}
void terminal_regressions() {
  for (unsigned kind = 0; kind < 7; ++kind) {
    FakeDurableStore store;
    store.issue();
    FakeWindows os(store);
    WindowsAdmissionCandidate c(os);
    NativeObservation native;
    L1CryptoLedger ledger;
    records(ledger, native);
    if (kind == 3) os.approval = false;
    if (kind == 6) store.lose_receipt = true;
    const bool admitted = c.admit(binding(), "fake-terminal");
    if (kind == 3 || kind == 6) {
      check(!admitted && c.state() == SupervisorState::kBlocked,
            "admission BLOCKED terminal");
    } else {
      check(admitted, "terminal fixture admitted");
      if (kind == 4) os.launch_ok = false;
      if (kind == 5) os.lost_start_receipt = true;
      if (kind == 4 || kind == 5) {
        check(!c.start(), "launch failed/unknown terminal");
        check(c.state() == (kind == 4 ? SupervisorState::kBlocked
                                      : SupervisorState::kSettlementUnknown),
              "known and unknown launch terminals distinguished");
      } else {
        check(c.start(), "terminal fixture running");
        all_samples(c, os, native);
        os.time = 200;
        os.worker.exit_observed = kind != 2;
        os.worker.normal_exit = true;
        if (kind == 1) ledger.completed = 1;
        c.settle(ledger, native);
        check(c.state() == (kind == 2 ? SupervisorState::kSettlementUnknown
                                      : SupervisorState::kComplete),
              "complete and unobserved-exit UNKNOWN terminals");
        if (kind == 0)
          check(c.evidence().observation.verdict == OfflineVerdict::kPass,
                "PASS fixture");
        if (kind == 1)
          check(c.evidence().observation.verdict == OfflineVerdict::kFail,
                "FAIL fixture");
        if (kind == 2)
          check(c.evidence().observation.verdict == OfflineVerdict::kUnknown,
                "UNKNOWN fixture");
      }
    }
    late_events(c, os, ledger, native);
  }
  // Exercise the owning E2 core directly; wrapper guards alone are
  // insufficient.
  for (unsigned kind = 0; kind < 3; ++kind) {
    OfflineSupervisor supervisor;
    FakeGrantCell cell;
    const auto g = binding().target;
    L1CryptoLedger ledger;
    NativeObservation native;
    records(ledger, native);
    if (kind == 2) {
      check(!supervisor.admit(cell, g, 100, "fake-core-blocked"),
            "E2 BLOCKED fixture");
    } else {
      check(cell.issue(g) && supervisor.admit(cell, g, 100, "fake-core") &&
                supervisor.launch_attempt(100, true),
            "E2 running fixture");
      for (unsigned i = 0; i < 18; ++i)
        check(supervisor.sample({101 + i, 512, 1024, 4, i == 17 ? 16 : i}),
              "E2 samples");
      supervisor.settle(200, kind == 0, ledger, native);
    }
    const auto before = snapshot(supervisor);
    auto unchanged = [&] {
      check(snapshot(supervisor) == before,
            "E2 terminal complete evidence immutable");
      ++terminal_snapshot_checks;
    };
    check(!supervisor.poll(90000, false), "E2 late poll");
    unchanged();
    check(!supervisor.sample({90000, 4096, 8192, 99, 16}), "E2 late sample");
    unchanged();
    supervisor.observe_worker_exit(90000);
    unchanged();
    supervisor.settle(90000, true, ledger, native);
    unchanged();
    supervisor.settle(90001, false, ledger, native);
    unchanged();
    supervisor.worker_failed();
    unchanged();
    supervisor.worker_failed();
    unchanged();
    supervisor.begin_settlement();
    unchanged();
  }
}

void exit_regressions() {
  {
    OfflineSupervisor supervisor;
    FakeGrantCell cell;
    const auto target = binding().target;
    check(cell.issue(target) &&
              supervisor.admit(cell, target, 100, "fake-exit-core") &&
              supervisor.launch_attempt(100, true),
          "E2 exit admission fixture");
    supervisor.observe_worker_exit(200);
    check(!supervisor.admission_open(201) &&
              supervisor.state() == SupervisorState::kSettling &&
              supervisor.evidence().process_exit_observed,
          "owning E2 admission_open closes immediately on accepted exit");
  }
  for (bool normal : {false, true}) {
    FakeDurableStore store;
    store.issue();
    FakeWindows os(store);
    WindowsAdmissionCandidate c(os);
    NativeObservation native;
    L1CryptoLedger ledger;
    records(ledger, native);
    check(c.admit(binding(), "fake-exit") && c.start(), "exit fixture started");
    all_samples(c, os, native);
    os.time =
        200;  // Healthy, authenticated, matching identity; 29,900 ms left.
    os.worker.exit_observed = true;
    os.worker.normal_exit = normal;
    check(!c.poll(native) && !c.start(),
          "observed exit immediately closes work/start");
    check(c.evidence().observation.process_exit_observed &&
              c.evidence().observation.process_end_ms == 200 &&
              c.evidence().normal_exit_observed == normal,
          "first accepted exit evidence");
    if (normal)
      check(c.state() == SupervisorState::kSettling && !native.stopped,
            "normal exit settles without manufacturing Native failure");
    else
      check(native.stopped &&
                c.evidence().observation.first_failure == StopReason::kWorker,
            "abnormal exit stops Native admission with original reason");
    os.time = 201;
    os.worker.exit_observed =
        false;  // A subsequent snapshot cannot reopen work.
    check(!c.poll(native) && !c.start(), "accepted exit is sticky");
    c.settle(ledger, native);
    check(c.evidence().observation.verdict ==
              (normal ? OfflineVerdict::kPass : OfflineVerdict::kFail),
          "normal fully settled path remains valid; abnormal never PASS");
    check(c.evidence().observation.process_end_ms == 200,
          "first exit timestamp retained");
  }
  for (bool normal : {false, true}) {
    FakeDurableStore store;
    store.issue();
    FakeWindows os(store);
    WindowsAdmissionCandidate c(os);
    NativeObservation native;
    L1CryptoLedger ledger;
    records(ledger, native);
    check(c.admit(binding(), "fake-exit-unknown") && c.start(),
          "unknown exit fixture");
    all_samples(c, os, native);
    os.time = 200;
    os.worker.exit_observed = true;
    os.worker.normal_exit = normal;
    check(!c.poll(native), "exit closes work before settlement evidence");
    native.still_owned = 1;
    native.released = 46;
    ledger.abi_calls[1].unknown = 1;
    c.settle(ledger, native);
    check(c.state() == SupervisorState::kSettlementUnknown &&
              c.evidence().observation.verdict == OfflineVerdict::kUnknown,
          "exit never proves missing Native settlement");
    late_events(c, os, ledger, native);
  }
  // The deadline is not terminal: original ownership can still legally release.
  FakeDurableStore store;
  store.issue();
  FakeWindows os(store);
  WindowsAdmissionCandidate c(os);
  NativeObservation native;
  L1CryptoLedger ledger;
  check(c.admit(binding(), "fake-deadline") && c.start(), "deadline fixture");
  unsigned releases = 0;
  NativeObservationScope scope(native);
  NativeOwnerObservation owner;
  owner.acquire(true);
  os.time = 30100;
  check(!c.poll(native), "inclusive deadline closes work");
  check(owner.release(
            NativeOp::kClose,
            [&] {
              ++releases;
              return true;
            },
            [](bool ok) { return ok; }, false) &&
            releases == 1 && native.still_owned == 0,
        "sole-owner release remains legal after deadline");
  os.worker.exit_observed = os.worker.normal_exit = true;
  ledger.settlement_unknown = true;
  c.settle(ledger, native);
  check(c.state() == SupervisorState::kSettlementUnknown,
        "deadline still reaches owning settlement");
}

void serialized_event_regressions() {
  for (bool normal : {false, true}) {
    for (bool unknown : {false, true}) {
      std::array<unsigned, 3> order{0, 1, 2};  // EXIT, STOP, SAMPLE
      do {
        FakeDurableStore store;
        store.issue();
        FakeWindows os(store);
        WindowsAdmissionCandidate c(os);
        NativeObservation native;
        L1CryptoLedger ledger;
        records(ledger, native);
        check(c.admit(binding(), "fake-event-order") && c.start(),
              "event order fixture");
        os.time = 200;
        for (unsigned event : order) {
          if (event == 0) {
            os.worker.exit_observed = true;
            os.worker.normal_exit = normal;
            check(!c.poll(native), "EXIT closes serialized admission");
          } else if (event == 1) {
            c.request_stop(native);
          } else {
            const bool expected = !os.worker.exit_observed && !native.stopped;
            check(c.sample({200, 512, 1024, 4, 0}, native) == expected,
                  "SAMPLE only before EXIT/STOP");
          }
        }
        if (unknown) ledger.settlement_unknown = true;
        check(!c.poll(native) && !c.start(),
              "event order never reopens admission");
        c.settle(ledger, native);
        check(c.evidence().observation.verdict ==
                  (unknown ? OfflineVerdict::kUnknown : OfflineVerdict::kFail),
              "all 24 EXIT/STOP/SAMPLE orders retain known failure or UNKNOWN");
      } while (std::next_permutation(order.begin(), order.end()));
    }
  }
  // Two Fake event producers share one explicit controller boundary. The
  // candidate itself promises serialized events, not unsynchronized thread use.
  FakeDurableStore store;
  store.issue();
  FakeWindows os(store);
  WindowsAdmissionCandidate c(os);
  NativeObservation native;
  check(c.admit(binding(), "fake-controller-boundary") && c.start(),
        "controller fixture");
  std::mutex events;
  std::thread exit([&] {
    std::lock_guard<std::mutex> guard(events);
    os.worker.exit_observed = os.worker.normal_exit = true;
    check(!c.poll(native), "serialized producer EXIT closes work");
  });
  std::thread stop([&] {
    std::lock_guard<std::mutex> guard(events);
    c.request_stop(native);
  });
  exit.join();
  stop.join();
  check(!c.poll(native) && !c.start(),
        "serialized concurrent producers cannot reopen work");
}
}  // namespace
int main() {
  check(!kRealExecutionAuthorized, "real execution remains denied");
  concurrency_and_restart();
  identity_and_denials();
  supervisor_matrix();
  unique_start_regressions();
  terminal_regressions();
  exit_regressions();
  serialized_event_regressions();
  std::cout << "PASS: OFFLINE/FAKE E3: 64 races, restart/UNKNOWN, identity, "
               "supervisor; NO LOCAL-L1 evidence\n";
  std::cout << "PASS: E3-R1: 4 noncopy/nonmove static assertions; 7 "
               "unique-start cases; "
               "10 terminal groups + 2 exit-UNKNOWN groups; snapshot checks="
            << terminal_snapshot_checks
            << "; 6 exit/deadline cases; 24 event permutations; 1 serialized "
               "producer race\n";
}
