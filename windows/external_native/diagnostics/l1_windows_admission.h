#ifndef SHIROHA_L1_WINDOWS_ADMISSION_H_
#define SHIROHA_L1_WINDOWS_ADMISSION_H_

#include "diagnostics/l1_crypto_admission.h"
#include <climits>

namespace shiroha_l1_crypto {
// Diagnostic ports only. No production wiring, JSON parser, environment reader,
// key material, path discovery or activation entry point exists here.
inline constexpr const char *kHumanApprovalBannerText =
    u8"\u672c\u64cd\u4f5c\u5c06\u6279\u51c6\u4e00\u6b21\u53d7\u9650\u7684 "
    u8"Windows "
    u8"\u5bc6\u7801\u5b66\u5b9e\u9a8c\u542f\u52a8\u5c1d\u8bd5\u3002\u5931\u8d25"
    u8"\u3001\u8d85\u65f6\u6216\u7ed3\u679c\u672a\u77e5\u5747\u4e0d\u81ea\u52a8"
    u8"\u91cd\u8bd5\u3002";

struct ObjectIdentityPin {
  uint64_t volume_serial = 0;
  std::array<uint8_t, 16> file_id{};
  bool valid() const noexcept {
    if (volume_serial == 0)
      return false;
    for (uint8_t b : file_id) {
      if (b != 0)
        return true;
    }
    return false;
  }
  bool operator==(const ObjectIdentityPin &other) const noexcept {
    return volume_serial == other.volume_serial && file_id == other.file_id;
  }
  bool operator!=(const ObjectIdentityPin &other) const noexcept {
    return !(*this == other);
  }
};

struct BatchObjectPins {
  ObjectIdentityPin dir_pin{};
  ObjectIdentityPin receipt_pin{};
  ObjectIdentityPin grant_pin{};
  bool valid() const noexcept {
    return dir_pin.valid() && receipt_pin.valid() && grant_pin.valid() &&
           dir_pin.volume_serial == receipt_pin.volume_serial &&
           dir_pin.volume_serial == grant_pin.volume_serial &&
           dir_pin.file_id != receipt_pin.file_id &&
           dir_pin.file_id != grant_pin.file_id &&
           receipt_pin.file_id != grant_pin.file_id;
  }
  bool operator==(const BatchObjectPins &other) const noexcept {
    return dir_pin == other.dir_pin && receipt_pin == other.receipt_pin &&
           grant_pin == other.grant_pin;
  }
};

class CanonicalHashBuilder {
public:
  void put_u8(uint8_t v) { bytes_.push_back(v); }
  void put_bool(bool v) { bytes_.push_back(v ? 1u : 0u); }
  void put_u16_le(uint16_t v) {
    bytes_.push_back(static_cast<uint8_t>(v & 0xffu));
    bytes_.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
  }
  void put_u32_le(uint32_t v) {
    for (unsigned i = 0; i < 4; ++i)
      bytes_.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xffu));
  }
  void put_u64_le(uint64_t v) {
    for (unsigned i = 0; i < 8; ++i)
      bytes_.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xffu));
  }
  void put_bytes(const uint8_t *data, size_t len) {
    put_u32_le(static_cast<uint32_t>(len));
    if (len > 0 && data)
      bytes_.insert(bytes_.end(), data, data + len);
  }
  void put_str(const std::string &s) {
    put_bytes(reinterpret_cast<const uint8_t *>(s.data()), s.size());
  }
  bool put_wstr_ascii(const std::wstring &ws) {
    if (ws.empty() || ws.size() > 256)
      return false;
    put_u32_le(static_cast<uint32_t>(ws.size()));
    for (wchar_t wc : ws) {
      if (wc < 0x20 || wc > 0x7e)
        return false;
      bytes_.push_back(static_cast<uint8_t>(wc & 0x7fu));
    }
    return true;
  }
  void finalize_raw(uint8_t out[32]) const noexcept {
    sha256_digest(bytes_.data(), bytes_.size(), out);
  }
  std::string finalize_hex() const {
    uint8_t digest[32]{};
    finalize_raw(digest);
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out(64, '0');
    for (size_t i = 0; i < 32; ++i) {
      out[i * 2] = kHex[(digest[i] >> 4) & 0x0fu];
      out[i * 2 + 1] = kHex[digest[i] & 0x0fu];
    }
    return out;
  }

