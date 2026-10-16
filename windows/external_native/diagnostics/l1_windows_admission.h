#ifndef SHIROHA_L1_WINDOWS_ADMISSION_H_
#define SHIROHA_L1_WINDOWS_ADMISSION_H_

#include "diagnostics/l1_crypto_admission.h"

namespace shiroha_l1_crypto {
// Diagnostic ports only. No production wiring, JSON parser, environment reader,
// key material, path discovery or activation entry point exists here.
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
