#include "diagnostics/l1_b1_unified.h"

#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>

using namespace shiroha_l1_crypto;
namespace x = shiroha_l1_crypto::e4;
namespace y = shiroha_l1_crypto::e5;
namespace z = shiroha_l1_crypto::b1;

namespace {
unsigned total_checks = 0;
void check(bool ok, const char *reason) {
  ++total_checks;
  if (!ok) {
    std::cerr << "FAIL: " << reason << '\n';
    std::exit(1);
  }
}

y::FixedTarget make_target(bool admission_only) {
  y::FixedTarget f;
  auto &t = f.grant;
  for (auto p :
       {&t.batch_id, &t.device_id, &t.compiler_id, &t.os_id, &t.stop_owner,
        &t.recovery_owner, &t.evidence_owner, &t.reviewer_id, &t.verifier_id,
        &t.user_approval_id})
    *p = "SYNTHETIC-B1";
  for (auto p : {&t.account_identity_sha256, &t.exe_sha256,
                 &t.dependency_manifest_sha256, &t.toolchain_manifest_sha256,
                 &t.review_sha256, &t.verification_sha256})
    *p = std::string(64, '1');
  t.source_sha = t.base_sha = std::string(40, 'a');
  if (admission_only) {
    t.user_scope = "L1-ADMISSION";
    t.abi_limits = {0, 0, 0, 0, 0, 0, 0};
  } else {
    t.user_scope = "L1-CRYPTO";
    t.abi_limits = {1, 3, 3, 6, 3, 45, 45};
  }
  t.non_elevated = t.reviewer_approved = t.verifier_approved =
      t.evidence_output_approved = true;
  t.working_set_bytes = 4096;
  t.commit_bytes = 8192;
  t.handles = 20;
  t.window_start_ms = 1700000000000ULL;
  t.window_end_ms = t.window_start_ms + 120000;
  f.scope.directory = "C:\\SYNTHETIC\\B1_ISOLATED";
  f.scope.cleanup_owner = "SYNTHETIC-B1";
  f.scope.recovery_record_sha256 = f.scope.controller_exe_sha256 =
      std::string(64, '2');
  f.scope.controller_working = 2048;
  f.scope.controller_commit = 4096;
  f.scope.controller_handles = 10;
  f.scope.recovery_approved = true;
  t.evidence_scope_id = f.scope.hash();
  f.sid = L"FAKE-SID";
  return f;
}

struct FakeGrantIo final : x::GrantIo {
  unsigned issues = 0, requests = 0, burns = 0, starts = 0, operations = 0,
           fail_at = 0;
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
      q->volume_serial = 9;
      q->file_id[0] = uint8_t(i++);
    }
    return outcome();
  }
  bool inspect(const BatchObjectPins &p) override { return p.valid(); }
  x::IoResult request_new(const x::Journal &j) override {
    ++requests;
    if (requested) return x::IoResult::denied;
    requested = true;
    bytes = j;
    return outcome();
  }
  x::IoResult burn_issued() override {
    ++burns;
    return outcome();
  }
  x::IoResult update_request(const x::Journal &j) override {
    bytes = j;
    if (j[6] == 3) ++starts;
    return outcome();
  }
};

struct FakePlatform final : y::Platform {
  FakeGrantIo &io;
  y::FixedTarget base_target;
  unsigned touches = 0, creates = 0, closes = 0, handoffs = 0, inspections = 0;
  bool enabled = true, cancel = false, inspect_ok = true, healthy = true;
  bool exited = false, normal = true, close_ok = true, io_close_ok = true;
  bool throw_create = false, drift_on_post_hello = false;
  bool exit_before_admission = false;
  uint64_t mono = 500, launch = 0;
  x::WorkerStart started{true, false, true, true, true, true,
                         true, true,  true, true, 321};
  std::deque<x::Frame> incoming;
  std::vector<x::Frame> outgoing;
  x::ApprovalPromptModel shown;

  FakePlatform(FakeGrantIo &store, y::FixedTarget t)
      : io(store), base_target(std::move(t)) {}
  bool runtime_allowed() const noexcept override { return enabled; }
  bool inspect_target(const y::FixedTarget &) override {
    ++touches;
    ++inspections;
    if (exit_before_admission && inspections == 3) exited = true;
    return inspect_ok && !(drift_on_post_hello && inspections == 3);
  }
  bool approve(const x::ApprovalPromptModel &p,
               x::ApprovalUiResponse &r) override {
    ++touches;
    shown = p;
    r = {true, cancel, false, true, p.suffix, p.target_hash};
    return !cancel;
  }
  x::ClockReading read_clock() override {
    ++touches;
    return {base_target.grant.window_start_ms + mono - 500, mono, 42, true};
  }
  x::WorkerStart start_suspended(const GrantTarget &t, const x::Digest &d,
                                 x::ClockReading r) override {
    ++touches;
    ++creates;
    launch = r.mono;
    check(io.bytes[6] == 3 && io.burns == 1 && io.starts == 1,
          "consume and start precede suspended creation");
    if (throw_create) throw std::runtime_error("synthetic");
    if (started.state() == WorkerState::kRunning) {
      auto f = x::frame(x::Message::hello, 1, 0, 1, d);
      x::put(f.data() + 32, started.pid, 4);
      x::put(f.data() + 36, 3, 4);
      x::Digest image{};
      decode_hex_bytes(t.exe_sha256, image.data(), 32);
      std::copy_n(image.begin(), 16, f.begin() + 48);
      incoming.push_back(f);
    }
    return started;
  }
  y::Observation observe() override {
    ++touches;
    return {{mono, 2048, 4096, exited ? 0u : 4u, 0},
            {mono, 1024, 2048, 4, 0},
            healthy,
            exited,
            normal};
  }
  bool next(x::Frame &f, bool &available) override {
    ++touches;
    available = !incoming.empty();
    if (available) {
      f = incoming.front();
      incoming.pop_front();
    }
    return true;
  }
  bool send(const x::Frame &f) override {
    ++touches;
    outgoing.push_back(f);
    return true;
  }
  bool close_observed_exit() override {
    ++touches;
    ++closes;
    return exited && close_ok;
  }
  bool close_owned_io() override {
    ++touches;
    return io_close_ok;
  }
  void handoff(const std::string &, uint32_t) noexcept override { ++handoffs; }
};

struct LoopbackWorkerLink final : x::WorkerLink {
  std::vector<x::Frame> sent;
  std::deque<x::Frame> to_worker;
  std::deque<x::Frame> control_frames;
  bool send(const x::Frame &f) override {
    sent.push_back(f);
    return true;
  }
  bool receive(x::Frame &f) override {
    if (to_worker.empty()) return false;
    f = to_worker.front();
    to_worker.pop_front();
    return true;
  }
  bool checkpoint(L1CryptoLedger &l) override {
    return l.resources(2048, 4096, 4);
  }
  bool poll_control(x::Frame &f, bool &available) override {
    available = !control_frames.empty();
    if (available) {
      f = control_frames.front();
      control_frames.pop_front();
    }
    return true;
  }
};

uint64_t worker_clock_now = 500;
bool fake_worker_clock(uint64_t &out) noexcept {
  out = worker_clock_now;
  return true;
}

