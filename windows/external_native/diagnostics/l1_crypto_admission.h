#ifndef SHIROHA_L1_CRYPTO_ADMISSION_H_
#define SHIROHA_L1_CRYPTO_ADMISSION_H_

#include "diagnostics/l1_crypto_probe.h"
#include <tuple>

namespace shiroha_l1_crypto {
// Pure OFFLINE model, not a Windows identity provider or runtime permission.
inline constexpr bool kRealExecutionAuthorized = false;
inline bool safe_id(const std::string &value) noexcept {
  if (value.empty() || value.size() > 80) return false;
  for (char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'))
      return false;
  }
  return true;
}
inline bool hex_digest(const std::string &value, size_t size) noexcept {
  if (value.size() != size) return false;
  for (char c : value)
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  return true;
}

struct GrantTarget {
  std::string batch_id, device_id, account_identity_sha256;
  std::string source_sha, base_sha, exe_sha256, dependency_manifest_sha256;
  std::string compiler_id, os_id, toolchain_manifest_sha256;
  std::string stop_owner, recovery_owner, evidence_owner, evidence_scope_id;
  std::string reviewer_id, verifier_id, review_sha256, verification_sha256;
  std::string user_approval_id, user_scope;
  bool non_elevated = false, reviewer_approved = false,
       verifier_approved = false;
  bool evidence_output_approved = false, user_approved = false;
  uint64_t working_set_bytes = 0, commit_bytes = 0;
  uint32_t handles = 0;
  uint64_t window_start_ms = 0, window_end_ms = 0;
  uint64_t max_execution_ms = 30000;
  std::array<unsigned, 7> abi_limits = {1, 3, 3, 6, 3, 45, 45};
  auto identity() const noexcept {
    return std::tie(
        batch_id, device_id, account_identity_sha256, source_sha, base_sha,
        exe_sha256, dependency_manifest_sha256, compiler_id, os_id,
        toolchain_manifest_sha256, stop_owner, recovery_owner, evidence_owner,
        evidence_scope_id, reviewer_id, verifier_id, review_sha256,
        verification_sha256, user_approval_id, user_scope, non_elevated,
        reviewer_approved, verifier_approved, evidence_output_approved,
        user_approved, working_set_bytes, commit_bytes, handles,
        window_start_ms, window_end_ms, max_execution_ms, abi_limits);
  }
  bool valid() const noexcept {
    for (const auto *id :
         {&batch_id, &device_id, &compiler_id, &os_id, &stop_owner,
          &recovery_owner, &evidence_owner, &evidence_scope_id, &reviewer_id,
          &verifier_id, &user_approval_id})
      if (!safe_id(*id)) return false;
    for (const auto *sha :
         {&account_identity_sha256, &exe_sha256, &dependency_manifest_sha256,
          &toolchain_manifest_sha256, &review_sha256, &verification_sha256})
      if (!hex_digest(*sha, 64)) return false;
    constexpr std::array<unsigned, 7> limits = {1, 3, 3, 6, 3, 45, 45};
    return hex_digest(source_sha, 40) && hex_digest(base_sha, 40) &&
           user_scope == "L1-CRYPTO" && non_elevated && reviewer_approved &&
           verifier_approved && evidence_output_approved && user_approved &&
           working_set_bytes && commit_bytes && handles &&
           abi_limits == limits && max_execution_ms == 30000 &&
           window_end_ms > window_start_ms &&
           window_end_ms - window_start_ms >= max_execution_ms;
  }
};

enum class GrantState {
  kUnissued,
  kIssued,
  kConsumed,
  kExpired,
  kMismatch,
  kUnknown,
  kRejected
};
// One storage cell models an atomic conditional consume, without file I/O.
// Cloning/restarting this Fake does NOT prove durable or cross-process one-use.
class FakeGrantCell {
 public:
  bool issue(const GrantTarget &target) {
    if (state_ != GrantState::kUnissued) return false;
    if (!target.valid()) {
      state_ = GrantState::kRejected;
      return false;
    }
    target_ = target;
    state_ = GrantState::kIssued;
    return true;
  }
  bool consume(const GrantTarget &observed, uint64_t now_ms,
               bool simulate_unknown_write = false) noexcept {
    if (state_ != GrantState::kIssued) return false;
    ++consumption_attempts_;
    // Reservation precedes launch, validation side effects or a lost receipt.
    state_ = GrantState::kConsumed;
    if (simulate_unknown_write) {
      state_ = GrantState::kUnknown;
      return false;
    }
    if (!observed.valid() || observed.identity() != target_.identity()) {
      state_ = GrantState::kMismatch;
      return false;
    }
    if (now_ms < target_.window_start_ms || now_ms >= target_.window_end_ms ||
        target_.window_end_ms - now_ms < target_.max_execution_ms) {
      state_ = GrantState::kExpired;
      return false;
    }
    return true;
  }
  GrantState state() const noexcept { return state_; }
  unsigned consumption_attempts() const noexcept {
    return consumption_attempts_;
  }