private:
  std::vector<uint8_t> bytes_;
};

inline bool decode_hex_bytes(const std::string &hex, uint8_t *out,
                             size_t expected_bytes) noexcept {
  if (!out || hex.size() != expected_bytes * 2)
    return false;
  auto nibble = [](char c, uint8_t &val) noexcept -> bool {
    if (c >= '0' && c <= '9') {
      val = static_cast<uint8_t>(c - '0');
      return true;
    }
    if (c >= 'a' && c <= 'f') {
      val = static_cast<uint8_t>(10 + (c - 'a'));
      return true;
    }
    return false;
  };
  for (size_t i = 0; i < expected_bytes; ++i) {
    uint8_t hi = 0, lo = 0;
    if (!nibble(hex[i * 2], hi) || !nibble(hex[i * 2 + 1], lo))
      return false;
    out[i] = static_cast<uint8_t>((hi << 4) | lo);
  }
  return true;
}

inline std::string encode_hex_bytes(const uint8_t *data, size_t len) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out(len * 2, '0');
  for (size_t i = 0; i < len; ++i) {
    out[i * 2] = kHex[(data[i] >> 4) & 0x0fu];
    out[i * 2 + 1] = kHex[data[i] & 0x0fu];
  }
  return out;
}

struct PreApprovalValidation {
  bool structure_complete = false;
  bool reviewer_verifier_ready = false;
  bool user_already_marked_approved = false;
  bool valid_for_prompt() const noexcept {
    return structure_complete && reviewer_verifier_ready;
  }
};

inline PreApprovalValidation
evaluate_pre_approval_target(const GrantTarget &t) noexcept {
  PreApprovalValidation res{};
  res.user_already_marked_approved = t.user_approved;
  res.reviewer_verifier_ready =
      t.reviewer_approved && t.verifier_approved && safe_id(t.reviewer_id) &&
      safe_id(t.verifier_id) && hex_digest(t.review_sha256, 64) &&
      hex_digest(t.verification_sha256, 64);
  res.structure_complete = t.structure_complete();
  return res;
}

// Stage 1 Hash: Computable BEFORE human approval and BEFORE any batch file/dir
// is created. Never reads object_identity_sha256, FileId or user_approved.
inline bool compute_target_binding_sha256(const GrantTarget &target,
                                          const std::wstring &account_sid,
                                          std::string &out_hex64) noexcept {
  out_hex64.clear();
  if (!target.valid_pre_approval() || account_sid.empty())
    return false;
  try {
    CanonicalHashBuilder b;
    b.put_str("SHIROHA_L1_TARGET_HASH_V1");
    b.put_u32_le(1u);
    b.put_str(target.batch_id);
    b.put_str(target.device_id);
    b.put_str(target.account_identity_sha256);
    b.put_str(target.source_sha);
    b.put_str(target.base_sha);
    b.put_str(target.exe_sha256);
    b.put_str(target.dependency_manifest_sha256);
    b.put_str(target.compiler_id);
    b.put_str(target.os_id);
    b.put_str(target.toolchain_manifest_sha256);
    b.put_str(target.stop_owner);
    b.put_str(target.recovery_owner);
    b.put_str(target.evidence_owner);
    b.put_str(target.evidence_scope_id);
    b.put_str(target.reviewer_id);
    b.put_str(target.verifier_id);
    b.put_str(target.review_sha256);
    b.put_str(target.verification_sha256);
    b.put_str(target.user_approval_id);
    b.put_str(target.user_scope);
    b.put_bool(target.non_elevated);
    b.put_bool(target.reviewer_approved);
    b.put_bool(target.verifier_approved);
    b.put_bool(target.evidence_output_approved);
    b.put_u64_le(target.working_set_bytes);
    b.put_u64_le(target.commit_bytes);
    b.put_u32_le(target.handles);
    b.put_u64_le(target.window_start_ms);
    b.put_u64_le(target.window_end_ms);
    b.put_u64_le(target.max_execution_ms);
    for (unsigned limit : target.abi_limits) {
      b.put_u32_le(limit);
    }
    if (!b.put_wstr_ascii(account_sid))
      return false;
    out_hex64 = b.finalize_hex();
    return hex_digest(out_hex64, 64);
  } catch (...) {
    out_hex64.clear();
    return false;
  }
}