// ============================================================================
// B1-A Tests: L1-ADMISSION Isolated Candidate & Lifecycle / Phase Ledger
// ============================================================================
void test_b1_a_admission_only() {
  check(!z::kUnifiedRealExecutionAuthorized,
        "unified B1 never authorizes real execution");
  const auto adm_target = make_target(true);
  const auto cry_target = make_target(false);
  check(adm_target.valid() && adm_target.grant.is_admission_only(),
        "L1-ADMISSION target valid with zero ABI limits");
  check(cry_target.valid() && !cry_target.grant.is_admission_only(),
        "L1-CRYPTO target valid with 106 ABI limits");

  // Scope mismatch rejected: L1-ADMISSION with non-zero ABI limit is invalid
  {
    auto bad = adm_target;
    bad.grant.abi_limits[0] = 1;
    check(!bad.grant.structure_complete() && !bad.valid(),
          "L1-ADMISSION rejects any non-zero ABI limit");
    auto bad2 = cry_target;
    bad2.grant.abi_limits = {0, 0, 0, 0, 0, 0, 0};
    check(!bad2.grant.structure_complete() && !bad2.valid(),
          "L1-CRYPTO rejects zero ABI limits");
  }

  // Worker cross-target isolation:
  // Crypto worker refuses L1-ADMISSION target; Admission worker refuses L1-CRYPTO
  {
    LoopbackWorkerLink link1, link2;
    check(!y::worker_candidate(link1, adm_target, 321, fake_worker_clock,
                               [](const char *) -> void * { return nullptr; }),
          "Crypto worker_candidate refuses L1-ADMISSION target");
    check(!z::admission_only_worker_candidate(link2, cry_target, 321,
                                              fake_worker_clock),
          "Admission-only worker_candidate refuses L1-CRYPTO target");
  }

  // Default closed runtime gate
  {
    FakeGrantIo io;
    FakePlatform os(io, adm_target);
    os.enabled = false;
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(!ctrl.begin() && os.touches == 0 && io.issues == 0 &&
              ctrl.evidence().runtime_denied,
          "closed runtime gate performs zero touches");
    check(ctrl.phases().lifecycle == z::ProcessLifecycleStage::kUncreated &&
              !ctrl.phases().consume.started && !ctrl.phases().create.started,
          "uncreated state preserved when runtime gate is closed");
  }

  // Missing approved recovery scheme blocks before any process creation
  {
    FakeGrantIo io;
    auto no_rec = adm_target;
    no_rec.scope.recovery_approved = false;
    FakePlatform os(io, no_rec);
    z::UnifiedAdmissionController ctrl(no_rec, io, os);
    check(!ctrl.begin() && os.creates == 0 && io.issues == 0,
          "missing approved recovery scheme blocks admission");
  }

  // Full positive L1-ADMISSION Controller + Admission-only Worker roundtrip
  {
    FakeGrantIo io;
    FakePlatform os(io, adm_target);
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(ctrl.allow_operation(z::OperationDomain::kAdmissionHandshake) &&
              ctrl.allow_operation(z::OperationDomain::kReleaseOwnedResource) &&
              !ctrl.allow_operation(z::OperationDomain::kCryptoAbiPrimitive) &&
              !ctrl.allow_operation(
                  z::OperationDomain::kObjectsLockAndPublish) &&
              !ctrl.allow_operation(
                  z::OperationDomain::kStoreDpapiAndTransaction),
          "L1-ADMISSION controller allowlist blocks crypto/objects/store");

    check(ctrl.begin() && os.outgoing.size() == 1,
          "L1-ADMISSION begin issues grant, consumes, creates suspended, "
          "resumes, and sends ADMISSION after HELLO");
    check(ctrl.phases().consume.started && ctrl.phases().consume.succeeded &&
              !ctrl.phases().consume.unknown && ctrl.phases().create.started &&
              ctrl.phases().create.succeeded && ctrl.phases().resume.started &&
              ctrl.phases().resume.succeeded &&
              ctrl.phases().lifecycle == z::ProcessLifecycleStage::kResumed,
          "consume/create/resume phases recorded and lifecycle is kResumed");

    // Run isolated Admission-only Worker against the controller's ADMISSION
    LoopbackWorkerLink wlink;
    wlink.to_worker.push_back(os.outgoing[0]);
    x::Digest d{};
    decode_hex_bytes(os.shown.target_hash, d.data(), 32);
    auto ack = x::frame(x::Message::ack, 2, 0, 1, d);
    x::put(ack.data() + 32, 1, 4);
    wlink.to_worker.push_back(ack);
    worker_clock_now = 500;
    check(z::admission_only_worker_candidate(wlink, adm_target, 321,
                                             fake_worker_clock),
          "admission_only_worker_candidate completes with zero crypto");
    // wlink.sent has: 1 HELLO + 18 SAMPLEs + 24 SETTLEMENTs = 43 frames
    check(wlink.sent.size() == 43,
          "admission-only worker emits 1 HELLO + 18 samples + 24 settlement");
    for (size_t i = 1; i < wlink.sent.size(); ++i) {
      os.incoming.push_back(wlink.sent[i]);
    }
    while (!os.incoming.empty()) {
      ++os.mono;
      check(ctrl.pump(), "pump processes admission-only frames");
    }
    os.exited = true;
    ++os.mono;
    check(!ctrl.pump(), "final pump settles after observed exit");
    const auto ev = ctrl.evidence();
    const auto &ph = ctrl.phases();
    check(ev.verdict == OfflineVerdict::kPass &&
              ev.core.observation.abi[0].attempted == 0 &&
              ev.core.observation.native.acquired == 0 &&
              ev.core.observation.sample_count == 18 && !ev.handoff_required,
          "L1-ADMISSION settles PASS with 0 ABI and 0 native resources");
    check(ph.ipc.started && ph.ipc.completed && ph.ipc.succeeded &&
              !ph.ipc.unknown && ph.close.started && ph.close.completed &&
              ph.close.succeeded && !ph.close.unknown &&
              ph.uncreated_observed && ph.created_suspended_observed &&
              ph.resumed_observed && ph.exited_observed &&
              ph.handles_released_observed && !ph.custody_retained &&
              ph.lifecycle == z::ProcessLifecycleStage::kHandlesReleased,
          "all 5 phases and all 5 process lifecycle states recorded");
  }

  // Negative phase cases: consume unknown, create unknown, suspended residue,
  // resume unknown, IPC incomplete, close failure
  {
    // 1) Consume unknown (burn_issued returns unknown)
    FakeGrantIo io;
    io.fail_at = 3;
    FakePlatform os(io, adm_target);
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(!ctrl.begin() && ctrl.phases().consume.started &&
              ctrl.phases().consume.unknown && !ctrl.phases().create.started &&
              ctrl.evidence().verdict == OfflineVerdict::kUnknown,
          "consume unknown stops before process creation and records UNKNOWN");
  }
  {
    // 2) Create unknown (exception during start_suspended)
    FakeGrantIo io;
    FakePlatform os(io, adm_target);
    os.throw_create = true;
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(!ctrl.begin() && ctrl.phases().create.started &&
              ctrl.phases().create.unknown && ctrl.phases().custody_retained &&
              ctrl.phases().lifecycle ==
                  z::ProcessLifecycleStage::kCustodyRetainedUnknown &&
              os.handoffs == 1,
          "create unknown retains custody and triggers operator handoff");
  }
  {
    // 3) Created suspended, token inspection fails before ResumeThread
    FakeGrantIo io;
    FakePlatform os(io, adm_target);
    os.started = {true,  false, false, true,  true, true,
                  false, false, false, false, 321};
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(!ctrl.begin() && ctrl.phases().created_suspended_observed &&
              !ctrl.phases().resumed_observed &&
              ctrl.phases().custody_retained &&
              ctrl.phases().lifecycle ==
                  z::ProcessLifecycleStage::kCustodyRetainedUnknown &&
              os.handoffs == 1,
          "suspended child failing token check is never resumed and retains "
          "custody");
  }
  {
    // 4) Resume unknown
    FakeGrantIo io;
    FakePlatform os(io, adm_target);
    os.started = {true, false, true, true,  true, true,
                  true, false, true, false, 321};
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(!ctrl.begin() && ctrl.phases().resume.started &&
              ctrl.phases().resume.unknown && ctrl.phases().custody_retained &&
              ctrl.evidence().verdict == OfflineVerdict::kUnknown,
          "unknown ResumeThread outcome records resume.unknown and retains "
          "custody");
  }
  {
    // 5) Exited, handle close fails
    FakeGrantIo io;
    FakePlatform os(io, adm_target);
    os.close_ok = false;
    z::UnifiedAdmissionController ctrl(adm_target, io, os);
    check(ctrl.begin(), "begin succeeds");
    os.exited = true;
    ++os.mono;
    check(!ctrl.pump() && ctrl.phases().exited_observed &&
              !ctrl.phases().handles_released_observed &&
              ctrl.phases().close.unknown && ctrl.phases().custody_retained &&
              ctrl.evidence().verdict == OfflineVerdict::kUnknown,
          "failed handle close after exit keeps custody and records UNKNOWN");
  }
}

