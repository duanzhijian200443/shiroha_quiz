#include "diagnostics/l1_e5_controller.h"
#include <cstdlib>
#include <deque>
#include <iostream>
#include <stdexcept>
using namespace shiroha_l1_crypto;
namespace x = shiroha_l1_crypto::e4;
namespace y = shiroha_l1_crypto::e5;
namespace {
unsigned checks = 0;
void check(bool b, const char *message) {
  ++checks;
  if (!b) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
y::FixedTarget target() {
  y::FixedTarget f;
  auto &t = f.grant;
  for (auto p : {&t.batch_id, &t.device_id, &t.compiler_id, &t.os_id,
      &t.stop_owner, &t.recovery_owner, &t.evidence_owner, &t.reviewer_id,
      &t.verifier_id, &t.user_approval_id}) *p = "SYNTHETIC";
  for (auto p : {&t.account_identity_sha256, &t.exe_sha256,
      &t.dependency_manifest_sha256, &t.toolchain_manifest_sha256,
      &t.review_sha256, &t.verification_sha256}) *p = std::string(64, '1');
  t.source_sha = t.base_sha = std::string(40, 'a');
  t.user_scope = "L1-CRYPTO";
  t.non_elevated = t.reviewer_approved = t.verifier_approved = t.evidence_output_approved = true;
  t.working_set_bytes = 4096; t.commit_bytes = 8192; t.handles = 20;
  t.window_start_ms = 1700000000000ULL; t.window_end_ms = t.window_start_ms + 120000;
  f.scope.directory = "C:\\SYNTHETIC\\E5";
  f.scope.cleanup_owner = "SYNTHETIC";
  f.scope.recovery_record_sha256 = f.scope.controller_exe_sha256 = std::string(64, '2');
  f.scope.controller_working = 2048; f.scope.controller_commit = 4096;
  f.scope.controller_handles = 10; f.scope.recovery_approved = true;
  t.evidence_scope_id = f.scope.hash();
  f.sid = L"FAKE-SID";
  return f;
}
struct Io final : x::GrantIo {
  unsigned issues = 0, requests = 0, burns = 0, starts = 0, operations = 0, fail_at = 0;
  bool issued = false, requested = false, throwing = false;
  x::Journal bytes{};
  bool principal(const std::wstring &s) override { return s == L"FAKE-SID"; }
  x::IoResult outcome() {
    if (++operations != fail_at) return x::IoResult::ok;
    if (throwing) throw std::runtime_error("synthetic");
    return x::IoResult::unknown;
  }
  x::IoResult issue_new(const x::Receipt &, BatchObjectPins &p) override {
    ++issues;
    if (issued) return x::IoResult::denied;
    issued = true;
    unsigned i = 1;
    for (auto q : {&p.dir_pin, &p.receipt_pin, &p.grant_pin}) {
      q->volume_serial = 9; q->file_id[0] = uint8_t(i++);
    }
    return outcome();
  }
  bool inspect(const BatchObjectPins &p) override { return p.valid(); }
  x::IoResult request_new(const x::Journal &j) override {
    ++requests;
    if (requested) return x::IoResult::denied;
    requested = true; bytes = j;
    return outcome();
  }
  x::IoResult burn_issued() override { ++burns; return outcome(); }
  x::IoResult update_request(const x::Journal &j) override {
    bytes = j;
    if (j[6] == 3) ++starts;
    return outcome();
  }
};
struct Fake final : y::Platform {
  Io &io;
  unsigned touches = 0, prompts = 0, inspections = 0, creates = 0, closes = 0, handoffs = 0;
  bool enabled = true, cancel = false, checked = true, drift = false, bad_hash = false;
  bool inspect_ok = true, healthy = true, exited = false, normal = true;
  bool close_ok = true, io_close_ok = true, transport_ok = true, send_ok = true;
  bool throw_create = false, deadline_at_send = false, budget_blow_at_send = false;
  uint64_t mono = 500, launch = 0;
  uint64_t controller_working = 1024, worker_working = 2048;
  x::WorkerStart started{true, false, true, true, true, true, true, true, true, true, 123};
  std::deque<x::Frame> incoming;
  std::vector<x::Frame> outgoing;
  x::ApprovalPromptModel shown;
  explicit Fake(Io &store) : io(store) {}
  bool runtime_allowed() const noexcept override { return enabled; }
  bool inspect_target(const y::FixedTarget &) override {
    ++touches; ++inspections;
    if (deadline_at_send && inspections == 3) mono = launch + 30000;
    if (budget_blow_at_send && inspections == 3) controller_working = 99999;
    return inspect_ok && !(drift && inspections > 1);
  }
  bool approve(const x::ApprovalPromptModel &p, x::ApprovalUiResponse &r) override {
    ++touches; ++prompts; shown = p;
    r = {true, cancel, false, checked, p.suffix, p.target_hash};
    if (bad_hash) r.displayed_hash[0] = 'f';
    return !cancel;
  }
  x::ClockReading read_clock() override {
    ++touches;
    return {target().grant.window_start_ms + mono - 500, mono, 42, true};
  }
  x::WorkerStart start_suspended(const GrantTarget &t, const x::Digest &d, x::ClockReading r) override {
    ++touches; ++creates; launch = r.mono;
    check(io.bytes[6] == 3 && io.burns == 1 && io.starts == 1, "write-ahead consume/start precedes sole create");
    if (throw_create) throw std::runtime_error("synthetic");
    if (started.state() == WorkerState::kRunning) {
      auto f = x::frame(x::Message::hello, 1, 0, 1, d);
      x::put(f.data() + 32, started.pid, 4); x::put(f.data() + 36, 3, 4);
      x::Digest image{}; decode_hex_bytes(t.exe_sha256, image.data(), 32);
      std::copy_n(image.begin(), 16, f.begin() + 48);
      incoming.push_back(f);
    }
    return started;
  }
  y::Observation observe() override {
    ++touches;
    return {{mono, worker_working, 4096, exited ? 0u : 4u, 0}, {mono, controller_working, 2048, 4, 0}, healthy, exited, normal};
  }
  bool next(x::Frame &f, bool &available) override {
    ++touches;
    available = !incoming.empty();
    if (available) { f = incoming.front(); incoming.pop_front(); }
    return transport_ok;
  }
  bool send(const x::Frame &f) override { ++touches; outgoing.push_back(f); return send_ok; }
  bool close_observed_exit() override { ++touches; ++closes; return exited && close_ok; }
  bool close_owned_io() override { ++touches; return io_close_ok; }
  void handoff(const std::string &, uint32_t) noexcept override { ++handoffs; }
};
struct Fixture {
  Io io;
  Fake os{io};
  y::Controller controller{target(), io, os};
};
void push_settlement(Fixture &f, const x::Digest &d, uint32_t seq,
                     unsigned parts, bool unknown = false) {
  L1CryptoLedger l;
  NativeObservation n;
  constexpr unsigned limits[] = {1, 3, 3, 6, 3, 45, 45};
  for (unsigned i = 0; i < 7; ++i) l.abi_calls[i] = {limits[i], limits[i], limits[i], limits[i], 0, 0};
  for (unsigned i = 0; i < 14; ++i) n.calls[i] = {kNativeLimits[i], kNativeLimits[i], kNativeLimits[i], kNativeLimits[i], 0, 0};
  l.abi_attempted_total = 106; l.attempted = l.returned = l.completed = l.accepted = 16;
  l.successful = 12; l.buffers_allocated = l.releases_attempted = l.releases_succeeded = 45;
  l.samples = 18; n.acquired = n.released = 47; n.unknown = unknown;
  x::Settlement bytes{};
  check(x::encode_settlement(l, n, bytes), "same E4 settlement encoding");
  auto frames = x::settlement_frames(bytes, d, seq);
  for (unsigned i = 0; i < parts; ++i) f.os.incoming.push_back(frames[i]);
}
void tail(Fixture &f, bool unknown = false, unsigned parts = 24) {
  x::Digest d{};
  decode_hex_bytes(f.os.shown.target_hash, d.data(), 32);
  for (uint16_t i = 0; i < 18; ++i) {
    auto frame = x::frame(x::Message::sample, i + 2, i, 18, d);
    x::put(frame.data() + 32, f.os.mono, 8);
    x::put(frame.data() + 40, 2048, 8); x::put(frame.data() + 48, 4096, 8);
    x::put(frame.data() + 56, 4, 4); x::put(frame.data() + 60, i == 17 ? 16 : i, 4);
    f.os.incoming.push_back(frame);
  }
  push_settlement(f, d, 20, parts, unknown);
}
void approvals() {
  {
    Fixture f; f.os.enabled = false;
    check(!f.controller.begin() && f.os.touches == 0 && f.io.issues == 0 &&
        f.controller.evidence().runtime_denied, "closed runtime gate touches no OS/UI/clock/close");
    check(!f.controller.begin() && !f.controller.pump() && f.os.touches == 0, "closed gate cannot replay");
  }
  for (unsigned k = 0; k < 9; ++k) {
    Io io; Fake os(io); auto t = target();
    if (k == 0) os.cancel = true;
    if (k == 1) os.checked = false;
    if (k == 2) os.drift = true;
    if (k == 3) t.grant.reviewer_approved = false;
    if (k == 4) t.grant.verifier_approved = false;
    if (k == 5) t.scope.recovery_approved = false;
    if (k == 6) t.scope.controller_working = 0;
    if (k == 7) t.scope.directory += "DRIFT";
    if (k == 8) os.bad_hash = true;
    y::Controller c(t, io, os);
    check(!c.begin() && io.issues == 0 && os.creates == 0, "missing/cancelled/drifting review denies BEFORE issuance");
    check(!c.begin() && os.prompts <= 1, "no approval retry");
  }
  auto t = target(); x::ApprovalPromptModel base, shown;
  check(y::presentation(t, base, shown) && base.target_hash == shown.target_hash &&
      shown.summary.find(t.scope.directory) != std::string::npos &&
      shown.summary.find(y::FixedScope::inventory) != std::string::npos &&
      shown.summary.find(y::FixedScope::measurement) != std::string::npos,
      "exact directory/inventory/method shown under SAME E4 hash");
  auto h = t.scope.hash();
  for (unsigned k = 0; k < 8; ++k) {
    auto s = t.scope;
    if (k == 0) s.directory += "X";
    if (k == 1) s.cleanup_owner += "X";
    if (k == 2) s.recovery_record_sha256[0] = '3';
    if (k == 3) s.controller_exe_sha256[0] = '3';
    if (k == 4) ++s.controller_working;
    if (k == 5) ++s.controller_commit;
    if (k == 6) ++s.controller_handles;
    if (k == 7) s.recovery_approved = false;
    check(s.hash() != h, "every E5 scope field changes approved target");
  }
}
void one_use_and_failures() {
  for (unsigned k = 1; k <= 5; ++k) for (bool throwing : {false, true}) {
    Fixture f; f.io.fail_at = k; f.io.throwing = throwing;
    check(!f.controller.begin() && f.os.creates == 0 && !f.controller.begin(), "uncertain persistence never launches/retries");
    check(f.controller.evidence().core.consumption.unknown, "lost write/reply preserves UNKNOWN");
  }
  for (unsigned k = 0; k < 7; ++k) {
    Fixture f;
    if (k == 0) f.os.started.created = false;
    if (k == 1) f.os.started.token = false;
    if (k == 2) f.os.started.image = false;
    if (k == 3) f.os.started.dependencies = false;
    if (k == 4) f.os.started.resume_known = false;
    if (k == 5) f.os.started.hello = false;
    if (k == 6) f.os.throw_create = true;
    check(!f.controller.begin() && f.os.creates == 1 && f.io.burns == 1 &&
        !f.controller.begin() && f.os.creates == 1, "failed create/validation/Resume never restores consumed permission");
    check((k == 0) ? f.os.handoffs == 0 : f.os.handoffs == 1, "suspended/unknown creation requires operator custody handoff");
    if (k != 0) check(f.controller.evidence().core.custody_unsettled, "no process close inferred from failure");
  }
  Io io;
  { Fake os(io); y::Controller c(target(), io, os); check(c.begin(), "first controller consumes"); }
  Fake os(io); y::Controller restarted(target(), io, os);
  check(!restarted.begin() && os.creates == 0 && io.requests == 1 && io.burns == 1, "reconstructed controller cannot reuse issued Batch (FAKE only)");
}
void pipeline() {
  for (unsigned outcome = 0; outcome < 8; ++outcome) {
    Fixture f;
    check(f.controller.begin() && f.os.outgoing.size() == 1 &&
        x::get(f.os.outgoing[0].data() + 6, 2) == 2, "human/issue/WAL/consume/start/HELLO/ADMISSION");
    tail(f, outcome == 1, outcome == 2 ? 23 : 24);
    while (!f.os.incoming.empty()) check(f.controller.pump(), "ordered samples and lossless settlement");
    if (outcome == 0) {
      f.os.transport_ok = false;
      check(f.controller.pump() && !f.controller.evidence().finished,
          "ACK then pipe EOF before observed exit neither fails nor settles");
    }
    f.os.exited = outcome != 3; f.os.normal = outcome != 4;
    f.os.close_ok = outcome != 5; f.os.io_close_ok = outcome != 6;
    if (outcome == 3 || outcome == 7) f.os.mono = f.os.launch + 30000;
    check(!f.controller.pump(), "bounded terminal settlement");
    auto e = f.controller.evidence();
    auto verdict = outcome == 0 || outcome == 6 ? OfflineVerdict::kPass :
        outcome == 4 || outcome == 7 ? OfflineVerdict::kFail : OfflineVerdict::kUnknown;
    check(e.core.observation.verdict == verdict, "exit alone never equals Native/IPC/handle settlement");
    check(e.verdict == (e.handoff_required ? OfflineVerdict::kUnknown : verdict),
        "unknown owned IO closure cannot yield overall PASS");
    check(e.handoff_required == (outcome == 3 || outcome == 5 || outcome == 6), "operator receives unresolved custody");
    auto touches = f.os.touches;
    check(!f.controller.begin() && !f.controller.pump() && f.os.touches == touches &&
        f.controller.evidence().core.observation.verdict == verdict, "late events cannot rewrite final snapshot");
  }
}
// The E4 Worker protocol permits a failure STOP followed by its 24 already
// produced settlement parts, the ACK and then the observed exit. E5 must
// collect that tail inside the SAME deadline, keep the failure verdict, and
// never re-authorize work because the run failed.
void worker_stop_tail() {
  {
    Fixture f;
    check(f.controller.begin() && f.os.outgoing.size() == 1, "worker STOP fixture admitted");
    x::Digest d{};
    decode_hex_bytes(f.os.shown.target_hash, d.data(), 32);
    for (uint16_t i = 0; i < 3; ++i) {
      auto frame = x::frame(x::Message::sample, i + 2, i, 18, d);
      x::put(frame.data() + 32, f.os.mono, 8);
      x::put(frame.data() + 40, 2048, 8); x::put(frame.data() + 48, 4096, 8);
      x::put(frame.data() + 56, 4, 4); x::put(frame.data() + 60, i, 4);
      f.os.incoming.push_back(frame);
    }
    auto stop = x::frame(x::Message::stop, 5, 0, 1, d);
    x::put(stop.data() + 32, unsigned(StopReason::kWorker), 4);
    f.os.incoming.push_back(stop);
    push_settlement(f, d, 6, 24);
    while (!f.os.incoming.empty())
      check(f.controller.pump(), "STOP then owed settlement drained in order");
    check(f.os.outgoing.size() == 2 && x::get(f.os.outgoing[1].data() + 6, 2) == 6 &&
        f.controller.evidence().ack_sent, "settlement after STOP still earns the ACK");
    f.os.exited = true; f.os.normal = false;
    check(!f.controller.pump(), "bounded terminal settlement after the STOP tail");
    auto e = f.controller.evidence();
    check(e.core.observation.verdict == OfflineVerdict::kFail &&
        !e.core.observation.settlement_incomplete,
        "worker STOP settles complete Native records as FAIL, not UNKNOWN");
    check(e.core.observation.first_failure == StopReason::kWorker,
        "the Worker STOP stays the first causal failure");
    check(!e.handoff_required && !e.stop_attempted,
        "drained custody needs no handoff and no second STOP");
  }
  {
    // A failure STOP ends nothing but cleanup: new work can never be admitted.
    Fixture f;
    check(f.controller.begin(), "post-STOP re-authorization fixture admitted");
    x::Digest d{};
    decode_hex_bytes(f.os.shown.target_hash, d.data(), 32);
    auto stop = x::frame(x::Message::stop, 2, 0, 1, d);
    x::put(stop.data() + 32, unsigned(StopReason::kWorker), 4);
    f.os.incoming.push_back(stop);
    check(f.controller.pump() && !f.controller.evidence().finished,
        "STOP alone keeps the bounded cleanup window open");
    auto sample = x::frame(x::Message::sample, 3, 0, 18, d);
    x::put(sample.data() + 32, f.os.mono, 8);
    x::put(sample.data() + 40, 2048, 8); x::put(sample.data() + 48, 4096, 8);
    x::put(sample.data() + 56, 4, 4); x::put(sample.data() + 60, 0, 4);
    f.os.incoming.push_back(sample);
    check(!f.controller.pump(), "SAMPLE after STOP is never re-authorized");
    auto e = f.controller.evidence();
    check(e.core.observation.verdict == OfflineVerdict::kUnknown && e.handoff_required,
        "rejected new work keeps UNKNOWN custody");
  }
  {
    // The retained tail is still bounded by the original inclusive deadline.
    Fixture f;
    check(f.controller.begin(), "bounded drain fixture admitted");
    x::Digest d{};
    decode_hex_bytes(f.os.shown.target_hash, d.data(), 32);
    auto stop = x::frame(x::Message::stop, 2, 0, 1, d);
    x::put(stop.data() + 32, unsigned(StopReason::kWorker), 4);
    f.os.incoming.push_back(stop);
    push_settlement(f, d, 3, 5);
    while (!f.os.incoming.empty()) check(f.controller.pump(), "partial tail drained");
    f.os.mono = f.os.launch + 30000;
    check(!f.controller.pump() && f.controller.evidence().handoff_required,
        "incomplete settlement after STOP ends UNKNOWN at the original deadline");
    check(f.controller.evidence().core.observation.verdict == OfflineVerdict::kUnknown &&
        f.controller.evidence().stop_attempted,
        "unpaid tail retains operator custody under one bounded STOP");
  }
  {
    // Exit must not waive an already-observed peak: the final observation is
    // still budget-authoritative, and an unavailable exit measurement is an
    // explicit downgrade instead of a silent pass.
    for (unsigned mode = 0; mode < 2; ++mode) {
      Fixture f;
      check(f.controller.begin() && f.os.outgoing.size() == 1, "post-exit budget fixture admitted");
      tail(f);
      while (!f.os.incoming.empty()) check(f.controller.pump(), "full run before the exit observation");
      f.os.worker_working = mode ? 0 : 99999;
      f.os.exited = true; f.os.normal = true;
      check(!f.controller.pump(), "post-exit peak/unavailable measurement cannot PASS");
      auto e = f.controller.evidence();
      check(e.core.observation.verdict == OfflineVerdict::kFail && !e.handoff_required,
          "over-budget or missing exit peaks settle FAIL with closed custody");
    }
  }
}
void deadline_and_transport() {
  {
    Fixture f; f.os.deadline_at_send = true;
    check(!f.controller.begin() && f.os.outgoing.empty() && f.os.creates == 1,
        "late identity inspection cannot forward ADMISSION at inclusive deadline");
  }
  {
    Fixture f; f.os.budget_blow_at_send = true;
    check(!f.controller.begin() && f.os.outgoing.empty() && f.os.creates == 1 &&
        f.os.handoffs == 1, "budget spent by the post-HELLO re-inspection blocks ADMISSION");
    check(f.controller.evidence().core.observation.verdict == OfflineVerdict::kUnknown,
        "no first work permission after a controller budget breach");
  }
  for (unsigned mode = 0; mode < 5; ++mode) {
    Fixture f; check(f.controller.begin(), "failure fixture admitted");
    if (mode == 0) f.os.mono = f.os.launch + 30000;
    if (mode == 1) f.os.transport_ok = false;
    if (mode == 2) f.os.controller_working = 99999;
    if (mode == 3) f.os.healthy = false;
    if (mode == 4) { x::Frame malformed{}; f.os.incoming.push_back(malformed); }
    check(!f.controller.pump() && f.os.creates == 1 && f.os.handoffs == 1,
        "idle deadline/IPC/resource observation failure STOPs with operator custody");
    check(f.controller.evidence().core.observation.verdict == OfflineVerdict::kUnknown,
        "unexited child and missing settlement stay UNKNOWN");
    check(f.controller.evidence().stop_attempted && f.os.outgoing.size() == 2,
        "at most one six-type STOP, no kill/restart");
  }
}
} // namespace
int main() {
  approvals(); one_use_and_failures(); pipeline(); worker_stop_tail(); deadline_and_transport();
  std::cout << "PASS: E5 OFFLINE/FAKE checks=" << checks
      << "; Windows persistence/process/crypto NOT EXECUTED\n";
}