// Stage 2 Hash: Computable ONLY AFTER human approval and AFTER batch directory,
// approval.receipt and grant.bin are created and pinned by handle.
// Hard-stops if any FileId or VolumeSerialNumber is zero, missing or duplicate.
inline bool
compute_object_identity_sha256(const std::string &target_binding_sha256,
                               const BatchObjectPins &pins,
                               const std::string &account_identity_sha256,
                               std::string &out_hex64) noexcept {
  out_hex64.clear();
  if (!hex_digest(target_binding_sha256, 64) || !pins.valid() ||
      !hex_digest(account_identity_sha256, 64)) {
    return false;
  }
  try {
    CanonicalHashBuilder b;
    b.put_str("SHIROHA_L1_OBJECT_HASH_V1");
    b.put_u32_le(1u);
    b.put_str(target_binding_sha256);
    for (const auto *pin :
         {&pins.dir_pin, &pins.receipt_pin, &pins.grant_pin}) {
      b.put_u64_le(pin->volume_serial);
      b.put_bytes(pin->file_id.data(), pin->file_id.size());
    }
    b.put_str(account_identity_sha256);
    out_hex64 = b.finalize_hex();
    return hex_digest(out_hex64, 64);
  } catch (...) {
    out_hex64.clear();
    return false;
  }
}

struct WindowsBinding {
  GrantTarget target;
  // Exact SID stays internal; evidence uses target.account_identity_sha256.
  std::wstring account_sid;
  std::string object_identity_sha256;
  bool primary_medium_token = false, unexpected_privileges = true;
  bool protected_object = false, parent_chain_pinned = false;
  bool reparse = true, owner_matches = false, device_matches = false;
  bool artifact_pinned = false, dependencies_pinned = false;
  bool isolated_environment = false, explicit_handle_list = false;
  bool matches(const WindowsBinding &approved) const noexcept {
    return target.valid() && target.identity() == approved.target.identity() &&
           !account_sid.empty() && account_sid == approved.account_sid &&
           hex_digest(object_identity_sha256, 64) &&
           object_identity_sha256 == approved.object_identity_sha256 &&
           primary_medium_token && !unexpected_privileges && protected_object &&
           parent_chain_pinned && !reparse && owner_matches && device_matches &&
           artifact_pinned && dependencies_pinned && isolated_environment &&
           explicit_handle_list;
  }
};

struct ConsumptionRecord {
  bool persisted_issuance = false;
  bool request_started = false;
  bool confirmed = false;
  bool unknown = false;
  GrantState state = GrantState::kUnissued;
};

struct WorkerObservation {
  WindowsBinding binding;
  bool authenticated = false, observer_healthy = false;
  bool exit_observed = false, normal_exit = false, logs_complete = false;
};

class WindowsOperations {
 public:
  virtual ~WindowsOperations() = default;
  // Independent authority must verify the complete immutable target, exact SID
  // and object pin. user_approved/reviewer_approved booleans alone never
  // suffice.
  virtual bool trusted_approval(const WindowsBinding &) noexcept = 0;
  virtual bool inspect(WindowsBinding &) noexcept = 0;
  virtual bool now(uint64_t &) noexcept = 0;
  // One atomic, durable request-start reservation across all consumers, BEFORE
  // examining/consuming the E2 cell. UNKNOWN permanently quarantines the batch.
  // Copies of object bytes without the external identity/journal are invalid.
  virtual ConsumptionRecord consume_once(const WindowsBinding &,
                                         uint64_t) noexcept = 0;
  // No caller-provided command line/environment. Any future implementation must
  // create suspended, inspect the actual image/token, authenticate IPC, and
  // only then resume. No retry/kill API is intentionally exposed.
  virtual WorkerState start_worker(const WindowsBinding &) noexcept = 0;
  virtual WorkerObservation observe_worker() noexcept = 0;
};

