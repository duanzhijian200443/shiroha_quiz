#include "tests/l1_r1_fixture.h"
namespace {
void positive() {
  Fixture t;
  ControllerBoot boot(t.c);
  wchar_t name[] = L"controller";
  wchar_t *argv[] = {name};
  check(r::controller_process_entry(1, argv, boot) == 0,
        "same process entry completes full injected composition");
  const auto v = t.c.result();
  check(v.terminal && v.evidence_preserved &&
            v.last.security == OfflineVerdict::kPass &&
            v.last.stability == OfflineVerdict::kNotRun,
        "offline security distinct from unrun OS stability");
  check(t.io.burns == 1 && t.owner.creates == 1 && t.owner.resumes == 1 &&
            t.owner.close_calls == 1 && t.id.closes == 1,
        "single consumption/create/Resume and unique handle/pin settlement");
  check(v.core.core.observation.sample_count == 18 && v.core.ack_sent &&
            v.core.core.logs_complete && t.owner.wire.checkpoints == 18,
        "actual Worker 18 samples, 24-part settlement and actual ACK");
  for (const auto &c : v.last.abi)
    check(c.attempted == 0, "zero ABI/Crypto/DPAPI attempts");
  for (const auto &c : v.last.native)
    check(c.attempted == 0, "zero direct native attempts");
  check(v.writes_attempted <= t.f.manifest.max_pumps + 32,
        "bounded external evidence writes");
  const auto hash = v.last.hash();
  const auto writes = v.writes_attempted;
  t.c.pump();
  t.c.begin();
  t.c.controller_lost();
  check(t.c.result().last.hash() == hash &&
            t.c.result().writes_attempted == writes,
        "terminal evidence immutable under late calls");
  // New controller uses a fresh sink namespace; external creator still refuses
  // the consumed intent. It cannot create/Resume again.
  Sink fresh_sink;
  r::Composition rebuilt(t.f, t.io, t.id, t.owner, fresh_sink);
  check(!rebuilt.begin() && t.owner.creates == 1 && t.owner.resumes == 1,
        "reconstructed controller cannot replay external intent");
}
void failures() {
  for (unsigned call : {1u, 3u, 5u})
    for (unsigned kind = 0; kind < 15; ++kind) {
      Fixture t;
      t.id.drift_at = call;
      t.id.drift_kind = kind;
      check(!t.c.begin(), "independently measured identity drift rejects");
      check(t.c.result().last.security != OfflineVerdict::kPass,
            "drift never PASS");
      if (call < 5)
        check(t.owner.creates == 0, "pre-create drift prevents create");
    }
  {
    Fixture t;
    t.owner.cancel = true;
    check(!t.c.begin() && !t.io.issues && !t.owner.creates,
          "no human approval no issuance");
  }
  {
    Fixture t;
    t.owner.accept_denied = true;
    check(!t.c.begin() && !t.io.issues && !t.owner.creates,
          "pre-create external custody required");
  }
  {
    Fixture t;
    t.owner.ack_lost = true;
    check(!t.c.begin() && t.owner.creates == 1 && !t.owner.resumes &&
              t.owner.owner_handles && t.c.result().last.recovery_required,
          "lost custody ACK retains sole owner, prevents Resume");
  }
  {
    Fixture t;
    t.owner.wrong_ack_identity = true;
    check(!t.c.begin() && t.owner.creates == 1 && !t.owner.resumes &&
              t.owner.owner_handles,
          "Custody ACK must bind observed PID/time/image/account/Target, not "
          "another process");
  }
  {
    Fixture t;
    t.owner.deadline_during_ack = true;
    check(!t.c.begin() && t.owner.creates == 1 && !t.owner.resumes &&
              t.c.result().first_failure == r::Failure::kDeadline,
          "slow Custody ACK cannot Resume at inclusive launch deadline");
  }
  {
    Fixture t;
    t.owner.wrong_process = true;
    check(!t.c.begin() && !t.owner.resumes && t.owner.owner_handles,
          "created identity binds Target");
  }
  {
    Fixture t;
    t.owner.wrong_dependency = true;
    check(!t.c.begin() && !t.owner.resumes, "dependency closure blocks Resume");
  }
  for (int crash = 1; crash <= 6; ++crash) {
    Fixture t;
    t.owner.crash = crash;
    check(
        !t.c.begin() && t.c.result().last.security != OfflineVerdict::kPass,
        "all acceptance/create/identity/ack/Resume crash windows fail closed");
    check(t.owner.creates <= 1 && t.owner.resumes <= 1,
          "crash never retries effects");
    if (crash >= 3)
      check(t.owner.owner_handles && t.id.closes == 0,
            "independent creator retains unknown process and pins");
    const auto n = t.owner.creates;
    t.c.begin();
    t.c.pump();
    check(t.owner.creates == n,
          "late crashed-controller events cannot recreate");
  }
  {
    Fixture t;
    check(t.c.begin(), "begin before post-ack controller loss");
    t.c.controller_lost();
    check(t.owner.owner_handles && t.owner.lost && t.owner.close_calls == 0 &&
              t.c.result().last.recovery_required,
          "surviving independent creator owns process after controller "
          "disappears");
  }
  for (auto stage :
       {r::Stage::kControllerStarted, r::Stage::kApproval,
        r::Stage::kIssueIntent, r::Stage::kIssued, r::Stage::kBurnIntent,
        r::Stage::kConsumed, r::Stage::kCreateAttempt,
        r::Stage::kProcessIdentity, r::Stage::kCustodyAcknowledged,
        r::Stage::kIpc, r::Stage::kExitObserved, r::Stage::kHandlesSettled,
        r::Stage::kFinal}) {
    for (bool unknown : {false, true}) {
      Fixture t;
      t.sink.fail = true;
      t.sink.fail_stage = stage;
      t.sink.unknown = unknown;
      t.sink.write_then_lose_ack = unknown;
      if (t.c.begin())
        t.finish();
      check(t.c.result().terminal && !t.c.result().evidence_preserved &&
                t.c.result().last.security != OfflineVerdict::kPass,
            "denied/unknown evidence including lost ACK never preserved PASS");
      check(t.sink.calls == t.sink.records.size() + (unknown ? 0u : 1u),
            "failed evidence write never retried");
    }
  }
  {
    Fixture t;
    t.sink.bad_digest = true;
    check(!t.c.begin() && !t.owner.creates,
          "sink acknowledgment hash mismatch rejects");
  }
  {
    Fixture t;
    check(t.c.begin(), "deadline fixture started");
    t.owner.mono = 30500;
    t.c.pump();
    check(t.c.result().last.security != OfflineVerdict::kPass &&
              t.owner.resumes == 1,
          "inclusive 30s deadline denies new work without replay");
  }
  {
    Fixture t;
    check(t.c.begin(), "deadline settlement fixture started");
    while (!t.owner.wire.acked)
      check(t.c.pump(), "drain actual settlement before inclusive deadline");
    t.owner.mono = 30500;
    t.c.pump();
    check(t.owner.close_calls == 1 && !t.owner.owner_handles &&
              t.c.result().last.security != OfflineVerdict::kPass,
          "deadline blocks work but permits already-owned observed-exit close");
  }
  {
    Fixture t;
    t.owner.close_unknown = true;
    check(t.c.begin(), "unknown-close fixture started");
    t.finish();
    check(t.owner.close_calls == 1 && t.owner.owner_handles &&
              t.id.closes == 0 &&
              t.c.result().last.security != OfflineVerdict::kPass,
          "unknown release retains custody and pins, never retries");
  }
  {
    Fixture t;
    t.owner.no_exit = true;
    check(t.c.begin(), "no-exit fixture started");
    t.finish();
    check(t.c.result().last.security != OfflineVerdict::kPass &&
              t.owner.close_calls == 0 && t.owner.owner_handles,
          "IPC/ACK and CloseHandle cannot invent process exit");
  }
}
void entry_gates() {
  r::ClosedWindowsBoundary ports;
  wchar_t a[] = L"candidate", b[] = L"101", c[] = L"102";
  wchar_t *one[] = {a}, *three[] = {a, b, c};
  check(!ports.allow_live_execution() &&
            r::controller_process_entry(1, one, ports) == 10 &&
            r::worker_process_entry(3, three, ports) == 10,
        "real process entries closed without port calls");
  check(r::controller_process_entry(3, three, ports) == 64,
        "controller rejects arbitrary parameters");
  wchar_t bad[] = L"-1";
  wchar_t *wrong[] = {a, b, b};
  check(r::worker_process_entry(3, wrong, ports) == 64,
        "worker rejects duplicate inherited endpoints");
  wrong[2] = bad;
  check(r::worker_process_entry(3, wrong, ports) == 64,
        "worker rejects nonnumeric handle token");
  Fixture t;
  auto f = t.f;
  f.target.grant.exe_sha256 = std::string(64, '9');
  check(!f.valid(), "artifact substitution invalidates frozen manifest");
  {
    std::lock_guard<std::mutex> lock(t.owner.wire.mutex);
    auto hash = t.f.hash();
    x::Digest d{};
    decode_hex_bytes(hash, d.data(), 32);
    x::Admission adm;
    adm.origin = 500;
    adm.working = 4096;
    adm.commit = 8192;
    adm.handles = 20;
    auto wrong_frame = adm.encode(d);
    wrong_frame[16] ^= 1;
    t.owner.wire.to_worker.push_back(wrong_frame);
  }
  WorkerBoot boot(t.f, t.owner.wire);
  check(r::worker_process_entry(3, three, boot) == 10 &&
            t.owner.wire.checkpoints == 0,
        "Worker entry cannot do zero-crypto sequence before correct target "
        "ADMISSION");
}
} // namespace
int main() {
  positive();
  failures();
  entry_gates();
  std::cout << "PASS: " << checks
            << " R1 Fake wiring/custody/evidence assertions; no Windows "
               "security operations\n";
}