 private:
  GrantState state_ = GrantState::kUnissued;
  unsigned consumption_attempts_ = 0;
  GrantTarget target_{};
};

enum class SupervisorState {
  kNotStarted,
  kAdmitted,
  kGrantConsumed = kAdmitted,
  kStartAttempted,
  kRunning,
  kSettling,
  kComplete,
  kStopRequested,
  kDeadlineExceeded,
  kSettlementUnknown,
  kBlocked
};
// Deadline/STOP/settling retain owning cleanup; only these final results
// freeze.
inline bool supervisor_terminal(SupervisorState state) noexcept {
  return state == SupervisorState::kComplete ||
         state == SupervisorState::kSettlementUnknown ||
         state == SupervisorState::kBlocked;
}
enum class OfflineVerdict { kNotRun, kPass, kFail, kUnknown, kInconclusive };
enum class StopReason {
  kNone,
  kAdmission,
  kLaunch,
  kDeadline,
  kMeasurement,
  kBudget,
  kWorker,
  kSettlement
};
enum class WorkerState {
  kNotStarted,
  kStartAttempted,
  kStartFailed,
  kRunning,
  kExitObserved,
  kUnknown
};

struct ResourceSample {
  uint64_t observed_at_ms = 0, peak_working_set = 0, peak_commit = 0;
  uint32_t handles = 0, completed_calls = 0;
};
// Evidence contains public digests/safe IDs only; no caller-supplied raw log or
// exception text, buffers, keys, certificates, environment or pathname fields.
struct OfflineEvidence {
  const char *evidence_class = "OFFLINE";
  std::string batch_id, trial_id, source_sha, base_sha, artifact_sha256;
  std::string environment_id, reviewer_id, verifier_id, review_sha256,
      verification_sha256;
  std::array<CallCounts, 7> abi{};
  NativeObservation native{};
  unsigned buffers_acquired = 0, buffers_live = 0;
  std::array<ResourceSample, 18> samples{};
  unsigned sample_count = 0;
  WorkerState worker_state = WorkerState::kNotStarted;
  unsigned completed_native_calls = 0;
  uint64_t launch_attempt_ms = 0, process_end_ms = 0;
  bool process_exit_observed = false, deadline_exceeded = false;
  bool settlement_incomplete = true;
  StopReason first_failure = StopReason::kNone;
  OfflineVerdict verdict = OfflineVerdict::kNotRun;
  // Sampled handle maxima miss short-lived CNG handles; OS internals, physical
  // pagefile I/O and native TLS heap accounting are outside this observation.
  bool sampled_handles_only = true, windows_internals_observable = false;
};

// An independent observer drives these events in Fake tests. No spawn, IPC,
// time source, cancellation, termination, restart or real worker adapter
// exists.
class OfflineSupervisor {
 public:
  template <typename GrantConsumer>
  bool admit(GrantConsumer &cell, const GrantTarget &observed, uint64_t now_ms,
             const std::string &trial_id) {
    if (state_ != SupervisorState::kNotStarted) return false;
    if (!safe_id(trial_id) || !cell.consume(observed, now_ms)) {
      stop(StopReason::kAdmission, SupervisorState::kBlocked);
      return false;
    }
    target_ = observed;
    last_ms_ = now_ms;
    evidence_.batch_id = observed.batch_id;
    evidence_.trial_id = trial_id;
    evidence_.source_sha = observed.source_sha;
    evidence_.base_sha = observed.base_sha;
    evidence_.artifact_sha256 = observed.exe_sha256;
    evidence_.environment_id = observed.device_id;
    evidence_.reviewer_id = observed.reviewer_id;
    evidence_.verifier_id = observed.verifier_id;
    evidence_.review_sha256 = observed.review_sha256;
    evidence_.verification_sha256 = observed.verification_sha256;
    state_ = SupervisorState::kAdmitted;
    return true;
  }
  bool begin_launch_attempt(uint64_t now_ms) noexcept {
    if (state_ != SupervisorState::kAdmitted || !time(now_ms)) return false;
    evidence_.launch_attempt_ms = now_ms;
    evidence_.worker_state = WorkerState::kStartAttempted;
    state_ = SupervisorState::kStartAttempted;
    started_ = true;
    if (now_ms >= target_.window_end_ms ||
        target_.window_end_ms - now_ms < target_.max_execution_ms) {
      stop(StopReason::kLaunch, SupervisorState::kBlocked);
      evidence_.worker_state = WorkerState::kStartFailed;
      return false;
    }
    return true;
  }
  bool confirm_launch(WorkerState result) noexcept {
    if (state_ != SupervisorState::kStartAttempted) return false;
    if (result == WorkerState::kUnknown) {
      stop(StopReason::kLaunch, SupervisorState::kSettlementUnknown);
      evidence_.worker_state = WorkerState::kUnknown;
      evidence_.verdict = OfflineVerdict::kUnknown;
      return false;
    }
    if (result != WorkerState::kRunning) {
      stop(StopReason::kLaunch, SupervisorState::kBlocked);
      evidence_.worker_state = WorkerState::kStartFailed;
      return false;
    }
    state_ = SupervisorState::kRunning;
    evidence_.worker_state = WorkerState::kRunning;
    return true;
  }
  bool launch_attempt(uint64_t now_ms, bool fake_started) noexcept {
    return begin_launch_attempt(now_ms) &&
           confirm_launch(fake_started ? WorkerState::kRunning
                                       : WorkerState::kStartFailed);
  }
  bool admission_open(uint64_t now_ms) noexcept {
    if (!poll(now_ms, true)) return false;
    return state_ == SupervisorState::kRunning &&
           evidence_.first_failure == StopReason::kNone;
  }
  bool poll(uint64_t now_ms, bool monitor_healthy) noexcept {
    if (supervisor_terminal(state_) || state_ == SupervisorState::kNotStarted)
      return false;
    if (!monitor_healthy || !time(now_ms)) {
      stop(StopReason::kMeasurement, SupervisorState::kStopRequested);
      return false;
    }
    // Unified inclusive deadline (>=), matching L1CryptoLedger::check_clock:
    // the 30-second execution clock counts from the recorded process-start
    // attempt (launch_attempt) and closes exactly at max_execution_ms.
    if (started_ &&
        now_ms - evidence_.launch_attempt_ms >= target_.max_execution_ms) {
      evidence_.deadline_exceeded = true;
      stop(StopReason::kDeadline, SupervisorState::kDeadlineExceeded);
      return false;
    }
    return evidence_.first_failure == StopReason::kNone;
  }
  bool sample(const ResourceSample &sample,
              bool measurement_ok = true) noexcept {
    if (state_ != SupervisorState::kRunning &&
        state_ != SupervisorState::kSettling)
      return false;
    if (!poll(sample.observed_at_ms, measurement_ok)) return false;
    if (evidence_.sample_count >= evidence_.samples.size() ||
        !sample.peak_working_set || !sample.peak_commit || !sample.handles ||
        sample.completed_calls !=
            (evidence_.sample_count == 17 ? 16 : evidence_.sample_count) ||
        (evidence_.sample_count &&
         (sample.peak_working_set <
              evidence_.samples[evidence_.sample_count - 1].peak_working_set ||
          sample.peak_commit <
              evidence_.samples[evidence_.sample_count - 1].peak_commit))) {
      stop(StopReason::kMeasurement, SupervisorState::kStopRequested);
      return false;
    }
    evidence_.samples[evidence_.sample_count++] = sample;
    if (sample.peak_working_set > target_.working_set_bytes ||
        sample.peak_commit > target_.commit_bytes ||
        sample.handles > target_.handles) {
      stop(StopReason::kBudget, SupervisorState::kStopRequested);
      return false;
    }
    return true;
  }
  void worker_failed() noexcept {
    stop(StopReason::kWorker, SupervisorState::kStopRequested);
  }
  void observe_worker_exit(uint64_t now_ms) noexcept {
    if (supervisor_terminal(state_) || !started_ ||
        evidence_.process_exit_observed || !time(now_ms))
      return;
    evidence_.process_exit_observed = true;
    evidence_.worker_state = WorkerState::kExitObserved;
    evidence_.process_end_ms = now_ms;
    begin_settlement();
  }
  void begin_settlement() noexcept {
    if (started_ && !supervisor_terminal(state_))
      state_ = SupervisorState::kSettling;
  }
  // Observer records, not worker exit=0 or a worker-provided PASS string.
  void settle(uint64_t now_ms, bool observed_exit, const L1CryptoLedger &ledger,
              const NativeObservation &native) noexcept {
    if (!started_ || supervisor_terminal(state_)) return;
    poll(now_ms, true);
    evidence_.abi = ledger.abi_calls;
    evidence_.native = native;
    evidence_.buffers_acquired = ledger.buffers_allocated;
    evidence_.buffers_live = ledger.buffers_live;
    if (observed_exit && !evidence_.process_exit_observed) {
      evidence_.process_exit_observed = true;
      evidence_.process_end_ms = now_ms;
    }
    evidence_.worker_state = evidence_.process_exit_observed
                                 ? WorkerState::kExitObserved
                                 : WorkerState::kUnknown;
    evidence_.completed_native_calls = ledger.completed;
    bool unresolved = !evidence_.process_exit_observed || native.unknown ||
                      native.still_owned || native.quarantined ||
                      native.acquired != native.released ||
                      ledger.settlement_unknown;
    bool exact =
        ledger.abi_attempted_total == 106 && ledger.attempted == 16 &&
        ledger.returned == 16 && ledger.completed == 16 &&
        ledger.accepted == 16 && ledger.successful == 12 &&
        ledger.buffers_allocated == 45 && ledger.releases_attempted == 45 &&
        ledger.releases_succeeded == 45 && !ledger.duplicate_release_attempts &&
        !ledger.forbidden_symbol_attempts && !ledger.observation_failures &&
        ledger.samples == 18 && !ledger.stopped && native.complete();
    for (const auto &count : native.calls)
      unresolved = unresolved || count.unknown ||
                   count.returned != count.attempted ||
                   count.settled != count.attempted;
    for (size_t i = 0; i < evidence_.abi.size(); ++i) {
      const auto &count = evidence_.abi[i];
      unresolved = unresolved || count.unknown ||
                   count.returned != count.attempted ||
                   count.settled != count.attempted;
      exact = exact && count.attempted == target_.abi_limits[i] &&
              count.accepted == count.attempted;
    }
    unresolved = unresolved || ledger.buffers_live || ledger.releases_unknown;
    evidence_.settlement_incomplete = unresolved;
    if (unresolved) {
      stop(StopReason::kSettlement, SupervisorState::kSettlementUnknown);
      evidence_.verdict = OfflineVerdict::kUnknown;
      return;
    }
    state_ = SupervisorState::kComplete;
    if (evidence_.first_failure == StopReason::kMeasurement)
      evidence_.verdict = OfflineVerdict::kInconclusive;
    else if (evidence_.first_failure != StopReason::kNone || !exact ||
             evidence_.sample_count != 18)
      evidence_.verdict = OfflineVerdict::kFail;
    else
      evidence_.verdict = OfflineVerdict::kPass;
  }
  SupervisorState state() const noexcept { return state_; }
  const OfflineEvidence &evidence() const noexcept { return evidence_; }

 private:
  bool time(uint64_t now_ms) noexcept {
    if (now_ms < last_ms_) {
      stop(StopReason::kMeasurement, SupervisorState::kStopRequested);
      return false;
    }
    last_ms_ = now_ms;
    return true;
  }
  void stop(StopReason reason, SupervisorState state) noexcept {
    if (supervisor_terminal(state_)) return;
    if (evidence_.first_failure == StopReason::kNone)
      evidence_.first_failure = reason;
    state_ = state;
  }
  GrantTarget target_{};
  OfflineEvidence evidence_{};
  SupervisorState state_ = SupervisorState::kNotStarted;
  uint64_t last_ms_ = 0;
  bool started_ = false;
};
}  // namespace shiroha_l1_crypto
#endif