struct WindowsAdmissionEvidence {
  const char *evidence_class = "OFFLINE";
  const char *os_backend = "FAKE";
  ConsumptionRecord consumption;
  OfflineEvidence observation;
  std::string dependency_sha256, toolchain_sha256, account_sha256;
  std::string object_identity_sha256;
  bool start_request_started = false, identity_verified = false;
  bool worker_identity_verified = false;
  bool normal_exit_observed = false;
  bool logs_complete = false, stop_requested = false;
  OfflineVerdict verifier = OfflineVerdict::kNotRun;
  OfflineVerdict reviewer = OfflineVerdict::kNotRun;
  const char *recovery = "NOT_AUTHORIZED";
};

// Reuses the E2 Supervisor/GrantTarget/crypto ledger; this adapter only
// supplies OS observations and maps durable consumption to E2's one-time
// admission seam.
// One controller serializes all methods and its Operations observations. Future
// IPC must dispatch EXIT/STOP/SAMPLE into that same serialized event boundary.
// This object is not a concurrent event queue or a cross-process one-use proof.
class WindowsAdmissionCandidate {
 public:
  explicit WindowsAdmissionCandidate(WindowsOperations &ops) : ops_(ops) {}
  WindowsAdmissionCandidate(const WindowsAdmissionCandidate &) = delete;
  WindowsAdmissionCandidate &operator=(const WindowsAdmissionCandidate &) =
      delete;
  WindowsAdmissionCandidate(WindowsAdmissionCandidate &&) = delete;
  WindowsAdmissionCandidate &operator=(WindowsAdmissionCandidate &&) = delete;
  bool admit(const WindowsBinding &approved, const std::string &trial) {
    if (terminal() || attempted_) return false;
    attempted_ = true;
    uint64_t now_ms = 0;
    WindowsBinding observed;
    if (!approved.matches(approved) || !safe_id(trial) ||
        !ops_.trusted_approval(approved) || !ops_.inspect(observed) ||
        !observed.matches(approved) || !ops_.now(now_ms)) {
      refuse(StopReason::kAdmission);
      return false;
    }
    approved_ = approved;
    struct Consumer {
      WindowsOperations &ops;
      const WindowsBinding &binding;
      ConsumptionRecord &record;
      bool consume(const GrantTarget &, uint64_t at) noexcept {
        record = ops.consume_once(binding, at);
        return record.persisted_issuance && record.request_started &&
               record.confirmed && !record.unknown &&
               record.state == GrantState::kConsumed;
      }
    } consumer{ops_, approved_, evidence_.consumption};
    if (!supervisor_.admit(consumer, observed.target, now_ms, trial)) {
      blocked_ = true;
      return false;
    }
    evidence_.identity_verified = true;
    evidence_.dependency_sha256 = approved.target.dependency_manifest_sha256;
    evidence_.toolchain_sha256 = approved.target.toolchain_manifest_sha256;
    evidence_.account_sha256 = approved.target.account_identity_sha256;
    evidence_.object_identity_sha256 = approved.object_identity_sha256;
    return true;
  }
  bool start() noexcept {
    if (blocked_ || supervisor_.state() != SupervisorState::kGrantConsumed)
      return false;
    uint64_t at = 0;
    WindowsBinding observed;
    if (!ops_.now(at) || !ops_.inspect(observed) ||
        !observed.matches(approved_) || at < approved_.target.window_start_ms ||
        at >= approved_.target.window_end_ms ||
        approved_.target.window_end_ms - at < 30000) {
      refuse(StopReason::kLaunch);
      return false;
    }
    // Record independently BEFORE the OS port is entered (including failure).
    evidence_.start_request_started = true;
    if (!supervisor_.begin_launch_attempt(at)) return false;
    auto started = ops_.start_worker(approved_);
    if (started == WorkerState::kRunning) {
      const auto worker = ops_.observe_worker();
      if (!worker.authenticated || !worker.observer_healthy ||
          !worker.binding.matches(approved_)) {
        started = WorkerState::kUnknown;
      } else {
        evidence_.worker_identity_verified = true;
      }
    }
    if (!supervisor_.confirm_launch(started)) {
      blocked_ = true;
      evidence_.stop_requested = true;
      return false;
    }
    return true;
  }
  bool poll(NativeObservation &native) noexcept {
    if (blocked_ || !evidence_.start_request_started || terminal())
      return false;
    uint64_t at = 0;
    const auto worker = ops_.observe_worker();
    const bool healthy = ops_.now(at) && worker.observer_healthy &&
                         worker.authenticated &&
                         worker.binding.matches(approved_);
    const bool within_deadline = supervisor_.poll(at, healthy);
    if (healthy) accept_exit(worker, at, native);
    if (!within_deadline || native.stopped || native.unknown ||
        native.quarantined) {
      latch_stop(native);
      return false;
    }
    // Exit is sticky even if a later observation lacks its earlier exit flag.
    // A normal exit closes work without manufacturing a Native failure/settle.
    if (supervisor_.evidence().process_exit_observed) return false;
    return supervisor_.admission_open(at);
  }
  bool sample(const ResourceSample &sample,
              NativeObservation &native) noexcept {
    if (terminal() || !poll(native)) return false;
    if (!supervisor_.sample(sample)) {
      latch_stop(native);
      return false;
    }
    return true;
  }
  void settle(const L1CryptoLedger &ledger,
              NativeObservation &native) noexcept {
    if (blocked_ || !evidence_.start_request_started || terminal()) return;
    poll(native);
    uint64_t at = 0;
    const auto worker = ops_.observe_worker();
    const bool healthy = ops_.now(at) && worker.observer_healthy &&
                         worker.authenticated &&
                         worker.binding.matches(approved_);
    evidence_.logs_complete = worker.logs_complete;
    if (!healthy || !worker.logs_complete) {
      supervisor_.poll(at, false);
      latch_stop(native);
    } else {
      accept_exit(worker, at, native);
    }
    supervisor_.begin_settlement();
    supervisor_.settle(at,
                       healthy && supervisor_.evidence().process_exit_observed,
                       ledger, native);
  }
  void request_stop(NativeObservation &native) noexcept { latch_stop(native); }
  SupervisorState state() const noexcept {
    if (supervisor_.state() == SupervisorState::kSettlementUnknown)
      return SupervisorState::kSettlementUnknown;
    return blocked_ ? SupervisorState::kBlocked : supervisor_.state();
  }
  WindowsAdmissionEvidence evidence() const {
    auto result = evidence_;
    result.observation = supervisor_.evidence();
    if (blocked_ && result.observation.verdict != OfflineVerdict::kUnknown)
      result.observation.verdict = evidence_.consumption.unknown
                                       ? OfflineVerdict::kUnknown
                                       : OfflineVerdict::kInconclusive;
    return result;
  }