// ============================================================================
// B1-B Tests: L1-CRYPTO & E5 Shared Contract Alignment
// ============================================================================
struct FakeCryptoSuite {
  static void fill_valid_raw_sig(const uint8_t *digest,
                                 uint8_t out_raw[64]) noexcept {
    for (size_t i = 0; i < 32; ++i) {
      out_raw[i] = static_cast<uint8_t>((digest[i] ^ 0x3cu) | 0x01u);
      out_raw[32 + i] = static_cast<uint8_t>((digest[31 - i] ^ 0x65u) | 0x01u);
    }
    out_raw[0] = 0x80u;
    out_raw[32] = 0x91u;
  }
  static bool record_call(NativeOp op, bool acquires_owner = false) noexcept {
    if (auto *o = active_native_observation) {
      if (!observe_native(
              op, false, o, [] { return true; }, [](bool b) { return b; },
              false))
        return false;
      if (acquires_owner) {
        ++o->acquired;
        ++o->still_owned;
      }
    }
    return true;
  }
  static bool record_release(NativeOp op) noexcept {
    if (auto *o = active_native_observation) {
      if (!observe_native(
              op, true, o, [] { return true; }, [](bool b) { return b; },
              false))
        return false;
      ++o->released;
      if (o->still_owned > 0) --o->still_owned;
    }
    return true;
  }
  static uint32_t SHIROHA_NATIVE_CALL abi() noexcept { return 3u; }
  static uint8_t *SHIROHA_NATIVE_CALL alloc(uint64_t n) noexcept {
    return new (std::nothrow) uint8_t[size_t(n)]{};
  }
  static void SHIROHA_NATIVE_CALL free_buf(uint8_t *p) noexcept { delete[] p; }
  static int32_t SHIROHA_NATIVE_CALL gen(uint32_t v, uint8_t *prv, uint64_t kc,
                                         uint64_t *kw, uint8_t *pub,
                                         uint64_t pc, uint64_t *pw) noexcept {
    if (v != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
    if (kc < 138 || pc < 65) return SHIROHA_NATIVE_INVALID_INPUT;
    std::memset(prv, 0xa1, 138);
    pub[0] = 0x04u;
    std::memset(pub + 1, 0xb1, 64);
    *kw = 138;
    *pw = 65;
    if (!record_call(NativeOp::kOpen, true) ||
        !record_call(NativeOp::kGenerate, true) ||
        !record_call(NativeOp::kFinalize, false) ||
        !record_call(NativeOp::kExport, false) ||
        !record_release(NativeOp::kDestroy) ||
        !record_release(NativeOp::kClose))
      return SHIROHA_NATIVE_UNAVAILABLE;
    return SHIROHA_NATIVE_OK;
  }
  static int32_t SHIROHA_NATIVE_CALL sign(uint32_t v, const uint8_t *prv,
                                          uint64_t kl, const uint8_t *pub,
                                          uint64_t pl, const uint8_t *dig,
                                          uint64_t dl, uint8_t *sig,
                                          uint64_t sc, uint64_t *sw) noexcept {
    if (v != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
    if (!prv || kl != 138 || !pub || pl != 65 || !dig || dl != 32 || !sig ||
        sc < 64)
      return SHIROHA_NATIVE_INVALID_INPUT;
    fill_valid_raw_sig(dig, sig);
    *sw = 64;
    if (!record_call(NativeOp::kOpen, true) ||
        !record_call(NativeOp::kImport, true) ||
        !record_call(NativeOp::kSign, false) ||
        !record_release(NativeOp::kDestroy) ||
        !record_release(NativeOp::kClose))
      return SHIROHA_NATIVE_UNAVAILABLE;
    return SHIROHA_NATIVE_OK;
  }
  static int32_t SHIROHA_NATIVE_CALL verify(uint32_t v, const uint8_t *pub,
                                            uint64_t pl, const uint8_t *dig,
                                            uint64_t dl, const uint8_t *sig,
                                            uint64_t sl) noexcept {
    if (v != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
    if (!pub || pl != 65 || !dig || dl != 32 || !sig || sl != 64)
      return SHIROHA_NATIVE_INVALID_INPUT;
    uint8_t expected[64]{};
    fill_valid_raw_sig(dig, expected);
    const bool bad = (std::memcmp(sig, expected, 64) != 0);
    if (!record_call(NativeOp::kOpen, true) ||
        !record_call(NativeOp::kImport, true) ||
        !record_call(NativeOp::kVerify, false) ||
        !record_release(NativeOp::kDestroy) ||
        !record_release(NativeOp::kClose))
      return SHIROHA_NATIVE_UNAVAILABLE;
    return bad ? SHIROHA_NATIVE_VERIFICATION_REJECTED : SHIROHA_NATIVE_OK;
  }
  static int32_t SHIROHA_NATIVE_CALL policy(uint32_t v, const uint8_t *der,
                                            uint64_t len,
                                            uint32_t role) noexcept {
    if (v != SHIROHA_NATIVE_ABI_VERSION) return SHIROHA_NATIVE_ABI_MISMATCH;
    if (!der || len == 0 || len > 16384 || (role != 1u && role != 2u))
      return SHIROHA_NATIVE_INVALID_INPUT;
    const std::string bytes(reinterpret_cast<const char *>(der),
                            static_cast<size_t>(len));
    const bool is_server =
        bytes.find("Shiroha External Host") != std::string::npos &&
        bytes.find(std::string("\x87\x04\x7f\x00\x00\x01", 6)) !=
            std::string::npos;
    const bool is_client =
        bytes.find("Shiroha External Bridge") != std::string::npos &&
        bytes.find(std::string("\x87\x04\x7f\x00\x00\x01", 6)) ==
            std::string::npos;
    const bool role_ok =
        (role == 1u && is_server) || (role == 2u && is_client);
    if (!record_call(NativeOp::kCertCreate, true))
      return SHIROHA_NATIVE_UNAVAILABLE;
    const unsigned decodes = is_server ? 7u : 6u;
    for (unsigned i = 0; i < decodes; ++i)
      if (!record_call(NativeOp::kDecode, true) ||
          !record_release(NativeOp::kLocalFree))
        return SHIROHA_NATIVE_UNAVAILABLE;
    if (!record_call(NativeOp::kTime, false) ||
        !record_release(NativeOp::kCertFree))
      return SHIROHA_NATIVE_UNAVAILABLE;
    return role_ok ? SHIROHA_NATIVE_OK : SHIROHA_NATIVE_VERIFICATION_REJECTED;
  }
  static void *resolve(const char *name) noexcept {
    if (!std::strcmp(name, "shiroha_native_abi_version"))
      return reinterpret_cast<void *>(&abi);
    if (!std::strcmp(name, "shiroha_native_buffer_alloc"))
      return reinterpret_cast<void *>(&alloc);
    if (!std::strcmp(name, "shiroha_native_buffer_free"))
      return reinterpret_cast<void *>(&free_buf);
    if (!std::strcmp(name, "shiroha_native_ecdsa_generate_key"))
      return reinterpret_cast<void *>(&gen);
    if (!std::strcmp(name, "shiroha_native_ecdsa_sign_digest"))
      return reinterpret_cast<void *>(&sign);
    if (!std::strcmp(name, "shiroha_native_ecdsa_verify_digest"))
      return reinterpret_cast<void *>(&verify);
    if (!std::strcmp(name, "shiroha_native_peer_certificate_policy"))
      return reinterpret_cast<void *>(&policy);
    return nullptr;
  }
};

void test_b1_b_crypto_e5_alignment() {
  const auto cry_target = make_target(false);

  // 1. Verify 7 ABI-3 symbol allowlist, 106 ABI attempts, 5 max live buffers,
  // 47 direct native resources, 18 samples, and zero crypto before ADMISSION
  {
    FakeGrantIo io;
    FakePlatform os(io, cry_target);
    z::UnifiedAdmissionController ctrl(cry_target, io, os);
    check(ctrl.allow_operation(z::OperationDomain::kAdmissionHandshake) &&
              ctrl.allow_operation(z::OperationDomain::kCryptoAbiPrimitive) &&
              ctrl.allow_operation(z::OperationDomain::kReleaseOwnedResource) &&
              !ctrl.allow_operation(
                  z::OperationDomain::kObjectsLockAndPublish) &&
              !ctrl.allow_operation(
                  z::OperationDomain::kStoreDpapiAndTransaction),
          "L1-CRYPTO allowlist permits crypto but blocks objects and store");

    // If ADMISSION is not sent to Worker, zero crypto symbols are resolved
    unsigned resolved_before_admission = 0;
    LoopbackWorkerLink blocked_link;
    check(!y::worker_candidate(blocked_link, cry_target, 321, fake_worker_clock,
                               [&](const char *s) -> void * {
                                 ++resolved_before_admission;
                                 return FakeCryptoSuite::resolve(s);
                               }) &&
              resolved_before_admission == 0,
          "zero crypto symbol resolutions before ADMISSION is received");

    // Full L1-CRYPTO roundtrip through UnifiedAdmissionController
    check(ctrl.begin() && os.outgoing.size() == 1, "L1-CRYPTO begin");
    LoopbackWorkerLink wlink;
    wlink.to_worker.push_back(os.outgoing[0]);
    x::Digest d{};
    decode_hex_bytes(os.shown.target_hash, d.data(), 32);
    auto ack = x::frame(x::Message::ack, 2, 0, 1, d);
    x::put(ack.data() + 32, 1, 4);
    wlink.to_worker.push_back(ack);
    worker_clock_now = 500;
    check(y::worker_candidate(wlink, cry_target, 321, fake_worker_clock,
                              FakeCryptoSuite::resolve),
          "Crypto worker_candidate receives ACK");
    for (size_t i = 1; i < wlink.sent.size(); ++i) {
      os.incoming.push_back(wlink.sent[i]);
    }
    while (!os.incoming.empty()) {
      ++os.mono;
      check(ctrl.pump(), "pump processes L1-CRYPTO frames");
    }
    // ACK sent, but process has NOT exited yet -> verdict is still kNotRun!
    check(ctrl.evidence().ack_sent &&
              ctrl.evidence().verdict == OfflineVerdict::kNotRun,
          "ACK alone never produces PASS before observed process exit");
    os.exited = true;
    ++os.mono;
    check(!ctrl.pump(), "settle on exit");
    const auto ev = ctrl.evidence();
    check(ev.verdict == OfflineVerdict::kPass &&
              ev.core.observation.buffers_acquired == 45 &&
              ev.core.observation.buffers_live == 0 &&
              ev.core.observation.native.acquired == 47 &&
              ev.core.observation.native.released == 47 &&
              ev.core.observation.sample_count == 18 &&
              ctrl.phases().lifecycle ==
                  z::ProcessLifecycleStage::kHandlesReleased,
          "L1-CRYPTO settles PASS with 106 ABI, 45 buffers, 47 native, 18 "
          "samples");
  }

  // 2. Post-HELLO drift or early exit never sends ADMISSION
  {
    FakeGrantIo io;
    FakePlatform os(io, cry_target);
    os.drift_on_post_hello = true;
    z::UnifiedAdmissionController ctrl(cry_target, io, os);
    check(!ctrl.begin() && !ctrl.evidence().admission_sent &&
              os.outgoing.empty(),
          "post-HELLO target/dependency drift blocks ADMISSION");
  }
  {
    FakeGrantIo io;
    FakePlatform os(io, cry_target);
    os.exit_before_admission = true;
    z::UnifiedAdmissionController ctrl(cry_target, io, os);
    check(!ctrl.begin() && !ctrl.evidence().admission_sent &&
              os.outgoing.empty(),
          "early Worker exit before ADMISSION blocks ADMISSION");
  }

  // 3. Unreturned synchronous call during timeout retains UNKNOWN
  {
    OfflineSupervisor sup;
    FakeGrantCell cell;
    auto g = cry_target.grant;
    g.user_approved = true;
    check(cell.issue(g) && sup.admit(cell, g, g.window_start_ms, "L1-CRYPTO") &&
              sup.launch_attempt(g.window_start_ms + 1, true),
          "admit supervisor");
    L1CryptoLedger l;
    NativeObservation n;
    l.abi_calls[0] = {1, 0, 0, 0, 1, 0};  // attempted=1, returned=0 (in-flight)
    sup.settle(g.window_start_ms + 30001, true, l, n);
    check(sup.state() == SupervisorState::kSettlementUnknown &&
              sup.evidence().verdict == OfflineVerdict::kUnknown,
          "unreturned synchronous call at timeout forces UNKNOWN");
  }

  // 4. Admission-only settlement never accepts a non-zero crypto ledger: the
  // Trial-specific zero ledger can never be traded for a weaker Crypto standard.
  {
    const auto adm_target = make_target(true);
    OfflineSupervisor sup;
    FakeGrantCell cell;
    auto g = adm_target.grant;
    g.user_approved = true;
    check(cell.issue(g) &&
              sup.admit(cell, g, g.window_start_ms, "L1-ADMISSION") &&
              sup.launch_attempt(g.window_start_ms + 1, true),
          "admit admission-only supervisor");
    for (unsigned i = 0; i < 18; ++i) {
      ResourceSample s{};
      s.observed_at_ms = g.window_start_ms + 2 + i;
      s.peak_working_set = 2048;
      s.peak_commit = 4096;
      s.handles = 4;
      s.completed_calls = 0;
      check(sup.sample(s, true), "admission-only resource sample");
    }
    L1CryptoLedger l;
    NativeObservation n;
    l.samples = 18;
    l.abi_calls[0] = {1, 1, 1, 1, 0, 0};
    sup.settle(g.window_start_ms + 20, true, l, n);
    check(sup.evidence().verdict == OfflineVerdict::kFail &&
              sup.state() == SupervisorState::kComplete,
          "admission-only settlement rejects a non-zero ABI ledger");
  }
}

// ============================================================================
// Fake ObjectOperations & DPAPI Operations for B1-C (OBJECTS) & B1-D (STORE)
// ============================================================================
struct FakeProtectedStoreEnv final : shiroha_native::ObjectOperations {
  shiroha_native::Sid sid{1, 2, 3, 4};
  uintptr_t next_handle = 1;
  uint64_t next_file = 10;
  std::map<HANDLE, shiroha_native::ObjectInfo> handles;
  std::map<std::pair<uint64_t, std::wstring>, shiroha_native::ObjectInfo>
      objects;
  std::set<uint64_t> locked;
  std::vector<std::wstring> calls;
  std::map<HANDLE, bool> is_lock;
  std::map<HANDLE, unsigned> close_attempts;
  std::map<uint64_t, std::vector<uint8_t>> contents;
  HANDLE state = nullptr, flushed = nullptr;
  std::wstring active_name = L"issuer.bin";
  bool unknown_after_replace = false;
  bool fail_close = false;
  bool fail_inspect = false;
  unsigned publication_fault = 0;
  unsigned opens_after_publish = 0;
  bool published = false;
  size_t leftovers = 0;

  // Seed the seam root up front so its identity is deterministic and can be
  // approved independently, exactly like an approved isolated root.
  FakeProtectedStoreEnv() {
    objects[std::make_pair(uint64_t{0}, std::wstring{L"LOCAL"})] =
        make_good(true);
  }
  z::ApprovedRootPin approved_root(const std::string &directory) const {
    const auto it =
        objects.find(std::make_pair(uint64_t{0}, std::wstring{L"LOCAL"}));
    if (it == objects.end()) return z::ApprovedRootPin{directory, 0, 0};
    return z::ApprovedRootPin{directory, it->second.volume, it->second.file};
  }

  shiroha_native::ObjectInfo publication_parent() const {
    for (const auto &entry : objects)
      if (entry.first.second == L"trust") return entry.second;
    return {};
  }

  void substitute_target() {
    const auto key = std::make_pair(handles[state].file, active_name);
    auto replacement = make_good(false);
    contents[replacement.file] = contents[objects[key].file];
    objects[key] = replacement;
  }

  shiroha_native::ObjectInfo make_good(bool dir) {
    shiroha_native::ObjectInfo i;
    i.volume = 77;
    i.file = next_file++;
    i.attributes = dir ? FILE_ATTRIBUTE_DIRECTORY : 0;
    i.drive_type = DRIVE_FIXED;
    i.filesystem = L"NTFS";
    i.links = 1;
    i.owner = sid;
    i.dacl_present = true;
    i.dacl_protected = true;
    i.aces.push_back(
        {ACCESS_ALLOWED_ACE_TYPE,
         static_cast<uint8_t>(dir ? CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE
                                  : 0),
         FILE_ALL_ACCESS, sid});
    return i;
  }

  HANDLE make_handle(const shiroha_native::ObjectInfo &i, bool exclusive) {
    const auto h = reinterpret_cast<HANDLE>(next_handle++);
    handles[h] = i;
    is_lock[h] = exclusive;
    if (exclusive) locked.insert(i.file);
    return h;
  }

  int32_t user_sid(shiroha_native::Sid &out) override {
    out = sid;
    return SHIROHA_NATIVE_OK;
  }
  int32_t local_directory(HANDLE &out) override {
    calls.push_back(L"LOCAL");
    auto key = std::make_pair(uint64_t{0}, std::wstring{L"LOCAL"});
    if (!objects.count(key)) objects[key] = make_good(true);
    out = make_handle(objects[key], false);
    return SHIROHA_NATIVE_OK;
  }
  int32_t child(HANDLE parent, const wchar_t *name, bool dir, bool create,
                const shiroha_native::Sid &, HANDLE &out) override {
    calls.push_back(name);
    out = nullptr;
    if (handles.count(parent) != 1) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto key = std::make_pair(handles[parent].file, std::wstring{name});
    if (!create && !objects.count(key)) return SHIROHA_NATIVE_UNAVAILABLE;
    if (!objects.count(key)) objects[key] = make_good(dir);
    auto info = objects[key];
    if (!dir && locked.count(info.file)) return SHIROHA_NATIVE_UNAVAILABLE;
    out = make_handle(info, !dir);
    return SHIROHA_NATIVE_OK;
  }
  int32_t inspect(HANDLE h, shiroha_native::ObjectInfo &out) override {
    if (fail_inspect || handles.count(h) != 1) return SHIROHA_NATIVE_UNAVAILABLE;
    out = handles[h];
    return SHIROHA_NATIVE_OK;
  }
  bool close(HANDLE h) noexcept override {
    ++close_attempts[h];
    if (fail_close) return false;
    if (!handles.count(h)) return false;
    if (is_lock[h]) locked.erase(handles[h].file);
    handles.erase(h);
    is_lock.erase(h);
    return true;
  }
  int32_t association_open(HANDLE parent, const shiroha_native::Sid &,
                           HANDLE &out) override {
    active_name = L"associations.bin";
    return fixed_open(parent, out);
  }
  int32_t credential_open(HANDLE parent, uint32_t kind,
                          const shiroha_native::Sid &, HANDLE &out) override {
    active_name = kind == 1   ? L"issuer.bin"
                  : kind == 2 ? L"server.bin"
                              : L"client.bin";
    if (published && ++opens_after_publish == 2 && publication_fault == 3)
      substitute_target(); // same bytes, different identity during readback
    return fixed_open(parent, out);
  }
  int32_t credential_replace(HANDLE h, HANDLE parent, uint32_t,
                             bool existing) override {
    return replace_file(h, parent, existing);
  }
  int32_t fixed_open(HANDLE parent, HANDLE &out) {
    state = parent;
    out = nullptr;
    if (handles.count(parent) != 1) return SHIROHA_NATIVE_UNAVAILABLE;
    const auto key = std::make_pair(handles[parent].file, active_name);
    if (!objects.count(key)) return SHIROHA_NATIVE_MISSING;
    out = make_handle(objects[key], false);
    return SHIROHA_NATIVE_OK;
  }
  int32_t read_file(HANDLE file, std::vector<uint8_t> &out) override {
    out = contents[handles[file].file];
    return SHIROHA_NATIVE_OK;
  }
  int32_t temporary_count(HANDLE, size_t &out) override {
    out = leftovers;
    return SHIROHA_NATIVE_OK;
  }
  int32_t random_name(std::wstring &runtime, std::wstring &random) override {
    runtime = L"0123456789abcdef";
    random = L"01234567";
    return SHIROHA_NATIVE_OK;
  }
  int32_t temporary_create(HANDLE parent, const std::wstring &name,
                           const shiroha_native::Sid &, HANDLE &out) override {
    out = nullptr;
    const auto key = std::make_pair(handles[parent].file, name);
    if (objects.count(key)) return SHIROHA_NATIVE_UNAVAILABLE;
    objects[key] = make_good(false);
    out = make_handle(objects[key], false);
    return SHIROHA_NATIVE_OK;
  }
  int32_t write_file(HANDLE h, const uint8_t *input, uint64_t length) override {
    contents[handles[h].file] =
        std::vector<uint8_t>(input, input + static_cast<size_t>(length));
    return SHIROHA_NATIVE_OK;
  }
  int32_t flush_file(HANDLE file) override {
    flushed = file;
    return SHIROHA_NATIVE_OK;
  }
  int32_t replace_file(HANDLE h, HANDLE parent, bool existing) override {
    if (flushed != h || handles.count(parent) != 1 || locked.empty())
      return SHIROHA_NATIVE_COMMIT_UNKNOWN;
    const auto key = std::make_pair(handles[parent].file, active_name);
    if (objects.count(key) != static_cast<size_t>(existing))
      return SHIROHA_NATIVE_COMMIT_UNKNOWN;
    const auto identity = handles[h];
    for (auto it = objects.begin(); it != objects.end();) {
      if (it->second.file == identity.file)
        it = objects.erase(it);
      else
        ++it;
    }
    objects[key] = identity;
    published = true;
    opens_after_publish = 0;
    if (publication_fault == 1) substitute_target();
    if (publication_fault == 2) ++handles[parent].file;
    if (publication_fault == 4) objects[key].dacl_protected = false;
    return unknown_after_replace ? SHIROHA_NATIVE_COMMIT_UNKNOWN
                                 : SHIROHA_NATIVE_OK;
  }
};

// ============================================================================
// B1-C Tests: L1-OBJECTS Restricted Diagnostic Candidate
// ============================================================================
void test_b1_c_objects_diagnostic() {
  // A successful root probe owns its handle even when the approved pin differs.
  for (bool wrong_volume : {false, true}) {
    for (bool close_fails : {false, true}) {
      FakeProtectedStoreEnv env;
      auto root = env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS");
      if (wrong_volume)
        ++root.volume;
      else
        ++root.file;
      env.fail_close = close_fails;
      z::B1ObjectsDiagnostic diag(root, env.sid, env, 1);
      check(!diag.begin(1000), "OBJECTS rejects mismatched root identity");
      check(env.close_attempts.size() == 1 &&
                env.close_attempts.begin()->second == 1 &&
                env.handles.size() == (close_fails ? 1u : 0u) &&
                env.calls == std::vector<std::wstring>{L"LOCAL"},
            "OBJECTS root mismatch closes once before any child opens");
      check(
          !diag.release_locks_and_settle(1010) &&
              diag.verdict() == (close_fails ? OfflineVerdict::kUnknown
                                             : OfflineVerdict::kFail) &&
              diag.release_ledger().acquired() == 1 &&
              diag.release_ledger().release_attempts() == 1 &&
              diag.release_ledger().still_owned() == (close_fails ? 1u : 0u) &&
              diag.release_ledger().quarantined() == (close_fails ? 1u : 0u) &&
              env.close_attempts.begin()->second == 1,
          "OBJECTS root mismatch retains UNKNOWN custody without retry");
    }
  }

  // DACL checks cannot be disabled, even if the caller ignores rejection.
  {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic diag(env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"),
                                env.sid, env, 1);
    check(diag.begin(1000), "begin DACL bypass negative");
    auto info = env.make_good(false);
    check(!diag.register_approved_object("unchecked", info.volume, info.file,
                                         false, false) &&
              !diag.acquire_app_lock(1010) &&
              !diag.release_locks_and_settle(1020) &&
              diag.verdict() == OfflineVerdict::kFail && env.handles.empty(),
          "disabled DACL observation is rejected and cannot lead to PASS");
  }

  // Completing file operations cannot replace security evidence for EVERY pin.
  // 0: no publication approval; 1: zero auxiliary observations;
  // 2: only one of two auxiliary pins observed; 3: all pins observed.
  for (unsigned mode = 0; mode < 4; ++mode) {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic diag(env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"),
                                env.sid, env, 1);
    check(diag.begin(1000) && diag.acquire_app_lock(1010) &&
              diag.attempt_competing_app_lock(1020) &&
              diag.acquire_bridge_lock(1030),
          "security completion test acquires all required locks");
    if (mode != 0) {
      const auto parent = env.publication_parent();
      check(diag.register_approved_publication("published", 1, parent.volume,
                                               parent.file),
            "approve actual publication parent and fixed kind");
    }
    if (mode != 0) {
      auto parent = env.make_good(true);
      auto info = env.make_good(false);
      HANDLE handle = env.make_handle(info, false);
      check(
          diag.register_approved_object("first", info.volume, info.file, false),
          "register first completion pin");
      if (mode >= 2) {
        check(diag.register_approved_object("second", info.volume, info.file,
                                            false) &&
                  diag.observe_object_security(1040, "first", handle, parent,
                                               parent.volume, parent.file),
              "observe first completion pin");
        if (mode == 3) {
          check(diag.observe_object_security(1050, "second", handle, parent,
                                             parent.volume, parent.file),
                "observe second completion pin");
        }
      }
      check(env.close(handle), "release borrowed observation handle");
    }
    std::vector<uint8_t> first{1, 2}, second{3, 4}, readback;
    const bool completed = diag.publish_new_target(1060, first, readback) &&
                           diag.replace_existing_target(1070, first, second,
                                                        readback);
    check(completed == (mode != 0),
          "publication requires its own explicit approval");
    check(diag.release_locks_and_settle(1080) == (mode == 3) &&
              diag.verdict() ==
                  (mode == 3 ? OfflineVerdict::kPass : OfflineVerdict::kFail) &&
              diag.release_ledger().still_owned() == 0 && env.handles.empty(),
          "OBJECTS PASS requires a nonempty fully observed approved set");
  }

  // 1. Reject production App/Bridge root and Host A root
  {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic bad_prod(
        env.approved_root("C:\\Users\\alice\\AppData\\Local\\ShirohaQuiz"),
        env.sid, env, 1);
    check(!bad_prod.begin(1000) &&
              std::strcmp(bad_prod.failure_code(), "ADMISSION_BLOCKED") == 0,
          "production ShirohaQuiz root rejected");

    z::B1ObjectsDiagnostic bad_host_a(
        env.approved_root("C:\\Shiroha\\Host_A_Trial"), env.sid, env, 1);
    check(!bad_host_a.begin(1000) &&
              std::strcmp(bad_host_a.failure_code(), "ADMISSION_BLOCKED") == 0,
          "Host A historical root rejected");

    // Isolation is decided by the seam's root identity, never by path text: a
    // production-rooted seam is rejected even with a plausible approved path.
    auto wrong_root = env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS");
    wrong_root.file += 1;
    z::B1ObjectsDiagnostic bad_seam(wrong_root, env.sid, env, 1);
    check(!bad_seam.begin(1000) &&
              std::strcmp(bad_seam.failure_code(),
                          "ISOLATION_ROOT_MISMATCH") == 0,
          "seam root not equal to the approved isolated root is rejected");
  }

  // 2. Reject cross-trial invocation (e.g. L1-CRYPTO grant trying L1-OBJECTS)
  {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic wrong_grant(
        env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"), env.sid, env, 1,
        z::TrialKind::kCrypto);
    check(!wrong_grant.begin(1000) &&
              wrong_grant.verdict() == OfflineVerdict::kFail &&
              std::strcmp(wrong_grant.failure_code(), "UNAUTHORIZED_ACCESS") ==
                  0,
          "L1-CRYPTO grant cannot execute L1-OBJECTS diagnostic");
  }

  // 3. Full positive L1-OBJECTS flow within exact frozen budget
  for (uint32_t kind : {1u, 2u}) {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic diag(
        env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"), env.sid, env, kind);
    check(diag.begin(1000), "L1-OBJECTS begin");

    // 1 App acquire + 1 competing acquire (expected denial) + 1 Bridge acquire
    check(diag.acquire_app_lock(1010), "App acquire 1");
    check(diag.attempt_competing_app_lock(1020),
          "competing App acquire 1 denied as expected");
    check(diag.acquire_bridge_lock(1030), "Bridge acquire 1");

    const auto parent = env.publication_parent();
    check(diag.register_approved_publication("target-obj", kind, parent.volume,
                                             parent.file),
          "approve fixed publication target under its actual parent");

    // 1 new-target publication + readback 1
    std::vector<uint8_t> v1 = {0x53, 0x43, 0x52, 0x31, 0x01, 0x02};
    std::vector<uint8_t> rb1;
    check(diag.publish_new_target(1060, v1, rb1) && rb1 == v1,
          "new target publish + readback 1");
    const auto first_identity = env.objects.at(
        std::make_pair(parent.file, env.active_name)).file;

    // 1 existing-target replacement + readback 2
    std::vector<uint8_t> v2 = {0x53, 0x43, 0x52, 0x31, 0x09, 0x0A, 0x0B};
    std::vector<uint8_t> rb2;
    check(diag.replace_existing_target(1070, v1, v2, rb2) && rb2 == v2,
          "existing target replace + readback 2");
    check(env.objects.at(std::make_pair(parent.file, env.active_name)).file !=
              first_identity &&
              env.active_name == (kind == 1 ? L"issuer.bin" : L"server.bin"),
          "approved kind stays fixed while atomic replace advances File ID");

    check(diag.release_locks_and_settle(1080) &&
              diag.verdict() == OfflineVerdict::kPass &&
              diag.app_acquires() == 1 && diag.competing_acquires() == 1 &&
              diag.bridge_acquires() == 1 && diag.observations() == 2 &&
              diag.new_publishes() == 1 && diag.replacements() == 1 &&
              diag.readbacks() == 2,
          "L1-OBJECTS settles PASS with exact frozen counts");
  }

  // The former positive fixture observed A but published an unrelated B.
  {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic diag(env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"),
                                env.sid, env, 1);
    check(diag.begin(1000) && diag.acquire_app_lock(1010) &&
              diag.attempt_competing_app_lock(1020) &&
              diag.acquire_bridge_lock(1030), "inspect-A fixture locks");
    auto parent = env.make_good(true);
    auto a = env.make_good(false);
    auto handle = env.make_handle(a, false);
    check(diag.register_approved_object("observed-a", a.volume, a.file, false) &&
              diag.observe_object_security(1040, "observed-a", handle, parent,
                                             parent.volume, parent.file),
          "safe independent object A is observed");
    env.close(handle);
    std::vector<uint8_t> bytes{1, 2}, readback;
    check(!diag.publish_new_target(1050, bytes, readback) &&
              !diag.release_locks_and_settle(1060) &&
              diag.verdict() != OfflineVerdict::kPass && env.contents.empty(),
          "inspect A does not approve publishing B or permit PASS");
  }

  // Bind kind/parent before writes; native identity/security drift never PASSes.
  // 0 wrong kind; 1 wrong approved parent; 2 post-publish target substitution;
  // 3 parent drift; 4 same-byte readback substitution; 5 published DACL drift;
  // 6 target substitution between publish and replace; 7 borrowed-handle bypass.
  for (unsigned fault = 0; fault < 8; ++fault) {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic diag(env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"),
                                env.sid, env, 1);
    check(diag.begin(1000) && diag.acquire_app_lock(1010) &&
              diag.attempt_competing_app_lock(1020) &&
              diag.acquire_bridge_lock(1030), "binding negative locks");
    const auto parent = env.publication_parent();
    const bool approved = diag.register_approved_publication(
        "published", fault == 0 ? 2u : 1u, parent.volume,
        parent.file + (fault == 1 ? 1u : 0u));
    check(approved == (fault != 0), "mismatched publication kind rejected");
    if (fault >= 2 && fault <= 5) env.publication_fault = fault - 1;
    if (fault == 7) {
      auto a = env.make_good(false);
      auto handle = env.make_handle(a, false);
      check(!diag.observe_object_security(1040, "published", handle, parent,
                                             parent.volume, parent.file),
            "borrowed handle cannot supply publication observation");
      env.close(handle);
    }
    std::vector<uint8_t> first{1, 2}, second{3, 4}, readback;
    const bool created = diag.publish_new_target(1050, first, readback);
    if (fault == 6) {
      check(created, "identity drift fixture first publication");
      env.substitute_target();
      check(!diag.replace_existing_target(1060, first, second, readback),
            "replacement rejects same-byte target with unapproved File ID");
    } else {
      check(!created, "kind, parent, target or readback binding rejects");
    }
    check(!diag.release_locks_and_settle(1080) &&
              diag.verdict() != OfflineVerdict::kPass && env.handles.empty(),
          "binding mismatch cannot settle PASS and closes owned handles once");
    if (fault == 0 || fault == 1 || fault == 7)
      check(env.contents.empty(), "binding rejects before payload writes");
    if (fault == 2 || fault == 3 || fault == 5)
      check(diag.verdict() == OfflineVerdict::kUnknown,
            "uncertain publication retains UNKNOWN verdict");
    for (const auto &attempt : env.close_attempts)
      check(attempt.second == 1, "binding failure never retries a close");
  }

  // 4. Negative cases: wrong Owner SID, unprotected DACL, parent drift,
  // reparse point, hard link count != 1, over-budget, 60s timeout, unknown close
  for (unsigned neg = 0; neg < 8; ++neg) {
    FakeProtectedStoreEnv env;
    z::B1ObjectsDiagnostic diag(
        env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"), env.sid, env, 1);
    check(diag.begin(1000) && diag.acquire_app_lock(1001), "setup negative");
    auto parent_info = env.make_good(true);
    auto child_info = env.make_good(false);
    if (neg == 0) child_info.owner = {9, 9, 9};               // wrong SID
    if (neg == 1) child_info.dacl_protected = false;          // unprotected DACL
    if (neg == 2) child_info.attributes |= FILE_ATTRIBUTE_REPARSE_POINT;
    if (neg == 3) child_info.links = 2;                       // hardlink > 1
    if (neg == 4) parent_info.attributes |= FILE_ATTRIBUTE_REPARSE_POINT;
    HANDLE child_h = env.make_handle(child_info, false);
    check(diag.register_approved_object("obj", child_info.volume,
                                        child_info.file, false, true),
          "register");
    if (neg < 5) {
      check(!diag.observe_object_security(1010, "obj", child_h, parent_info,
                                          parent_info.volume,
                                          parent_info.file) &&
                std::strcmp(diag.failure_code(), "OWNERSHIP_UNKNOWN") == 0,
            "security/identity negative rejected with OWNERSHIP_UNKNOWN");
    } else if (neg == 5) {
      // Parent file ID drift
      check(!diag.observe_object_security(1010, "obj", child_h, parent_info,
                                          parent_info.volume,
                                          parent_info.file + 99) &&
                std::strcmp(diag.failure_code(), "OWNERSHIP_UNKNOWN") == 0,
            "parent chain drift rejected");
    } else if (neg == 6) {
      // 3rd observation on same object exceeds per-object max 2
      check(diag.observe_object_security(1010, "obj", child_h, parent_info,
                                         parent_info.volume,
                                         parent_info.file) &&
                diag.observe_object_security(1020, "obj", child_h, parent_info,
                                             parent_info.volume,
                                             parent_info.file) &&
                !diag.observe_object_security(1030, "obj", child_h, parent_info,
                                              parent_info.volume,
                                              parent_info.file) &&
                std::strcmp(diag.failure_code(), "BUDGET_EXCEEDED") == 0,
            "3rd per-object observation rejected with BUDGET_EXCEEDED");
    } else if (neg == 7) {
      // 60-second inclusive deadline exceeded
      check(!diag.observe_object_security(61000, "obj", child_h, parent_info,
                                          parent_info.volume,
                                          parent_info.file) &&
                std::strcmp(diag.failure_code(), "BUDGET_EXCEEDED") == 0,
            "60s inclusive deadline enforced on L1-OBJECTS");
    }
    env.close(child_h);
  }

  // Unknown commit / unknown release retains custody and verdicts UNKNOWN
  {
    FakeProtectedStoreEnv env;
    env.unknown_after_replace = true;
    z::B1ObjectsDiagnostic diag(
        env.approved_root("C:\\SYNTHETIC\\B1_OBJECTS"), env.sid, env, 1);
    check(diag.begin(1000) && diag.acquire_app_lock(1005), "begin");
    const auto parent = env.publication_parent();
    check(diag.register_approved_publication("published", 1, parent.volume,
                                             parent.file), "approve unknown case");
    std::vector<uint8_t> v1 = {1, 2, 3}, rb;
    check(!diag.publish_new_target(1010, v1, rb) &&
              !diag.release_locks_and_settle(1020) &&
              diag.verdict() == OfflineVerdict::kUnknown &&
              std::strcmp(diag.failure_code(), "SETTLEMENT_UNKNOWN") == 0,
          "COMMIT_UNKNOWN produces UNKNOWN verdict in L1-OBJECTS");
  }
}

// ============================================================================
// B1-D Tests: L1-STORE Restricted Diagnostic Candidate
// ============================================================================
BOOL fake_dpapi_protect(DATA_BLOB *in, DATA_BLOB *out) noexcept {
  if (!in || !out || !in->pbData || !in->cbData) return FALSE;
  out->cbData = in->cbData;
  out->pbData = static_cast<BYTE *>(
      std::malloc(in->cbData));  // freed by fake_free_local
  if (!out->pbData) return FALSE;
  for (DWORD i = 0; i < in->cbData; ++i) out->pbData[i] = in->pbData[i] ^ 0x5Au;
  return TRUE;
}
BOOL fake_dpapi_unprotect(DATA_BLOB *in, DATA_BLOB *out) noexcept {
  return fake_dpapi_protect(in, out);
}
void fake_free_local(void *p) noexcept { std::free(p); }
HRESULT fake_known_folder(PWSTR *) noexcept { return E_FAIL; }
void fake_free_task(void *) noexcept {}

const shiroha_native::Operations kFakeDpapiOps{
    fake_dpapi_protect, fake_dpapi_unprotect, fake_free_local,
    fake_known_folder, fake_free_task};

void test_b1_d_store_diagnostic() {
  for (bool wrong_volume : {false, true}) {
    for (bool close_fails : {false, true}) {
      FakeProtectedStoreEnv env;
      auto root = env.approved_root("C:\\SYNTHETIC\\B1_STORE");
      if (wrong_volume)
        ++root.volume;
      else
        ++root.file;
      env.fail_close = close_fails;
      z::B1StoreDiagnostic store(root, env.sid, 1, 1, kFakeDpapiOps, env);
      check(!store.begin(1000), "STORE rejects mismatched root identity");
      check(env.close_attempts.size() == 1 &&
                env.close_attempts.begin()->second == 1 &&
                env.handles.size() == (close_fails ? 1u : 0u) &&
                env.calls == std::vector<std::wstring>{L"LOCAL"} &&
                store.ledger().owner_acquire.attempted == 0,
            "STORE root mismatch closes once before Owner acquisition");
      check(
          !store.close_and_settle(1010) &&
              store.verdict() == (close_fails ? OfflineVerdict::kUnknown
                                              : OfflineVerdict::kFail) &&
              store.release_ledger().acquired() == 1 &&
              store.release_ledger().release_attempts() == 1 &&
              store.release_ledger().still_owned() == (close_fails ? 1u : 0u) &&
              store.release_ledger().quarantined() == (close_fails ? 1u : 0u) &&
              env.close_attempts.begin()->second == 1,
          "STORE root mismatch retains UNKNOWN custody without retry");
    }
  }

  // Every prefix is within budget; only the complete successful trial may PASS.
  for (unsigned steps = 0; steps <= 10; ++steps) {
    FakeProtectedStoreEnv env;
    z::B1StoreDiagnostic store(env.approved_root("C:\\SYNTHETIC\\B1_STORE"),
                               env.sid, 1, 1, kFakeDpapiOps, env);
    check(store.begin(1000), "begin STORE completion prefix");
    std::vector<uint8_t> plain{1, 2, 3}, cipher, recovered, existing;
    uint64_t ticket = 0;
    if (steps >= 1)
      check(store.dpapi_protect(1010, 1, plain, cipher), "prefix Protect 1");
    if (steps >= 2)
      check(store.dpapi_unprotect(1020, 1, cipher, recovered),
            "prefix Unprotect 1");
    if (steps >= 3)
      check(store.dpapi_protect(1030, 1, plain, cipher), "prefix Protect 2");
    if (steps >= 4)
      check(store.dpapi_unprotect(1040, 1, cipher, recovered),
            "prefix Unprotect 2");
    if (steps >= 5)
      check(store.store_begin(1050, 1, existing, ticket) ==
                SHIROHA_NATIVE_MISSING,
            "prefix Begin 1");
    if (steps >= 6)
      check(store.store_commit(1060, 1, ticket, cipher) == SHIROHA_NATIVE_OK,
            "prefix Commit 1");
    if (steps >= 7)
      check(store.store_begin(1070, 1, existing, ticket) == SHIROHA_NATIVE_OK,
            "prefix Begin 2");
    if (steps >= 8)
      check(store.store_commit(1080, 1, ticket, cipher) == SHIROHA_NATIVE_OK,
            "prefix Commit 2");
    if (steps >= 9)
      check(store.store_begin(1090, 1, existing, ticket) == SHIROHA_NATIVE_OK,
            "prefix Begin 3");
    if (steps >= 10)
      check(store.store_abort(1100, 1, ticket) == SHIROHA_NATIVE_OK,
            "prefix Abort 1");
    const bool outstanding_ticket = steps == 5 || steps == 7 || steps == 9;
    const auto expected = steps == 10          ? OfflineVerdict::kPass
                          : outstanding_ticket ? OfflineVerdict::kUnknown
                                               : OfflineVerdict::kFail;
    check(store.close_and_settle(1110) == (steps == 10) &&
              store.verdict() == expected && env.handles.empty(),
          "STORE zero/partial work cannot PASS; complete trial can PASS");
  }

  // 1. Reject bundling multiple Store kinds (e.g., App 1/2/3 + Bridge 4) or
  // invalid Store kind
  {
    FakeProtectedStoreEnv env;
    z::B1StoreDiagnostic bundled(
        env.approved_root("C:\\SYNTHETIC\\B1_STORE"), env.sid, 1, 4,
        kFakeDpapiOps, env);
    check(!bundled.begin(1000) &&
              std::strcmp(bundled.failure_code(), "ADMISSION_BLOCKED") == 0,
          "bundling 4 Store kinds in one batch is rejected");

    z::B1StoreDiagnostic invalid_kind(
        env.approved_root("C:\\SYNTHETIC\\B1_STORE"), env.sid, 0, 1,
        kFakeDpapiOps, env);
    check(!invalid_kind.begin(1000) &&
              std::strcmp(invalid_kind.failure_code(), "ADMISSION_BLOCKED") ==
                  0,
          "unselected Store kind (0) is rejected");
  }

  // 2. Reject cross-trial invocation (e.g., L1-CRYPTO grant calling L1-STORE)
  {
    FakeProtectedStoreEnv env;
    z::B1StoreDiagnostic wrong_grant(
        env.approved_root("C:\\SYNTHETIC\\B1_STORE"), env.sid, 1, 1,
        kFakeDpapiOps, env, z::TrialKind::kCrypto);
    check(!wrong_grant.begin(1000) &&
              std::strcmp(wrong_grant.failure_code(), "UNAUTHORIZED_ACCESS") ==
                  0,
          "L1-CRYPTO grant cannot run L1-STORE operations");
  }

  // 3. Positive single-kind execution for each Store kind (1, 2, 3, 4) within
  // frozen budget: Protect <=2, Unprotect <=2, <=65536B, Begin <=3, Commit <=2,
  // Abort <=1, <=60s
  for (uint32_t kind : {1u, 2u, 3u, 4u}) {
    FakeProtectedStoreEnv env;
    if (kind == 4) {
      // Seed shared parent directories in fake environment before Bridge role=2
      shiroha_native::ProtectedObjects seeder(env);
      uint64_t seed_tok = 0;
      check(seeder.acquire(3, 1, &seed_tok) == 0 &&
                seeder.close(3, seed_tok) == 0,
            "seed shared parent for kind 4");
    }
    z::B1StoreDiagnostic store(env.approved_root("C:\\SYNTHETIC\\B1_STORE"),
                               env.sid, kind, 1, kFakeDpapiOps, env);
    check(store.begin(1000), "L1-STORE begin for single kind");

    // Protect 2 & Unprotect 2 (including max 65536-byte boundary)
    std::vector<uint8_t> plain1 = {10, 20, 30, 40};
    std::vector<uint8_t> cipher1, recovered1;
    check(store.dpapi_protect(1010, kind, plain1, cipher1) &&
              store.dpapi_unprotect(1020, kind, cipher1, recovered1) &&
              recovered1 == plain1,
          "DPAPI protect/unprotect 1");

    std::vector<uint8_t> plain2(z::StoreBudget::kMaxPlaintextBytes, 0x42);
    std::vector<uint8_t> cipher2, recovered2;
    check(store.dpapi_protect(1030, kind, plain2, cipher2) &&
              store.dpapi_unprotect(1040, kind, cipher2, recovered2) &&
              recovered2 == plain2,
          "DPAPI protect/unprotect 2 at the realizable plaintext limit");

    // Begin 1 (create-if-missing) -> Commit 1
    std::vector<uint8_t> existing;
    uint64_t ticket1 = 0;
    check(store.store_begin(1050, kind, existing, ticket1) ==
                  SHIROHA_NATIVE_MISSING &&
              ticket1 != 0 && existing.empty(),
          "store_begin 1 missing");
    check(store.store_commit(1060, kind, ticket1, cipher1) == SHIROHA_NATIVE_OK,
          "store_commit 1 create-if-missing");

    // Begin 2 (CAS existing) -> Commit 2
    uint64_t ticket2 = 0;
    check(store.store_begin(1070, kind, existing, ticket2) ==
                  SHIROHA_NATIVE_OK &&
              existing == cipher1,
          "store_begin 2 reads committed bytes");
    check(store.store_commit(1080, kind, ticket2, plain1) == SHIROHA_NATIVE_OK,
          "store_commit 2 replaces existing");

    // Begin 3 -> Abort 1
    uint64_t ticket3 = 0;
    check(store.store_begin(1090, kind, existing, ticket3) ==
                  SHIROHA_NATIVE_OK &&
              existing == plain1,
          "store_begin 3 reads second commit");
    check(store.store_abort(1100, kind, ticket3) == SHIROHA_NATIVE_OK,
          "store_abort 1");

    check(store.close_and_settle(1110) &&
              store.verdict() == OfflineVerdict::kPass,
          "L1-STORE settles PASS");

    const auto &l = store.ledger();
    check(l.owner_acquire.attempted == 1 && l.owner_acquire.settled == 1 &&
              l.owner_close.attempted == 1 && l.owner_close.settled == 1 &&
              l.dpapi_protect.attempted == 2 && l.dpapi_protect.settled == 2 &&
              l.dpapi_unprotect.attempted == 2 &&
              l.dpapi_unprotect.settled == 2 && l.store_begin.attempted == 3 &&
              l.store_begin.settled == 3 && l.store_commit.attempted == 2 &&
              l.store_commit.settled == 2 && l.store_abort.attempted == 1 &&
              l.store_abort.settled == 1 && l.total_abi_attempts == 12 &&
              l.temporaries_created_sequential == 2 &&
              l.max_temporaries_live == 1 && l.memory_zeroed_buffers >= 5,
          "StorePrimitiveLedger expands and audits all underlying calls");
  }

  // 4. Negative cases for L1-STORE: kind switch mid-batch, >65536 bytes,
  // 3rd protect, 4th begin, 2nd abort, COMMIT_UNKNOWN -> UNKNOWN
  {
    FakeProtectedStoreEnv env;
    z::B1StoreDiagnostic store(env.approved_root("C:\\SYNTHETIC\\B1_STORE"),
                               env.sid, 1, 1, kFakeDpapiOps, env);
    check(store.begin(1000), "begin");
    std::vector<uint8_t> data = {1, 2}, out;
    check(!store.dpapi_protect(1010, 4, data, out) &&
              std::strcmp(store.failure_code(), "UNAUTHORIZED_ACCESS") == 0,
          "switching Store kind from 1 to 4 mid-batch is rejected");
  }
  {
    FakeProtectedStoreEnv env;
    z::B1StoreDiagnostic store(env.approved_root("C:\\SYNTHETIC\\B1_STORE"),
                               env.sid, 1, 1, kFakeDpapiOps, env);
    check(store.begin(1000), "begin");
    std::vector<uint8_t> oversize(z::StoreBudget::kMaxPlaintextBytes + 1, 1),
        out;
    check(!store.dpapi_protect(1010, 1, oversize, out) &&
              std::strcmp(store.failure_code(), "BUDGET_EXCEEDED") == 0,
          "plaintext beyond the realizable DPAPI ceiling is rejected");
  }
  {
    FakeProtectedStoreEnv env;
    env.unknown_after_replace = true;
    z::B1StoreDiagnostic store(env.approved_root("C:\\SYNTHETIC\\B1_STORE"),
                               env.sid, 3, 1, kFakeDpapiOps, env);
    check(store.begin(1000), "begin");
    std::vector<uint8_t> existing, payload = {7, 8, 9};
    uint64_t ticket = 0;
    check(store.store_begin(1010, 3, existing, ticket) ==
              SHIROHA_NATIVE_MISSING,
          "begin");
    check(store.store_commit(1020, 3, ticket, payload) ==
                  SHIROHA_NATIVE_COMMIT_UNKNOWN &&
              !store.close_and_settle(1030) &&
              store.verdict() == OfflineVerdict::kUnknown &&
              store.ledger().store_commit.unknown == 1,
          "SHIROHA_NATIVE_COMMIT_UNKNOWN records unknown and settles UNKNOWN");
  }
}

// ============================================================================
// B1-E Tests: L1-RELEASE Unified Resource Settlement & Cross-Trial Allowlist
// ============================================================================
void test_b1_e_release_settlement() {
  // 1. Cross-Trial Operation Allowlist matrix
  check(z::operation_allowed_for_trial(
            z::TrialKind::kAdmission,
            z::OperationDomain::kAdmissionHandshake) &&
            !z::operation_allowed_for_trial(
                z::TrialKind::kAdmission,
                z::OperationDomain::kCryptoAbiPrimitive) &&
            !z::operation_allowed_for_trial(
                z::TrialKind::kCrypto,
                z::OperationDomain::kObjectsLockAndPublish) &&
            !z::operation_allowed_for_trial(
                z::TrialKind::kCrypto,
                z::OperationDomain::kStoreDpapiAndTransaction) &&
            !z::operation_allowed_for_trial(
                z::TrialKind::kObjects,
                z::OperationDomain::kStoreDpapiAndTransaction) &&
            !z::operation_allowed_for_trial(
                z::TrialKind::kStore,
                z::OperationDomain::kObjectsLockAndPublish) &&
            z::operation_allowed_for_trial(
                z::TrialKind::kRelease,
                z::OperationDomain::kReleaseOwnedResource) &&
            !z::operation_allowed_for_trial(
                z::TrialKind::kRelease,
                z::OperationDomain::kCryptoAbiPrimitive),
        "strict cross-Trial Operation Allowlist isolation");

  // 2. Missing clock, invalid clock and lost observation are fail-closed.
  {
    z::B1ReleaseLedger rel;
    check(rel.settle() == OfflineVerdict::kUnknown && rel.stopped() &&
              rel.unknown() &&
              std::strcmp(rel.failure_code(), "MEASUREMENT_UNAVAILABLE") == 0,
          "no release timing window can never settle PASS");
  }
  {
    z::B1ReleaseLedger rel;
    check(!rel.register_acquired(1, "owner-a", z::ResourceKind::kAbiBuffer) &&
              rel.acquired() == 0 && rel.stopped() && rel.unknown() &&
              !rel.begin_window(100) &&
              rel.settle() == OfflineVerdict::kUnknown,
          "pre-window acquisition cannot be legalized by starting a later clock");
  }
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(100) &&
              rel.settle() == OfflineVerdict::kFail &&
              std::strcmp(rel.failure_code(), "ARTIFACT_INVALID") == 0,
          "empty timed window has no release evidence and cannot PASS");
  }
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(1000) &&
              rel.register_acquired(1, "owner-a", z::ResourceKind::kAbiBuffer),
          "observation-loss fixture has tracked Owner");
    rel.mark_observation_lost();
    check(rel.stopped() && rel.unknown() &&
              !rel.register_acquired(2, "owner-b", z::ResourceKind::kAbiBuffer) &&
              rel.acquired() == 1 &&
              rel.release_once(1, "owner-a", true) && rel.still_owned() == 0 &&
              rel.release_attempts() == 1 &&
              rel.settle() == OfflineVerdict::kUnknown,
          "lost observation blocks new Owners but allows one legal owned release");
  }
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(1000) &&
              rel.register_acquired(1, "owner-a", z::ResourceKind::kAbiBuffer),
          "clock-rollback fixture has tracked Owner");
    check(!rel.advance_clock(999) && rel.stopped() && rel.unknown() &&
              !rel.register_acquired(2, "owner-b", z::ResourceKind::kAbiBuffer) &&
              rel.acquired() == 1 &&
              rel.release_once(1, "owner-a", true) &&
              rel.settle() == OfflineVerdict::kUnknown,
          "clock rollback stops acquisition and preserves UNKNOWN settlement");
  }
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(1000) &&
              rel.register_acquired(1, "owner-a", z::ResourceKind::kAbiBuffer),
          "inclusive deadline fixture has tracked Owner");
    check(!rel.advance_clock(31000) && rel.deadline_exceeded() && rel.stopped() &&
              !rel.register_acquired(2, "owner-b", z::ResourceKind::kAbiBuffer) &&
              rel.acquired() == 1 &&
              rel.release_once(1, "owner-a", true) &&
              rel.settle() != OfflineVerdict::kPass,
          "inclusive 30s cutoff blocks new acquisition but not owned cleanup");
  }

  // 3. Positive release + STOP does NOT block independent Owner's single legal
  // release
  {
    z::B1ReleaseLedger rel(z::TrialKind::kRelease);
    check(rel.begin_window(5000), "begin 30s release window");
    check(rel.register_acquired(1, "owner-alpha", z::ResourceKind::kAbiBuffer) &&
              rel.register_acquired(2, "owner-beta",
                                    z::ResourceKind::kProtectedLockLease) &&
              rel.register_acquired(3, "owner-gamma",
                                    z::ResourceKind::kProcessHandle),
          "register 3 independent owners");

    // Observe process exit before closing process handle 3
    rel.observe_process_exit(3);
    check(rel.release_once(1, "owner-alpha", true) &&
              rel.release_once(2, "owner-beta", true) &&
              rel.release_once(3, "owner-gamma", true) &&
              rel.settle() == OfflineVerdict::kPass && rel.still_owned() == 0,
          "all independent owners release once and settle PASS");
  }
  {
    // After STOP, new acquisition is blocked, but independent owner-beta can
    // still release its already-acquired resource once!
    z::B1ReleaseLedger rel(z::TrialKind::kRelease);
    check(rel.begin_window(5000) &&
              rel.register_acquired(10, "owner-alpha",
                                    z::ResourceKind::kAbiBuffer) &&
              rel.register_acquired(20, "owner-beta",
                                    z::ResourceKind::kProtectedLockLease),
          "acquire before STOP");
    rel.request_stop("supervisor_stop", "BUDGET_EXCEEDED");
    check(!rel.register_acquired(30, "owner-gamma",
                                 z::ResourceKind::kAbiBuffer),
          "new acquisition blocked after STOP");
    check(rel.release_once(10, "owner-alpha", true) &&
              rel.release_once(20, "owner-beta", true) &&
              rel.still_owned() == 0 && rel.quarantined() == 0,
          "STOP never prevents independent owners from releasing owned "
          "resources");
  }

  // 3. Duplicate release attempt & wrong owner release attempt
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(100) &&
              rel.register_acquired(1, "owner-a", z::ResourceKind::kAbiBuffer) &&
              rel.release_once(1, "owner-a", true) &&
              !rel.release_once(1, "owner-a", true) &&
              rel.duplicate_releases() == 1 &&
              rel.settle() == OfflineVerdict::kFail,
          "duplicate release attempt rejected and fails settlement");
  }
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(100) &&
              rel.register_acquired(1, "owner-a", z::ResourceKind::kAbiBuffer) &&
              !rel.release_once(1, "owner-b", true) &&
              rel.unowned_releases() == 1 &&
              rel.settle() == OfflineVerdict::kFail,
          "wrong owner release attempt rejected and fails settlement");
  }

  // 4. Void buffer release does NOT prove underlying Native resource released
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(100) &&
              rel.register_acquired(100, "crypto-worker",
                                    z::ResourceKind::kCngKey) &&
              rel.register_acquired(101, "crypto-worker",
                                    z::ResourceKind::kAbiBuffer, 100) &&
              rel.release_once(101, "crypto-worker", true) &&
              rel.still_owned() == 1 &&
              rel.settle() == OfflineVerdict::kUnknown,
          "void buffer_free settles only buffer; unreleased CNG key forces "
          "UNKNOWN");
  }

  // 5. CloseHandle without observed process exit forces UNKNOWN
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(100) &&
              rel.register_acquired(50, "controller",
                                    z::ResourceKind::kProcessHandle) &&
              !rel.release_once(50, "controller", true) &&
              rel.quarantined() == 1 &&
              rel.settle() == OfflineVerdict::kUnknown,
          "CloseHandle without observed process exit quarantines and forces "
          "UNKNOWN");
  }

  // 6. Timeout during in-flight synchronous Native call forces UNKNOWN
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(1000), "begin");
    rel.begin_sync_call();
    check(!rel.advance_clock(31000) && rel.deadline_exceeded() &&
              rel.in_flight_sync_calls() == 1 &&
              rel.settle() == OfflineVerdict::kUnknown,
          "timeout does not cancel in-flight sync call and forces UNKNOWN");
  }

  // 7. Deletion without ownership proof or without explicit authorization is
  // forbidden
  {
    z::B1ReleaseLedger rel;
    check(rel.begin_window(100) &&
              rel.register_acquired(7, "owner-a",
                                    z::ResourceKind::kPublishedObject) &&
              rel.release_once(7, "owner-a", true),
          "release object handle");
    check(!rel.attempt_delete_object(7, "owner-a", false, true) &&
              rel.forbidden_deletes() == 1 &&
              rel.settle() == OfflineVerdict::kFail,
          "deletion without verified ownership proof is forbidden");

    z::B1ReleaseLedger rel2;
    check(rel2.begin_window(100) &&
              rel2.register_acquired(8, "owner-a",
                                     z::ResourceKind::kPublishedObject) &&
              rel2.release_once(8, "owner-a", true) &&
              !rel2.attempt_delete_object(8, "owner-a", true, false) &&
              rel2.forbidden_deletes() == 1 &&
              std::strcmp(rel2.failure_code(), "UNAUTHORIZED_ACCESS") == 0,
          "deletion without explicit user authorization is forbidden");
  }
}

}  // namespace

int main() {
  test_b1_a_admission_only();
  test_b1_b_crypto_e5_alignment();
  test_b1_c_objects_diagnostic();
  test_b1_d_store_diagnostic();
  test_b1_e_release_settlement();
  std::cout << "PASS: L1 B1 unified offline contracts (" << total_checks
            << " checks)\n";
  return 0;
}