 private:
  bool terminal() const noexcept { return supervisor_terminal(state()); }
  void accept_exit(const WorkerObservation &worker, uint64_t at,
                   NativeObservation &native) noexcept {
    if (terminal() || !worker.exit_observed ||
        supervisor_.evidence().process_exit_observed)
      return;
    supervisor_.observe_worker_exit(at);
    if (!supervisor_.evidence().process_exit_observed) return;
    evidence_.normal_exit_observed = worker.normal_exit;
    if (!worker.normal_exit) latch_stop(native);
  }
  // Fail-closed refusal for adapter-detected invalid approval/identity/
  // observation or a failed launch preflight: the E2 Supervisor latches the
  // first causal StopReason and freezes the terminal BLOCKED result. A
  // pre-consumption refusal leaves the grant unconsumed; a post-consume
  // pre-launch refusal keeps the consumed grant consumed without a second
  // consumption. Neither starts a Worker or restarts anything, and an already
  // terminal cause/snapshot is never overwritten.
  void refuse(StopReason reason) noexcept {
    if (terminal()) return;
    supervisor_.refuse(reason);
    blocked_ = true;
    evidence_.stop_requested = true;
  }
  void latch_stop(NativeObservation &native) noexcept {
    if (terminal()) return;
    evidence_.stop_requested = true;
    supervisor_.worker_failed();
    // Cross-defense: a Supervisor stop forbids subsequent native business work;
    // original RAII releases stay legal. Never manufacture call settlement.
    native.fail("supervisor_stop");
  }
  WindowsOperations &ops_;
  WindowsBinding approved_;
  OfflineSupervisor supervisor_;
  WindowsAdmissionEvidence evidence_;
  bool attempted_ = false, blocked_ = false;
};
}  // namespace shiroha_l1_crypto
#endif
